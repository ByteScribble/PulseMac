# AGENTS.md — working on PulseMac

Instructions for humans and coding agents contributing to this repo.

## Before changing code
1. Read [architecture](docs/architecture/architecture.md) and the relevant ADRs.
2. Check the [capability matrix](docs/architecture/capability-matrix.md) before adding any metric;
   add a row (API, OS, permission, limitation, status) first.
3. Follow [coding standards](docs/engineering/coding-standards.md).

## Hard rules
- `PulseCore` stays pure (no I/O, no Darwin/IOKit). Put logic there and test it.
- Views never call collectors, IOKit, libproc or SQLite.
- Missing data is `nil` → "—" / `UnavailableNotice`. Never zero, never fabricated.
- No shell commands, no `sudo`, no privileged helpers, no private frameworks, no permanent
  deletion, no network interception, no telemetry. Changing any of these needs an ADR.
- Correlation is never written as cause. Evidence must be typed.
- Fixture data must be visibly labelled (`FixtureBanner`) and must not write to history.
- Do not claim hardware verification, benchmarks, or macOS builds you did not run. Update
  status columns honestly.

## Workflow
```bash
scripts/check.sh        # lint (if available) + build + tests (macOS)
scripts/test-linux.sh   # portable targets in Docker
```
Add/adjust tests with every logic change (`Tests/…`). New diagnostic rules need replay coverage
in `ScenarioReplayTests` or a dedicated engine test. Update docs in the same change.

## Where things live
| Concern | Location |
|---|---|
| Metric IDs, units, explanations | `PulseCore/Metrics/MetricID.swift` |
| Rules & thresholds | `PulseCore/Diagnostics/BuiltInRules.swift` |
| Incident state machine | `PulseCore/Diagnostics/IncidentEngine.swift` |
| Action policy / redaction | `PulseCore/Actions/` |
| Cleanup rules & guard | `PulseCore/Storage/DevArtifacts.swift` |
| Collectors | `PulseMonitoring/Collectors/` |
| Sampling loop | `PulseMonitoring/Coordinator/SamplingCoordinator.swift` |
| History DB | `PulsePersistence/HistoryStore.swift` |
| UI tokens/components | `PulseMacApp/DesignSystem/` |
