#!/bin/bash
# hibdbg - find and silence what keeps Synology disks awake. Run as root.
set -eu

# sudo PATH on DSM lacks /usr/bin (pgrep, etc.)
export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

# recordings must not land on md0 (8G, fills up); home sits on a volume
RECBASE=$(dirname "$(readlink -f "$0")")
SLEEPLOG=$RECBASE/sleepd.log
WLOG=$RECBASE/watch.log
WMODE=$RECBASE/.watch_mode
WMARK=$RECBASE/.watch_mark
WGEN=$RECBASE/.watch_gen
RUNDIR=/run/hibdbg
WPID=$RUNDIR/watch.pid
SPID=$RUNDIR/sleepd.pid

die() { echo "$*" >&2; exit 1; }

num() { case "$1" in ''|*[!0-9]*) die "$2: expected a number, got '$1'" ;; esac; }

denoise() { grep -vE 'ppid:[0-9]+\(syno_hibernatio' || true; }

# daemon liveness via pidfile: /run clears at boot (no stale files survive a
# reboot); the cmdline check guards against pid reuse
alive() { # alive PIDFILE TAG -> prints the pid; fails if not running
	local pid
	pid=$(cat "$1" 2>/dev/null) || return 1
	grep -qa "$2" "/proc/$pid/cmdline" 2>/dev/null || return 1
	echo "$pid"
}

# the queue names a thread; /proc names the app. Reads only /proc, so it costs
# no volume I/O and can run while the drives are still spinning up.
whois() { # whois PID -> "cmd < parent(ppid) [docker <id>]", empty if pid is gone
	local pid=$1 cmd ppid out cid
	[ -d "/proc/$pid" ] || return 0
	# stat field 4 is ppid, but the comm in field 2 may hold spaces
	ppid=$(sed -E 's/.*\) [A-Za-z] //' "/proc/$pid/stat" 2>/dev/null | awk '{print $1}')
	cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-60)
	# kernel threads have an empty cmdline
	out="${cmd:-[$(cat "/proc/$pid/comm" 2>/dev/null)]}"
	if [ -n "${ppid:-}" ] && [ "$ppid" != 0 ]; then
		out="$out < $(cat "/proc/$ppid/comm" 2>/dev/null)($ppid)"
	fi
	cid=$(sed -nE 's|.*/docker[-/]([0-9a-f]{12}).*|\1|p' "/proc/$pid/cgroup" 2>/dev/null | head -1)
	echo "${out}${cid:+ [docker $cid]}"
}

# nfsd is a kernel thread: the requester is a remote host, named by the live
# connections, or failing those by who the export admits at all
nfs_peers() {
	local peers
	peers=$(netstat -tn 2>/dev/null | awk '$4 ~ /:2049$/ {sub(/:[0-9]+$/,"",$5); print $5}' | sort -u)
	if [ -n "$peers" ]; then
		echo "$peers" | tr '\n' ' '
	else
		awk '$1 ~ /^\// {printf "%s(%s) ", $1, $2}' /proc/fs/nfs/exports 2>/dev/null
	fi
}

devnum() { # kernel dev_t of a block device node (maj<<20|min)
	local maj min
	IFS=: read -r maj min <<< "$(stat -Lc '%t:%T' "$1" 2>/dev/null)"
	echo $(( 0x${maj:-0} * 1048576 + 0x${min:-0} ))
}

hdd_dms() {
	local d name deps sub md
	for d in /sys/block/dm-*; do
		name=$(cat "$d/dm/name")
		deps=$(dmsetup deps -o devname "$name" 2>/dev/null)
		while :; do
			case "$deps" in
			*md*)
				md=$(echo "$deps" | grep -o 'md[0-9]*' | head -1)
				if ls -l "/sys/block/$md/slaves" 2>/dev/null | grep -q sata; then
					basename "$d"
				fi
				break ;;
			*)
				sub=$(echo "$deps" | grep -oE '\((dm-[0-9]+|[a-z_0-9-]+)\)' | tr -d '()' | head -1)
				[ -n "$sub" ] || break
				deps=$(dmsetup deps -o devname "$sub" 2>/dev/null) || break ;;
			esac
		done
	done | sort -u
}

agg_proc() { sed -E 's/.*pid:[0-9]+\(([^)]*)\), (READ|WRITE|dirtied).*/\1 \2/' | sort | uniq -c | sort -rn || true; }
agg_path() { grep dirtied | sed -E 's/.*dirtied (subvolume [0-9]+ )?inode [0-9]+ \(([^)]*)\).*/\2/' | sort | uniq -c | sort -rn || true; }

# event filter matching all sata whole-disk queues (kernel dev_t = maj<<20|min)
rqfilter() {
	local d maj min f=""
	for d in /sys/block/sata[0-9]*; do
		IFS=: read -r maj min < "$d/dev"
		f="${f:+$f || }dev == $((maj*1048576+min))"
	done
	echo "$f"
}

# single-pass aggregation: a queue-command storm makes block.log too big to sort
rq_agg() { sed -E 's/.*block_rq_issue: ([0-9]+,[0-9]+) ([A-Z]*).*\[([^]]*)\]$/\1 \2 \3/' \
	| awk '{n[$0]++} END{for(k in n) printf "%7d %s\n", n[k], k}' | sort -rn; }

# HDD-backed mounted filesystems, one "device mountpoint fstype" per line
hdd_mnts() {
	local d
	{ for d in $(hdd_dms); do echo "/dev/mapper/$(cat "/sys/block/$d/dm/name")"; done
	  for d in /sys/block/md*; do
		ls "$d/slaves" 2>/dev/null | grep -q sata && echo "/dev/$(basename "$d")"
	  done; } | grep -Ff - /proc/mounts \
	| awk '!seen[$1]++ {print $1, $2, $3}' || true
	# one mount per device: bind mounts (ContainerManager all_shares) list the
	# same fs again under an alias path; the first mount is the real one
}

# event filter matching those filesystems, for the page-cache tracepoint
fmfilter() {
	local dev mnt fst f=""
	while read -r dev mnt fst; do
		f="${f:+$f || }s_dev == $(devnum "$dev")"
	done < <(hdd_mnts)
	echo "$f"
}

