"""Draw the README's animated panel: docs/assets/panel-dark.svg and panel-light.svg.

The panel acts out two reconnects in a 16 s loop. Proton VPN forwards a new port, qBittorrent's
readout goes out of sync, port-sync reads the log, sets the port, and the readouts match again.
The SVG's base styles are the first frame (both ports 48213, in sync), which is what a viewer that
skips the animation shows.

Text is converted to paths from the page's own Cyclorama Dawn fonts (docs/fonts), because an SVG
shown through <img> can't load fonts. Run from the repo root:

    python -m pip install -r docs/art/requirements.txt
    python docs/art/make-panel.py
"""
import os
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "..", "fonts")
OUT = os.path.join(HERE, "..", "assets")

# Cyclorama Dawn v2.1.0 (Steel & Beacon Orange + Signal Crimson Fault)
THEMES = {
    "dark": dict(bg="#050507", plate="#0C0C10", glass="#050507", line="#2A2C35", ink="#F4F5F8", mute="#B3B5C0",
                 steel="#74B8E8", ember="#F06E2B", beacon_ink="#FF9254", amber="#FFC247", mint="#3DDC97", rasp="#FF5C6C", ghost=0.06),
    "light": dict(bg="#F5F7F9", plate="#FFFFFF", glass="#E9EEF3", line="#D2DAE2", ink="#0D1016", mute="#525B69",
                  steel="#164669", ember="#BD4811", beacon_ink="#AD3D0A", amber="#885800", mint="#127247", rasp="#B91C2E", ghost=0.10),
}

W, H = 1000, 430
CYCLE = 16.0  # seconds
EVENTS = [(3.0, 48213, 51037), (11.0, 51037, 48213)]
SCAN, PULSE, SETTLE, SET_OFF = 1.5, 0.4, 0.3, 0.5

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

FACES = {
    "disp": ("big-shoulders-stencil-latin.woff2", 800),
    "sans": ("albert-sans-latin.woff2", 600),
    "sans_b": ("albert-sans-latin.woff2", 700),
    "mono": ("azeret-mono-latin.woff2", 400),
}

_ttfs = {}
_glyphsets = {}
_glyphs = {}


def glyphset(face):
    if face not in _glyphsets:
        fname, wght = FACES[face]
        if fname not in _ttfs:
            _ttfs[fname] = TTFont(os.path.join(FONTS, fname))
        f = _ttfs[fname]
        _glyphsets[face] = (f.getGlyphSet(location={"wght": wght}), f.getBestCmap(), f["head"].unitsPerEm)
    return _glyphsets[face]


def advance(s, size, face, ls=0.0):
    gs, cmap, upm = glyphset(face)
    return sum(gs[cmap[ord(ch)]].width for ch in s) * size / upm + ls * size * max(0, len(s) - 1)


def text(s, x, y, size, face, fill, ls=0.0, anchor="start"):
    """Path for `s` with its baseline at y. ls is letter spacing in em."""
    gs, cmap, upm = glyphset(face)
    k = size / upm
    names = []
    for ch in s:
        if ord(ch) not in cmap:
            sys.exit(f"{FACES[face][0]} has no glyph for {ch!r}")
        names.append(cmap[ord(ch)])
    width = sum(gs[n].width * k for n in names) + ls * size * max(0, len(names) - 1)
    pen_x = {"start": x, "middle": x - width / 2, "end": x - width}[anchor]
    uses = []
    for n in names:
        key = (face, n)
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
        out.append(f'<g transform="translate({dx:.2f} {y:.2f}) translate(0 {h:.2f}) skewX(-6) translate(0 {-h:.2f}) scale({k:.4f})">{polys}</g>')
    attr = f' class="{cls}"' if cls else ""
    return f'<g{attr} fill="{fill}">{"".join(out)}</g>'


def pct(t):
    return f"{t / CYCLE * 100:.3f}%"


def toggle(name, windows):
    shown = lambda t: int(any(a <= t < b for a, b in windows))
    points = sorted({0.0} | {t for w in windows for t in w if 0 < t < CYCLE})
    body = "".join(f"{pct(t)}{{opacity:{shown(t)}}}" for t in points)
    return f"@keyframes {name}{{{body}100%{{opacity:{shown(0.0)}}}}}"


