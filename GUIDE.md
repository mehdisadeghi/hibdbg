# Making Synology HDDs actually sleep (DS923+, DSM 7.3)

A field guide to finding — and killing — everything that keeps a Synology HDD
array awake, with a single-file diagnostic-and-mitigation script (`hibdbg.sh`,
shared alongside). Spoiler with the benefit of the full journey: on a box
whose NVMe storage pool hosts Docker, **DSM's native hibernation never
engages, and its own debug mode cannot tell you why**. Standby is still
achievable — by taking over the job from DSM.

Tested on: DS923+, DSM 7.3.2, 2x IronWolf 12TB (RAID1, encrypted btrfs
volume) + 2x NVMe as a storage pool. Method transfers to any DSM 7.x box;
culprits will differ per setup.

**Fair warning:** the fixes below include a wrapped Synology binary and a
daemon that spins your drives down behind DSM's back. Both are reversible
and re-asserted automatically at every boot, but it is your array and your
risk.

---

## The goal

NAS drives are rated for 24/7 spinning, so this is about noise and ~10W of
idle power. IronWolf drives perform periodic head sweeps (preventive wear
leveling) that tick audibly *whenever the platters spin*; firmware updates
don't remove it. The only silence is standby.

## Why this is genuinely hard on DSM

1. **The OS lives on your HDDs.** DSM mirrors its system partition (`md0` =
   `/`) and swap (`md1`) across drives, one slot per bay. Every log line and
   journal commit lands on the disks you want asleep, as write+flush
   barriers.
2. **The observer effect is everywhere.** `block_dump` tracing feeds
   syslog-ng which writes to `/var/log` — on `md0` — generating the writes
   you're tracing. DSM's own hibernation debug mode is itself a top writer.
   An open Storage Manager tab polls storage APIs, which re-reads encrypted
   volumes' LUKS headers from disk.
3. **Some wakers are invisible to standard tools.** SG_IO/ATA-passthrough
   commands appear in neither `block_dump` nor `/proc/diskstats`. Two of the
   decisive culprits here were exactly that class.
4. **`hdparm -y` is not a valid hibernation test.** scemd (DSM's hardware
   daemon) polls drive temperature via SCT every ~10–20s; the poll wakes a
   drive that *you* put in standby behind scemd's back. Days of ghost-chasing
   originate from this single fact.
5. **DSM heals itself at every boot.** Not just updates: each boot restores
   modified system binaries, and assembles the system arrays from the SATA
   bays alone (Fix 1). Any mitigation must be re-asserted by a boot task.
6. **The hibernation policy veto is silent.** With zero HDD I/O for hours,
   timer set, and debug mode active in "can't enter hibernation" mode, the
   debug log stays empty and the drives stay awake: the veto (NVMe pool
   activity — Docker never sleeps) is outside what the debugger traces.

## Platform anatomy: what DSM actually is

Worth internalizing before debugging, because it predicts every surprise in
this guide:

- **It is Linux** — patched ~4.4-era kernel, real systemd, mdadm, LVM,
  dm-crypt, btrfs. Standard instruments (sysfs, tracepoints, diskstats,
  mdadm) all work, which is what made this hunt possible.
- **The kernel is patched in ways that change semantics:** drives are named
  `sataN` (not `sdX`), `block_dump` lines carry an extra `ppid:` field,
  btrfs has Synology-only features (`auto_reclaim_space`, `syno_allocator`,
  `synoacl`) with no upstream documentation. Expect upstream man pages to be
  approximately true.
- **`synoacl` is not POSIX ACLs** — a proprietary Windows-style ACL layer
  (the `+` in listings) that DSM treats as the real permission system,
  which is why DSM-managed files often carry 777 POSIX modes.
- **The proprietary layer is `/usr/syno`:** the web UI, `SYNO.*` API CGIs,
  `scemd` (fans + hibernation policy), `synostgd`, `synopkg`. These are
  black boxes making undocumented decisions — the hibernation veto in this
  guide had to be established by elimination because no config or log states
  it.