# fs hooks, dispatched on fstype: fsmark_<fs> prints a cheap change cursor,
# fsdiff_<fs> MNT CUR prints the paths changed since it (the write side), and
# fsino_<fs> MNT INO names an inode (the read side). A filesystem without them
# gets no file attribution (the generic headline).
fsmark_btrfs() { # fs-wide transid; a huge gen lists nothing, just the marker
	btrfs subvolume find-new "$1" 9999999999 2>/dev/null | tail -1 | awk '{print $NF}'
}
fsdiff_btrfs() { # find-new does not recurse: also diff each share subvolume
	# (a subvolume root is always inode 256); RO snapshots error out silently
	local mnt=$1 gen=$2 d
	for d in "$mnt" "$mnt"/*/; do
		d=${d%/}
		[ "$(stat -c %i "$d" 2>/dev/null)" = 256 ] || continue
		btrfs subvolume find-new "$d" "$gen" 2>/dev/null \
		| awk -v m="$d" '$1=="inode" {
			# the path is everything after the fixed fields: $NF would
			# truncate filenames containing spaces to their last word
			sub(/^inode [0-9]+ file offset [0-9]+ len [0-9]+ disk start [0-9]+ offset [0-9]+ gen [0-9]+ flags [^ ]+ /, "")
			print m"/"$0
		}'
	done
}

fsino_btrfs() { # first path holding the inode; backrefs, no tree walk
	btrfs inspect-internal inode-resolve "$2" "$1" 2>/dev/null | head -1
}

fs_mark() { # refresh cursors; caller guarantees every drive is spinning
	hdd_mnts | while read -r dev mnt fst; do
		declare -F "fsmark_$fst" >/dev/null || continue
		echo "$mnt $fst $("fsmark_$fst" "$mnt")"
	done > "$WGEN"
}
fs_diff() { # paths changed since the recorded cursors
	[ -f "$WGEN" ] || return 0
	while read -r mnt fst cur; do
		[ -n "${cur:-}" ] || continue
		"fsdiff_$fst" "$mnt" "$cur"
	done < "$WGEN" | sort -u
}

# reads that reach a sleeping disk are page-cache misses by definition, so the
# filemap tracepoint sees every one: it names the reader and the inode, which
# the fs hook turns into a path
fs_reads() { # fs_reads TRACEFILE -> "comm path" per distinct inode read
	local map dev mnt fst comm maj min ino hit p
	# dev_t -> mount, resolved once: the trace identifies the fs by number
	map=$(hdd_mnts | while read -r dev mnt fst; do
		echo "$(devnum "$dev") $mnt $fst"
	done)
	sed -nE 's/^ *(.+)-[0-9]+ .*mm_filemap_add_to_page_cache: dev ([0-9]+):([0-9]+) ino ([0-9a-f]+).*/\1 \2 \3 \4/p' \
		"$1" 2>/dev/null | sort -u | head -20 \
	| while read -r comm maj min ino; do
		hit=$(echo "$map" | awk -v d=$((maj*1048576+min)) '$1==d {print; exit}')
		[ -n "$hit" ] || continue
		fst=${hit##* }
		mnt=${hit#* }; mnt=${mnt% *}
		declare -F "fsino_$fst" >/dev/null || continue
		p=$("fsino_$fst" "$mnt" $((0x$ino)))
		if [ -n "$p" ]; then echo "$comm $p"; fi
	done
}

# parent chains for COMM execs found in a fork/exec trace file
forkchain() {
	local f=$1 c=$2 pids pid pline pn pp gline gn gpid
	pids=$(grep sched_process_exec "$f" | grep "$c" | sed -E 's/.* pid=([0-9]+).*/\1/' | sort -u || true)
	[ -n "$pids" ] || { echo "no $c exec in $f"; return 0; }
	for pid in $pids; do
		pline=$(grep -E "sched_process_fork.*child_pid=$pid( |\$)" "$f" | head -1 || true)
		pn=$(echo "$pline" | sed -E 's/.*comm=([^ ]+) pid=([0-9]+).*/\1/')
		pp=$(echo "$pline" | sed -E 's/.*comm=([^ ]+) pid=([0-9]+).*/\2/')
		gline=$(grep -E "sched_process_fork.*child_pid=$pp( |\$)" "$f" | head -1 || true)
		if [ -n "$gline" ]; then
			gn=$(echo "$gline" | sed -E 's/.*comm=([^ ]+) pid=([0-9]+).*/\1(\2)/')
		else
			gpid=$(awk '{print $4}' "/proc/$pp/stat" 2>/dev/null || echo "")
			gn="$(cat "/proc/$gpid/comm" 2>/dev/null || echo '?')($gpid)"
		fi
		echo "$gn -> ${pn}(${pp}) -> $c"
	done | sort | uniq -c | sort -rn
}

# synodsmnotify accepts only i18n string keys, no free text: register ours in
# DSM's strings file (overwritten by DSM updates; watch start re-asserts)
watch_strings() {
	local s=/usr/syno/synoman/webman/texts/enu/strings
	grep -q '^\[hibdbg\]' "$s" 2>/dev/null && return 0
	printf '\n[hibdbg]\nwake_title\t=\t"hibdbg: HDD wake"\nwake_msg\t=\t"A sleeping HDD received commands; details in watch.log and the daily digest mail."\ntest_title\t=\t"hibdbg: test notification"\n' >> "$s"
	echo "registered notification strings in $s"
}

# sample kernel ring buffer for N sec with syslog-ng paused (no disk feedback)
ringsample() {
	local sec="$1" t0
	t0=$(awk '{print $1}' /proc/uptime)
	systemctl stop syslog-ng
	trap 'echo 0 > /proc/sys/vm/block_dump; systemctl start syslog-ng' EXIT
	echo 1 > /proc/sys/vm/block_dump
	sleep "$sec"
	[ "$(cat /proc/sys/vm/block_dump)" = 1 ] \
		|| echo "WARNING: block_dump cleared mid-window by another process; results incomplete" >&2
	echo 0 > /proc/sys/vm/block_dump
	dmesg | awk -v t0="$t0" '
		match($0, /\[ *[0-9]+\.[0-9]+\]/) {
			ts = substr($0, RSTART+1, RLENGTH-2) + 0
			if (ts >= t0) print
		}'
	systemctl start syslog-ng
	trap - EXIT
}

usage() { cat <<USAGE
hibdbg - keep Synology HDDs asleep: find what wakes them, fix it, verify

usage: hibdbg <command> [args]
       hibdbg <command> --help        details for any command

health
  status                       drive state, timer, shim+sleepd, last standbys
  status probe                 10-minute verdict: is anything still writing?

sample (seconds to minutes)
  status live [sec]            which devices saw I/O (diskstats delta)
  status state                 drive power state (never wakes a drive)
  status lcc [sec]             SMART start/stop + load-cycle wear counters
  who [devpat] [sec]           which process writes which files
  who rq [sec]                 every sata command, incl. ATA passthrough
  who forks [sec] [comm]       which daemon spawns a short-lived helper
  who fresh [min] [path]       files modified in the last MIN minutes

record (hours, detached)
  rec [sec]                    start recorder (default 4h; survives logout)
  rec stop                     stop the latest recording cleanly
  rec wakes DIR                per-wake report: what woke the drives
  rec sum DIR                  full flat summary of a recording
  rec who DIR COMM             parent chains: who spawned COMM

test
  sleepnow [sec] [nopoll]      force standby now, watch what wakes it

notify
  watch start|stop|status      wake-notify daemon: log who woke the drives
  watch mode [digest|perwake]  show or set the notification mode
  watch digest                 wake episodes since last digest (mail body)
  watch test                   append a test episode, send a notification

configure and mitigate
  hib [MIN|undo]               show or set the idle timer (minutes)
  fix shim on|off|status       cache scemd temp polls so standby holds
  fix sleepd start|stop|status the standby daemon itself
  fix sysmig                   move DSM system partition HDD -> NVMe
  fix quiesce|unquiesce        disable / restore indexing daemons
  fix calm [sec|off]           batch system-partition (md0) writes
  fix calm3 [sec|off]          batch volume3 btrfs commits
  boot                         re-assert shim+sysmig+sleepd+watch (boot task)

inspect DSM
  status map                   device topology (dm, md, partitions)
  status audit                 disk-writing DSM components + tunables
  status disks                 drive model/serial/firmware
  dsm debug on|off             DSM's own hibernation debug logging
  dsm log [n]                  scemd hibernation decisions, wake reasons
  dsm sched                    crontab, synocrond, smart schedules
  dsm smb|nfs                  connected clients
USAGE
}

# hibdbg <verb> --help
help_cmd() {
	case "$1" in
	status) cat <<'EOF'
usage: hibdbg status [state|live [sec]|lcc [sec]|map|audit|disks|probe]

Bare: one health page -- drive power state, standbytimer, whether the shim
and sleepd are in place, and the last standbys issued. Run it after every
reboot and DSM update; the stack self-reverts (see boot).

  state       HDD power state via hdparm -C (never wakes a drive)
  live [sec]  diskstats delta, ground truth that I/O reached a device (def 10)
  lcc [sec]   SMART start/stop + load-cycle counters; with SEC show delta.
              The wear ledger. Drives in standby are skipped: smartctl
              identifies the device before honoring -n standby, which wakes
              it (queue-trace proven; only hdparm -C is truly non-waking).
  map         device topology: dm chains, md members, mdstat, partitions
  audit       status of every DSM component known to write to disk + tunables
  disks       model/serial/firmware per drive (standby drives skipped)
  probe       10-minute verdict pass: live + state + system-partition trace +
              lcc delta, with a key telling you which layer to blame
EOF
	;;
	who) cat <<'EOF'
usage: hibdbg who [devpat] [sec]                        (default all, 60s)

Feedback-free attribution: arms block_dump, pauses syslog-ng so the tracing
does not generate the disk writes it is measuring, samples the kernel ring for
SEC seconds, then reports writers and dirtied paths. devpat is an extended
regex over device names (e.g. "dm-3|md4|sata1"; "md0|md1" for the system
partition). block_dump cannot see SG_IO/ATA passthrough -- use who rq.

  rq [sec]            every request reaching a sata queue (block_rq_issue
                      tracepoint) with issuer and CDB bytes -- the only
                      instrument that sees ATA passthrough, which is what
                      defeats standby (def 120)
  forks [sec] [comm]  parent chain of short-lived helper spawns via fork/exec
                      tracepoints; /proc sampling loses the ~ms race
                      (def 30s, sg_raw)
  fresh [min] [path]  files modified in last MIN minutes, tracer-free mtime
                      walk; generates reads itself (def 10, /volume3)
EOF
	;;
	rec) cat <<'EOF'
usage: hibdbg rec [sec]                                        (default 14400)

Detached all-instrument recorder; survives ssh logout (setsid). Writes into
<scriptdir>/hibdbg.rec.<timestamp>/ -- keep the script on an SSD volume, never
on the drives under test, and never on / (md0 is 8G).

  block.log      sata queue requests, incl. ATA passthrough  (uncompressed)
  fork.log.gz    fork/exec graph, the bulk of the data       (~3G/day)
  blockdump.log  process + dirtied-path attribution, HDD stack only
  diskstats.log  30s I/O snapshots        state.log  30s power state
  meta           start/end, device numbers, block_dump pattern

syslog-ng stays stopped for the whole recording (its writes would be measured
as disk activity). Run only one block_dump-family and one tracepoint-family
instrument at a time; concurrent recorders starve each other's traces.
A full day is the shortest run that separates scheduled wakes from real use.

  stop          stop the latest recording cleanly (never kill the process:
                syslog-ng would stay stopped and tracing armed)
  wakes DIR     one block per wake episode: duration, sata I/O totals, and the
                processes + dirtied paths from the FIRST 15 MINUTES -- only the
                opening minutes identify the waker; everything later is other
                work piggybacking on an already-spinning drive
  sum DIR       flat summary: I/O episodes, state transitions, aggregated
                processes/paths/queue issuers, exec'd storage tools
  who DIR COMM  parent chains for every COMM exec in the recording:
                grandparent -> parent -> COMM with exec and pid counts; names
                the daemon behind millisecond-lived helpers (sg_raw,
                cryptsetup, ffprobe). ? = forked before the recording started.
EOF
	;;
	sleepnow) cat <<'EOF'
usage: hibdbg sleepnow [sec] [nopoll]                           (default 300)

Acceptance test for the whole stack. Syncs, waits out the ext4 and btrfs commit
intervals, issues hdparm -y to every HDD, then samples for SEC seconds at 5s
grain: diskstats timeline, block_dump attribution, and a queue-level trace that
includes passthrough. Does not stop at the first wake.

Pass "nopoll" as the second argument to stop scemd for the window: SCT
temperature polls cease and fans hold their speed. That is the A/B that proved
the polls themselves wake a manually-slept drive.

syslog-ng is paused for the window. Do not run other hibdbg commands meanwhile.
EOF
	;;
	watch) cat <<'EOF'
