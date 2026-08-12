#!/bin/bash
# hibdbg - find and silence what keeps Synology disks awake. Run as root.
set -eu

# sudo PATH on DSM lacks /usr/bin (pgrep, etc.)
export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

LOG=/var/log/hibernationFull.log
DEF_MIN=60
# recordings must not land on md0 (8G, fills up); home sits on a volume
RECBASE=$(dirname "$(readlink -f "$0")")

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || echo "note: not root; privileged steps fail if unpermitted" >&2

num() { case "$1" in ''|*[!0-9]*) die "$2: expected a number, got '$1'" ;; esac; }

denoise() { grep -vE 'ppid:[0-9]+\(syno_hibernatio' || true; }

recent() {
	awk -v min="$1" '
	BEGIN { getline up < "/proc/uptime"; split(up, a, " "); now = a[1]; cut = now - min*60 }
	{
		if (match($0, /\[[0-9]+\.[0-9]+\]/)) {
			ts = substr($0, RSTART+1, RLENGTH-2) + 0
			if (ts >= cut && ts <= now) print
		}
	}'
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

hdd_pat() {
	local dms
	dms=$(hdd_dms | tr '\n' '|'); dms=${dms%|}
	[ -n "$dms" ] || die "no HDD dm layers found; use raw 'dm-3|dm-4|dm-6'"
	echo "on ($dms|md[2-9][0-9]*|sata[0-9]+) "
}

SYSPAT='on (md0|md1|sata[0-9]+p[125]) '

agg_proc() { sed -E 's/.*pid:[0-9]+\(([^)]*)\), (READ|WRITE|dirtied).*/\1 \2/' | sort | uniq -c | sort -rn || true; }
agg_ppid() { sed -E 's/.*ppid:[0-9]+\(([^)]*)\), pid:[0-9]+\(([^)]*)\).*/\1 -> \2/' | sort | uniq -c | sort -rn || true; }
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

rq_agg() { sed -E 's/.*block_rq_issue: ([0-9]+,[0-9]+) ([A-Z]*).*\[([^]]*)\]$/\1 \2 \3/' | sort | uniq -c | sort -rn; }

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
usage: hibdbg <cmd> [args]        hibdbg <cmd> --help for detail
 discovery
  map                 device topology
  audit               status of disk-writing DSM components + tunables
  sched               crontab, synocrond jobs, smart schedules
 tracing (writes to md0 itself; prefer md0/md0files for system-side)
  on|off              toggle block-dump tracing
  hdd [min]           HDD-volume offenders from $LOG
  sys [min]           system-partition offenders from $LOG
  raw PAT [min]       custom device pattern
  tree [min]          parent -> child of HDD writers
  files PROC [min]    paths PROC dirtied
  when PROC [min]     wallclock timestamps (spot periodicity)
 feedback-free (pauses syslog-ng during sample)
  md0 [sec]           system-partition writers via ring buffer (def 120)
  md0files [sec]      dirtied paths on md0
  who [devpat] [sec]  writers + dirtied paths on any devices (def all, 60s)
 ground truth
  live [sec]          diskstats delta (def 10)
  rq [sec]            every sata queue request incl. passthrough (def 120)
  pollwho [sec] [comm]  parent chain of short-lived helper spawns (def sg_raw)
  state               HDD power state (non-waking)
  smb / nfs           client sessions
 mitigation
  quiesce             stop+disable index daemons, purge stale queues
  unquiesce           re-enable indexing
  hib [min|undo]      show hibernation keys / set standbytimer / undo
  hiblog [n]          scemd hibernation decisions / wake reasons (def 40)
  hibdebug on|off     DSM hibernation debug logging (safe post-sysmig)
  sysmig              migrate md0/md1 system arrays HDD -> NVMe (re-run until done)
  pollshim on|off|status  cache scemd SCT polls while drives sleep (no wake)
  sleepd start|stop|status  DIY standby daemon (needs pollshim)
  boot                idempotent boot task: pollshim on + sysmig + sleepd start
  calm [sec]          batch md0 journal+writeback (def 600s); print persist hint
  uncalm              restore defaults
  calm3 [sec]         batch volume3 btrfs commits (def 600s)
  uncalm3             restore volume3 commit=30s
 tracer-free attribution
  logs [sec]          /var/log file growth + tails (def 120s); finds chatty services
  fresh [min] [path]  files modified in last MIN min (def 10, /volume3)
 long recording
  rec [sec]           background all-instrument recorder (def 4h), survives
                      logout; writes <scriptdir>/hibdbg.rec.<ts>/
  recstop             stop the latest recording
  recsum DIR          summarize a recording (episodes, states, attribution)
  recwakes DIR        per-wake table: duration, I/O, what woke it
  recwho DIR COMM     parent chains for COMM execs in a recording
 one-shot
  sleepnow [sec] [nopoll]  force standby, report wakes; nopoll stops scemd
                      (SCT temp polls off, fans hold speed) for the window
  probe               live + state + md0 trace + lcc delta, with verdict key
  rootspace           md0 space breakdown (what filled the system partition)
  lcc [sec]           SMART load-cycle counters; with SEC show delta (non-waking)
  disks               model/serial/firmware per drive (non-waking)
USAGE
}