- **Boot re-materializes the OS.** GRUB and systemd are FOSS, but DSM
  re-extracts/verifies system files from packed images at every boot and
  assembles the system arrays from a fixed list of SATA partitions. Modified
  binaries and array membership silently revert. Consequence: on DSM you get full
  *observability*, substantial *control*, and only **provisional
  persistence** — durable changes are re-assertion hooks (boot tasks), not
  one-time edits.

## Method

Evidence-first, one instrument per layer, all wrapped as script subcommands
so runs are reproducible and no ad-hoc command pollutes a measurement:

- `/proc/diskstats` deltas (`live`) — ground truth that I/O reached a disk.
- `block_dump` via kernel ring with syslog-ng paused (`who`, `md0`,
  `sleepnow`) — process + dirtied-file attribution, feedback-free.
- `block:block_rq_issue` tracepoint (`rq`) — every request on the drive
  queues including passthrough, with issuer and CDB bytes.
- `sched_process_fork/exec` tracepoints (`who forks`, `rec who`) — naming
  daemons that spawn millisecond-lived helpers (`sg_raw`, `cryptsetup`)
  that /proc sampling can never catch.
- `hdparm -C` (`status state`) — power state, genuinely non-waking. smartctl
  is NOT, even with `-n standby`: it identifies the device (ATA IDENTIFY via
  SAT) *before* honoring the flag and wakes a sleeping drive — queue-trace
  proven. `status lcc`/`status disks` therefore skip drives in standby.
- A detached long recorder (`rec`, analyzed with `rec sum`/`rec who`/
  `rec wakes`) — all of the above for hours, surviving ssh logout,
  summarized into an episode timeline.

Recorder practicalities, learned the hard way over a 24h run:

- Recordings must not land on `/` (md0 is 8 GB; a 4h run left a 6.4 GB
  `trace.log` and filled it, after which every package update fails with
  "free space of system partition is insufficient"). They now go next to the
  script — keep that on an SSD volume, never on the drives under test.
- The fork/exec stream is the bulk of the data and is gzipped
  (`fork.log.gz`, ~3 GB/day); queue events stay uncompressed in `block.log`
  so attribution greps are instant. `rec who` streams the compressed graph.
- Only the **first ~15 minutes** after a wake identify the waker. Everything
  later is other work piggybacking on an already-spinning drive — the single
  most misleading thing in a raw timeline. `rec wakes DIR` cuts exactly there
  and prints one block per episode: wake → sleep, duration, sata I/O totals,
  and the top processes and dirtied paths from that opening window.
- Run one block_dump-family and one tracepoint-family instrument at a time;
  concurrent recorders starve each other's traces.

## What was keeping the box awake (discovery order)

Per-setup checklist, not a verdict for yours:

1. **AFP** (`afpd`/`cnid_dbd`) serving a Mac — top writer. Disabled; SMB.
2. **Universal Search / SynoFinder indexing** — stopped, disabled, stale
   queues purged (`fix quiesce`).
3. **Orphaned Synology Drive queues** from a removed package.
4. **Download clients' state on the HDD volume** — nzbget queue/temp moved
   to SSD; later round: its **RSS feed files** (`feed-*.tmp`, `feeds.new`,
   `queue`) were still under the HDD MainDir, rewriting every 15 minutes.
5. **DSM hibernation debug mode** as md0 load (pre-migration).
6. **Storage Manager browser tabs** — LUKS header reads every ~5s while open.
7. **The system partition itself** (structural; migrating it off the
   HDDs was tried and withdrawn — Fix 1).
8. **scemd's SCT temperature polls** (the invisible standby-killer — Fix 3).
9. **An external API poller**: something queried `SYNO.Core.Storage` every
   15 minutes (here: a Home-Assistant-class integration); each query spawns
   `cryptsetup` to re-read the LUKS headers from disk. Found via fork-trace
   (`rec who ... cryptsetup` → `SYNO.Storage.CGI`). Fixed client-side by
   disabling/retiming the storage sensors.
