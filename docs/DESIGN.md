# Design: port-sync (`docs/`, README panel, and tray icon)

## Concept

`port-sync` is a process controller: Proton VPN's forwarded port is the set point, and qBittorrent's listening port follows it every 15 seconds. The page and README panel present two 7-segment readouts linked by a 15-second sweep ring and `READ`/`SET` lamps.

## Brand System

Built on **Cyclorama Dawn `v2.1.0`** (`Real-Fruit-Snacks/rfs-brand`):
- **Default mode:** Beacon Horizon Dark (`LX 263`, matte `#050507`) with opt-in Alabaster Day Light (`LX 512`, `#F5F7F9`) toggle synced across tabs via `localStorage['rfs-theme']`.
- **Two chromatic poles:** Glacial Steel (`#1F547A` / `#74B8E8` / `#164669`) and Maritime Beacon Orange (`#F06E2B` / `#FF9254` / `#AD3D0A`), interpolated strictly in Cartesian `in oklab`.
- **Semantic signals:** Amber (`#FFC247` / `#885800`) for Proton VPN's forwarded port and waiting states, Mint (`#3DDC97` / `#127247`) for `[ok] In sync`, and **Signal Crimson** (`#FF5C6C` / `#B91C2E`) for `[x] Out of sync` and tray `Look::Problem` states (`src/winutil.rs`).
- **Typography:** Self-hosted variable WOFF2 — `Big Shoulders Stencil` (display headings), `Albert Sans` (UI and prose), and `Azeret Mono` (telemetry, log lines, and commands).
- **Shell & scrollbars:** Uses `.rfs-shell` + `.rfs-shell-header` + `.rfs-scroll-region` so the vertical scrollbar starts strictly below the top header bar.

## Generated Art & CI Verification

`docs/art/make-panel.py` draws `docs/assets/panel-{dark,light}.svg` from `docs/fonts/`. `.github/workflows/ci.yml` (`art` job) regenerates both SVGs and enforces zero diff. `docs/assets/cover-*` and `social-*` are generated via `rfs-brand/tools/make-cover.py`.
