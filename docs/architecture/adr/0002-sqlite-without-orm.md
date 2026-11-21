# ADR 0002 — SQLite through a thin wrapper, no ORM

Status: Accepted (2026-11-01)

## Context
History needs batched time-series writes, rollups expressed as SQL aggregates, retention, and
migrations. Options: SwiftData/Core Data, GRDB, raw SQLite.

## Decision
System SQLite (`CSQLite` module map) behind `SQLiteDatabase`/`Statement` (~150 lines) and a
single `HistoryStore` owning the schema.

## Why
- Rollups/retention are single SQL statements; an ORM adds little.
- No third-party dependency to audit or update; works on Linux for tests.
- SwiftData is not designed for high-rate append-only series and is not available on Linux.

## Consequences
We own a small amount of unsafe C interop (tested). If query needs grow (full-text search,
observation), GRDB is the preferred upgrade path.