10. **Sonarr** rescan/analyse walking the media library with `ffprobe`
    (thousands of reads per pass) — "Analyse video files" off, "Rescan after
    refresh" never; same treatment as Radarr/Lidarr.

11. **Scheduled DSM maintenance, scattered across the day** — a 24h
    recording showed 7 wakes, and none of them was the hourly cycle it
    sounded like: snapshot, retention and reclaim jobs
    (`synosharesnapsh`, `synoretainer`, `synostgreclaim`, `snaptree.bin`,
    `btrfs_deleted_subvol.info`) firing at ~8 unrelated times. What you
    hear as "hourly" is the idle timer's post-wake spin window, not the
    trigger. Consolidating those schedules into one or two slots — ideally
    adjacent to the replication window you already accept — collapses
    several wakes into one.
12. **Container backups written to the HDD volume** — an Immich database
    dump (`immich-db-backup-*.sql.gz.tmp`) at 02:00 nightly; retargeting
    the backup path to the SSD volume removes that wake outright.
13. **The instruments themselves** — `smartctl` wakes a sleeping drive even
    with `-n standby`: it issues ATA IDENTIFY through the SAT layer before
    the power check. Both wake storms in the decisive recording were the
    tool's own `lcc` runs. Each such passthrough wake triggers a kernel
    requeue storm — millions of block-layer retries during the spin-up
    window (830 MB of queue trace in minutes), audible as a "machine-gun"
    burst right after the spin-up sound. Fixed by gating every smartctl
    behind `hdparm -C` and skipping drives in standby.

Accepted periodic wakes: snapshot replication (3h), real client access,
btrfs `auto_reclaim_space` housekeeping episodes (Synology-internal, no
exposed tuning knob worth touching; `commit=` batching exists via `fix calm3`
but batching cannot produce standby, only fewer bursts).

## Fix 1: the system partition off the HDDs — withdrawn

DSM mirrors its OS (`md0` = `/`) and swap (`md1`) onto every data drive, so
the root filesystem alone writes to the HDDs. The obvious move was to add the
NVMe drives' unused system partitions to those arrays and strip the HDD
members (`fix sysmig`, 2026-07-23). It ran for seven weeks and was withdrawn
after a power outage on 2026-09-08 showed what DSM actually does at boot:

    /sbin/mdadm /dev/md1 -A -u <uuid> --run /dev/sata2p2

The system arrays are assembled from an explicit list of SATA-slot
partitions, with `--run` forcing a degraded start. NVMe partitions are never
offered. So the migration cannot persist across a boot, and worse: once the
HDD members are stripped, everything DSM writes to `/` lives only on NVMe,
and the next boot comes up on the HDD copy frozen at strip time — a rollback
of the whole system partition at every reboot, tasks and settings included.
Zeroing the HDD superblocks would not help; it leaves DSM with no system
partition at all. The stock layout stays. See ADR 6.

What the migration was meant to buy was smaller than it looked: the
standby log shows the drives reaching their idle timer regularly with the
system partition on them. `md0` is a contributor, not the blocker, and the
wake attribution names the real ones.

## Fix 6: DSM's log stores on the SSD (`fix logs on`)

With every app-level writer scheduled or disabled, two-hour recordings still
showed the same residual: `synostgd-disk` writing `.SYNODISKDB`, `synologaccd`
writing `.SYNOACCOUNTDB`, connection logs, `auth.log`, `messages` — DSM
writing its own logs and log databases to `/var/log`, on md0, mirrored to
every HDD. One 4 KB sqlite WAL write ended a 24-minute standby. `fix calm`
cannot batch these: sqlite `fsync`s its WAL, which forces the journal out
regardless of the commit interval.

