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

**Fair warning:** the fixes below include unsupported mdadm surgery on the
DSM system partition and a wrapped Synology binary. Both are reversible and
both are re-verified automatically at every boot, but it is your array and
your risk.

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
   you're tracing. DSM's own hibernation debug mode is itself a top writer
   (until the system partition moves off the HDDs; then it becomes usable).
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
   modified system binaries and re-adds HDD members to the system arrays.
   Any mitigation must be re-asserted by a boot task.
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
  re-runs system-partition auto-repair. Modified binaries and array
  membership silently revert. Consequence: on DSM you get full
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
- `sched_process_fork/exec` tracepoints (`pollwho`, `recwho`) — naming
  daemons that spawn millisecond-lived helpers (`sg_raw`, `cryptsetup`)
  that /proc sampling can never catch.
- SMART `-n standby` + `hdparm -C` (`state`, `lcc`) — power state and
  wear counters that never wake a sleeping drive.
- A detached long recorder (`rec`/`recsum`/`recwho`/`recwakes`) — all of the
  above for hours, surviving ssh logout, summarized into an episode timeline.

Recorder practicalities, learned the hard way over a 24h run:

- Recordings must not land on `/` (md0 is 8 GB; a 4h run left a 6.4 GB
  `trace.log` and filled it, after which every package update fails with
  "free space of system partition is insufficient"). They now go next to the
  script — keep that on an SSD volume, never on the drives under test.
  `rootspace` breaks down what is eating md0.
- The fork/exec stream is the bulk of the data and is gzipped
  (`fork.log.gz`, ~3 GB/day); queue events stay uncompressed in `block.log`
  so attribution greps are instant. `recwho` streams the compressed graph.
- Only the **first ~15 minutes** after a wake identify the waker. Everything
  later is other work piggybacking on an already-spinning drive — the single
  most misleading thing in a raw timeline. `recwakes DIR` cuts exactly there
  and prints one block per episode: wake → sleep, duration, sata I/O totals,
  and the top processes and dirtied paths from that opening window.
- Run one block_dump-family and one tracepoint-family instrument at a time;
  concurrent recorders starve each other's traces.

## What was keeping the box awake (discovery order)

Per-setup checklist, not a verdict for yours:

1. **AFP** (`afpd`/`cnid_dbd`) serving a Mac — top writer. Disabled; SMB.
2. **Universal Search / SynoFinder indexing** — stopped, disabled, stale
   queues purged (`quiesce`).
3. **Orphaned Synology Drive queues** from a removed package.
4. **Download clients' state on the HDD volume** — nzbget queue/temp moved
   to SSD; later round: its **RSS feed files** (`feed-*.tmp`, `feeds.new`,
   `queue`) were still under the HDD MainDir, rewriting every 15 minutes.
5. **DSM hibernation debug mode** as md0 load (pre-migration).
6. **Storage Manager browser tabs** — LUKS header reads every ~5s while open.
7. **The system partition itself** (structural — Fix 1).
8. **scemd's SCT temperature polls** (the invisible standby-killer — Fix 3).
9. **An external API poller**: something queried `SYNO.Core.Storage` every
   15 minutes (here: a Home-Assistant-class integration); each query spawns
   `cryptsetup` to re-read the LUKS headers from disk. Found via fork-trace
   (`recwho ... cryptsetup` → `SYNO.Storage.CGI`). Fixed client-side by
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

Accepted periodic wakes: snapshot replication (3h), real client access,
btrfs `auto_reclaim_space` housekeeping episodes (Synology-internal, no
exposed tuning knob worth touching; `commit=` batching exists via `calm3`
but batching cannot produce standby, only fewer bursts).

## Fix 1: move the DSM system partition off the HDDs (`sysmig`)

The rq view showed every residual `md0` write arriving at the HDDs as
write+flush barriers. If your NVMe drives are a DSM storage pool, DSM already
created exactly-sized unused system partitions on them. The migration is
mdadm RAID1 member management, automated idempotently by `sysmig` (one safe
step per run, refuses while resyncing, re-run until done):

add NVMe p1/p2 to md0/md1 → wait `[UUUU]` → fail+remove sata members →
`--grow --raid-devices=2`.

**Discoveries that cost real time:**

