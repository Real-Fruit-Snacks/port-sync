"""Draw the README's animated panel: docs/assets/panel-dark.svg and panel-light.svg.

The panel acts out two reconnects in a 16 s loop. Proton VPN forwards a new port, qBittorrent's
readout goes out of sync, port-sync reads the log, sets the port, and the readouts match again.
The SVG's base styles are the first frame (both ports 48213, in sync), which is what a viewer that
skips the animation shows.

Text is converted to paths from the page's own fonts (docs/fonts), because an SVG shown through
<img> can't load fonts. Run from the repo root:

    python -m pip install -r docs/art/requirements.txt
    python docs/art/make-panel.py
"""
import os
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "..", "fonts")
OUT = os.path.join(HERE, "..", "assets")

# RFS Nightshift and Dayshift
THEMES = {
    "dark": dict(bg="#0C0D10", plate="#1A1D24", glass="#070809", line="#262A33", ink="#E8E6E1", mute="#8A8F99",
                 ember="#FF6A3D", amber="#FFC247", mint="#3DDC97", rasp="#F06292", ghost=0.06, glow=True),
    "light": dict(bg="#F6F5F2", plate="#FFFFFF", glass="#ECEAE4", line="#D6D3CB", ink="#1A1B1E", mute="#666A73",
                  ember="#C03B0A", amber="#925F00", mint="#15794D", rasp="#B0306A", ghost=0.10, glow=False),
}

W, H = 1000, 430
CYCLE = 16.0  # seconds
# Each reconnect: (time Proton changes, old port, new port). Reading, setting and syncing follow it.
EVENTS = [(3.0, 48213, 51037), (11.0, 51037, 48213)]
SCAN, PULSE, SETTLE, SET_OFF = 1.5, 0.4, 0.3, 0.5

# The seven segments in a 64 x 112 box (the same polygons as docs/index.html).
SEGMENTS = {
    "a": "6.5,5 11.5,0 52.5,0 57.5,5 52.5,10 11.5,10",
    "b": "59,6.5 64,11.5 64,49.5 59,54.5 54,49.5 54,11.5",
    "c": "59,57.5 64,62.5 64,100.5 59,105.5 54,100.5 54,62.5",
    "d": "6.5,107 11.5,102 52.5,102 57.5,107 52.5,112 11.5,112",
    "e": "5,57.5 10,62.5 10,100.5 5,105.5 0,100.5 0,62.5",
    "f": "5,6.5 10,11.5 10,49.5 5,54.5 0,49.5 0,11.5",
    "g": "6.5,56 11.5,51 52.5,51 57.5,56 52.5,61 11.5,61",
}
LIT = {"0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
       "6": "afgecd", "7": "abc", "8": "abcdefg", "9": "abcdfg"}

_fonts = {}
_glyphs = {}   # (font, glyph name) -> (id, path in font units); drawn once in <defs>, reused by <use>


def font(name):
    if name not in _fonts:
        _fonts[name] = TTFont(os.path.join(FONTS, name))
    return _fonts[name]


def advance(s, size, fname, ls=0.0):
    f = font(fname)
    gs, cmap = f.getGlyphSet(), f.getBestCmap()
    return sum(gs[cmap[ord(ch)]].width for ch in s) * size / f["head"].unitsPerEm + ls * size * (len(s) - 1)


def text(s, x, y, size, fname, fill, ls=0.0, anchor="start"):
    """Path for `s` with its baseline at y. ls is letter spacing in em."""
    f = font(fname)
    gs, cmap, upm = f.getGlyphSet(), f.getBestCmap(), f["head"].unitsPerEm
    k = size / upm
    names = []
    for ch in s:
        if ord(ch) not in cmap:
            sys.exit(f"{fname} has no glyph for {ch!r}")
        names.append(cmap[ord(ch)])
    width = sum(gs[n].width * k for n in names) + ls * size * (len(names) - 1)
    pen_x = {"start": x, "middle": x - width / 2, "end": x - width}[anchor]
    uses = []
    for n in names:
        key = (fname, n)
        if key not in _glyphs:
            pen = SVGPathPen(gs, ntos=lambda v: "%g" % round(v, 1))
            gs[n].draw(pen)
            _glyphs[key] = (f"g{len(_glyphs)}", pen.getCommands())
        gid, d = _glyphs[key]
        if d:
            uses.append(f'<use href="#{gid}" transform="matrix({k:.5f} 0 0 {-k:.5f} {pen_x:.2f} {y:.2f})"/>')
        pen_x += gs[n].width * k + ls * size
    return f'<g fill="{fill}">{"".join(uses)}</g>'