# hibdbg <cmd> --help. Commands whose behaviour needs more than the one-line
# summary get a block here; the rest fall back to their line in usage().
help_cmd() {
	case "$1" in
	rec) cat <<'EOF'
usage: hibdbg rec [sec]                                        (default 14400)

Detached all-instrument recorder; survives ssh logout (setsid). Writes into
<scriptdir>/hibdbg.rec.<timestamp>/ -- keep the script on an SSD volume, never
on the drives under test, and never on / (md0 is 8G; see rootspace).

  block.log      sata queue requests, incl. ATA passthrough  (uncompressed)
  fork.log.gz    fork/exec graph, the bulk of the data       (~3G/day)
  blockdump.log  process + dirtied-path attribution, HDD stack only
  diskstats.log  30s I/O snapshots        state.log  30s power state
  meta           start/end, device numbers, block_dump pattern

syslog-ng stays stopped for the whole recording (its writes would be measured
as disk activity). Run only one block_dump-family and one tracepoint-family
instrument at a time; concurrent recorders starve each other's traces.

A full day is the shortest run that separates scheduled wakes from real use.
Analyze with recwakes (per-wake attribution), recsum (raw timeline), recwho.
EOF
	;;
	recwakes) cat <<'EOF'
usage: hibdbg recwakes DIR

One block per wake episode: wake -> sleep time, duration, total sata reads and
writes, then the top processes and dirtied paths from the FIRST 15 MINUTES.

That cutoff is the point of the command. Only the opening minutes identify
what woke the drive; everything later is unrelated work piggybacking on an
already-spinning disk, which is what makes a raw timeline unreadable.

Reads state.log, diskstats.log and blockdump.log; needs no root. Timing rides
the 30s sample grid rather than date arithmetic (DSM's date may lack -d).

Avoidable vs legitimate is your call: nfsd/smbd reads in the opening window are
your own access; synosharesnapsh, synoretainer, synostgreclaim, btrfs-transacti
on a backup .tmp file are scheduled jobs you can retime or relocate.
EOF
	;;
	recsum) cat <<'EOF'
usage: hibdbg recsum DIR

Flat summary of a recording: every 30s interval in which sata counters moved,
drive state transitions, aggregated block_dump processes and dirtied paths,
queue requests by issuer, and the storage helpers that were exec'd.

Use recwakes first -- it attributes each wake. recsum is the raw view for when
you already know which episode you care about. Needs no root.
EOF
	;;
	recwho) cat <<'EOF'
usage: hibdbg recwho DIR COMM

Parent chains for every exec of COMM in a recording: grandparent -> parent ->
COMM, aggregated by frequency. Names the daemon behind millisecond-lived
helpers (sg_raw, cryptsetup, ffprobe) that /proc sampling can never catch.

