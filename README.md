# hibdbg

Single-file toolkit to diagnose and fix Synology DSM HDD standby: find every
process, daemon, and DSM internal that keeps drives awake, then keep them
asleep with a DIY standby stack that DSM's boot self-healing can't undo.

Built on/for a DS923+ (DSM 7.3, 2x IronWolf + 2x NVMe storage pool); works
on any DSM 7.x box. Run as root on the NAS.

## Deploy

    make deploy            # scp to $HOST (default synas.local) login home
    make run CMD="live 60" # run a subcommand remotely
    make check             # bash -n

## Use

    sudo ./hibdbg.sh                 # full command reference
    sudo ./hibdbg.sh audit           # component + writer status
    sudo ./hibdbg.sh rec 86400       # day-long background recorder
    sudo ./hibdbg.sh recsum DIR      # episode timeline + attribution
    sudo ./hibdbg.sh recwakes DIR    # per-wake: duration, I/O, what woke it
    sudo ./hibdbg.sh sleepnow 120    # forced-standby acceptance test
    sudo ./hibdbg.sh rootspace       # what is filling the 8G system partition

Recordings land next to the script — keep it on an SSD volume, not on the
drives under test.

Mitigation stack (see GUIDE.md for the reasoning):

    sudo ./hibdbg.sh sysmig          # OS arrays md0/md1 -> NVMe
    sudo ./hibdbg.sh pollshim on     # cache scemd SCT polls while asleep
    sudo ./hibdbg.sh sleepd start    # idle-timer standby daemon
    sudo ./hibdbg.sh boot            # all three, idempotent

DSM reverts the binary shim and array membership at every boot: register a
Task Scheduler boot-up task (root) running `hibdbg.sh boot`.

## Docs

- `GUIDE.md`  — full field guide: method, culprits, fixes, verification, undo
- `SYSMIG.md` — system-partition migration record and undo
- `ADR.md`    — architecture decisions
- `HANDOFF.md` — historical hunt notes