`fix logs on` bind-mounts each directory in the script's `LOGDIRS` list
(`/var/log`, `/var/lib/diskutil`) onto `<vol>/@<path-with-dashes>` on the
SSD volume holding the script, seeds it once from the md0 copy, and restarts
the services still holding files on the old copy — found generically: any
service, in any slice, with an fd under a log dir on the wrong device. On
this NAS that was the system syslog-ng, Log Center's own syslog-ng, nginx,
smbd, nmbd and rsyncd; `fix logs status` lists every stale handle with pid,
unit and file. Reversible with `fix logs off`; if the boot task misses, DSM
simply logs to md0 as stock. The bind cannot happen before the volume is
mounted, which is after syslog-ng starts — hence the restart step rather
than a systemd ordering. See ADR 7.

`/var/lib/diskutil` is there because of what `/var/log` alone left behind:
md0 still took ~20 writes per 10 minutes with zero ext4 write or fsync
events. `who sys` traces ext4, jbd2 and the bios of the root device with the
filter applied in the kernel (an unfiltered ring is overrun by the volumes
within a minute, and the few md0 events are lost — which is how the first
attempts saw "nothing"), proves itself with a probe write, and resolves
inodes to paths and paths to holders. The writer was Log Center's syslog-ng
flushing the mmap'd wal-index of its connection-log sqlite: mmap dirtying
passes no write syscall, so only writeback shows it, as `kworker` on the
inode. Any future residual goes the same way: `who sys`, then the directory
joins `LOGDIRS`. See ADR 9.

## Fix 7: system-partition reads from the SSDs (`fix mirror on`)

With the log stores moved, md0 took no writes for ten-minute windows, and
the drives still woke on use: opening DSM, a cold binary, any page-cache
miss on `/`. RAID1 serves each read from a single member, and md prefers the
first: since boot sata1 had served 64k reads to sata2's 17k, with identical
writes — which is also why one drive reached standby and the other did not.

`fix mirror on` adds the SSD partitions shaped like md0's HDD members (same
partition number and size, mounted nowhere, held by nothing — on this box
the NVMe drives' own DSM-style system partitions) as extra mirrors in the
array's free slots, and flags the HDD members write-mostly. md then reads
from the SSDs and writes to everyone.

This is not Fix 1 again. Fix 1 removed the HDD members, which left DSM — it
assembles md0 from the SATA bays only — booting a stale copy. Here nothing
is removed: the HDDs receive every write, so the copy DSM assembles is
always current. DSM drops the SSD members at every boot and `boot` re-adds
them with a full recovery (8 GB, a minute or two of HDD reads). A missed
boot task costs the mitigation, never data. The SSD members fill the free
slots DSM would use for a new drive: `fix mirror off` before inserting one.

What it does not fix: writes. Changing a setting writes `/etc` or
`/usr/syno/etc` on md0 and wakes the drives, and must — those directories
are authoritative at boot, before any bind could exist, so they cannot go
the way of the logs. The only clean way to take writes off the HDDs is a
SATA SSD in a free bay: DSM makes it a real md0 member, assembled at boot,
after which the HDD members can be dropped safely. See ADR 10.

## Fix 2: the native idle timer — a documented dead end

The timer lives in `/etc/synoinfo.conf` (`standbytimer`, minutes;
`hib MIN` / `hib undo` manage it). On this box it was set all along. With
every I/O source eliminated (verified: hours of zero HDD I/O at every
layer), drives still never slept. DSM's hibernation debug mode ("unable to
hibernate" level) logged its banner and then **nothing** — no blocker,
no countdown, no standby. Conclusion, consistent with wide community
reports for NVMe-pool models: the hibernation gate requires all internal
storage idle; an NVMe pool running Docker never qualifies; the debug
tooling doesn't trace NVMe, so the veto is invisible. Stop fighting this
layer; bypass it.

## Fix 3: `fix shim` — cache the temperature polls

The A/B that settled it: `sleepnow 60` (forced standby, scemd running) —
drives back awake in seconds; `sleepnow 60 nopoll` (scemd stopped for the
window) — drives held standby with literally two commands on the queues.
The poll is ATA READ LOG EXT page 0xE0 (SCT status) via `sg_raw`, spawned
by scemd (proven with fork-tracing), and it spins up a standby drive.