Streams the compressed fork graph in three passes (exec pids, their forks,
grandparents), so a day-long recording takes minutes, not hours. No root.
EOF
	;;
	recstop) cat <<'EOF'
usage: hibdbg recstop

Stops the most recent recording under the script's directory: disarms the
tracepoints, clears block_dump, and restarts syslog-ng. Always use this rather
than killing the process, or syslog-ng stays stopped and tracing stays armed.
EOF
	;;
	rootspace) cat <<'EOF'
usage: hibdbg rootspace

Breakdown of the 8G system partition (md0): top-level directories, files over
50M, /var/log sizes, recordings, and leftover tracing state.

Run this when DSM reports "the free space of system partition is insufficient"
on a package update. Usual causes are a recording left in /root and /var/log
grown by block_dump lines after a recorder died without clearing it.
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
	sleepd) cat <<'EOF'
usage: hibdbg sleepd start|stop|status

DIY standby daemon with hd-idle semantics: watches /proc/diskstats and issues
hdparm -y per drive after standbytimer idle minutes. The timer is DSM's own
setting, re-read every cycle, so hib MIN or the DSM UI takes effect without a
restart; standbytimer=0 is DSM's "hibernation off" and stops nothing. DSM's own
idle timer never fires on this box (NVMe pool activity vetoes it), which is why
this exists.

Issuing standby resets the idle clock for that drive. Passthrough wakes move no
diskstats counter, so without that reset an expired clock re-stops the drive
seconds after every spin-up.

Refuses to start, and exits if the shim disappears, unless pollshim is
installed: scemd's polls would wake the drives right back and the pair would
churn start/stop cycles. Reverted at boot -- see boot.
EOF
	;;
	pollshim) cat <<'EOF'
usage: hibdbg pollshim on|off|status

Wraps /usr/syno/bin/sg_raw (original kept as sg_raw.real). While a drive is in
standby, SCT status reads (ATA PASS-THROUGH, CDB byte 2f) are answered from a
cached response instead of being passed to the disk; every other command goes
straight through. scemd issues those reads every 10-20s and each one spins a
sleeping drive back up -- without this, standby cannot hold.

The standby test is hdparm -C, which does not itself wake the drive. "on" is
idempotent. DSM restores the stock binary at every boot; "status" reports the
install state and cache hits, and audit shows it too.
EOF
	;;
	sysmig) cat <<'EOF'
usage: hibdbg sysmig

Migrates the DSM system arrays (md0 = /, md1 = swap) off the HDDs onto the
NVMe drives, one safe step per run -- re-run until it reports done. Adds the
NVMe system partitions, waits for resync, then fails and removes the sata
members and shrinks the arrays to two devices.

DSM mirrors its OS onto every data drive, so the root filesystem alone keeps
the HDDs awake regardless of which userspace writers you silence. After this,
Storage Manager permanently shows "system partition failed" on BOTH HDDs: that
is the correct state, and Repair undoes the migration. See SYSMIG.md.
EOF
	;;
	boot) cat <<'EOF'
usage: hibdbg boot

Re-asserts the whole stack, idempotently: pollshim on, sysmig, sleepd start.

DSM reverts the wrapper binary and re-adds the HDD members to md0/md1 at every
boot, not just across updates. Register this as a Task Scheduler triggered
task (Boot-up, user root) or the stack silently degrades after any reboot.
EOF
	;;
	hib) cat <<'EOF'
usage: hibdbg hib [MIN|undo]

No argument shows the hibernation-related keys from scemd.xml and both
synoinfo.conf files. MIN sets standbytimer (minutes), recording the previous
value so undo can restore it, and restarts scemd. sleepd picks the new value
up on its next cycle, no restart needed.

This sets the idle threshold only. DSM's native hibernation still will not
fire on this box; standby comes from sleepd.
EOF
	;;
	who) cat <<'EOF'
usage: hibdbg who [devpat] [sec]                        (default all, 60s)

Feedback-free attribution: arms block_dump, pauses syslog-ng so the tracing
does not generate the disk writes it is measuring, samples the kernel ring for
SEC seconds, then reports writers and dirtied paths. devpat is an extended
regex over device names (e.g. "dm-3|md4|sata1").

