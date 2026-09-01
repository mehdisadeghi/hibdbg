# System-array migration (md0/md1: HDD -> NVMe)

Date: 2026-07-23. Box: DS923+ (synas), DSM 7.3.2u4.

## What was done

DSM keeps its OS (`md0` = `/`, ext4) and swap (`md1`) as RAID1 arrays with one
slot per bay, mirrored onto every data drive. Here they ran on `sata3p1/p2` +
`sata4p1/p2` — the 4x12TB IronWolf pair we want in standby.

Migration (now scripted as `hibdbg sysmig`, idempotent, one safe step per run):

1. `mdadm /dev/md0 --add /dev/nvme0n1p1 /dev/nvme1n1p1` (md1: same with p2) —
   the NVMe drives already carried unused, exactly-sized system partitions.
2. Wait for resync to `[4/4] [UUUU]` (spares auto-promote one at a time).
3. `mdadm /dev/mdX --fail /dev/sataYpZ --remove /dev/sataYpZ` for all four
   sata members.
4. `mdadm --grow /dev/mdX --raid-devices=2` on both arrays.

End state: `md0`/`md1` are clean 2-way NVMe mirrors (`[2/2] [UU]`). The HDD
p1/p2 partitions still exist but are orphaned; Storage Manager permanently
shows "system partition failed" on both HDDs. That warning is cosmetic and
expected.

## Rationale

`rq` tracing (block_rq_issue) showed every residual md0 write landing on
sata3+sata4 as write+flush barriers, and md0 reads being served from sata3 —
the OS partition itself was waking the HDDs and defeating standby regardless
of how many userspace writers got quiesced. Moving the mirrors to NVMe removes
the entire class instead of chasing individual writers.

The final `--grow -n 2` is hygiene with teeth: it clears the permanent
"degraded" status and closes the two empty slots, so an incidental
`mdadm --add` (hot-plug, DSM housekeeping) can only create a never-syncing
spare instead of silently rebuilding the satas back in. It does not prevent a
deliberate repair (root can always reshape).

## Undo

Official path: Storage Manager -> the "Repair" action on the system partition
warning. This is the one-click undo — which is exactly why it must never be
clicked otherwise.

Manual equivalent:

    mdadm --grow /dev/md0 --raid-devices=4
    mdadm /dev/md0 --add /dev/sata3p1 /dev/sata4p1
    mdadm --grow /dev/md1 --raid-devices=4
    mdadm /dev/md1 --add /dev/sata3p2 /dev/sata4p2

Wait for resync; arrays return to spanning both HDDs (original layout, minus
the two never-populated bay slots' degraded state).

## Standing rules

- Never click "Repair" in Storage Manager unless intentionally undoing.
- **DSM re-adds HDD members at EVERY BOOT** (empirically confirmed
  2026-07-27; not just updates as originally assumed). A Task Scheduler
  boot task running `hibdbg.sh boot` re-strips them automatically
  (`fix shim on` + `fix sysmig` + `fix sleepd start`, all idempotent). Cost: one
  ~8GB system-partition resync onto the HDDs per boot before the strip.
- Health signature: BOTH HDDs showing "system partition failed" in Storage
  Manager = correct state. One or zero warnings = DSM re-adopted a drive.
- Drive names can re-enumerate across reboots (sata3/sata4 became
  sata1/sata2 = 8,0/8,16 here); check `map` before reading device numbers
  in old traces.
- Both NVMe failing now kills OS + volume1 together; recovery = DSM reinstall,
  data volumes unaffected.
