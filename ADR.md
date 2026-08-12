# Architecture decisions

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