Note that block_dump cannot see SG_IO/ATA passthrough -- use rq for that.
EOF
	;;
	rq) cat <<'EOF'
usage: hibdbg rq [sec]                                         (default 120)

Every request that reaches a sata queue, via the block:block_rq_issue
tracepoint, with issuing process and CDB bytes. This is the only instrument
that sees ATA passthrough: the SCT temperature polls are invisible to both
block_dump and diskstats, and they are what defeats standby.

Blocks for SEC seconds. Filtered to sata devices by kernel dev_t.
EOF
	;;
	*)	usage | grep -E "^  $1( |\||\$)" \
			|| die "unknown command: $1 (hibdbg --help for the list)" ;;
	esac
}

# "hibdbg <cmd> --help" documents that command; "--help" alone lists them all
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

case "${1:-}" in

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

on)	echo 1 > /proc/sys/vm/block_dump; echo "tracing on -> dmesg / $LOG" ;;
off)	echo 0 > /proc/sys/vm/block_dump; echo "tracing off"
	if pgrep -f syno_hibernatio >/dev/null 2>&1; then
		echo "WARNING: DSM's syno_hibernatio debug daemon is running;"
		echo "it re-arms tracing and writes $LOG continuously (this is"
		echo "itself md0 disk load). Disable: Support Center -> Support"
		echo "Services -> system hibernation debugging mode -> uncheck."
	fi ;;

hdd)	grep -E "$(hdd_pat)" "$LOG" | recent "${2:-$DEF_MIN}" | denoise | agg_proc ;;

sys)	grep -E "$SYSPAT" "$LOG" | recent "${2:-$DEF_MIN}" | denoise \
	| sed -E 's/.*pid:[0-9]+\(([^)]*)\).*/\1/' | sort | uniq -c | sort -rn ;;

raw)	[ -n "${2:-}" ] || die "usage: hibdbg raw <egrep-pattern> [min]"
	grep -E "on (${2}) " "$LOG" | recent "${3:-$DEF_MIN}" | denoise | agg_proc ;;

tree)	grep -E "$(hdd_pat)" "$LOG" | recent "${2:-$DEF_MIN}" | agg_ppid ;;

files)	[ -n "${2:-}" ] || die "usage: hibdbg files <procname> [min]"
	grep "($2)" "$LOG" | recent "${3:-$DEF_MIN}" | agg_path | head -30 ;;

when)	[ -n "${2:-}" ] || die "usage: hibdbg when <procname> [min]"
	grep "($2)" "$LOG" | recent "${3:-$DEF_MIN}" \
	| awk '
	BEGIN { getline up < "/proc/uptime"; split(up,a," "); boot = systime() - a[1] }
	match($0, /\[[0-9]+\.[0-9]+\]/) {
		ts = substr($0, RSTART+1, RLENGTH-2) + 0
		t = int(boot + ts)
		if (t != last) { print strftime("%H:%M:%S", t); last = t }
	}' | uniq -c ;;

md0)	# hibdbg md0 [sec]: trace system-partition writers via ring buffer,
	# syslog-ng paused during sampling -> no self-feedback. default 120s
	ringsample "${2:-120}" | grep -E "$SYSPAT" | denoise | agg_proc ;;

md0files) # hibdbg md0files [sec]: which paths get dirtied on md0/md1 only
	ringsample "${2:-120}" | grep -E "$SYSPAT" | denoise | agg_path | head -40 ;;

who)	# hibdbg who [devpat] [sec]: attribute writes on any devices via ring
	# buffer (feedback-free). dirtied paths answer the "why". def: all devs
	pat="${2:-[^ ]+}"
	out=$(ringsample "${3:-60}" | grep -E "on (${pat})( |\$)" | denoise)
	[ -n "$out" ] || { echo "no events on (${pat}) in window"; exit 0; }
	echo "== processes =="
	echo "$out" | agg_proc
	echo "== dirtied paths =="
	echo "$out" | agg_path | head -30 ;;