You can't kill the poller (it drives the fans). You can make it harmless:

- `fix shim on` moves `/usr/syno/bin/sg_raw` to `sg_raw.real` and installs
  a wrapper: non-sata targets and non-READ-LOG CDBs pass through untouched;
  for the poll CDB it checks drive power state first (`hdparm -C` CHECK
  POWER MODE — verified non-waking) and serves a cached copy of the last
  real answer while the drive sleeps. scemd sees byte-identical output;
  a sleeping drive only cools, so the stale temperature is conservative.
- Acceptance trace reads like a proof: passthrough entries while awake,
  the two standby commands, then 150s of cache hits and an end state of
  `standby` on both drives.
- DSM restores the stock binary at every boot; `fix shim on` is idempotent
  and boot-safe (detects and discards the stale `.real`).

## Fix 4: `sleepd` — DIY standby daemon

hd-idle semantics: a detached loop checks sata diskstats once a minute and
issues `hdparm -y` after `standbytimer` idle minutes, re-read every cycle so
the DSM setting is the single source of truth (`0` = off, stops nothing).
It refuses to start — and exits mid-flight — if the shim is not installed,
because standby without the shim produces a wake/sleep churn loop that eats
the start/stop budget. All its probes are non-waking and invisible to
diskstats, so it never resets its own idle measurement.

Every standby it issues is appended to `sleepd.log` beside the script with the
idle minutes behind it, and `fix sleepd status` shows the last five. Two separate
investigations stalled on not being able to tell "never issued standby" from
"issued it and the drive was woken again inside the 30s sampling grid".

Issuing standby resets that drive's idle clock, which is not cosmetic:
passthrough wakes move no diskstats counter, so an expired clock would
otherwise re-stop the drive on the next cycle, seconds after each spin-up —
the same churn the shim requirement exists to prevent. See `ADR.md`.

## Fix 5: `watch` — know about every wake, by name

