# Test strategy

## What exists (all passing, run on Linux / Swift 6.0 in Docker — 87 tests)

| Suite | Covers |
|---|---|
| `CounterTests` | 32-bit wrap, 64-bit reset, rate after sleep gap, first-sample nil |
| `CPUTests` | Aggregate/per-core math, tick wrap, nice-as-user, process % semantics (per core vs system) |
| `MemoryTests` | Activity-Monitor "used" definition, clamp, pressure mapping, cached-vs-pressure interpretation (acceptance C), unknown ≠ healthy |
| `FormatTests`, `SnapshotTests` | Units, durations, every metric has explanation; missing domains produce no samples (acceptance G) |
| `RingBuffer/Downsampler/Trend/MetricHistory` | Buffer overwrite, bucket aggregation, gaps stay gaps, regression |
| `IncidentEngineTests` | Transient vs sustained, hysteresis band, clear duration, dedup in cooldown, missing data, sleep discontinuity, snooze, correlation wording, restore |
| `ScenarioReplayTests` | Offline replay of fixture scenarios through all rules: calm → none; memory pressure → pressure + swap; runaway → CPU (names `node`) + thermal; battery drain → discharge with limitation |
| `AnalysisTests` | Growth heuristic + caveat, effect verifier, health summary |
| `ProcessActionPolicyTests` | Protected names/paths, other users, self, quit requires app, force-quit warning |
| `RedactorTests` | Home/user/host, secrets in args, IPs (keeps loopback), MACs, emails, URL creds, bearer |
| `StorageSafetyTests` | Marker-based artifact rules, guard refusals (outside home, top-level, iCloud, symlink, unknown, review-only, `..` traversal) |
| `WorkloadTests` | Classification precedence, app grouping, nil-not-zero sums |
| `HistoryStoreTests` | Batched flush, rollup tiers & weighted counts, late samples, retention, resolution choice, incidents/actions round-trip, process ranking with NULLs, clear, CSV, reopen |
| `CoordinatorTests` | Tick → history/store, background cadence, low-power interval, incident persistence + restore, wake resets observation, overhead reported |
| `ProcessSummarizerTests`, `StorageScannerTests` | Minute boundary, top-N retention; real temp-dir scan, dry run touches nothing |

Run: `scripts/test-linux.sh` (Docker) or `swift test` on a Mac.

## Not yet covered (must be done on a Mac)
- **Compilation of macOS collectors and the SwiftUI app** — authored without a macOS toolchain;
  first `swift build` on Xcode 15.3+/16 may surface fixes. CI job `macos-app` enforces this.
- Collector integration tests (values within plausible ranges; rates non-negative; process list
  contains own PID; disk/volume totals consistent with `df`).
- UI tests (XCUITest): navigation ⌘1–6, popover, table sort/search, investigation cursor,
  cleanup dry run, settings persistence, VoiceOver labels.
- Sleep/wake, network interface switch, process exit during action, permission changes.
- Performance: see [performance-budgets.md](../engineering/performance-budgets.md).

## Hardware matrix (to fill)
| Chip | Device | macOS | Battery | GPU % | Result |
|---|---|---|---|---|---|
| M1 | MacBook Air | 14.x | | | not run |
| M2 Pro | MacBook Pro | 15.x | | | not run |
| M3/M4 | iMac / mini (no battery) | 15.x / 26 | n/a | | not run |

Fixture and Linux tests are **not** hardware verification.
