# ADR 0001 — Modular monolith in one Swift package

Status: Accepted (2026-11-01)

## Context
The product needs strict separation between UI, instrumentation and diagnostics, testability
without a Mac for most logic, and low ceremony.

## Decision
One SwiftPM package with four modules (`PulseCore`, `PulsePersistence`, `PulseMonitoring`,
`PulseMacApp`). `PulseCore` is pure Swift and builds on Linux; macOS-specific code is behind
`#if os(macOS)`. An XcodeGen spec wraps the app target for signing.

## Alternatives
- One app target with folders: no enforced boundaries.
- A package per feature: high ceremony, slower builds, little benefit at this size.
- XPC services per collector: isolation not needed without privileged helpers.

## Consequences
CI can test core logic on Linux in seconds; macOS CI builds the app. Feature folders inside the
app are conventions, not modules.
