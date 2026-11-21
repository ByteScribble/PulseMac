# Navigation & window architecture

## Layers
| Layer | Scene | Purpose |
|---|---|---|
| A — Menu bar | `MenuBarExtra(.window)` | Always available; status + ≤3 readings; popover answers "is anything wrong?" without opening the app |
| B — Dashboard | `WindowGroup("main")` with `NavigationSplitView` | Overview, Processes, Investigate, Storage, Insights, Developer |
| C — Detail | Pushed in Overview (`DetailRoute`) | CPU, Memory, Network, Disk, GPU, Battery & Thermal — one consistent layout |
| D — Investigation | Section *and* separate `Window("investigation")` | Linked timelines, incidents, what-was-running, before/after, notes, report |
| Settings | `Settings` scene | General, Data & Privacy, Capabilities, About (self-overhead) |

Hardware domains are deliberately **not** top-level sidebar items; they are reached from
Overview cards so the first screen stays understandable.

## Menu bar
Label is a single `Text` with an inline SF Symbol (reliable in `MenuBarExtra`):
- Minimal: `◉ 23%`
- Balanced: `◉ 23% M● ↓1.2M`
- Developer: `◉ 23% M● W4.0M`
The symbol switches to the incident severity symbol when something needs attention. Memory
uses ● ▲ ■ for normal / elevated / critical so it is not colour-dependent.

Popover (340 pt): status headline + detail → CPU/memory/network sparklines → top incident with
*Investigate* → top 5 apps (CPU, memory) → *Open Dashboard* (⌘D) and ⋯ menu (Settings, Pause,
Quit).

## Wireframes (text)

```
┌ Overview ─────────────────────────────────────────────────────────────┐
│ ▲ Memory pressure is elevated                                          │
│   macOS is compressing and possibly swapping…                          │
│ Needs attention  [incident card: evidence · Investigate · Snooze]      │
│ ┌CPU──────┐ ┌MEMORY───┐ ┌NETWORK──┐                                    │
│ │23 %     │ │Elevated │ │↓1.2MB/s │   adaptive grid, click → detail    │
│ │~~~~~~~~ │ │▇▇▇▇▇▁▁  │ │~~~~~~~~ │                                    │
│ └─────────┘ └─────────┘ └─────────┘ (Disk, GPU, Battery & Thermal)     │
│ Top consumers: CPU | Memory      Recent activity                       │
└────────────────────────────────────────────────────────────────────────┘

┌ Processes ───────────────────────────────────────┬ Inspector ─────────┐
│ [search] [Filter ▾] [Group by app] [Inspector]   │ Slack  PID 1900    │
│ Name           PID   CPU%  Memory  Writes  User  │ CPU · Memory charts│
│ ▸ Google Chrome 3 pr  19.0  1.86 GB  —     you   │ Growth: stable     │
│   node         1502 780.0  310 MB  1.5MB/s you   │ Details · cmd line │
│ kernel_task 🔒    0     —       —     —    root  │ [Quit][End][Force] │
└──────────────────────────────────────────────────┴────────────────────┘

┌ Investigate ─┬──────────────────────────────────────────────────────────┐
│ Incidents    │ [15m|1h|6h|24h|7d]  10:02–11:02  [Compare] [Report] [⧉]  │
│ ▲ Memory…    │ Focused incident: evidence chips                         │
│ ● CPU…       │ CPU ~~~~~~~|~~~~  (shared cursor across all charts)      │
│              │ Pressure ▁▁▁▇▇|▇▇                                          │
│              │ Swap ____/‾|‾‾  Disk · Network · GPU · Battery · Thermal │
│              │ What was running (per-minute summaries) · Notes          │
└──────────────┴──────────────────────────────────────────────────────────┘
```

## Context retention
`AppModel` holds `selection`, `detailRoute`, `inspectedProcess`, `investigationFocus`, so
switching sections and returning keeps context; Overview/popover "Investigate" sets the focus.