rq)	# hibdbg rq [sec]: every request hitting sata queues via block_rq_issue
	# tracepoint -- sees passthrough/SG_IO that block_dump and diskstats miss
	sec=${2:-120}
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

fresh)	# hibdbg fresh [min] [path]: files modified in the last MIN minutes
	# (mtime attribution, tracer-free). Full metadata walk: generates reads.
	find "${3:-/volume3}" -xdev -type f -mmin "-${2:-10}" ! -path '*/@eaDir/*' \
		-exec stat -c '%Y %12s %n' {} + 2>/dev/null | sort -rn | head -40 \
	| gawk '{$1=strftime("%H:%M:%S",$1); print}'
	echo "-- end (top 40 by mtime)" ;;

hibdebug) # hibdbg hibdebug on|off: DSM's own hibernation debug logging.
	# Harmless to HDDs since sysmig (md0 on NVMe). Restarting scemd
	# resets the idle clock. Verify 'on' took: hibernation*.log must grow.
	case "${2:-}" in
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
	*)	die "usage: hibdbg hibdebug on|off" ;;
	esac ;;

hiblog)	# hibdbg hiblog [n]: scemd's hibernation decisions and wake reasons
	f=/var/log/scemd.log
	[ -f "$f" ] || die "no $f"
	grep -iE 'hibernat|standby|spindown|wake|idle' "$f" | tail -"${2:-40}"
	echo "-- /var/log/hibernation.log (scemd narration, needs hibdebug on):"
	tail -"${2:-40}" /var/log/hibernation.log 2>/dev/null || echo "  (absent)"
	echo "-- other hibernation logs present:"
	ls -la /var/log/hibernation* 2>/dev/null || echo "  (none)" ;;

pollwho) # hibdbg pollwho [sec] [comm]: name the daemon spawning short-lived
	# helpers (def sg_raw). /proc sampling loses the ~ms race; fork/exec
	# tracepoints catch every spawn and give the parent chain
	sec=${2:-30}
	c=${3:-sg_raw}
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

smb)	smbstatus -v 2>/dev/null; echo; smbstatus -L 2>/dev/null ;;