usage: hibdbg watch start|stop|status | mode [digest|perwake] | digest | test

Wake-notify daemon. Keeps a private ftrace instance armed on the sata queues
(RAM only, zero disk I/O, coexists with rec and who), checks drive state once
a minute, and when a command reaches the queues while a drive was in standby
it appends one episode to watch.log next to the script: wallclock, drive
states, and the first queue commands with their issuing process -- including
ATA passthrough, the wake class invisible to every other layer. Deep-dive a
named issuer with rec / rec who.

Buffered writes reach the queue as anonymous kernel plumbing (dmcrypt_write,
kworker), so the daemon also keeps a per-filesystem change cursor while the
drives spin and diffs it at wake time to name the files written while asleep.
On btrfs the cursor is the transaction id (subvolume find-new: instant, pure
metadata); other filesystems need an fsmark_<fs>/fsdiff_<fs> hook pair in the
script or get no file attribution.

Reads leave no such trace, so a second ftrace instance records page-cache
misses on the HDD filesystems (mm_filemap_add_to_page_cache), armed only while
a drive sleeps -- when a miss is by definition the wake. It yields reader plus
inode, and fsino_<fs> names the file (btrfs: inode-resolve). Whatever process
the queue named is also resolved through /proc at wake time -- cmdline, parent
and docker container -- and nfsd, a kernel thread, additionally logs the NFS
client that asked.

  mode digest   (default) episodes only collect in watch.log. For the daily
                mail, create a DSM task that Synology mails with its own
                configured email -- Control Panel > Task Scheduler > Create >
                Scheduled task > user root, daily:
                    /path/to/hibdbg.sh watch digest
                and enable "Send run details by email" in its settings.
  mode perwake  additionally push a DSM notification (desktop bell + mobile
                app) the minute a wake is detected -- for live debugging.
                The push text is static (synodsmnotify accepts only i18n
                string keys, registered by watch start); who/why is in
                watch.log. Per-wake email is deliberately absent: DSM
                exposes no CLI to its configured SMTP, and duplicating mail
                credentials into the tool is worse than the digest.

  digest        print episodes appended since the previous digest call and
                advance the marker (the mail task's output is the email
                body); exits 1 when there were wakes, 0 when quiet. Daily
                summary: daily schedule + "Send run details by email".
                Near-real-time mail: schedule every few minutes + "Send run
                details only when the script terminates abnormally" --
                Synology then mails only the intervals that had wakes.
  test          append a fake episode and send a DSM notification now

Started by boot. Independent of sleepd: wakes are recorded whether or not
anything puts the drives back to sleep.
EOF
	;;
	hib) cat <<'EOF'
usage: hibdbg hib [MIN|undo]

No argument shows the hibernation-related keys from scemd.xml and both
synoinfo.conf files. MIN sets standbytimer (minutes), recording the previous
value so undo can restore it, and restarts scemd. sleepd picks the new value
up on its next cycle, no restart needed.

This sets the idle threshold only. DSM's native hibernation still will not
fire on this box; standby comes from fix sleepd.
EOF
	;;
	fix) cat <<'EOF'
usage: hibdbg fix <sub>

  shim on|off|status
     Wraps /usr/syno/bin/sg_raw (original kept as sg_raw.real). While a drive
     is in standby, SCT status reads (ATA PASS-THROUGH, CDB byte 2f) are
     answered from a cached response instead of being passed to the disk;
     every other command goes straight through. scemd issues those reads every
     10-20s and each one spins a sleeping drive back up -- without this,
     standby cannot hold. The standby test is hdparm -C, which does not itself
     wake the drive. "on" is idempotent; DSM restores the stock binary at
     every boot (status and audit report it).

  sysmig
     Migrates the DSM system arrays (md0 = /, md1 = swap) off the HDDs onto
     the NVMe system partitions, one safe step per run -- re-run until it
     reports done. DSM mirrors its OS onto every data drive, so the root
     filesystem alone keeps the HDDs awake regardless of which userspace
     writers you silence. Afterwards Storage Manager permanently shows
     "system partition failed" on BOTH HDDs: that is the correct state, and
     Repair is the undo button. See SYSMIG.md.

  sleepd start|stop|status
     DIY standby daemon with hd-idle semantics: watches /proc/diskstats and
     issues hdparm -y per drive after standbytimer idle minutes. The timer is
     DSM's own setting, re-read every cycle (hib MIN or the DSM UI take effect
     without restart); 0 stops nothing. Issuing standby resets that drive's
     idle clock: passthrough wakes move no diskstats counter, and an expired
     clock would re-stop the drive seconds after every spin-up. Every standby
     is appended to sleepd.log next to the script. Refuses to run without the
     shim: scemd's polls would wake the drives right back and the pair would
     churn start/stop cycles.

  quiesce | unquiesce
     Stop + disable indexing daemons and purge stale index/drive queues;
     unquiesce restores them.

  calm [sec|off]     batch md0 journal+writeback (remount commit, def 600s)
  calm3 [sec|off]    batch volume3 btrfs commits (def 600s); up to SEC seconds
                     of buffered writes lost on power failure. off = defaults.
EOF
	;;
	dsm) cat <<'EOF'
usage: hibdbg dsm <sub>

  debug on|off  DSM's own hibernation debug logging (safe for the HDDs since
                sysmig, but it arms block_dump behind the recorder's back:
                keep it off while any hibdbg instrument runs). Restarting
                scemd resets DSM's idle clock.
  log [n]       scemd's hibernation decisions and wake reasons (def 40 lines)
  sched         crontab, synocrond jobs, smart self-test schedules
  smb           SMB client sessions and locks
  nfs           NFS client connections
EOF
	;;
	boot) cat <<'EOF'
usage: hibdbg boot

Re-asserts the whole stack, idempotently: fix shim on, fix sysmig,
fix sleepd start, watch start.

DSM reverts the wrapper binary and re-adds the HDD members to md0/md1 at every
boot, not just across updates. Register this as a Task Scheduler triggered
task (Boot-up, user root) or the stack silently degrades after any reboot.
EOF
	;;
	*)	die "unknown command: $1 (hibdbg --help for the list)" ;;
	esac
}

# "hibdbg <verb> --help" documents that verb; "--help" alone lists them all
for a in "$@"; do
	case "$a" in
	-h|--help|help)
		case "$1" in
		-h|--help|help) usage ;;
		*) help_cmd "$1" ;;
		esac
		exit 0 ;;
	esac
done

