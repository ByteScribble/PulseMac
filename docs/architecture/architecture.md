# Architecture

Modular monolith in one Swift package. Four library/app modules with one-way dependencies:

```
PulseMacApp (SwiftUI/AppKit, macOS only)
   │  depends on
   ├── PulseMonitoring  (collectors [macOS], SamplingCoordinator, storage scanner, actions [macOS])
   │      ├── PulsePersistence (SQLite history)  ── CSQLite (system module)
   │      └── PulseCore
   ├── PulsePersistence
   └── PulseCore         (pure Swift: models, units, diagnostics, policies, fixtures — no OS calls)
```

Rules (enforced by module boundaries, checked in review):

1. `PulseCore` has no dependency and performs no I/O or system calls. Everything decision-making
   (rules, policies, interpretation, formatting) lives here so it is unit-testable on any OS.
2. Platform code is isolated in `PulseMonitoring/Collectors` and `PulseMonitoring/Actions` behind
   `#if os(macOS)` and the `Collector` / `SnapshotSource` protocols.
3. Views never call collectors, IOKit, libproc or SQLite. They read `AppModel` (main actor),
   which subscribes to the `SamplingCoordinator` actor.
4. No feature module depends on another feature module; shared UI lives in `DesignSystem`.

## Data flow

```
Collectors ──► CollectorSet (SnapshotSource) ──► SamplingCoordinator (actor, one tick)
                                                   ├─► MetricHistory (ring buffers, 15 min @ 1 Hz)
                                                   ├─► HistoryStore.enqueue (flush every 30 s)
                                                   ├─► ProcessSummarizer → per-minute top groups
                                                   ├─► IncidentEngine.evaluate → incidents persisted
                                                   └─► AsyncStream<MonitorUpdate> ──► AppModel ──► Views
```

One tick produces one `SystemSnapshot`. Missing domains are `nil`, never zero; flattening to
`Sample`s drops them, so history and rules see gaps as gaps.

### Sampling modes (product principle 2.5)

| Mode | When | Interval | Processes |
|---|---|---|---|
| background | no window/popover visible | 5 s | every 3rd tick (15 s) |
| interactive | dashboard or popover visible | 1 s | every 2nd tick |
| investigation | investigation workspace visible | 1 s | every tick |

Low Power Mode doubles the interval. Per-collector cadence: volumes every 30 ticks, power every
5, GPU every 2. Sleep: flush; wake: reset counters (`RateCalculator` also refuses gaps > 30 s)
and `IncidentEngine.noteDiscontinuity()` restarts pending observation windows.

## Collector contract

Each collector declares a `CollectorDescriptor`: id, capabilities, source API, cadence,
permission, expected cost, failure behaviour. `probe()` sets initial capability statuses;
`collect(into:monotonicTime:)` fills one domain; `reset()` forgets counters. Failures are
caught per collector by `CollectorSet`, recorded as `.failed(reason)` in the
`CapabilityRegistry`, and other collectors continue. Collectors are stateful and confined to
the coordinator actor (not thread-safe by design).

## Diagnostics

`DiagnosticRule` = `evaluate(context) → RuleSignal` + `content(...)` + timing parameters.

State machine per rule (in `IncidentEngine`):

```
idle ──triggered──► pending ──(held ≥ minimumObservation)──► active
  ▲                   │ not triggered                          │ clear held ≥ clearDuration
  └───────────────────┘                                        ▼
  └──────────────(cooldown elapsed)──────────────────────── cooldown ──triggered──► (reopen same incident)
```

- `holding` (hysteresis band) keeps an active incident open but never opens one.
- `unknown` (insufficient samples/coverage) never opens and never resolves.
- Evidence is typed: observation / correlation / hypothesis / limitation. Contributors are always
  correlations ("high use at the same time does not prove cause").
- Restored incidents from a previous run are closed at their last observation.

Built-in rules: sustained CPU, memory pressure, swap growth, sustained disk writes, low disk
space, thermal pressure, rapid battery discharge. Thresholds are in `BuiltInRules.swift`.

## Persistence

SQLite (WAL, `synchronous=NORMAL`) via a ~150-line wrapper — no ORM dependency (ADR 0002).
Tables: `samples_raw`, `samples_rollup` (tier 60 s / 900 s), `process_summary`, `incidents`,
`actions`, `meta`. Migrations via `PRAGMA user_version`. Writes are batched; rollups are
idempotent and re-aggregate a trailing window so late batches are included. Retention and a
200 MB soft cap are enforced hourly. Users can clear everything.

## Actions & safety

`ProcessActionPolicy` (pure) decides; `ActionExecutor` (macOS, main actor) re-checks policy and
PID identity (PID + start time) immediately before acting. Actions: quit app, SIGTERM, force
quit, reveal, open Activity Monitor, move to Trash. Every action is recorded (`ActionRecord`)
with lifecycle phases; effects are verified from measurements (`EffectVerifier`), never assumed.
Cleanup goes through `CleanupGuard` (home-only, no top-level personal folders, no iCloud, no
symlinks, recognised rule, not review-only) for every item at execution time.

## Concurrency

`SamplingCoordinator` is an actor; collectors run inside it (off the main thread).
`HistoryStore` serialises on a private queue. `AppModel` is `@MainActor @Observable`; it applies
at most one update per tick (stream buffering `.bufferingNewest(1)` provides backpressure).

## Known architectural debt

- `AppModel.timeline` reads SQLite synchronously on the main actor for long ranges; move to an
  async query if profiling shows hitches.
- Per-process history lives in `AppModel` memory only (bounded); not persisted beyond per-minute
  group summaries.
- `HistoryStore` uses `@unchecked Sendable` with a serial queue; revisit with Swift 6 strict mode.