nfs)	netstat -tn 2>/dev/null | grep :2049 || echo "no tcp nfs connections"
	echo
	showmount -a localhost 2>/dev/null || true
	cat /proc/fs/nfsd/clients/*/info 2>/dev/null || true ;;

live)	a=$(grep -E ' (sata[0-9]+|nvme[0-9]+n1|md[0-9]+|dm-[0-9]+) ' /proc/diskstats)
	sleep "${2:-10}"
	b=$(grep -E ' (sata[0-9]+|nvme[0-9]+n1|md[0-9]+|dm-[0-9]+) ' /proc/diskstats)
	echo "dev     reads+ writes+"
	join -j1 <(echo "$a" | awk '{print $3, $4, $8}' | sort) \
	          <(echo "$b" | awk '{print $3, $4, $8}' | sort) \
	| awk '$4-$2 || $5-$3 {printf "%-8s %6d %6d\n", $1, $4-$2, $5-$3}' ;;

state)	for d in /dev/sata[0-9]*; do
		case "$d" in *p[0-9]*) continue;; esac
		printf '%s: ' "$d"; hdparm -C "$d" 2>/dev/null | grep -o 'drive state is:.*' || echo '?'
	done ;;

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
	pgrep -f 'hibdbg.sh _sleepd' >/dev/null \
		&& echo "sleepd:   running" || echo "sleepd:   not running" ;;

calm)	# hibdbg calm [sec]: batch md0 writes. remount commit=SEC (default 600)
	# + relax dirty writeback so flushes coalesce
	sec=${2:-600}
	mount -o remount,commit="$sec" /
	echo $((sec*100)) > /proc/sys/vm/dirty_expire_centisecs
	echo 6000 > /proc/sys/vm/dirty_writeback_centisecs
	echo "md0 journal commit=${sec}s, expire=${sec}s, writeback=60s"
	echo "persist: Task Scheduler > Triggered > Boot-up > root:"
	echo "  $(readlink -f "$0") calm $sec" ;;

uncalm)	mount -o remount,commit=5 /
	echo 3000 > /proc/sys/vm/dirty_expire_centisecs
	echo 500 > /proc/sys/vm/dirty_writeback_centisecs
	echo "defaults restored (commit=5s, expire=30s, writeback=5s)" ;;

calm3)	# hibdbg calm3 [sec]: batch volume3 btrfs commits (def 600s).
	# One flush burst per interval instead of every 30s; up to SEC seconds
	# of buffered writes lost on power failure.
	sec=${2:-600}
	mount -o remount,commit="$sec" /volume3
	echo "volume3 commit=${sec}s"
	echo "persist: Task Scheduler > Triggered > Boot-up > root:"
	echo "  $(readlink -f "$0") calm3 $sec" ;;

uncalm3) mount -o remount,commit=30 /volume3
	echo "volume3 commit=30s (btrfs default)" ;;


lcc)	# hibdbg lcc [sec]: SMART load-cycle counters; with SEC, show delta.
	# uses -n standby: never wakes a sleeping drive
	snap() {
		for d in /dev/sata[0-9]*; do
			case "$d" in *p[0-9]*) continue;; esac
			smartctl -n standby -A "$d" 2>/dev/null \
			| awk -v d="$d" '$2 ~ /Load_Cycle_Count|Start_Stop_Count|Power-Off_Retract/ \
				{printf "%s %s %s\n", d, $2, $10}'
		done
	}
	if [ -n "${2:-}" ]; then
		a=$(snap); sleep "$2"; b=$(snap)
		echo "counter                        before after delta"
		join -j1 <(echo "$a" | awk '{print $1"_"$2, $3}' | sort) \
		         <(echo "$b" | awk '{print $1"_"$2, $3}' | sort) \
		| awk '{printf "%-30s %6d %6d %5d\n", $1, $2, $3, $3-$2}'
	else
		snap
	fi ;;

probe)	# hibdbg probe: one-shot verdict pass.
	# 1) diskstats delta  2) power state  3) feedback-free md0 trace  4) lcc delta
	echo "== live 60s (diskstats truth) =="
	"$0" live 60
	echo; echo "== drive power state =="
	"$0" state
	echo; echo "== md0 writers, 180s ring-buffer trace (syslog-ng paused) =="
	"$0" md0 180
	echo; echo "== load-cycle delta over the same period (600s total) =="
	"$0" lcc 300
	echo; echo "read: live=0 + lcc delta>0  -> drive-internal head parks (hdparm -B)"
	echo "      live>0                    -> md0 section names the writer"
	echo "      live=0 + lcc delta=0     -> quiet; sleepd will reach standby" ;;


logs)	# hibdbg logs [sec]: growth per file under /var/log (tracer-free).
	# names the files syslog-ng & friends are actually growing; tails top text growers
	sec=${2:-120}
	snap_sizes() { find /var/log -type f -exec stat -c '%s %n' {} + 2>/dev/null | sort -k2; }
	a=$(snap_sizes); sleep "$sec"; b=$(snap_sizes)
	growth=$(join -j2 <(echo "$a") <(echo "$b") \
	| awk '$3>$2 {printf "%10d %s\n", $3-$2, $1}' | sort -rn)
	if [ -z "$growth" ]; then echo "no growth under /var/log in ${sec}s"; exit 0; fi
	echo "bytes-grown file"
	echo "$growth"
	echo
	echo "$growth" | head -3 | awk '{print $2}' | while read -r f; do
		case "$f" in *.db|*.db-*|*.xz|*.gz|*.zst) continue;; esac
		echo "== tail $f =="; tail -5 "$f" 2>/dev/null; echo
	done ;;


disks)	# model / serial / firmware per drive (identify data; no spin-up)
	for d in /dev/sata[0-9]*; do
		case "$d" in *p[0-9]*) continue;; esac
		echo "== $d =="
		smartctl -n standby -i "$d" 2>/dev/null \
		| grep -E 'Device Model|Serial Number|Firmware Version|Rotation|Model Family' \
		|| echo "  (in standby or no smart)"
	done ;;


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

rec)	# hibdbg rec [sec]: all-instrument background recorder; survives ssh
	# logout (setsid). Collects into $RECBASE/hibdbg.rec.<ts>/ :
	#   blockdump.log  block_dump events on the HDD stack (proc + paths)
	#   block.log      block_rq_issue (sata, incl passthrough)
	#   fork.log.gz    fork/exec graph (bulk; ~3G/day gzipped)
	#   diskstats.log  30s diskstats snapshots   state.log  30s power state
	# syslog-ng is stopped for the whole recording. Analyze: recsum DIR
	dur=${2:-14400}; num "$dur" "rec [sec]"
	d="$RECBASE/hibdbg.rec.$(date +%Y%m%d-%H%M%S)"
	mkdir "$d"
	setsid "$0" _rec "$dur" "$d" >/dev/null 2>&1 < /dev/null &
	echo "recording ${dur}s -> $d"
	echo "stop early: $0 recstop   analyze: $0 recsum $d" ;;

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

recwho)	# hibdbg recwho DIR COMM: parent chains for COMM execs in a recording.
	# fork.log.gz is too big to grep per-pid; extract the COMM-relevant
	# slice in 3 streaming passes, then run forkchain on the extract.
	d=${2:?usage: hibdbg recwho DIR COMM}; c=${3:?comm}
	ex=$(zcat -q "$d/fork.log.gz" | grep sched_process_exec | grep "$c" || true)
	[ -n "$ex" ] || die "no $c exec in $d"
	pat=$(echo "$ex" | sed -E 's/.* pid=([0-9]+).*/\1/' | sort -u | paste -sd'|' -)
	pf=$(zcat -q "$d/fork.log.gz" \
		| grep -E "sched_process_fork.*child_pid=($pat)( |\$)" || true)
	gpat=$(echo "$pf" | sed -E 's/.*comm=[^ ]+ pid=([0-9]+).*/\1/' | sort -u | paste -sd'|' -)
	gf=$([ -n "$gpat" ] && zcat -q "$d/fork.log.gz" \
		| grep -E "sched_process_fork.*child_pid=($gpat)( |\$)" || true)
	tmp=$(mktemp)
	printf '%s\n%s\n%s\n' "$ex" "$pf" "$gf" > "$tmp"
	forkchain "$tmp" "$c"
	rm -f "$tmp" ;;