[ $# -gt 0 ] || { usage; exit 0; }
[ "$(id -u)" = 0 ] || echo "note: not root; privileged steps fail if unpermitted" >&2

case "${1:-}" in

status)	case "${2:-}" in
	"")
		"$0" status state
		echo "standbytimer: $(synogetkeyvalue /etc/synoinfo.conf standbytimer 2>/dev/null || echo '?')m (0 = off)"
		grep -q pollshim /usr/syno/bin/sg_raw 2>/dev/null \
			&& echo "pollshim: installed" || echo "pollshim: NOT installed (stock sg_raw)"
		pid=$(alive "$SPID" _sleepd) \
			&& echo "sleepd:   running (pid $pid)" || echo "sleepd:   NOT running"
		printf 'dsm debug: '
		[ "$(synogetkeyvalue /etc/synoinfo.conf enable_hibernation_debug 2>/dev/null)" = yes ] \
			&& echo "on (arms block_dump; dsm debug off)" || echo "off"
		echo "-- standby issued (last 5 of $SLEEPLOG):"
		tail -5 "$SLEEPLOG" 2>/dev/null || echo "  (none yet)" ;;
	state)
		for d in /dev/sata[0-9]*; do
			case "$d" in *p[0-9]*) continue;; esac
			printf '%s: ' "$d"; hdparm -C "$d" 2>/dev/null | grep -o 'drive state is:.*' || echo '?'
		done ;;
	live)
		a=$(grep -E ' (sata[0-9]+|nvme[0-9]+n1|md[0-9]+|dm-[0-9]+) ' /proc/diskstats)
		sleep "${3:-10}"
		b=$(grep -E ' (sata[0-9]+|nvme[0-9]+n1|md[0-9]+|dm-[0-9]+) ' /proc/diskstats)
		echo "dev     reads+ writes+"
		join -j1 <(echo "$a" | awk '{print $3, $4, $8}' | sort) \
		          <(echo "$b" | awk '{print $3, $4, $8}' | sort) \
		| awk '$4-$2 || $5-$3 {printf "%-8s %6d %6d\n", $1, $4-$2, $5-$3}' ;;
	lcc)	# -n standby is NOT sufficient: smartctl identifies the device (ATA
		# IDENTIFY via SAT) before honoring it, waking a sleeping drive --
		# queue-trace proven 2026-09-01. Gate on hdparm -C, which is safe.
		for d in /dev/sata[0-9]*; do
			case "$d" in *p[0-9]*) continue;; esac
			hdparm -C "$d" 2>/dev/null | grep -q active \
				|| echo "$d: in standby, skipped (smartctl would wake it)"
		done
		snap() {
			for d in /dev/sata[0-9]*; do
				case "$d" in *p[0-9]*) continue;; esac
				hdparm -C "$d" 2>/dev/null | grep -q active || continue
				smartctl -n standby -A "$d" 2>/dev/null \
				| awk -v d="$d" '$2 ~ /Load_Cycle_Count|Start_Stop_Count|Power-Off_Retract/ \
					{printf "%s %s %s\n", d, $2, $10}'
			done
		}
		if [ -n "${3:-}" ]; then
			a=$(snap); sleep "$3"; b=$(snap)
			echo "counter                        before after delta"
			join -j1 <(echo "$a" | awk '{print $1"_"$2, $3}' | sort) \
			         <(echo "$b" | awk '{print $1"_"$2, $3}' | sort) \
			| awk '{printf "%-30s %6d %6d %5d\n", $1, $2, $3, $3-$2}'
		else
			snap
		fi ;;
	map)
		for d in /sys/block/dm-*; do
			echo "$(basename "$d"): $(cat "$d/dm/name") <- $(dmsetup deps -o devname "$(cat "$d/dm/name")" | sed 's/.*: //')"
		done
		echo
		for m in /sys/block/md*; do
			echo "$(basename "$m"): $(ls "$m/slaves" | tr '\n' ' ')"
		done
		echo
		cat /proc/mdstat
		echo
		grep -E 'nvme|sata' /proc/partitions ;;
	audit)	# status of DSM components known to write to disk; read-only
		echo "== packages =="
		for p in ActiveInsight SynoFinder MediaServer SynologyPhotos AudioStation \
		         VideoStation SurveillanceStation Virtualization ContainerManager \
		         SnapshotReplication ScsiTarget; do
			printf '%-20s %s\n' "$p" "$(synopkg status "$p" 2>/dev/null | head -1 || echo 'not installed')"
		done
		echo "== chatty units =="
		for u in synoindex-scand synoindex-mediad synoindex-plugind synoindex-workerd \
		         synoindex-notifyd synologaccd synomibcollectord synorelayd \
		         synocachepind pkgctl-SynoFinder; do
			printf '%-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)/$(systemctl is-enabled "$u" 2>/dev/null || true)"
		done
		echo "== ext4 commit interval on / =="
		grep ' / ' /proc/mounts
		echo "== volume mounts (atime/commit) =="
		grep -E ' /volume[0-9]+ ' /proc/mounts
		echo "== btrfs sysfs tunables =="
		for f in /sys/fs/btrfs/*-*/; do
			echo "-- $f -> $(cat "$f/mount_path" 2>/dev/null)"
			grep -r . "$f/cleaner_tuning" "$f/snapshot_cleaner" 2>/dev/null || true
			for k in syno_orphan_cleanup_enable syno_orphan_cleanup_delayed \
			         locker_update_interval commit_time_debug_ms; do
				[ -f "$f$k" ] && echo "$k=$(cat "$f$k")"
			done
		done
		echo "== dirty writeback (centisecs: writeback/expire) =="
		echo "$(cat /proc/sys/vm/dirty_writeback_centisecs)/$(cat /proc/sys/vm/dirty_expire_centisecs)"
		echo "== hibernation setting =="
		grep -r . /usr/syno/etc/scemd.xml 2>/dev/null | grep -iE 'hibern|spindown' | head -5 || true
		echo "== hibdbg components (re-check after every DSM update) =="
		grep -q pollshim /usr/syno/bin/sg_raw 2>/dev/null \
			&& echo "pollshim: installed" || echo "pollshim: NOT installed (stock sg_raw)"
		pid=$(alive "$SPID" _sleepd) \
			&& echo "sleepd:   running (pid $pid)" || echo "sleepd:   not running" ;;
	disks)	# model / serial / firmware per drive. smartctl wakes a sleeping
		# drive even with -n standby (IDENTIFY precedes the check): skip.
		for d in /dev/sata[0-9]*; do
			case "$d" in *p[0-9]*) continue;; esac
			echo "== $d =="
			hdparm -C "$d" 2>/dev/null | grep -q active \
				|| { echo "  (in standby, skipped -- smartctl would wake it)"; continue; }
			smartctl -n standby -i "$d" 2>/dev/null \
			| grep -E 'Device Model|Serial Number|Firmware Version|Rotation|Model Family' \
			|| echo "  (no smart)"
		done ;;
	probe)	# one-shot verdict pass:
		# 1) diskstats delta  2) power state  3) feedback-free md0 trace  4) lcc delta
		echo "== live 60s (diskstats truth) =="
		"$0" status live 60
		echo; echo "== drive power state =="
		"$0" status state
		echo; echo "== md0 writers, 180s ring-buffer trace (syslog-ng paused) =="
		"$0" who 'md0|md1|sata[0-9]+p[125]' 180
		echo; echo "== load-cycle delta over the same period (600s total) =="
		"$0" status lcc 300
		echo; echo "read: live=0 + lcc delta>0  -> drive-internal head parks (hdparm -B)"
		echo "      live>0                    -> md0 section names the writer"
		echo "      live=0 + lcc delta=0     -> quiet; sleepd will reach standby" ;;
	*)	die "usage: hibdbg status [state|live|lcc|map|audit|disks|probe]" ;;
	esac ;;