Once the box mostly sleeps, the remaining wakes happen when nobody is
listening. `watch` is a permanent daemon that keeps a *private ftrace
instance* armed on the sata queues — a RAM ring buffer, zero disk I/O,
separate enable/filter so `rec` and `who` still work — and samples drive
state once a minute with the non-waking `hdparm -C`. Any queue command that
arrives while a drive was in standby (excluding the stack's own probes) is
an episode: wallclock, drive states, and the first commands with their
issuing process land in `watch.log`, passthrough included.

Buffered writes reach the queue as anonymous plumbing (`dmcrypt_write`,
`kworker`) — the btrfs → md → dm-crypt stack strips the originator — so the
daemon also keeps a change cursor per HDD-backed filesystem while the drives
spin and diffs it at wake time: the episode lists the files written while
asleep, and the headline names the first one. On btrfs the cursor is the
transaction id (`btrfs subvolume find-new`, instant metadata delta); other
filesystems take an `fsmark_<fs>`/`fsdiff_<fs>` hook pair. See ADR 3.

Reads leave no cursor behind, so they get the mirror mechanism: a second
ftrace instance records page-cache misses on those filesystems
(`mm_filemap_add_to_page_cache`), armed only while a drive sleeps — a read
that reaches a sleeping disk is a cache miss by definition. The record names
reader and inode, and `fsino_<fs>` resolves the inode to a path (btrfs:
`inspect-internal inode-resolve`). Whatever comm the queue saw is a thread
name, so the episode also resolves it through `/proc` at wake time — cmdline,
parent, docker container — and for `nfsd`, a kernel thread, logs the NFS
client that asked. See ADR 5.

Notification reuses Synology's own mail rather than duplicating SMTP
credentials: DSM 7 exposes no CLI to its configured mailer (ssmtp.conf
ships empty), but Task Scheduler mails a task's output. A daily root task
running `watch digest` + "Send run details by email" is the digest channel
(default). `watch mode perwake` additionally pushes a DSM notification
(desktop + mobile app) the minute a wake is detected, for live debugging.
See ADR 2.

## Boot task: the whole stack self-heals

DSM reverts the binary and the arrays at every boot, so persistence is one
Task Scheduler entry (Triggered / Boot-up / root):

    bash /path/to/hibdbg.sh boot

which runs `fix shim on` → `fix logs on` → `fix swap off` → `fix mirror on` → `fix quiesce` →
`fix sleepd start` → `watch start`, all idempotent. Every reboot and every DSM update reverts
all five. Post-update ritual: `status` (shim/daemon/timer health).

## Verification

- `sleepnow [sec]` — forced-standby window with 5s-grain diskstats
  timeline, block_dump attribution, and a queue-level trace that includes
  passthrough; the acceptance test for the whole stack.
- `rec [sec]` / `rec sum DIR` / `rec wakes DIR` / `rec who DIR COMM` —
  hours-long detached recording; episode timeline, per-wake attribution
  table, and parent chains for short-lived helpers. A 24h run is the only
  way to separate scheduled wakes from your own access.
- `status state` / `status lcc` — power state and SMART wear counters
  (lcc skips sleeping drives; smartctl would wake them).
  The 24h `Start_Stop_Count` delta is the wear ledger: budgets are ~50k
  start/stop and 600k load/unload cycles; ~10–16 wakes/day ≈ 5k/year —
  a decade of headroom. The regime to avoid (and the reason `sleepd`
  hard-requires the shim) is a wake every few minutes.
- Ears: PWL ticking exists only while spinning.

## Script reference (grouped)

    status         health page; subverbs state, live [s], lcc [s], map,
                   audit, disks, probe
    who            attribution: who [pat] [s], who rq [s],
                   who forks [s] [comm], who fresh [min] [path],
                   who sys [s]
    rec            long recording: rec [s], rec stop, rec sum DIR,
                   rec wakes DIR, rec who DIR COMM
    sleepnow       forced-standby acceptance test: sleepnow [s] [nopoll]
    watch          wake-notify daemon: start/stop/status,
                   mode [digest|perwake], digest, test
    hib            idle timer: hib [min|undo]
    fix            mitigations: shim on|off|status, logs on|off|status,
                   swap off|on|status, mirror on|off|status,
                   sleepd start|stop|status, quiesce/unquiesce,
                   calm [s|off], calm3 [s|off]
    dsm            DSM-side: debug on|off, log [n], sched, smb, nfs
    boot           re-assert the whole stack

## Undo, complete list

| Change | Undo |
|---|---|
| Log stores on the SSD (`fix logs on`) | `fix logs off` (copies kept in `<vol>/@var-log`, `<vol>/@var-lib-diskutil`); any reboot also reverts it |
| Swap released (`fix swap off`) | `fix swap on`; any reboot also reverts it |
| SSD read mirrors on md0 (`fix mirror on`) | `fix mirror off` (removes the SSD members, clears write-mostly); any reboot also drops the SSD members |
| Poll shim (`fix shim on`) | `fix shim off` (restores original binary); any reboot also reverts it |
| `sleepd` | `fix sleepd stop`; delete the boot task to stop re-asserting |
| Idle timer (`hib MIN`) | `hib undo` |
| Indexing off (`fix quiesce`) | `fix unquiesce` |
| Commit batching (`fix calm`/`fix calm3`) | `fix calm off` / `fix calm3 off` |
| Wake notifications (`watch`) | `watch stop`; delete the digest mail task |
| Whole stack | remove the Task Scheduler entry and reboot: DSM restores everything itself |

## Closing notes

- The end state is not zero wakes; it is *self-limiting* wakes: replication,
  real use, and btrfs housekeeping each cost one idle-timer period of
  spinning, then the box goes back to sleep on its own.
- Everything here was established by counter-testable measurement, and the
  script ships the same instruments. If your box stays awake, it will tell
  you why — by name, with the CDB bytes to prove it.