- DSM re-adds HDD system partitions **at every boot** (not just updates),
  one or more drives at a time. The boot task re-strips them (~8GB resync
  onto the HDDs per boot before the strip — the price of DSM's auto-repair).
- Storage Manager showing **both** HDDs with "system partition failed" is
  the *correct* state signature. One or zero warnings = DSM has re-adopted
  a drive. Never click "Repair" — that is the undo button.
- Drive names can re-enumerate across reboots (sata3/4 became sata1/2
  here); decode old traces via the device table each recording stores in
  its `meta`.

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

## Fix 3: `pollshim` — cache the temperature polls

The A/B that settled it: `sleepnow 60` (forced standby, scemd running) —
drives back awake in seconds; `sleepnow 60 nopoll` (scemd stopped for the
window) — drives held standby with literally two commands on the queues.
The poll is ATA READ LOG EXT page 0xE0 (SCT status) via `sg_raw`, spawned
by scemd (proven with fork-tracing), and it spins up a standby drive.

You can't kill the poller (it drives the fans). You can make it harmless:

- `pollshim on` moves `/usr/syno/bin/sg_raw` to `sg_raw.real` and installs
  a wrapper: non-sata targets and non-READ-LOG CDBs pass through untouched;
  for the poll CDB it checks drive power state first (`hdparm -C` CHECK
  POWER MODE — verified non-waking) and serves a cached copy of the last
  real answer while the drive sleeps. scemd sees byte-identical output;
  a sleeping drive only cools, so the stale temperature is conservative.
- Acceptance trace reads like a proof: passthrough entries while awake,
  the two standby commands, then 150s of cache hits and an end state of
  `standby` on both drives.
- DSM restores the stock binary at every boot; `pollshim on` is idempotent
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
idle minutes behind it, and `sleepd status` shows the last five. Two separate
investigations stalled on not being able to tell "never issued standby" from
"issued it and the drive was woken again inside the 30s sampling grid".

Issuing standby resets that drive's idle clock, which is not cosmetic:
passthrough wakes move no diskstats counter, so an expired clock would
otherwise re-stop the drive on the next cycle, seconds after each spin-up —
the same churn the shim requirement exists to prevent. See `ADR.md`.

## Boot task: the whole stack self-heals

DSM reverts the binary and the arrays at every boot, so persistence is one
Task Scheduler entry (Triggered / Boot-up / root):

    bash /path/to/hibdbg.sh boot

which runs `pollshim on` → `sysmig` → `sleepd start`, all idempotent.
Post-update ritual: `audit` (component section states shim/daemon status)
and `map` (arrays `[2/2]` NVMe-only) — or just check that *both* HDDs still
show the failed-system-partition warning.

## Verification

- `sleepnow [sec]` — forced-standby window with 5s-grain diskstats
  timeline, block_dump attribution, and a queue-level trace that includes
  passthrough; the acceptance test for the whole stack.
- `rec [sec]` / `recsum DIR` / `recwakes DIR` / `recwho DIR COMM` —
  hours-long detached recording; episode timeline, per-wake attribution
  table, and parent chains for short-lived helpers. A 24h run is the only
  way to separate scheduled wakes from your own access.
- `state` / `lcc` — non-waking power state and SMART wear counters.
  The 24h `Start_Stop_Count` delta is the wear ledger: budgets are ~50k
  start/stop and 600k load/unload cycles; ~10–16 wakes/day ≈ 5k/year —
  a decade of headroom. The regime to avoid (and the reason `sleepd`
  hard-requires the shim) is a wake every few minutes.
- Ears: PWL ticking exists only while spinning.

## Script reference (grouped)

    discovery      map (topology+mdstat+partitions), audit, sched
    ground truth   live [s], rq [s], state, lcc [s], disks
    attribution    who [pat] [s], md0/md0files [s], pollwho [s] [comm],
                   fresh [min] [path], logs [s], hdd/sys/raw/tree/files/when
    long recording rec [s], recstop, recsum DIR, recwakes DIR,
                   recwho DIR COMM
    one-shot       sleepnow [s] [nopoll], probe, rootspace
    mitigation     quiesce/unquiesce, sysmig, pollshim on|off|status,
                   sleepd start|stop|status, boot,
                   hib [min|undo], hibdebug on|off, calm/uncalm, calm3/uncalm3
    smb / nfs / hiblog

## Undo, complete list

| Change | Undo |
|---|---|
| System partition on NVMe (`sysmig`) | Storage Manager "Repair", or `mdadm --grow -n 4` + re-add sata members |
| `pollshim` | `pollshim off` (restores original binary); any reboot also reverts it |
| `sleepd` | `sleepd stop`; delete the boot task to stop re-asserting |
| Idle timer (`hib MIN`) | `hib undo` |
| Indexing off (`quiesce`) | `unquiesce` |
| Commit batching (`calm`/`calm3`) | `uncalm` / `uncalm3` |
| Whole stack | remove the Task Scheduler entry and reboot: DSM restores everything itself |

## Closing notes

- The end state is not zero wakes; it is *self-limiting* wakes: replication,
  real use, and btrfs housekeeping each cost one idle-timer period of
  spinning, then the box goes back to sleep on its own.
- Everything here was established by counter-testable measurement, and the
  script ships the same instruments. If your box stays awake, it will tell
  you why — by name, with the CDB bytes to prove it.