recstop) d=$(ls -dt "$RECBASE"/hibdbg.rec.*/ 2>/dev/null | head -1)
	[ -n "$d" ] || die "no recordings under $RECBASE"
	kill "$(cat "${d}pid")" 2>/dev/null && echo "stopped ${d%/}" \
		|| echo "not running (${d%/})" ;;

recsum)	d=${2:?usage: hibdbg recsum DIR}
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
	echo "== exec'd storage tools (full graph stays in fork.log.gz for recwho) =="
	zcat -q "$d/fork.log.gz" 2>/dev/null | grep sched_process_exec \
	| sed -E 's/.*filename=([^ ]+).*/\1/' \
	| grep -E 'sg_raw|cryptsetup|hdparm|smartctl|synospace|synofstool|synostgd|dmsetup|mdadm|btrfs' \
	| sort | uniq -c | sort -rn | head -20 ;;

recwakes) # hibdbg recwakes DIR: one block per wake episode — duration, sata
	# I/O totals, and block_dump attribution from the first 15 min (the
	# waker; later activity piggybacks on an already-spinning drive).
	# All timing rides the 30s state.log sample grid: no date arithmetic.
	d=${2:?usage: hibdbg recwakes DIR}
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

sysmig)	# hibdbg sysmig: migrate DSM system arrays (md0=/, md1=swap) off the
	# HDDs onto the NVMe system partitions. Idempotent: one safe step per
	# run, re-run until both report done. Never click DSM's "Repair" after.
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