who)	case "${2:-}" in
	rq)	# every request hitting sata queues via block_rq_issue tracepoint --
		# sees passthrough/SG_IO that block_dump and diskstats miss
		sec=${3:-120}
		T=/sys/kernel/debug/tracing
		[ -d "$T" ] || mount -t debugfs none /sys/kernel/debug
		[ -e "$T/events/block/block_rq_issue/enable" ] || die "block tracepoints unavailable in this kernel"
		rqfilter > "$T/events/block/block_rq_issue/filter"
		echo > "$T/trace"
		echo 1 > "$T/events/block/block_rq_issue/enable"
		sleep "$sec"
		echo 0 > "$T/events/block/block_rq_issue/enable"
		grep . /sys/block/sata[0-9]*/dev | sed 's|/sys/block/||;s|/dev||'
		grep -v '^#' "$T/trace" > /tmp/hibrq.$$ || true
		echo "-- raw (first 40) --"; head -40 /tmp/hibrq.$$
		echo "-- aggregated (dev rwbs issuer) --"; rq_agg < /tmp/hibrq.$$
		[ -s /tmp/hibrq.$$ ] || echo "(no requests)"
		rm -f /tmp/hibrq.$$
		echo 0 > "$T/events/block/block_rq_issue/filter" ;;
	forks)	# name the daemon spawning short-lived helpers (def sg_raw).
		# /proc sampling loses the ~ms race; fork/exec tracepoints catch
		# every spawn and give the parent chain
		sec=${3:-30}
		c=${4:-sg_raw}
		T=/sys/kernel/debug/tracing
		[ -e "$T/events/sched/sched_process_exec/enable" ] || die "sched tracepoints unavailable"
		echo > "$T/trace"
		echo 1 > "$T/events/sched/sched_process_fork/enable"
		echo 1 > "$T/events/sched/sched_process_exec/enable"
		sleep "$sec"
		echo 0 > "$T/events/sched/sched_process_fork/enable"
		echo 0 > "$T/events/sched/sched_process_exec/enable"
		forkchain "$T/trace" "$c"
		echo "binaries referencing $c:"
		grep -l "$c" /usr/syno/sbin/* /usr/syno/bin/* 2>/dev/null || echo "  (none in /usr/syno/{sbin,bin})" ;;
	fresh)	# files modified in the last MIN minutes (mtime attribution,
		# tracer-free). Full metadata walk: generates reads.
		find "${4:-/volume3}" -xdev -type f -mmin "-${3:-10}" ! -path '*/@eaDir/*' \
			-exec stat -c '%Y %12s %n' {} + 2>/dev/null | sort -rn | head -40 \
		| gawk '{$1=strftime("%H:%M:%S",$1); print}'
		echo "-- end (top 40 by mtime)" ;;
	*)	# attribute writes on any devices via ring buffer (feedback-free).
		# dirtied paths answer the "why". def: all devs
		pat="${2:-[^ ]+}"
		out=$(ringsample "${3:-60}" | grep -E "on (${pat})( |\$)" | denoise)
		[ -n "$out" ] || { echo "no events on (${pat}) in window"; exit 0; }
		echo "== processes =="
		echo "$out" | agg_proc
		echo "== dirtied paths =="
		echo "$out" | agg_path | head -30 ;;
	esac ;;

rec)	case "${2:-}" in
	stop)	d=$(ls -dt "$RECBASE"/hibdbg.rec.*/ 2>/dev/null | head -1)
		[ -n "$d" ] || die "no recordings under $RECBASE"
		kill "$(cat "${d}pid")" 2>/dev/null && echo "stopped ${d%/}" \
			|| echo "not running (${d%/})" ;;
	sum)	d=${3:?usage: hibdbg rec sum DIR}
		echo "== meta =="; cat "$d/meta" 2>/dev/null || true
		echo "== sata I/O episodes (30s-interval deltas) =="
		awk '/^== /{ts=$2" "$3; next}
		     $3 ~ /^sata[0-9]+$/ {k=$3
			if (k in pw && ($4>pr[k] || $8>pw[k]))
				printf "%s %s r+%d w+%d\n", ts, k, $4-pr[k], $8-pw[k]
			pr[k]=$4; pw[k]=$8}' "$d/diskstats.log" 2>/dev/null || true
		echo "== drive state transitions =="
		awk '/^== /{if(l)print t"  "l; t=$2" "$3; l=""} /^\/dev\//{l=l $1"="$NF" "}
		     END{if(l)print t"  "l}' "$d/state.log" 2>/dev/null | uniq -f2 || true
		echo "== block_dump processes =="
		grep -v '^== ' "$d/blockdump.log" 2>/dev/null | agg_proc
		echo "== dirtied paths =="
		grep -v '^== ' "$d/blockdump.log" 2>/dev/null | agg_path | head -30
		echo "== rq aggregated (dev rwbs issuer) =="
		cat "$d/block.log" 2>/dev/null | rq_agg | head -20
		echo "== rq non-sg_raw/hdparm (first 40) =="
		grep -vE '\[(sg_raw[^]]*|hdparm)\]' "$d/block.log" 2>/dev/null | head -40 || true
		echo "== exec'd storage tools (full graph stays in fork.log.gz for rec who) =="
		zcat -q "$d/fork.log.gz" 2>/dev/null | grep sched_process_exec \
		| sed -E 's/.*filename=([^ ]+).*/\1/' \
		| grep -E 'sg_raw|cryptsetup|hdparm|smartctl|synospace|synofstool|synostgd|dmsetup|mdadm|btrfs' \
		| sort | uniq -c | sort -rn | head -20 ;;
	wakes)	# one block per wake episode -- duration, sata I/O totals, and
		# block_dump attribution from the first 15 min (the waker; later
		# activity piggybacks on an already-spinning drive).
		# All timing rides the 30s state.log sample grid: no date arithmetic.
		d=${3:?usage: hibdbg rec wakes DIR}
		# state.log -> "W|S <ts>" per sample, in order
		awk '
		function emit() { print (act ? "W " : "S ") t }
		/^== /{ if (t != "") emit(); t=$2" "$3; act=0; next }
		/^\/dev\//{ if ($NF != "standby" && $NF != "sleeping") act=1 }
		END{ if (t != "") emit() }' "$d/state.log" > /tmp/hibstate.$$
		# episodes: wake-ts, sleep-ts (or last sample), 15min-cutoff ts, samples
		awk 'BEGIN{n=0}
		{ s=$1; ts=$2" "$3
		  if (s == "W") {
			if (n == 0) { w=ts; cut=ts; n=1 } else { n++; if (n <= 30) cut=ts }
		  } else if (n > 0) { print w "|" ts "|" cut "|" n; n=0 }
		}
		END{ if (n > 0) print w "|" ts "|" cut "|" n "|awake-at-end" }' \
			/tmp/hibstate.$$ > /tmp/hibep.$$
		rm -f /tmp/hibstate.$$
		[ -s /tmp/hibep.$$ ] || { echo "no wake episodes in $d"; rm -f /tmp/hibep.$$; exit 0; }
		while IFS='|' read -r w s cut n tail; do
			io=$(awk -v a="$w" -v b="$s" '
				/^== /{ts=$2" "$3; next}
				$3 ~ /^sata[0-9]+$/ { k=$3
					if (k in pw && ts >= a && ts <= b) { r+=$4-pr[k]; w+=$8-pw[k] }
					pr[k]=$4; pw[k]=$8 }
				END{ printf "r+%d w+%d", r, w }' "$d/diskstats.log")
			echo "== wake $w -> $s  ($(( n / 2 ))m)  $io ${tail:+[$tail]}"
			awk -v a="$w" -v b="$cut" '
				/^== /{ts=$2" "$3; next}
				ts >= a && ts <= b' "$d/blockdump.log" 2>/dev/null > /tmp/hibwk.$$
			if [ -s /tmp/hibwk.$$ ]; then
				echo "  procs (first 15m):"; agg_proc < /tmp/hibwk.$$ | head -5 | sed 's/^/    /'
				echo "  paths (first 15m):"; agg_path < /tmp/hibwk.$$ | head -5 | sed 's/^/    /'
			else
				echo "  (no block_dump events in first 15m; check rq/diskstats)"
			fi
			rm -f /tmp/hibwk.$$
		done < /tmp/hibep.$$
		rm -f /tmp/hibep.$$ ;;
	who)	# parent chains for COMM execs in a recording. one pass: fork edges
		# into a map, then resolve each COMM exec two levels up. a pid
		# alternation would exceed the 128K argument cap and per-pid greps
		# would rescan the graph thousands of times.
		d=${3:?usage: hibdbg rec who DIR COMM}; c=${4:?comm}
		out=$(zcat -q "$d/fork.log.gz" | awk -v c="$c" '
		/sched_process_fork/ {
			if (!match($0, /comm=[^ ]+ pid=[0-9]+/)) next
			split(substr($0, RSTART, RLENGTH), a, /[= ]/)
			if (match($0, /child_pid=[0-9]+/)) {
				ch = substr($0, RSTART + 10, RLENGTH - 10)
				pcomm[ch] = a[2]; ppid[ch] = a[4]
			}
			next
		}
		/sched_process_exec/ {
			if (!index($0, c) || !match($0, / pid=[0-9]+/)) next
			p = substr($0, RSTART + 5, RLENGTH - 5)
			# resolve here, not at EOF: a day-long recording cycles through the
			# pid space many times, so the map must be read as it stood when
			# this exec happened
			pn = (p in pcomm) ? pcomm[p] : "?"
			pp = (p in ppid)  ? ppid[p]  : "?"
			# ? = forked before the recording; /proc cannot be trusted to still
			# hold that pid afterwards, so it is left unnamed rather than guessed
			gn = (pp in pcomm) ? pcomm[pp] : "?"
			k = gn " -> " pn " -> " c
			n[k]++
			if (!seen[k SUBSEP pp]++) np[k]++
		}
		END { for (k in n) printf "%8d %6d  %s\n", n[k], np[k], k }' | sort -rn)
		[ -n "$out" ] || die "no $c exec in $d"
		printf '%8s %6s  %s\n' execs pids chain
		echo "$out" ;;
	*)	# background all-instrument recorder; survives ssh logout (setsid)
		dur=${2:-14400}; num "$dur" "rec [sec]"
		d="$RECBASE/hibdbg.rec.$(date +%Y%m%d-%H%M%S)"
		mkdir "$d"
		setsid "$0" _rec "$dur" "$d" >/dev/null 2>&1 < /dev/null &
		echo "recording ${dur}s -> $d"
		echo "stop early: $0 rec stop   analyze: $0 rec wakes $d" ;;
	esac ;;

_rec)	dur=$2; d=$3
	echo $$ > "$d/pid"
	T=/sys/kernel/debug/tracing
	dms=$(hdd_dms | tr '\n' '|')
	mds=$(for m in /sys/block/md*; do
		ls "$m/slaves" 2>/dev/null | grep -q sata && basename "$m"
	done | tr '\n' '|')
	BD="on (${dms}${mds}sata[0-9]+(p[0-9]+)?)( |\$)"
	cleanup() {
		[ -z "${cleaned:-}" ] || return 0
		cleaned=1
		kill "${tp:-0}" 2>/dev/null || true
		echo 0 > "$T/events/block/block_rq_issue/enable" 2>/dev/null
		echo 0 > "$T/events/sched/sched_process_fork/enable" 2>/dev/null
		echo 0 > "$T/events/sched/sched_process_exec/enable" 2>/dev/null
		echo 0 > "$T/events/block/block_rq_issue/filter" 2>/dev/null
		echo 0 > /proc/sys/vm/block_dump
		systemctl start syslog-ng
		date '+%F %T end' >> "$d/meta"
	}
	trap cleanup EXIT
	trap 'cleanup; trap - EXIT; exit 0' TERM INT
	date "+%F %T start dur=${dur}s bdpat=$BD" > "$d/meta"
	grep . /sys/block/sata[0-9]*/dev 2>/dev/null \
		| sed 's|/sys/block/||;s|/dev||' >> "$d/meta"
	systemctl stop syslog-ng
	rqfilter > "$T/events/block/block_rq_issue/filter"
	echo > "$T/trace"
	echo 1 > "$T/events/block/block_rq_issue/enable"
	echo 1 > "$T/events/sched/sched_process_fork/enable"
	echo 1 > "$T/events/sched/sched_process_exec/enable"
	# killing cat (not gzip) lets the pipeline flush and close cleanly
	cat "$T/trace_pipe" > >(tee >(grep --line-buffered block_rq_issue > "$d/block.log") \
		| grep -v block_rq_issue | gzip > "$d/fork.log.gz") & tp=$!
	dmesg -c >/dev/null 2>&1 || true
	echo 1 > /proc/sys/vm/block_dump
	end=$(( $(date +%s) + dur )); i=0
	while [ "$(date +%s)" -lt "$end" ]; do
		sleep 10
		out=$(dmesg -c 2>/dev/null | grep -E "$BD" || true)
		if [ -n "$out" ]; then
			{ date '+== %F %T'; echo "$out"; } >> "$d/blockdump.log"
		fi
		[ "$(cat /proc/sys/vm/block_dump)" = 1 ] || echo 1 > /proc/sys/vm/block_dump
		i=$((i+1)); [ $((i % 3)) -eq 0 ] || continue
		{ date '+== %F %T'; grep -E ' (sata[0-9]+|dm-[0-9]+|md[0-9]+) ' /proc/diskstats; } >> "$d/diskstats.log"
		{ date '+== %F %T'
		  for dev in /dev/sata[0-9]*; do
			case "$dev" in *p[0-9]*) continue;; esac
			printf '%s %s\n' "$dev" "$(hdparm -C "$dev" 2>/dev/null | grep -oE 'standby|active/idle|sleeping' || echo '?')"
		  done; } >> "$d/state.log"
	done ;;

