# Architecture decisions

## ADR 8: `calm` leaves the boot task; swap is released

2026-09-14

`fix calm` (ext4 `commit=600` on `/`) was meant to coalesce the system
partition's writes. ADR 7's recordings showed its limit and its cost: the
writers that actually ended standby were sqlite WALs, which fsync and so
commit the journal regardless of the interval, while a 600 s window
collided exactly with a 10-minute idle timer and turned every flush into a
clock reset. Meanwhile up to ten minutes of unsynced metadata on the system
partition would die with the power, which this box has now lost once. With
`/var/log` off md0 the remaining benefit is nil; `calm` stays as an
experiment knob and is no longer re-asserted.

`md1` (swap) is mirrored on the HDDs like `md0`, so any paging is a
spin-up. `boot` now releases it. No SSD-backed replacement exists on this
kernel: btrfs swapfiles need 5.0+, DSM ships 4.4; a swap partition on the
NVMe would mean creating an array DSM does not know about. The box runs
without swap; `free -m` decides whether that holds.

## ADR 7: DSM's logs move to the SSD; the system partition stays put

2026-09-14

### Context

ADR 6 left md0 on the HDDs. Two-hour recordings with every application
writer scheduled away still never reached the idle timer in normal
operation, and the one standby that did occur (24 min) was ended by
`synostgd-disk` writing `.SYNODISKDB-wal`. Every residual writer lived under
`/var/log`: DSM's log files and the sqlite databases behind Log Center and
Storage Manager. `fix calm` does not reach them -- sqlite fsyncs its WAL,
which commits the journal regardless of `commit=`. The recording instruments
had hidden this: block_dump-based commands pause syslog-ng, so the
measurements were quieter than the box.

### Decision

`fix logs on` bind-mounts `/var/log` onto `<vol>/@varlog` on the SSD volume
that holds the script, seeded once from the md0 copy, and restarts the
services found still holding files on the old copy. `boot` re-asserts it.

### Consequences

- Nothing on md0 is relocated or rewritten, so there is no boot-time
  dependency and no rollback mode: without the bind DSM logs to md0 as
  stock and the mitigation merely lapses. This is the property ADR 6's
  migration lacked.
- Logs live on the SSD volume. Log Center, logrotate and the DSM UI see the
  same paths; nothing is configured, only mounted.
- The bind can only follow volume mount, which follows syslog-ng start, so
  services that opened files before it must be restarted -- detected by
  device number, not by a hard-coded list. At boot nothing is in use yet;
  by hand it is a visible restart of the listed services.
- `who`, `rec` and `sleepnow` still pause syslog-ng. With `/var/log` off
  the HDDs that pause no longer changes what the HDDs see, but it still
  hides syslog-ng from the writer lists.

## ADR 6: the system partition stays on the HDDs; `fix sysmig` is removed

2026-09-09

### Context

`fix sysmig` (2026-07-23) added the NVMe drives' system partitions to md0/md1
and stripped the HDD members, so that DSM's root filesystem would stop
writing to the drives meant to sleep. A power outage on 2026-09-08 exposed
how DSM assembles those arrays at boot:

    /sbin/mdadm /dev/md1 -A -u <uuid> --run /dev/sata2p2

An explicit list of SATA-bay partitions, `--run` forcing a degraded start,
NVMe partitions never offered. After the outage md0/md1 came up `[4/1]` on
`sata2p1`/`sata2p2` alone; the NVMe members, carrying the newest copy, were
simply not assembled. In this instance the root was still current because
the migration had never completed: `boot` runs sysmig once, and sysmig needs
a second run after the resync to strip the HDD members, which nobody made.

### Decision

The migration is withdrawn and its code deleted. md0/md1 keep DSM's stock
layout, mirrored across the SATA bays.

### Consequences

- Had the migration completed, every boot would have rolled the system
  partition back to the HDD copy frozen at strip time, discarding all DSM
  state written since (tasks, settings, package registrations), and the
  boot task would then have resynced the NVMe members from that stale copy.
  A one-time migration on DSM is a rollback time bomb, not a mitigation.
- Zeroing the stripped HDD superblocks is not a fix: it leaves DSM with no
  assemblable system array and no path to the NVMe copy.
- `md0` writes reach the HDDs again. The standby log shows the drives
  reaching the idle timer regularly even so; the system partition is a
  contributor, and `fix calm` batches its commits, but it is not the
  blocker. Wake attribution names the actual writers.
