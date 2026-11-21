# ADR 0003 — Direct distribution, hardened runtime, no sandbox, no privileged helper

Status: Accepted (2026-11-01)

## Context
Core features (enumerating all processes, `proc_pid_rusage`, IOKit registry reads, arbitrary
folder scanning) are restricted inside the App Sandbox. Privileged helpers would allow more data
(other users' process usage, `powermetrics`) but contradict least privilege.

## Decision
Ship outside the Mac App Store as a Developer ID–signed, notarized app with hardened runtime,
**no** sandbox, **no** entitlements, **no** privileged helper. Never run `sudo`. Full Disk Access
is optional and only improves storage scans.

## Consequences
- Other users' and system processes show identity without resource figures (labelled).
- A sandboxed "lite" App Store edition would need a separate capability set; not planned.
- Any future helper requires a new ADR with security review and explicit user opt-in.
