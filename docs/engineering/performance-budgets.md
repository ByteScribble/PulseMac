# Performance budgets

These are **design targets, not measurements**. No figure below has been measured on Apple
hardware yet. The app reports its own overhead live (Settings › About PulseMac, sidebar footer)
via `SelfOverhead`: average/last tick time and own CPU over the last minute (`getrusage`).

| Budget | Target | How measured | Status |
|---|---|---|---|
| Idle CPU (menu bar only, background mode, 5 s interval) | < 0.3 % of one core | `SelfOverhead.processCPUPercent`; Instruments Time Profiler, 30 min | Not measured |
| Dashboard open (1 s interval) | < 2 % of one core | same | Not measured |
| Investigation open | < 3 % of one core | same | Not measured |
| Steady-state memory (basic monitoring) | ≈ 100 MB or less | Activity Monitor footprint after 1 h | Not measured |
| Tick duration (all collectors incl. processes) | < 10 ms p95 on M1 | `SelfOverhead.averageTickMilliseconds` | Not measured |
| Disk writes | 1 batched transaction / 30 s; ≤ ~5 MB/day raw at 5 s background | `fs_usage`, DB size growth | Not measured |
| DB size | ≤ 200 MB hard-ish cap (soft trimming) | `HistoryStore.sizeBytes()` | Enforced in code |
| Menu bar popover open | < 100 ms to first render | Instruments, signposts (TODO) | Not measured |
| Process count stress | Responsive with 2 000 processes | synthetic fixture + real stress | Not measured |

## Design choices that serve the budgets
- Adaptive sampling modes; process enumeration at lower cadence; per-collector cadences.
- Single shared stream; `.bufferingNewest(1)` backpressure; one `@Observable` update per tick.
- Ring buffers (O(1) append, bounded); per-process history bounded and pruned on exit.
- Path and username caches keyed by process identity.
- Batched SQLite writes in WAL mode; idempotent rollups every 5 min; retention hourly.
- Charts: no per-point animation; gap segmentation computed once per render.

## Benchmark plan (Phase 6)
1. Add `os_signpost` intervals around `performTick`, each collector and view updates.
2. Scripted runs: idle 30 min, dashboard 10 min, investigation 10 min, `stress-ng`/`yes` load,
   2 000 sleeping processes.
3. Record results per chip/macOS version in `docs/testing/hardware-results.md`.