- The Storage Manager "system partition failed" warning is once more a real
  fault, and DSM's Repair is once more the right answer to it.

## ADR 5: read wakes are named by page-cache misses and /proc, in that order

2026-09-07

### Context

ADR 3 named written files from the btrfs change cursor, and the digests that
followed split the wakes in two. Writes were solved; reads were not. A read
wake shows a comm at the queue (`nfsd`, `libuv-worker`) but no path, because
`find-new` reports written extents only -- and the comm is a thread name, not
an application: `libuv-worker` is any Node process, `nfsd` is a kernel thread
whose real requester is a machine on the network.

### Decision

Reads that reach a sleeping disk are page-cache misses by definition, so a
second ftrace instance (`instances/hibread`) records
`mm_filemap_add_to_page_cache`, filtered to the HDD filesystems' `s_dev` and
armed only while a drive sleeps. Each record carries reader and inode; a new
`fsino_<fs>` hook turns the inode into a path (btrfs: `inspect-internal
inode-resolve`, backref lookup, no tree walk).

The issuer is resolved at wake time from `/proc` alone -- cmdline, parent, and
docker container id from the cgroup -- while the process that issued the
command still exists. `nfsd` additionally logs the live NFS peers, falling
back to the export table's client list.

### Consequences

- The read side gets its own ring: the spin-up requeue storm reaches ~20k
  lines in `hibwatch` and would evict the record that explains the wake.
- Arming is sleep-gated. The tracepoint fires on every cached read of the
  volume, which is unbearable while awake and exactly the wake evidence while
  asleep.
- If the filter cannot be installed the daemon leaves read tracing off for
  its lifetime rather than recording unfiltered: no attribution beats a
  flooded ring. Kernels without the tracepoint keep the queue-only headline.
- Attribution is resolved live, so it is only as good as the process still
  being alive one sample later. A short-lived reader leaves the path (from
  the fs hook) but no chain.
- `O_DIRECT` reads bypass the page cache and stay unnamed; btrfs metadata
  reads resolve to no path.


## ADR 4: daemons are managed by pidfiles under /run, not pgrep

2026-09-02

`watch` and `sleepd` were located with `pgrep -f 'hibdbg.sh _watch'`:
pattern-dependent (breaks if the script is renamed), no pid to inspect, and
`stop` was a blind `pkill`. Replaced with the conventional mechanism: each
daemon writes `/run/hibdbg/<name>.pid`, removed on exit. Liveness is the
pidfile plus a `/proc/<pid>/cmdline` check (pid reuse guard); `/run` is
tmpfs, so no stale pidfile survives a reboot. `stop` kills exactly that pid;
`status` prints it. Daemons started by pre-pidfile builds are invisible to
the new `stop` — kill them once by hand; no pgrep fallback is kept.

## ADR 3: buffered-write wakes are named by fs change cursors, not tracing

2026-09-02

### Context

ADR 2 accepted issuer-comm-only attribution, and the first night of digests
showed its limit: every wake was a small (~25 KB) buffered write surfacing at
the sata queue as `dmcrypt_write`/`kworker` — the btrfs → md → dm-crypt stack
strips the originator, so the queue can never name this wake class. Naming it
from the process side would need `writeback_dirty_inode` tracing plus inode
resolution; heavier, and the user-facing question is "what was written",
which the filesystem itself can answer.

### Decision

The daemon keeps a change cursor per HDD-backed mounted filesystem,
refreshed each minute — but only while every drive spins, since querying fs
metadata against a sleeping drive could itself wake it. At wake time it diffs
the cursor and logs the paths written while asleep; when no userspace comm
reached the queue, the headline names the first changed path instead of the
generic buffered-write line.

Cursor and diff are fs hooks dispatched on fstype (`fsmark_<fs>` /
`fsdiff_<fs>` pairs). btrfs implements them via the fs-wide transaction id
and `btrfs subvolume find-new` — an instant metadata delta, no tree walk, no
tracing; find-new does not recurse, so each share subvolume (root inode 256)
is diffed alongside the volume root. A filesystem without a hook pair keeps
the generic headline.

### Consequences

- Attribution is file-level, not process-level: the path names the app in
  practice. If ever ambiguous, `writeback_dirty_inode` in the hibwatch
  instance is the escalation, not the default.
- Pure-metadata wakes (renames, timestamps, md superblock housekeeping)
  produce an empty diff and fall back to the generic headline: find-new
  reports data extents.