def digits(value, x, y, h, fill, cls=None, ghost=False):
    """Five seven-segment digits, right-aligned like a meter, top-left at (x, y), h tall."""
    k = h / 112
    gap = 13 * k
    out = []
    for i, ch in enumerate(str(value).rjust(5)):
        dx = x + i * (64 * k + gap)
        lit = "abcdefg" if ghost else LIT.get(ch, "")
        polys = "".join(f'<polygon points="{SEGMENTS[s]}"/>' for s in lit)
        # skewX(-6deg) about the digit's baseline, as on the page
        out.append(f'<g transform="translate({dx:.2f} {y:.2f}) translate(0 {h:.2f}) skewX(-6) translate(0 {-h:.2f}) scale({k:.4f})">{polys}</g>')
    attr = f' class="{cls}"' if cls else ""
    return f'<g{attr} fill="{fill}">{"".join(out)}</g>'


def pct(t):
    return f"{t / CYCLE * 100:.3f}%"


def toggle(name, windows):
    """Keyframes (run with step-end) that show an element only inside the given (start, end) windows."""
    shown = lambda t: int(any(a <= t < b for a, b in windows))
    points = sorted({0.0} | {t for w in windows for t in w if 0 < t < CYCLE})
    body = "".join(f"{pct(t)}{{opacity:{shown(t)}}}" for t in points)
    return f"@keyframes {name}{{{body}100%{{opacity:{shown(0.0)}}}}}"


