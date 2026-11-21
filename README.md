# PulseMac

PulseMac is a native macOS performance monitor and diagnostics app for Apple silicon. It lives in
the menu bar, keeps a bounded local history of system metrics, and explains what it sees using
typed evidence (measured, at the same time, possible cause, not visible). It offers only safe,
allowlisted actions and checks their effect against later measurements. Everything stays on your
machine: no account, cloud service, or telemetry.

**Status: early-stage (v0.1.0).** The portable core is built and tested on Linux. The macOS
collectors and SwiftUI app have not yet been verified on real hardware, so expect rough edges
and compile fixes. See [docs/testing/test-strategy.md](docs/testing/test-strategy.md) for what is
and is not covered.

## Features

- Menu bar item plus a main window with Overview, Processes, Investigate, Storage, Insights and
  Developer sections (Cmd-1 to Cmd-6), and per-metric detail pages.
- Collectors for CPU, memory, processes, disks/volumes, network, power/battery, thermal and GPU
  (Mach, sysctl, libproc, IOKit). Missing data is shown as unavailable, never as zero.
- Bounded history: in-memory ring buffers plus a SQLite time series with rollups, retention, a
  soft size cap, CSV export, and a clear-everything option.
- Diagnostics engine with an incident state machine and built-in rules for sustained CPU, memory
  pressure, swap growth, sustained disk writes, low disk space, thermal pressure and rapid
  battery discharge.
- Process actions (quit, SIGTERM, force quit, reveal, open Activity Monitor, move to Trash)
  gated by a safety policy; effects are verified from measurements.
- Storage cleanup for known developer artifacts: preview-first, moves items to the Trash, and
  refuses anything outside the home folder, symlinks, iCloud, or unrecognised paths.
- Redaction of usernames, hostnames, secrets, IPs and similar values in shareable output.
- Fixture scenarios (`calm`, `memoryPressure`, `runawayProcess`, `batteryDrain`) for UI
  development, clearly bannered and never written to history.

## Requirements

- macOS 14 or later, Apple silicon
- Xcode 15.3 or later (Swift 5.10+); CI builds with Xcode 15.4
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the Xcode project
- Optional: Docker, to run the portable tests on any OS with the `swift:6.0-noble` image

## Build, run, test

```bash
swift build                       # build all targets
swift test                        # run all tests
scripts/build-app.sh              # build/PulseMac.app (release, ad-hoc signed); pass "debug" for a debug build
open build/PulseMac.app
open build/PulseMac.app --args -PulseFixture memoryPressure   # fixture demo
scripts/check.sh                  # swift-format lint (if installed) + build + tests
scripts/test-linux.sh             # portable targets in Docker (no macOS app target)
```

For a signed app via Xcode: `brew install xcodegen && xcodegen`, then open `PulseMac.xcodeproj`.

The bundle ID `com.example.PulseMac` is a placeholder (in `project.yml` and `Resources/Info.plist`);
change it before distributing a build. The app is hardened-runtime and not sandboxed; see the ADRs.

## Architecture

A single Swift package with one-way module dependencies:

```
Sources/
  PulseCore/         Pure Swift domain: metrics, diagnostics, action policy, storage rules,
                     redaction, fixtures. No I/O or OS calls; builds and tests anywhere.
  PulsePersistence/  SQLite time-series history (via the CSQLite system module)
  PulseMonitoring/   macOS collectors, SamplingCoordinator, StorageScanner, ActionExecutor
  PulseMacApp/       SwiftUI/AppKit app (macOS only): DesignSystem + Features
  CSQLite/           System SQLite shim
Tests/               PulseCoreTests, PulsePersistenceTests, PulseMonitoringTests
```

Collectors feed a `SamplingCoordinator` actor, which updates history, runs the incident engine
and streams updates to the main-actor `AppModel`. Views never touch collectors, IOKit, libproc
or SQLite directly. Details: [docs/architecture/architecture.md](docs/architecture/architecture.md),
[capability matrix](docs/architecture/capability-matrix.md) and the ADRs in
[docs/architecture/adr](docs/architecture/adr).

## Contributing

Contributions are welcome once the project settles; issues and pull requests are open now. Please
read [AGENTS.md](AGENTS.md) first: it lists the hard rules (keep `PulseCore` pure, represent missing
data as `nil`, no shell commands or privileged helpers, never present correlation as cause) and
the expectation that logic changes come with tests and doc updates. Run `scripts/check.sh` before
opening a pull request, and do not claim hardware verification you have not done.

## License

MIT. See [LICENSE](LICENSE).