- The cursor lags the last awake minute by at most 60 s, so a diff can
  include that final pre-sleep tail alongside the wake writes.

## ADR 2: `watch` — armed-while-asleep tracing, digest mail via Task Scheduler

2026-09-01

### Context

Wakes need attribution *and* notification, but the waker is only identifiable
if instrumentation was running before the wake — and the decisive wake class
is ATA passthrough, invisible to diskstats and block_dump. A permanent `rec`
is not an option: it stops syslog-ng and writes ~3 GB/day. For delivery, DSM
already has working email alerts, but exposes no CLI to its configured SMTP
(`/etc/ssmtp/ssmtp.conf` ships empty; `synonotify` sends only canned event
templates).

### Decision

A permanent daemon (`watch`, started by `boot`) keeps a private ftrace
instance (`instances/hibwatch`) armed on `block_rq_issue` filtered to the
sata queues: a RAM ring, no disk I/O, and separate enable/filter files so
`rec`, `who rq`, and `sleepnow` keep working unchanged. Drive state is
sampled once a minute with non-waking `hdparm -C`; any queue command not
issued by the stack's own probes (`hdparm`, `sg_raw*`) while a drive was in
standby on the previous sample is appended to `watch.log` as an episode with
its issuer and CDB.

Notification is digest-first: a daily DSM Task Scheduler task runs
`watch digest` with "Send run details by email" — Synology's own mail, no
credentials duplicated. `watch mode perwake` adds an immediate DSM
notification (`synodsmnotify`) per wake for live debugging; that binary
accepts only i18n string keys, so `watch start` registers a `[hibdbg]`
section in DSM's strings file (re-asserted at boot; DSM updates overwrite
it) and the push text is static — attribution stays in `watch.log` and the
digest. Per-wake *email* is deliberately not implemented.

### Consequences

- Attribution is issuer comm + CDB only; parent chains need `rec who`
  (fork tracing is the 3 GB/day component and stays out of the daemon).
- Wakes and re-sleeps completing between two 60s samples are still caught:
  the evidence is the ring content, not the state transition.
- Requires ftrace instance support in the kernel; the daemon refuses to
  start without it rather than fighting other tracers over the main buffer.
- One episode may cover several wakes inside a minute (natural collapse —
  a churn storm cannot spam notifications).

## ADR 1: `sleepd` takes its idle timer from DSM's `standbytimer`

2026-08-12

### Context

`sleepd` accepted an optional fixed interval (`sleepd start 60`) and only fell
back to `standbytimer` when none was given. That produced two failures on the
live box:

- The daemon ran at a fixed 60 minutes while the DSM UI said 3 hours. Two
  timers, one of them invisible in every DSM screen, and no way to tell from
  the UI which one governed.
- `boot` starts the daemon with no interval, so it tracked `standbytimer`.
  After hibernation was switched off in the UI that key became `0`, which is
  non-empty and therefore passed the existing `[ -n "$min" ]` guard, giving
  `min=0` and `now - last >= 0` on every pass. The next reboot would have
  stopped both drives on every cycle, permanently.

A third defect sat underneath both: `last[]` was assigned only when
`/proc/diskstats` changed, never when standby was issued. Wakes carried by ATA
passthrough move no diskstats counter (the reason `pollshim` exists at all), so
once the clock expired it stayed expired and the daemon re-stopped the drive on
the following cycle, seconds after each spin-up. Observed as repeated audible
spin-ups within one hour on drives configured for a 3-hour timer.

### Decision

DSM's `standbytimer` is the only interval. The fixed-minutes argument to
`sleepd start` is removed, `0` and unset both mean "hibernation off, stop
nothing", the silent `min=10` fallback is gone, and issuing `hdparm -y` resets
that drive's idle clock exactly as real I/O does.

### Consequences

- One control surface. The DSM UI and `hib MIN` are the same knob, read every
  cycle, so changes take effect without restarting the daemon.
- Nothing spins down while `standbytimer=0`. This is correct but looks like a
  regression, so `sleepd start` now prints the value it will use.
- Stops are bounded to one per interval per drive regardless of what wakes the
  drive or whether the wake is visible to diskstats.
- `sleepd` can no longer be run at an interval different from DSM's for a quick
  experiment; use `hib MIN` and let the daemon pick it up.

### Alternatives rejected

Keeping the fixed-interval override alongside live tracking. It is the only
mechanism that can desync the daemon from the setting the operator sees, which
is what produced this investigation.
