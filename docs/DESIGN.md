# Design: the port-sync page (docs/) and README panel

## Concept

port-sync is a control loop: Proton VPN's forwarded port is the set point, qBittorrent's listening port is the value that has to follow it, and port-sync reads one and corrects the other every 15 seconds. So the page is the front panel of a process controller. Two seven-segment readouts, one above the other the way a controller shows its set point over its process value. Panel legends are set in condensed capitals, and lamps light when something happens. A visitor should leave knowing which two numbers port-sync keeps equal, and that it's a small, exact thing.

## Audience and primary action

People who torrent through Proton VPN on Windows and have noticed seeding stop after a reconnect. They need to see what it does, that it's safe (the password stays on the machine) and reversible, then copy the install line.

## Type

- Display and panel legends: Barlow Condensed 600 and 700. It's the condensed grotesque of signage and equipment labels, and it fits five-digit numbers and long legends into narrow panels.
- Text: Barlow 400 to 600, the same family at normal width, so the page reads as one voice.
- Mono: DM Mono 400 and 500 for commands, log lines and code. It's quieter than the panel type, so commands don't compete with the readouts.
- Scale: `scale.mjs`, 16px to 18px, ratio 1.2 to 1.333. The headline is `clamp(2.6rem, …, 4.7rem)`.
- Fonts are self-hosted in `fonts/`, with their OFL licences.

## Color

The RFS Nightshift and Dayshift values and nothing else. The OS setting decides the theme, the Night/Day switch overrides it, and the choice is saved as `rfs-theme` like the other RFS pages.

| Role | Night | Day | Use |
|---|---|---|---|
| bg / surface / raised | `#0C0D10` / `#13151A` / `#1A1D24` | `#F6F5F2` / `#FFFFFF` / `#ECEAE4` | Page, the plate (raised at night, surface by day) |
| glass | `#070809` | `#ECEAE4` | The readout windows: black LED glass at night, LCD grey by day |
| line / line-strong | `#262A33` / `#636872` | `#D6D3CB` / `#89867F` | Rules; control borders |
| ink / mute | `#E8E6E1` / `#8A8F99` | `#1A1B1E` / `#666A73` | Text |
| Ember | `#FF6A3D` | `#C03B0A` | port-sync itself: the wire, the 15 s ring, the Set lamp, the copy button, focus |
| Amber | `#FFC247` | `#925F00` | Proton VPN's port; the Read lamp |
| Mint | `#3DDC97` | `#15794D` | qBittorrent's port when it matches ("In sync") |
| Raspberry | `#F06292` | `#B0306A` | qBittorrent's port when it doesn't ("Out of sync") |

Every colour state comes with a word: "In sync" and "Out of sync", the lamp labels, and "Fixed", "Waiting" or "Stopped" in the sync.log table. Unlit segments are the lit colour at 5% (night) or 10% (day) over the glass. Only Night glows.

## Layout

A 1200px wrap. The hero puts the headline and install line on the left and the panel on the right; on a phone the panel comes straight after the headline, so it's on the first screen. Below it, each section takes the form its content needs: a statement for why it exists, a three-stop signal path for the loop (in: Proton's log line, port-sync, out: the Web UI call), a table of real sync.log lines, a two-column command sheet, and the parameter table.

## Signature

The readouts. Digits are seven-segment SVG: seven polygons drawn once and reused by every digit, leaning 6°, right-aligned like a meter. The model label `PORT-SYNC 2.1.0` sits on the plate.

## Wow moment

On load the panel shows the synced state (48213 over 48213). After 1.1s Proton "reconnects": the top readout jumps to 51037 and its window edge flashes Amber. The bottom readout turns Raspberry and reads "Out of sync", and the Ember ring refills. That's the 15s wait, shortened to 1.5s and labelled as a simulation. Then the Read lamp lights, a pulse runs down the wire, and Set lights. The bottom readout switches to 51037 in Mint, and the log line underneath prints the real `listening port updated: 48213 -> 51037`. "Simulate a reconnect" replays it with a new port.

- **No JS:** the synced panel, complete.
- **Reduced motion:** no automatic run. The button still works, with no ring, pulse or pauses.
- **Phone:** the same panel, full width, right under the headline.

## README panel

`docs/art/make-panel.py` draws the same panel side by side as `assets/panel-{dark,light}.svg`, with text turned to paths from `fonts/` (an `<img>` can't load fonts). It runs a 16s loop of two reconnects (48213 to 51037 and back) using CSS keyframes. Its base styles are the first frame. CI regenerates it and fails if the committed SVGs differ. `card.html` puts that first frame under the name for the 1280 × 640 social preview (`assets/social.png`).

Don't wrap the README's `<picture>` in a link: GitHub then shows the light image in dark mode.

## Motion

Lamps and digits switch the way hardware does, with a 90ms fill transition at most. The ring fills linearly. The pulse uses `cubic-bezier(.2, .7, .2, 1)`. Nothing loops on the page. Nothing flashes more than once a second.

## Voice

Plain and exact, as in the README: real commands, real log lines, real parameter names, and limits stated near the top. The log lines are quoted exactly as `port-sync.ps1` writes them.

## Files

- `index.html`, `styles.css`, `script.js`, `fonts/`, and the icons and manifest. The favicon is an Amber bar over a Mint bar on the Nightshift tile: two values, equal.
- `assets/cover-*`, `assets/social-*.png` and `assets/cover.toml` are the RFS brand cover from rfs-brand's `make-cover.py`. The page doesn't use them, but the rfs-brand site's cover gallery loads `cover-{dark,light}.svg` from here, so they stay.

## Alternatives considered

- A patch bay: a cable re-patched from Proton's jack to qBittorrent's on every reconnect. It's more playful, but drawing cables and jacks well by hand is risky, and the numbers would get smaller.
- A sync.log page: the whole page set as a log file, with the forwarded-port lines lit. It's honest but quiet, and it hides the one number that matters in a wall of text.
