# Synology D923+ HDD tick/hibernation hunt — handoff

## Goal
Stop continuous audible head activity on the 4x12TB IronWolf array (DS923+,
DSM 7.3.2u4) and reach working HDD standby. User: seasoned, terse, CLI-only;
all diagnostic commands must live in the `hibdbg` script (bash, runs on DSM),
no ad-hoc command requests.

## Topology (established)
- md0/md1 = DSM system/swap, ext4, RAID1 across ALL four satas.
- md3 = nvme0n1p5+nvme1n1p5 (SSD) -> vg2-volume_1(dm-1) -> cachedev_1(dm-5)
  -> cryptvol_1(dm-7) = volume1 (SSD, VMs/containers/appdata/homes).
- md4 = sata3p5+sata4p5 ONLY -> vg3-volume_3(dm-3) -> cachedev_0(dm-4)
  -> cryptvol_3(dm-6) = volume3 (HDD, encrypted; shares incl. downloads, sync).
- sata1/sata2 carry ONLY md0/md1 (no data partition) — unexplained/possibly
  spare pair; never investigated further.
- Volumes btrfs; md0 is ext4 (jbd2/md0-8). /volume3/sync = Syncthing folder
  (container mount label mismatch /volume3 vs /volume2 is a known separate issue).

## Fixed (real culprits, verified dead)
- AFP: afpd+cnid_dbd were top writer (Mac client). AFP disabled; Mac must use
  smb:// (stale Finder AFP favorite caused "can't connect" — resolved).
- Universal Search / synoindex: units stopped+disabled via `quiesce`
  (synoindex-{scand,mediad,plugind,workerd,notifyd}, synopkg stop SynoFinder,
  systemctl disable pkgctl-SynoFinder). Stale queues removed from 3 shares
  (incl. /volume3/downloads, /volume3/sync). Side effect: no server-side
  Spotlight in SMB shares.
- Synology Drive orphan: @drive.queues remnants purged (pkg already removed).
- nzbget: QueueDir/TempDir/NzbDir/InterDir -> SSD; DestDir stays HDD.
- Lidarr: Rescan After Refresh -> Never; "Refresh Monitored Downloads" is
  API-only unless queue nonempty.
- Snapshot Replication: SSD->HDD replication every 3h (+ daily) — expected
  periodic wake, accepted.
- Storage Manager browser tab: polls SYNO.Core.Storage every ~5s -> cryptsetup
  reads LUKS header on HDD. Close DSM tabs when idle.
- DSM hibernation debug mode (syno_hibernatio): re-arms block_dump and writes
  hibernationFull.log continuously = self-inflicted md0 load. Keep OFF except
  during hunts.

## Measurement traps burned into the design (do not regress)
1. block_dump + syslog-ng persisting trace to /var/log (md0) = feedback loop.
   -> ringsample pattern: pause syslog-ng, read dmesg ring only, trap-restore.
2. `dirtied` events fire for tmpfs/procfs too (scemd temperature.tmp etc.) —
   only `on <dev>` filtering counts; WRITE block lines are disk truth.
3. Data-volume bios log at dm layer (dm-3/4/6), NOT sata/md — filters must
   include dm chain (hdd_dms derives it).
4. sudo/auth.log + bash_history.log writes from launching a test flush AFTER
   standby and self-wake -> sleepnow settles: sync; sleep 35; sync (outlasts
   ext4 5s + btrfs 30s commits) before hdparm -y.
5. smartctl with -n standby never wakes; hdparm -C never wakes.
   (CORRECTED 2026-09-01: false for smartctl through SAT — it issues ATA
   IDENTIFY before the power check and wakes the drive, queue-trace proven;
   lcc/disks now gate on hdparm -C, which remains safe.)

## Current state (last measurements)
- Idle md0: ~4 writes/min (was 124 with debug mode on). Data volume: 0.
- sleepnow 300: sata1+sata2 stayed in standby the FULL window (md0 silent).
  One burst on sata3+sata4 (md4/volume3) at +210s: w+2, w+165, w+3 = one btrfs
  transaction flush. Attribution was empty due to trap #3 (dm filter bug) —
  NOW FIXED in script, not yet re-run.
- Teardown ordering fixed: state is read before syslog-ng restarts.

## Single open thread
Identify the volume3 dirtier behind the +210s flush. Next command:
    sudo ./hibdbg.sh sleepnow 600
Raw section now prints `dirtied inode (path) on dm-X` lines -> name + file.
Candidates: Syncthing peer push into /volume3/sync (legit but wake-inducing),
@eaDir regeneration, synospace/quota housekeeping, Kodi NFS touch.
If attribution empty despite diskstats deltas: below-page-cache class
(md superblock / ATA passthrough) => DSM-internal poller, likely unfixable.

## Endgame options (already discussed with user)
- If dirtier killable: kill it; then `hib 20` (scemd.xml idle timer via script;
  tag names unverified — `hib` shows lines first, sed only known tags, backup +
  diff + scemd restart) for automatic standby. PWL ticking stops in standby.
- Audible tick while spinning = IronWolf PWL head sweeps (by design; firmware
  updates don't remove it; Seagate serial lookup via `disks` + seagate.com).
- calm 600 (remount / commit=600 + dirty_expire/writeback relax) = standing
  fallback to batch residual md0 writes; persist via Task Scheduler boot task.
- Structural: user's Proxmox NUC already does spin-down right (XFS + hd-idle);
  long-term bulk storage belongs there; DSM 7 hibernation is historically
  unreliable (synostgd-disk/scemd pollers not cleanly disableable).
- DSM updates resurrect services (synoindex, debug mode) — re-run `audit`
  and `quiesce` after every update.

## The tool: hibdbg (bash, single file, subcommands)
(Historical: commands were since regrouped under 9 verbs — see GUIDE.md
"Script reference" or `hibdbg --help` for current names.)
Lives on the NAS (user runs `sudo ./hibdbg.sh <cmd>`). Trusted trio is
tracer-free: live / logs / state (+lcc). Commands:
map, audit, sched, on/off (off warns if syno_hibernatio active),
hdd/sys/raw/tree/files/when [min] (parse hibernationFull.log; only meaningful
while DSM debug mode feeds it), md0/md0files [sec] (ringsample; blind spot:
pauses syslog-ng so cannot see syslog-ng itself — use `logs` for that),
who [devpat] [sec] (generic ringsample attribution: processes + dirtied files),
logs [sec] (/var/log size-delta + tails; tracer-free), live [sec], state,
smb, nfs (netstat-based; DSM has no ss/lsof), lcc [sec], disks (model/serial/
firmware, -n standby), sleepnow [sec] (force standby, 5s-grain full timeline,
dm-aware attribution, settle 35s, state-before-syslog-restart), quiesce/
unquiesce, hib [min], calm [sec]/uncalm, probe (live+state+md0+lcc verdict).
Known DSM quirks encoded: no synopkg disable verb (use systemctl disable
pkgctl-*), busybox-ish userland (netstat yes, ss/lsof no), gawk present.

## Style contract (strict)
Terse, convergent, no checklists, no re-explaining settled facts, commit to
the most specific hypothesis, treat user observations as precise data, all
runnable steps go INTO the script, admit uncertainty explicitly (e.g. scemd.xml
tag names), UI steps only when DSM offers no CLI path.