def build(theme):
    c = THEMES[theme]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img">']

    (t1, a, b), (t2, _, _) = EVENTS
    s1, s2 = t1 + SCAN + PULSE + SETTLE, t2 + SCAN + PULSE + SETTLE
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
        rk[t - 0.001] = 0
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

    # --- the plate ---
    o.append(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="16" fill="{c["plate"]}" stroke="{c["line"]}"/>')
    o.append(f'<rect x="16" y="1" width="{W - 32}" height="3" rx="1.5" fill="url(#horizon)"/>')
    o.append(text("PORT-SYNC", 40, 52, 22, "disp", c["ink"], ls=0.08))
    o.append(text("3.0.0", 960, 52, 14, "mono", c["mute"], ls=0.08, anchor="end"))

    # --- the two readouts ---
    wy, wh, ww = 108, 176, 380
    dh = 98
    k = dh / 112
    span = 5 * 64 * k + 4 * 13 * k + dh * 0.1051
    for wx, who, what in ((40, "PROTON VPN", "FORWARDED PORT"), (580, "QBITTORRENT", "LISTENING PORT")):
        o.append(text(who, wx, 92, 14, "mono", c["ink"], ls=0.04))
        o.append(text(what, wx + advance(who, 14, "mono", 0.04) + 12, 92, 13, "mono", c["mute"], ls=0.04))
        o.append(f'<rect x="{wx}" y="{wy}" width="{ww}" height="{wh}" rx="10" fill="{c["glass"]}" stroke="{c["line"]}"/>')
    dx_l, dx_r, dy = 40 + (ww - span) / 2, 580 + (ww - span) / 2, wy + (wh - dh) / 2
    ghost = lambda col: f'{col}" fill-opacity="{c["ghost"]}'
    o.append(digits(88888, dx_l, dy, dh, ghost(c["amber"]), ghost=True))
    o.append(digits(88888, dx_r, dy, dh, ghost(c["mute"]), ghost=True))
    o.append("<g>")
    o.append(digits(a, dx_l, dy, dh, c["amber"], "src-a"))
    o.append(digits(b, dx_l, dy, dh, c["amber"], "src-b"))
    o.append(digits(a, dx_r, dy, dh, c["mint"], "dst-a-ok"))
    o.append(digits(a, dx_r, dy, dh, c["rasp"], "dst-a-off"))
    o.append(digits(b, dx_r, dy, dh, c["mint"], "dst-b-ok"))
    o.append(digits(b, dx_r, dy, dh, c["rasp"], "dst-b-off"))
    o.append("</g>")

    # --- port-sync between them ---
    cx, cy = 500, wy + wh / 2
    o.append(text("port-sync", cx, cy - 46, 17, "sans_b", c["ink"], anchor="middle"))
    o.append(text("every 15 s", cx, cy - 26, 13, "mono", c["mute"], anchor="middle"))
    o.append(f'<rect x="420" y="{cy - 1:.1f}" width="160" height="2" fill="{c["line"]}"/>')
    o.append(f'<rect class="pulse" x="421" y="{cy - 2:.1f}" width="40" height="4" rx="2" fill="{c["ember"]}"/>')
    o.append(f'<circle cx="{cx}" cy="{cy}" r="15" fill="{c["plate"]}" stroke="{c["line"]}" stroke-width="4"/>')
    o.append(f'<circle class="ring" cx="{cx}" cy="{cy}" r="15" fill="none" stroke="{c["ember"]}" stroke-width="4" stroke-dasharray="{ring_len:.2f}" transform="rotate(-90 {cx} {cy})"/>')
    for i, (label, col, cls) in enumerate((("READ", c["amber"], "read"), ("SET", c["beacon_ink"], "set"))):
        ly = cy + 46 + i * 26
        o.append(f'<rect x="{cx - 34}" y="{ly - 10}" width="8" height="8" rx="2" fill="{c["line"]}"/>')
        o.append(f'<rect class="{cls}" x="{cx - 34}" y="{ly - 10}" width="8" height="8" rx="2" fill="{col}"/>')
        o.append(text(label, cx - 18, ly, 13, "mono", c["mute"], ls=0.08))

    # --- under the readouts ---
    sy = wy + wh + 38
    for cls, port in (("src-a", a), ("src-b", b)):
        o.append(f'<g class="{cls}">' + text(f"Port pair {port}->{port}", 40, sy, 15, "mono", c["mute"]) + "</g>")
    o.append(f'<g class="ok">{text("[ok] IN SYNC", 580, sy, 15, "mono", c["mint"], ls=0.04)}</g>')
    o.append(f'<g class="off">{text("[x] OUT OF SYNC", 580, sy, 15, "mono", c["rasp"], ls=0.04)}</g>')

    # --- sync.log ---
    o.append(f'<rect x="40" y="{H - 82}" width="920" height="1" fill="{c["line"]}"/>')
    lines = {
        "log0": "08:14:02 [port-sync] listening port already correct: 48213",
        "log2": f"08:14:17 [port-sync] listening port updated: {a} -> {b}",
        "log4": f"09:02:31 [port-sync] listening port updated: {b} -> {a}",
    }
    for cls, s in lines.items():
        o.append(f'<g class="{cls}">' + text(s, 40, H - 40, 15, "mono", c["ink"]) + "</g>")

    grad = f'<linearGradient id="horizon" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{c["steel"]}"/><stop offset="1" stop-color="{c["ember"]}"/></linearGradient>'
    defs = "".join(f'<path id="{gid}" d="{d}"/>' for gid, d in _glyphs.values() if d)
    o.insert(1, f"<defs>{grad}{defs}</defs>")
    o.append("</svg>")
    return "".join(o)


for theme in THEMES:
    _glyphs.clear()
    path = os.path.join(OUT, f"panel-{theme}.svg")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(build(theme) + "\n")
    print(f"wrote {os.path.relpath(path)} ({os.path.getsize(path) // 1024} KB)")