pollshim) # hibdbg pollshim on|off|status: wrap /usr/syno/bin/sg_raw so scemd's
	# SCT temperature polls against a standby drive are served from cache
	# instead of waking it. Passthrough for non-sata targets and non-read
	# CDBs. Survives until a DSM update restores the stock binary (audit
	# reports it). off = restore original.
	B=/usr/syno/bin/sg_raw
	case "${2:-}" in
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
		echo "installed; verify: pollshim status after next poll (~20s)" ;;
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
	*)	die "usage: hibdbg pollshim on|off|status" ;;
	esac ;;

sleepd)	# hibdbg sleepd start|stop|status: DIY standby daemon (hd-idle
	# semantics). Issues hdparm -y per drive after standbytimer idle
	# minutes, re-read every cycle. Requires pollshim, else scemd's
	# polls wake the drives right back (proven) and the pair would churn.
	case "${2:-}" in
	start)
		grep -q pollshim /usr/syno/bin/sg_raw 2>/dev/null \
			|| die "pollshim not installed; refusing (polls would wake drives)"
		if pgrep -f 'hibdbg.sh _sleepd' >/dev/null; then
			echo "already running"; exit 0
		fi
		setsid "$0" _sleepd >/dev/null 2>&1 < /dev/null &
		cur=$(synogetkeyvalue /etc/synoinfo.conf standbytimer 2>/dev/null)
		echo "sleepd started (standbytimer ${cur:-0}m -> standby; 0 = off)"
		echo "persist: Task Scheduler > Triggered > Boot-up > root:"
		echo "  $(readlink -f "$0") sleepd start" ;;
	stop)	pkill -f 'hibdbg.sh _sleepd' && echo "stopped" || echo "not running" ;;
	status)	pgrep -f 'hibdbg.sh _sleepd' >/dev/null && echo "running" || echo "not running"
		"$0" state ;;
	*)	die "usage: hibdbg sleepd start|stop|status" ;;
	esac ;;

_sleepd) declare -A last prev
	while :; do
		# shim gone (boot/update restored stock sg_raw): polls wake drives
		# again -> issuing standby would churn cycles; die, audit shows it
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
					# a wake carried by passthrough moves no diskstats counter,
					# so without this the clock stays expired and every cycle
					# re-stops the drive seconds after it spins up
					last[$name]=$now
				fi
			fi
		done < <(grep -E ' sata[0-9]+ ' /proc/diskstats | awk '{print $3, $4, $8}')
		sleep 60
	done ;;

boot)	# hibdbg boot: idempotent boot task. DSM reverts both hacks at boot:
	# restores stock sg_raw AND re-adds HDD members to md0/md1 (system
	# partition auto-repair). Re-assert all three. Task Scheduler:
	# Triggered > Boot-up > root: /path/hibdbg.sh boot
	"$0" pollshim on
	"$0" sysmig
	"$0" sleepd start ;;

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


sleepnow) # hibdbg sleepnow [sec]: force standby, record full wake timeline
	# with kernel-attributed events. syslog-ng paused for the window
	# (trace must not persist to md0). Do not run other commands meanwhile.
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
	"$0" state    # before syslog-ng returns and wakes md0
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

rootspace)
	echo "== md0 =="
	df -h /
	echo; echo "== top-level dirs (md0 only) =="
	du -xhd1 / 2>/dev/null | sort -rh | head -15
	echo; echo "== files >50M on md0 =="
	find / -xdev -type f -size +50M 2>/dev/null | xargs -r du -h | sort -rh | head -20
	echo; echo "== /var/log by size =="
	du -sh /var/log/* 2>/dev/null | sort -rh | head -15
	echo; echo "== recordings on md0 =="
	du -sh /root/hibdbg.rec.* 2>/dev/null || echo "(none)"
	echo; echo "== leftover instrument state =="
	echo "block_dump=$(cat /proc/sys/vm/block_dump)"
	pgrep -af 'hibdbg.*_rec|cat.*trace_pipe' || echo "no stray recorder processes" ;;

*)	usage ;;
esac