sleepnow) # force standby, record full wake timeline with kernel-attributed
	# events. syslog-ng paused for the window (trace must not persist to
	# md0). Do not run other commands meanwhile.
	dur=${2:-300}; num "$dur" "sleepnow [sec]"
	nopoll=${3:-}
	t0=$(awk '{print $1}' /proc/uptime)
	systemctl stop syslog-ng
	trap 'echo 0 > /proc/sys/vm/block_dump; echo 0 > /sys/kernel/debug/tracing/events/block/block_rq_issue/enable 2>/dev/null; [ -z "$nopoll" ] || systemctl start scemd; systemctl start syslog-ng' EXIT
	[ -z "$nopoll" ] || { systemctl stop scemd; echo "scemd stopped (no SCT polls; fans hold last speed)"; }
	echo 1 > /proc/sys/vm/block_dump
	T=/sys/kernel/debug/tracing
	[ -d "$T" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
	if [ -e "$T/events/block/block_rq_issue/enable" ]; then
		rqfilter > "$T/events/block/block_rq_issue/filter"
		echo > "$T/trace"
		echo 1 > "$T/events/block/block_rq_issue/enable"
	fi
	# settle: outlast ext4 (5s) and btrfs (30s) commit intervals so nothing
	# dirtied before the window flushes inside it
	sync; sleep 35; sync
	snap() { grep -E ' sata[0-9]+ ' /proc/diskstats | awk '{print $3, $4, $8}'; }
	prev=$(snap)
	for d in /dev/sata[0-9]*; do
		case "$d" in *p[0-9]*) continue;; esac
		hdparm -y "$d" >/dev/null 2>&1
	done
	echo "standby issued; sampling ${dur}s (5s grain, not stopping on wake)..."
	el=0
	while [ "$el" -lt "$dur" ]; do
		sleep 5; el=$((el+5))
		cur=$(snap)
		ev=$(join -j1 <(echo "$prev"|sort) <(echo "$cur"|sort) \
			| awk '$4>$2 || $5>$3 {printf "%s r+%d w+%d ", $1, $4-$2, $5-$3}')
		[ -n "$ev" ] && echo "+${el}s $ev"
		prev=$cur
	done
	echo 0 > /proc/sys/vm/block_dump
	echo 0 > "$T/events/block/block_rq_issue/enable" 2>/dev/null || true
	"$0" status state    # before syslog-ng returns and wakes md0
	dms=$(hdd_dms | tr '\n' '|')
	mds=$(for m in /sys/block/md*; do
		ls "$m/slaves" 2>/dev/null | grep -q sata && basename "$m"
	done | tr '\n' '|')
	pat="on (${dms}${mds}sata[0-9]+(p[0-9]+)?)( |\$)"
	echo; echo "== kernel events on HDD stack (dm+md+sata) during window =="
	echo "-- raw (first 40, with paths) --"
	dmesg | awk -v t0="$t0" '
		match($0, /\[ *[0-9]+\.[0-9]+\]/) {
			ts = substr($0, RSTART+1, RLENGTH-2) + 0
			if (ts >= t0) print
		}' | grep -E "$pat" > /tmp/hibwake.$$ || true
	head -40 /tmp/hibwake.$$
	echo "-- dirtied (paths, never crowded out) --"
	grep dirtied /tmp/hibwake.$$ | head -20
	echo "-- reads --"
	grep 'READ block' /tmp/hibwake.$$ | head -10
	echo "-- aggregated --"
	sed -E 's/.*ppid:[0-9]+\(([^)]*)\), pid:[0-9]+\(([^)]*)\), (READ|WRITE|dirtied).*/\1>\2 \3/' /tmp/hibwake.$$ \
	| sort | uniq -c | sort -rn
	[ -s /tmp/hibwake.$$ ] || echo "(none - below page layer: ata passthrough or md superblock)"
	rm -f /tmp/hibwake.$$
	if [ -e "$T/trace" ]; then
		echo; echo "== every sata queue request (block_rq_issue; incl passthrough) =="
		grep . /sys/block/sata[0-9]*/dev | sed 's|/sys/block/||;s|/dev||'
		grep -v '^#' "$T/trace" > /tmp/hibrq.$$ || true
		echo "-- raw (first 30) --"; head -30 /tmp/hibrq.$$
		echo "-- aggregated (dev rwbs issuer) --"; rq_agg < /tmp/hibrq.$$
		[ -s /tmp/hibrq.$$ ] || echo "(no requests reached sata queues)"
		rm -f /tmp/hibrq.$$
		echo 0 > "$T/events/block/block_rq_issue/filter"
	fi
	[ -z "$nopoll" ] || systemctl start scemd
	systemctl start syslog-ng
	trap - EXIT ;;

hib)	# hibdbg hib        -> show hibernation config (timer = synoinfo.conf)
	# hibdbg hib MIN    -> set standbytimer minutes
	# hibdbg hib undo   -> restore previously recorded value
	C=/etc/synoinfo.conf; K=standbytimer
	S="$(dirname "$(readlink -f "$0")")/.hib_prev"
	if [ -z "${2:-}" ]; then
		grep -nE -i 'hibern|spindown|idle' /usr/syno/etc/scemd.xml | grep -v fan_config \
			|| echo "nothing besides fan_config in scemd.xml"
		for f in "$C" /etc.defaults/synoinfo.conf; do
			echo "-- $f"
			grep -nE 'idle|hibern|spindown|standby' "$f" || echo "  (no matches)"
		done
		exit 0
	fi
	case "$2" in
	undo)
		[ -s "$S" ] || die "no recorded value ($S)"
		prev=$(tail -1 "$S" | awk '{print $3}')
		synosetkeyvalue "$C" "$K" "$prev"
		sed -i '$d' "$S"
		systemctl restart scemd
		echo "$K restored to $prev; scemd restarted" ;;
	*[!0-9]*)
		die "usage: hibdbg hib [MIN|undo]" ;;
	*)
		cur=$(synogetkeyvalue "$C" "$K")
		echo "$(date +%F.%T) $K ${cur:-0}" >> "$S"
		synosetkeyvalue "$C" "$K" "$2"
		systemctl restart scemd
		echo "$K: ${cur:-unset} -> $2 min; scemd restarted (undo: hibdbg hib undo)" ;;
	esac ;;

