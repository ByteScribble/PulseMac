# Design system

Source of truth in code: `Sources/PulseMacApp/DesignSystem/` (`Tokens.swift`, `Components.swift`,
`Charts.swift`). This document explains intent; values live in code only.

## Direction
Premium native utility: system font, neutral surfaces, one restrained blue/cyan accent, small
meaningful status marks, dense-but-calm layouts. No neon, no glass everywhere, no gauges, no
composite score.

## Tokens
- **Spacing** 2 / 4 / 8 / 12 / 16 / 24 / 32 (`Spacing.xxs…xxl`).
- **Radius** 6 small, 10 card, 12 window.
- **Colour** (light/dark adaptive):
  - `accent` #0B72B9 / #4CB3EA, `accentSoft` for tags.
  - Status: `neutral` (secondary label), `warning` amber #B86E00 / #F2B441, `urgent` system red,
    `verified` system green — **green only for verified healthy/success** (e.g. a measured
    improvement), never for "probably fine".
  - Surfaces: `controlBackgroundColor` cards on `windowBackgroundColor`, hairline separators.
  - Chart series: accent, violet, orange, teal — distinguishable in both appearances.
- **Type**: SF system; live readings use `.rounded` + `monospacedDigit()` (26 pt primary,
  17 pt secondary); card titles 12 pt semibold uppercase with tracking; captions secondary.

## Status never relies on colour alone
`StatusLabel` = SF Symbol shape + colour + text (calm ✓ circle, attention ▲, urgent octagon,
unknown ?, verified seal). Evidence chips are text-labelled: MEASURED, AT THE SAME TIME,
POSSIBLE CAUSE, NOT VISIBLE.

## Components
| Component | Use |
|---|---|
| `Card` | All grouped content; 16 pt padding, hairline border |
| `MetricCard` (Overview) | Title, info, primary reading, context line, sparkline, click → detail |
| `ReadingView` | Value + unit + caption with numeric transitions |
| `InfoButton` | Popover: meaning, source, sampling interval (trustworthy numbers) |
| `UnavailableNotice` | Honest state for any non-available capability (never zero) |
| `FixtureBanner` | Always visible when synthetic data is shown |
| `EvidenceRow`, `IncidentCard`, `ActionStatusRow` | Diagnostics and remediation lifecycle |
| `UsageBar`, `MemoryBreakdownBar`, `SafetyBadge` | Capacity, composition, cleanup safety |
| `Sparkline` | Non-interactive trend, gap-aware |
| `TimeSeriesChart` | Units on axis, hover value, shared cursor (linked crosshair), incident shading, gap segments, empty state, VoiceOver summary, no per-point animation |

## States
Every data view handles: loading ("Measuring…"), empty (`ContentUnavailableView`), unavailable
(`UnavailableNotice` with reason), permission-limited (lock + explanation), error (collector
`.failed(reason)`), fixture (banner).

## Accessibility spec
- All status combines icon + text; VoiceOver labels on cards, charts (`accessibilityValue`
  summary: latest/avg/max), bars and core grid.
- Keyboard: ⌘1–6 sections, ⌘[ back from detail, ⌘⇧I investigation window, ⌘⌥I inspector, ⌘⇧P
  pause; tables are fully keyboard navigable.
- Reduced motion: only `numericText` content transitions; charts disable animation.
- Dynamic type is limited on macOS; layouts use adaptive grids and wrap text
  (`fixedSize(horizontal: false, …)`).

## UI review checklist
- [ ] Every number has a unit and an info source.
- [ ] Missing data renders "—" or an `UnavailableNotice`, never 0.
- [ ] Colour is never the only signal.
- [ ] Correlation wording never implies cause.
- [ ] Destructive actions confirm and say what is lost.
- [ ] Works in light, dark, increased contrast, at 900×600.
- [ ] VoiceOver reads each card as one sensible sentence.
- [ ] Fixture banner visible whenever fixture data is shown.
