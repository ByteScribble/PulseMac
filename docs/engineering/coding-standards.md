# Coding standards

Convention: Swift API Design Guidelines + `.swift-format` in repo root (140 columns, 4 spaces,
ordered imports). `scripts/check.sh` runs lint (if `swift-format` is installed), build and tests;
use it as the pre-commit hook (`ln -s ../../scripts/check.sh .git/hooks/pre-commit`).

## Rules
1. **Boundaries**: `PulseCore` has no I/O. OS calls only in `PulseMonitoring/Collectors|Actions`
   behind `#if os(macOS)`. Views never touch collectors, IOKit, libproc or SQLite.
2. **Explicit models**: typed structs/enums for domain data; no `[String: Any]` beyond the IOKit
   boundary, where it is converted immediately.
3. **Missing ≠ zero**: optional values for anything that can be unavailable; render "—" or an
   `UnavailableNotice`. Never coerce `nil` to `0` for display or storage.
4. **Units in names or types**: `…Bytes`, `…Rate` (per second), `…Percent`; `MetricID.unit` is the
   single source of a series' unit. Document the denominator of every percentage.
5. **Errors**: collectors throw `CollectorFailure`; the set records `.failed(reason)`. Don't
   swallow instrumentation errors silently. `try?` is acceptable only where failure is surfaced
   another way (documented inline).
6. **Concurrency**: collectors are confined to the coordinator actor; UI state is `@MainActor`.
   No `DispatchQueue.main.sync`. No polling loops when monitoring is paused.
7. **Safety**: new actions must be added to `RemediationKind`, `ProcessActionPolicy` and tests.
   No shell execution, no `sudo`, no permanent deletion.
8. **Copy**: correlation is never phrased as cause; limitations are stated.
9. **Size**: views < ~300 lines; split into private subviews. Types with one responsibility.
10. **Dependencies**: none without an ADR.
11. **Docs**: non-obvious decisions get a comment or an ADR; contracts live in one place
    (capability matrix, architecture, design-system) — link, don't duplicate.

## Review checklist
Modularity · naming · units/denominators · missing-data handling · performance (hot paths,
allocations per tick) · security/safety · duplication · tests added · docs updated.