fix)	case "${2:-}" in
	shim)	# wrap /usr/syno/bin/sg_raw so scemd's SCT temperature polls
		# against a standby drive are served from cache instead of waking
		# it. Passthrough for non-sata targets and non-read CDBs. Survives
		# until a DSM update restores the stock binary (status reports it).
		B=/usr/syno/bin/sg_raw
		case "${3:-}" in
		on)
			if grep -q pollshim "$B" 2>/dev/null; then
				echo "already installed"; exit 0
			fi
			if [ -e "$B.real" ]; then
				# stock binary restored over the wrapper (reboot/update):
				# both copies are the original -> drop the stale .real
				[ "$(md5sum < "$B")" = "$(md5sum < "$B.real")" ] \
					|| die "$B.real exists and differs from $B; inspect manually"
				rm -f "$B.real"
			fi
			cat > "$B.shim" <<-'WRAP'
			#!/bin/bash
			# pollshim (hibdbg): cached SCT poll answers while drive is in standby
			REAL=/usr/syno/bin/sg_raw.real
			dev=
			for a in "$@"; do case "$a" in /dev/sata[0-9]*) dev=$a ;; esac; done
			[ -n "$dev" ] || exec "$REAL" "$@"
			C=/run/pollshim; mkdir -p "$C"
			key=$(printf '%s' "$*" | md5sum | awk '{print $1}')
			cacheable=
			case " $* " in *" 2f "*) cacheable=1 ;; esac
			if [ -n "$cacheable" ] && hdparm -C "$dev" 2>/dev/null | grep -q standby; then
			  if [ -f "$C/$key" ]; then
			    echo "$(date '+%F %T') cached $dev" >> "$C/log"
			    cat "$C/$key"; exit 0
			  fi
			  echo "$(date '+%F %T') miss-live $dev $*" >> "$C/log"
			fi
			"$REAL" "$@" > "$C/$key.$$.tmp"; rc=$?
			if [ $rc -eq 0 ] && [ -n "$cacheable" ]; then
			  mv "$C/$key.$$.tmp" "$C/$key"; cat "$C/$key"
			else
			  cat "$C/$key.$$.tmp"; rm -f "$C/$key.$$.tmp"
			fi
			exit $rc
			WRAP
			chmod 755 "$B.shim"
			mv "$B" "$B.real"
			mv "$B.shim" "$B"
			echo "installed; verify: fix shim status after next poll (~20s)" ;;
		off)
			[ -e "$B.real" ] || die "not installed"
			mv -f "$B.real" "$B"
			rm -rf /run/pollshim
			echo "original sg_raw restored" ;;
		status)
			if grep -q pollshim "$B" 2>/dev/null; then
				echo "installed ($(ls /run/pollshim 2>/dev/null | grep -vc '^log$' || true) cache entries)"
				tail -5 /run/pollshim/log 2>/dev/null || echo "  (no shim activity yet)"
			else
				echo "not installed (stock sg_raw)"
			fi ;;
		*)	die "usage: hibdbg fix shim on|off|status" ;;
		esac ;;
	sysmig)	# migrate DSM system arrays (md0=/, md1=swap) off the HDDs onto
		# the NVMe system partitions. Idempotent: one safe step per run,
		# re-run until both report done. Never click DSM's "Repair" after.
		for pair in md0:1 md1:2; do
			md=${pair%:*}; p=${pair#*:}
			sync=$(cat "/sys/block/$md/md/sync_action")
			nd=$(cat "/sys/block/$md/md/raid_disks")
			slaves=" $(ls "/sys/block/$md/slaves" | tr '\n' ' ') "
			if [ "$sync" != "idle" ]; then
				echo "$md: $sync running; re-run when idle"; continue
			fi
			miss=""
			for b in /sys/block/nvme[0-9]n1; do
				d="$(basename "$b")p$p"
				case "$slaves" in *" $d "*) ;; *) miss="$miss $d";; esac
			done
			if [ -n "$miss" ]; then
				for d in $miss; do mdadm "/dev/$md" --add "/dev/$d"; done
				echo "$md: added$miss; resync starting, re-run when idle"; continue
			fi
			satas=$(echo "$slaves" | tr ' ' '\n' | grep '^sata' || true)
			nvme_ok=1
			for b in /sys/block/nvme[0-9]n1; do
				d="$(basename "$b")p$p"
				grep -q in_sync "/sys/block/$md/md/dev-$d/state" 2>/dev/null || nvme_ok=0
			done
			if [ -n "$satas" ] && [ "$nvme_ok" != 1 ]; then
				echo "$md: nvme members not all in_sync yet; re-run when resynced"
				continue
			fi
			for d in $satas; do
				mdadm "/dev/$md" --fail "/dev/$d" --remove "/dev/$d"
				echo "$md: removed $d"
			done
			if [ "$nd" -gt 2 ]; then
				mdadm --grow "/dev/$md" --raid-devices=2
				echo "$md: shrunk to 2 slots"
			fi
			echo "$md: done, members:$(ls "/sys/block/$md/slaves" | tr '\n' ' ')"
		done ;;
	sleepd)	# DIY standby daemon (hd-idle semantics). Issues hdparm -y per
		# drive after standbytimer idle minutes, re-read every cycle.
		# Requires the shim, else scemd's polls wake the drives right back
		# (proven) and the pair would churn.
		case "${3:-}" in
		start)
			grep -q pollshim /usr/syno/bin/sg_raw 2>/dev/null \
				|| die "pollshim not installed; refusing (polls would wake drives)"
			if pid=$(alive "$SPID" _sleepd); then
				echo "already running (pid $pid)"; exit 0
			fi
			setsid "$0" _sleepd >/dev/null 2>&1 < /dev/null &
			cur=$(synogetkeyvalue /etc/synoinfo.conf standbytimer 2>/dev/null)
			echo "sleepd started (standbytimer ${cur:-0}m -> standby; 0 = off)"
			echo 'persist across reboots: covered by the "hibdbg.sh boot" boot-up task' ;;
		stop)	if pid=$(alive "$SPID" _sleepd); then
				kill "$pid" && echo "stopped (pid $pid)"
			else
				echo "not running"
			fi ;;
		status)	pid=$(alive "$SPID" _sleepd) \
				&& echo "running (pid $pid)" || echo "not running"
			"$0" status state
			echo "-- standby issued (last 5 of $SLEEPLOG):"
			tail -5 "$SLEEPLOG" 2>/dev/null || echo "  (none yet)" ;;
		*)	die "usage: hibdbg fix sleepd start|stop|status" ;;
		esac ;;
	quiesce) # stop + disable indexing daemons, clear stale index/drive queues
		for u in synoindex-scand synoindex-mediad synoindex-plugind \
		         synoindex-workerd synoindex-notifyd; do
			systemctl stop "$u" 2>/dev/null && echo "stopped  $u" || true
			systemctl disable "$u" 2>/dev/null && echo "disabled $u" || true
		done
		synopkg stop SynoFinder 2>/dev/null && echo "stopped  SynoFinder pkg" || true
		systemctl disable pkgctl-SynoFinder 2>/dev/null && echo "disabled pkgctl-SynoFinder unit" \
			|| echo "note: pkgctl-SynoFinder unit not disableable; pkg may return on reboot"
		for q in /volume*/@eaDir/SYNO@file_index_queue \
		         /volume*/*/@eaDir/SYNO@file_index_queue \
		         /volume*/*/@eaDir/@drive.queues; do
			[ -e "$q" ] && { rm -rf "$q"; echo "removed  $q"; }
		done
		echo "residual check:"; pgrep -l 'synoindex|synoelastic' || echo "  no index daemons running" ;;
	unquiesce)
		systemctl enable pkgctl-SynoFinder 2>/dev/null || true
		synopkg start SynoFinder 2>/dev/null || true
		for u in synoindex-scand synoindex-mediad synoindex-plugind \
		         synoindex-workerd synoindex-notifyd; do
			systemctl enable "$u" 2>/dev/null || true
			systemctl start "$u" 2>/dev/null || true
		done
		echo "indexing restored" ;;
	calm)	# batch md0 writes: remount commit=SEC (default 600) + relax dirty
		# writeback so flushes coalesce. off = restore defaults
		case "${3:-}" in
		off)	mount -o remount,commit=5 /
			echo 3000 > /proc/sys/vm/dirty_expire_centisecs
			echo 500 > /proc/sys/vm/dirty_writeback_centisecs
			echo "defaults restored (commit=5s, expire=30s, writeback=5s)" ;;
		*)	sec=${3:-600}
			mount -o remount,commit="$sec" /
			echo $((sec*100)) > /proc/sys/vm/dirty_expire_centisecs
			echo 6000 > /proc/sys/vm/dirty_writeback_centisecs
			echo "md0 journal commit=${sec}s, expire=${sec}s, writeback=60s"
			echo "persist: Task Scheduler > Triggered > Boot-up > root:"
			echo "  $(readlink -f "$0") fix calm $sec" ;;
		esac ;;
	calm3)	# batch volume3 btrfs commits (def 600s). One flush burst per
		# interval instead of every 30s; up to SEC seconds of buffered
		# writes lost on power failure. off = restore commit=30s
		case "${3:-}" in
		off)	mount -o remount,commit=30 /volume3
			echo "volume3 commit=30s (btrfs default)" ;;
		*)	sec=${3:-600}
			mount -o remount,commit="$sec" /volume3
			echo "volume3 commit=${sec}s"
			echo "persist: Task Scheduler > Triggered > Boot-up > root:"
			echo "  $(readlink -f "$0") fix calm3 $sec" ;;
		esac ;;
	*)	die "usage: hibdbg fix shim|sysmig|sleepd|quiesce|unquiesce|calm|calm3 ..." ;;
	esac ;;

_sleepd) mkdir -p "$RUNDIR"; echo $$ > "$SPID"
	trap 'rm -f "$SPID"' EXIT
	trap 'rm -f "$SPID"; trap - EXIT; exit 0' TERM INT
	declare -A last prev
	while :; do
		# shim gone (boot/update restored stock sg_raw): polls wake drives
		# again -> issuing standby would churn cycles; die, status shows it
		grep -q pollshim /usr/syno/bin/sg_raw 2>/dev/null || exit 0
		min=$(synogetkeyvalue /etc/synoinfo.conf standbytimer 2>/dev/null)
		now=$(date +%s)
		while read -r name r w; do
			cur="$r $w"
			if [ "${prev[$name]:-}" != "$cur" ]; then
				last[$name]=$now; prev[$name]=$cur; continue
			fi
			# 0 or unset is DSM's "hibernation off"; keep tracking idle, stop nothing
			[ "${min:-0}" -gt 0 ] || continue
			if [ $(( now - ${last[$name]:-$now} )) -ge $(( min * 60 )) ]; then
				if hdparm -C "/dev/$name" 2>/dev/null | grep -q 'active'; then
					hdparm -y "/dev/$name" >/dev/null 2>&1 || true
					printf '%s %s standby after %dm idle\n' "$(date '+%F %T')" \
						"$name" $(( (now - ${last[$name]:-$now}) / 60 )) >> "$SLEEPLOG"
					# a wake carried by passthrough moves no diskstats counter,
					# so without this the clock stays expired and every cycle
					# re-stops the drive seconds after it spins up
					last[$name]=$now
				fi
			fi
		done < <(grep -E ' sata[0-9]+ ' /proc/diskstats | awk '{print $3, $4, $8}')
		# background + wait: TERM lands only after a foreground child exits
		sleep 60 & wait $!
	done ;;

watch)	case "${2:-}" in
	start)
		[ -d /sys/kernel/debug/tracing ] || mount -t debugfs none /sys/kernel/debug
		mkdir -p /sys/kernel/debug/tracing/instances/hibwatch 2>/dev/null \
			|| die "kernel lacks ftrace instances; watch cannot coexist with other tracers"
		watch_strings
		if pid=$(alive "$WPID" _watch); then
			echo "already running (pid $pid)"; exit 0
		fi
		setsid "$0" _watch >/dev/null 2>&1 < /dev/null &
		echo "watch started (mode: $(cat "$WMODE" 2>/dev/null || echo digest); episodes -> $WLOG)"
		echo "daily digest mail: Task Scheduler > Create > Scheduled task > root, daily:"
		echo "  $(readlink -f "$0") watch digest"
		echo "  + task settings: Send run details by email" ;;
	stop)	if pid=$(alive "$WPID" _watch); then
			kill "$pid" && echo "stopped (pid $pid)"
		else
			echo "not running"
		fi ;;
	status)	pid=$(alive "$WPID" _watch) \
			&& echo "running (pid $pid)" || echo "not running"
		echo "mode: $(cat "$WMODE" 2>/dev/null || echo digest)"
		fm=/sys/kernel/debug/tracing/instances/hibread/events/filemap
		if [ -d "$fm/mm_filemap_add_to_page_cache" ]; then
			echo "read attribution: available ($(cat "$fm/mm_filemap_add_to_page_cache/enable") = armed while asleep)"
		else
			echo "read attribution: unavailable (kernel lacks the filemap tracepoint)"
		fi
		echo "-- last episodes ($WLOG):"
		tail -20 "$WLOG" 2>/dev/null || echo "  (none yet)" ;;
	mode)	case "${3:-}" in
		"")	cat "$WMODE" 2>/dev/null || echo digest ;;
		digest|perwake)
			echo "$3" > "$WMODE"; echo "mode: $3" ;;
		*)	die "usage: hibdbg watch mode [digest|perwake]" ;;
		esac ;;
	digest)	[ -f "$WLOG" ] || { echo "no wakes recorded yet"; exit 0; }
		n=$(( $(cat "$WMARK" 2>/dev/null || echo 0) ))
		total=$(( $(wc -l < "$WLOG") ))
		# log shorter than the marker: watch.log was rotated or removed
		[ "$total" -ge "$n" ] || n=0
		if [ "$total" -eq "$n" ]; then
			echo "no wakes since last digest"
			echo "$total" > "$WMARK"
		else
			tail -n +"$((n+1))" "$WLOG"
			echo "$total" > "$WMARK"
			# nonzero = "abnormal" to Task Scheduler: scheduling digest
			# frequently with "send run details only when the script
			# terminates abnormally" mails only the intervals with wakes
			exit 1
		fi ;;
	test)	watch_strings
		printf '== %s TEST episode (watch test)\n' "$(date '+%F %T')" >> "$WLOG"
		synodsmnotify @administrators hibdbg:test_title hibdbg:wake_msg \
			&& echo "dsm notification sent; test episode appended to $WLOG" ;;
	*)	die "usage: hibdbg watch start|stop|status|mode|digest|test" ;;
	esac ;;