def build(theme):
    c = THEMES[theme]
    cond, cond_b, mono = "barlow-condensed-latin-600.woff2", "barlow-condensed-latin-700.woff2", "dm-mono-latin-400.woff2"
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img">']

    # --- timing: when each state shows ---
    (t1, a, b), (t2, _, _) = EVENTS
    s1, s2 = t1 + SCAN + PULSE + SETTLE, t2 + SCAN + PULSE + SETTLE  # qBittorrent catches up
    win = {
        "src-a": [(0, t1), (t2, CYCLE)], "src-b": [(t1, t2)],
        "dst-a-ok": [(0, t1), (s2, CYCLE)], "dst-a-off": [(t1, s1)],
        "dst-b-ok": [(s1, t2)], "dst-b-off": [(t2, s2)],
        "ok": [(0, t1), (s1, t2), (s2, CYCLE)], "off": [(t1, s1), (t2, s2)],
        "log0": [(0, s1)], "log2": [(s1, s2)], "log4": [(s2, CYCLE)],
        "read": [(t1 + SCAN, t1 + SCAN + PULSE), (t2 + SCAN, t2 + SCAN + PULSE)],
        "set": [(t1 + SCAN + PULSE, s1 + SET_OFF), (t2 + SCAN + PULSE, s2 + SET_OFF)],
    }
    css = [toggle(k, v) for k, v in win.items()]
    ring_len = 2 * 3.14159265 * 15
    rk = {0.0: 0}
    for t in (t1, t2):
        rk[t - 0.001] = 0          # hold full until Proton changes, then empty and refill over SCAN
        rk[t] = ring_len
        rk[t + SCAN] = 0
    css.append("@keyframes ring{" + "".join(f"{pct(t)}{{stroke-dashoffset:{v:.2f}}}" for t, v in sorted(rk.items())) + "100%{stroke-dashoffset:0}}")
    pk = []
    for t in (t1, t2):
        st = t + SCAN
        pk += [f"{pct(st - 0.001)}{{transform:translateX(0);opacity:0}}", f"{pct(st)}{{transform:translateX(0);opacity:1}}",
               f"{pct(st + PULSE)}{{transform:translateX(118px);opacity:1}}", f"{pct(st + PULSE + 0.001)}{{transform:translateX(118px);opacity:0}}"]
    css.append("@keyframes pulse{0%{opacity:0}" + "".join(pk) + "100%{opacity:0}}")
    rules = "".join(f".{k}{{animation:{k} {CYCLE}s step-end infinite}}" for k in win)
    rules += f".ring{{animation:ring {CYCLE}s linear infinite}}.pulse{{animation:pulse {CYCLE}s linear infinite}}"
    base = "".join(f".{k}{{opacity:{1 if v[0][0] == 0 else 0}}}" for k, v in win.items())
    o.append(f"<style>{base}@media (prefers-reduced-motion:no-preference){{{''.join(css)}{rules}}}</style>")

    if c["glow"]:
        o.append('<defs><filter id="glow" x="-10%" y="-20%" width="120%" height="140%"><feGaussianBlur stdDeviation="5" result="b"/>'
                 '<feComponentTransfer in="b" result="g"><feFuncA type="linear" slope=".7"/></feComponentTransfer>'
                 '<feMerge><feMergeNode in="g"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>')
    glow = ' filter="url(#glow)"' if c["glow"] else ""

    # --- the plate ---
    o.append(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="22" fill="{c["plate"]}" stroke="{c["line"]}"/>')
    o.append(text("PORT-SYNC", 40, 52, 17, cond_b, c["mute"], ls=0.2))
    o.append(text("2.0.0", 960, 52, 17, cond_b, c["mute"], ls=0.2, anchor="end"))

    # --- the two readouts ---
    wy, wh, ww = 108, 176, 380
    dh = 98
    k = dh / 112
    span = 5 * 64 * k + 4 * 13 * k + dh * 0.1051   # five digits, four gaps, and the lean (tan 6 deg)
    for wx, who, what in ((40, "PROTON VPN", "FORWARDED PORT"), (580, "QBITTORRENT", "LISTENING PORT")):
        o.append(text(who, wx, 92, 19, cond_b, c["ink"], ls=0.12))
        o.append(text(what, wx + advance(who, 19, cond_b, 0.12) + 12, 92, 19, cond, c["mute"], ls=0.12))
        o.append(f'<rect x="{wx}" y="{wy}" width="{ww}" height="{wh}" rx="12" fill="{c["glass"]}" stroke="{c["line"]}"/>')
    dx_l, dx_r, dy = 40 + (ww - span) / 2, 580 + (ww - span) / 2, wy + (wh - dh) / 2
    ghost = lambda col: f'{col}" fill-opacity="{c["ghost"]}'
    o.append(digits(88888, dx_l, dy, dh, ghost(c["amber"]), ghost=True))
    o.append(digits(88888, dx_r, dy, dh, ghost(c["mute"]), ghost=True))   # neutral: the colour of the number changes
    o.append(f'<g{glow}>')
    o.append(digits(a, dx_l, dy, dh, c["amber"], "src-a"))
    o.append(digits(b, dx_l, dy, dh, c["amber"], "src-b"))
    o.append(digits(a, dx_r, dy, dh, c["mint"], "dst-a-ok"))
    o.append(digits(a, dx_r, dy, dh, c["rasp"], "dst-a-off"))
    o.append(digits(b, dx_r, dy, dh, c["mint"], "dst-b-ok"))
    o.append(digits(b, dx_r, dy, dh, c["rasp"], "dst-b-off"))
    o.append("</g>")

    # --- port-sync between them: label, wire, the 15 s ring, the lamps ---
    cx, cy = 500, wy + wh / 2
    o.append(text("port-sync", cx, cy - 46, 24, cond_b, c["ink"], anchor="middle"))
    o.append(text("every 15 s", cx, cy - 24, 17, cond, c["mute"], anchor="middle"))
    o.append(f'<rect x="420" y="{cy - 1:.1f}" width="160" height="2" fill="{c["line"]}"/>')
    o.append(f'<rect class="pulse" x="421" y="{cy - 2:.1f}" width="40" height="4" rx="2" fill="{c["ember"]}"/>')
    o.append(f'<circle cx="{cx}" cy="{cy}" r="15" fill="{c["plate"]}" stroke="{c["line"]}" stroke-width="4"/>')
    o.append(f'<circle class="ring" cx="{cx}" cy="{cy}" r="15" fill="none" stroke="{c["ember"]}" stroke-width="4" stroke-dasharray="{ring_len:.2f}" transform="rotate(-90 {cx} {cy})"/>')
    for i, (label, col, cls) in enumerate((("READ", c["amber"], "read"), ("SET", c["ember"], "set"))):
        ly = cy + 46 + i * 28
        o.append(f'<circle cx="{cx - 30}" cy="{ly - 6}" r="5" fill="{c["line"]}"/>')
        o.append(f'<circle class="{cls}" cx="{cx - 30}" cy="{ly - 6}" r="5" fill="{col}"/>')
        o.append(text(label, cx - 18, ly, 16, cond_b, c["mute"], ls=0.14))

    # --- under the readouts: Proton's log line on the left, the sync state on the right ---
    sy = wy + wh + 38
    for cls, port in (("src-a", a), ("src-b", b)):
        o.append(f'<g class="{cls}">' + text(f"Port pair {port}->{port}", 40, sy, 17, mono, c["mute"]) + "</g>")
    o.append(f'<g class="ok"><circle cx="587" cy="{sy - 6}" r="6" fill="{c["mint"]}"/>{text("IN SYNC", 602, sy, 19, cond_b, c["mint"], ls=0.14)}</g>')
    o.append(f'<g class="off"><circle cx="587" cy="{sy - 6}" r="6" fill="{c["rasp"]}"/>{text("OUT OF SYNC", 602, sy, 19, cond_b, c["rasp"], ls=0.14)}</g>')

    # --- sync.log ---
    o.append(f'<rect x="40" y="{H - 82}" width="920" height="1" fill="{c["line"]}"/>')
    lines = {
        "log0": "08:14:02 [port-sync] listening port already correct: 48213",
        "log2": f"08:14:17 [port-sync] listening port updated: {a} -> {b}",
        "log4": f"09:02:31 [port-sync] listening port updated: {b} -> {a}",
    }
    for cls, s in lines.items():
        o.append(f'<g class="{cls}">' + text(s, 40, H - 40, 18, mono, c["ink"]) + "</g>")

    defs = "".join(f'<path id="{gid}" d="{d}"/>' for gid, d in _glyphs.values() if d)
    o.insert(1, f"<defs>{defs}</defs>")
    o.append("</svg>")
    return "".join(o)


for theme in THEMES:
    _glyphs.clear()
    path = os.path.join(OUT, f"panel-{theme}.svg")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(build(theme) + "\n")
    print(f"wrote {os.path.relpath(path)} ({os.path.getsize(path) // 1024} KB)")