_watch)	# wake-notify daemon: a private ftrace instance on the sata queues
	# stays armed (RAM ring, no disk I/O, own enable/filter -> rec and
	# who keep working). A wake = any queue command not from our own
	# non-waking probes while a drive was in standby on the last sample.
	T=/sys/kernel/debug/tracing/instances/hibwatch
	mkdir -p "$T" 2>/dev/null || exit 1
	# page-cache misses go to their own ring: the spin-up requeue storm in
	# hibwatch runs to ~20k lines and would evict the read record
	TR=/sys/kernel/debug/tracing/instances/hibread
	mkdir -p "$TR" 2>/dev/null || true
	FM=$TR/events/filemap/mm_filemap_add_to_page_cache
	[ -d "$FM" ] || FM=""
	mkdir -p "$RUNDIR"; echo $$ > "$WPID"
	cleanup() {
		echo 0 > "$T/events/block/block_rq_issue/enable" 2>/dev/null
		rmdir "$T" 2>/dev/null
		if [ -n "$FM" ]; then echo 0 > "$FM/enable" 2>/dev/null; fi
		rmdir "$TR" 2>/dev/null
		rm -f "$WPID"
	}
	trap cleanup EXIT
	trap 'cleanup; trap - EXIT; exit 0' TERM INT
	rqfilter > "$T/events/block/block_rq_issue/filter"
	echo > "$T/trace"
	echo 1 > "$T/events/block/block_rq_issue/enable"
	sleepy=0
	while :; do
		if [ "$sleepy" -gt 0 ]; then
			ev=$(grep block_rq_issue "$T/trace" 2>/dev/null \
				| grep -vE '\[(hdparm|sg_raw[^]]*)\]' || true)
			if [ -n "$ev" ]; then
				# headline: name the waker when a userspace comm reached the
				# queue; buffered writes surface only as kernel plumbing (the
				# dm/md boundary strips the origin) -> name the changed file
				files=$(fs_diff)
				reads=$(if [ -n "$FM" ]; then fs_reads "$TR/trace"; fi)
				top=$(echo "$ev" | rq_agg \
					| awk '$4 !~ /^(kworker|irq\/|dmcrypt|btrfs|md[0-9]|jbd2|flush)/ {print $4; exit}')
				# the issuer pid is in the raw trace as comm-pid; resolve it
				# now, while the process that issued the command still exists
				pid=$(echo "$ev" | awk -v c="$top" \
					'{f=$1; n=split(f,a,"-"); p=a[n]; sub("-" p "$","",f)
					  if (f==c) {print p; exit}}')
				who=$(if [ -n "${pid:-}" ]; then whois "$pid"; fi)
				case "${top:-}" in
				nfsd|lockd|nfsv4*) who="${who:+$who }clients: $(nfs_peers)" ;;
				esac
				if [ -z "$top" ] && [ -n "$reads" ]; then
					top="a read of $(echo "$reads" | head -1 | cut -d' ' -f2-)"
				fi
				if [ -z "$top" ] && [ -n "$files" ]; then
					top="a write to $(echo "$files" | head -1)"
				fi
				{ date "+== %F %T wake: ${top:-a buffered write to the HDD volume} woke your device"
				  "$0" status state
				  if [ -n "$who" ]; then
					echo "-- issuer: ${top}${pid:+($pid)} $who"
				  fi
				  if [ -n "$reads" ]; then
					echo "-- files read while asleep:"
					echo "$reads" | head -20
				  fi
				  if [ -n "$files" ]; then
					echo "-- files changed since the drives went to sleep:"
					echo "$files" | head -20
				  fi
				  echo "$ev" | rq_agg | head -5
				  echo "$ev" | head -5
				} >> "$WLOG"
				echo > "$T/trace"
				if [ -n "$FM" ]; then echo > "$TR/trace"; fi
				if [ "$(cat "$WMODE" 2>/dev/null)" = perwake ]; then
					# i18n keys only: the push is static, details in the log
					synodsmnotify @administrators hibdbg:wake_title \
						hibdbg:wake_msg 2>/dev/null || true
				fi
			fi
		else
			echo > "$T/trace"
		fi
		sleepy=0
		for d in /dev/sata[0-9]*; do
			case "$d" in *p[0-9]*) continue;; esac
			case "$(hdparm -C "$d" 2>/dev/null)" in
			*standby*|*sleeping*) sleepy=$((sleepy+1)) ;;
			esac
		done
		# cursors are refreshed only while every drive spins: querying fs
		# metadata against a sleeping drive could itself wake it
		if [ "$sleepy" -eq 0 ]; then
			fs_mark
		fi
		# the page-cache tracepoint fires on every cached read, so it is
		# armed only while a drive sleeps -- when a hit is by definition a
		# wake. Both writes are idempotent, no transition state to keep.
		if [ -n "$FM" ]; then
			if [ "$sleepy" -gt 0 ]; then
				# no filter, no tracing: unfiltered it would record
				# every cached read on every filesystem
				if fmfilter > "$FM/filter" 2>/dev/null; then
					echo 1 > "$FM/enable"
				else
					FM=""
				fi
			else
				echo 0 > "$FM/enable"
				echo > "$TR/trace"
			fi
		fi
		# background + wait: bash delivers TERM only after a foreground
		# child exits, which made stop take up to a full minute
		sleep 60 & wait $!
	done ;;

dsm)	case "${2:-}" in
	debug)	# DSM's own hibernation debug logging. Harmless to HDDs since
		# sysmig (md0 on NVMe), but it arms block_dump behind the
		# recorder's back. Restarting scemd resets the idle clock.
		case "${3:-}" in
		on)	synosetkeyvalue /etc/synoinfo.conf enable_hibernation_debug yes
			synosetkeyvalue /etc/synoinfo.conf hibernation_debug_level 1
			systemctl restart scemd
			echo "debug on, scemd restarted (idle clock reset)"
			echo "verify in ~2min: ls -la /var/log/hibernation*.log" ;;
		off)	synosetkeyvalue /etc/synoinfo.conf enable_hibernation_debug no
			synosetkeyvalue /etc/synoinfo.conf hibernation_debug_level 0
			systemctl restart scemd
			echo 0 > /proc/sys/vm/block_dump
			echo "debug off; block_dump disarmed" ;;
		*)	die "usage: hibdbg dsm debug on|off" ;;
		esac ;;
	log)	# scemd's hibernation decisions and wake reasons
		f=/var/log/scemd.log
		[ -f "$f" ] || die "no $f"
		grep -iE 'hibernat|standby|spindown|wake|idle' "$f" | tail -"${3:-40}"
		echo "-- /var/log/hibernation.log (scemd narration, needs dsm debug on):"
		tail -"${3:-40}" /var/log/hibernation.log 2>/dev/null || echo "  (absent)"
		echo "-- other hibernation logs present:"
		ls -la /var/log/hibernation* 2>/dev/null || echo "  (none)" ;;
	sched)	echo "== /etc/crontab =="
		grep -vE '^#|^ *$' /etc/crontab 2>/dev/null || true
		echo "== synocrond jobs =="
		for f in /usr/syno/etc/synocrond.config /usr/syno/etc/synocron.d/*.conf; do
			[ -f "$f" ] && { echo "-- $f"; cat "$f"; }
		done 2>/dev/null || true
		echo "== smart self-test =="
		for d in /dev/sata[0-9]*; do case "$d" in *p*) continue;; esac
			printf '%s: ' "$d"; smartctl -c "$d" 2>/dev/null | grep -A1 'Self-test execution' | tail -1
		done ;;
	smb)	smbstatus -v 2>/dev/null; echo; smbstatus -L 2>/dev/null ;;
	nfs)	netstat -tn 2>/dev/null | grep :2049 || echo "no tcp nfs connections"
		echo
		showmount -a localhost 2>/dev/null || true
		cat /proc/fs/nfsd/clients/*/info 2>/dev/null || true ;;
	*)	die "usage: hibdbg dsm debug|log|sched|smb|nfs ..." ;;
	esac ;;

boot)	# idempotent boot task. DSM reverts both hacks at boot: restores stock
	# sg_raw AND re-adds HDD members to md0/md1 (system partition
	# auto-repair). Re-assert all three. Task Scheduler:
	# Triggered > Boot-up > root: /path/hibdbg.sh boot
	"$0" fix shim on
	"$0" fix sysmig
	"$0" fix sleepd start
	"$0" watch start ;;

*)	die "unknown command: $1 (hibdbg --help for the list)" ;;
esac
