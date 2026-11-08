"""Draws the README illustrations: how Error Signal's messages arrive on Discord. Light
and dark versions of each, as plain SVG (system fonts, no script), so GitHub can show the
one matching the reader's theme.

    python3 docs/assets/make_images.py

The payloads below are what the gem's own builders produced for fake errors of a fake
"shop" app (a small Rails app reporting them through ErrorSignal.subscriber, with
Delivery.post stubbed to collect the payloads, then Report.deliver("daily")), copied
verbatim: the texts are the gem's English strings. When a message changes, rebuild them
the same way, paste them here and run this again. The images are not part of the gem
package (see the gemspec).
"""

from __future__ import annotations

import re
from html import escape
from pathlib import Path

OUT = Path(__file__).resolve().parent
W = 720
FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif'
MONO = 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace'

THEMES = {
    "light": {"bg": "#ffffff", "embed": "#f2f3f5", "text": "#313338", "strong": "#060607", "muted": "#5c5e66",
              "badge": "#4e5d94", "line": "#e3e5e8", "code": "#e3e5e8", "code_text": "#2e3338",
              "mention": "#e6e8fd", "mention_text": "#3a46c2"},
    "dark": {"bg": "#313338", "embed": "#2b2d31", "text": "#dbdee1", "strong": "#f2f3f5", "muted": "#949ba4",
             "badge": "#5865f2", "line": "#3f4147", "code": "#1e1f22", "code_text": "#dbdee1",
             "mention": "#3c4270", "mention_text": "#c9cdfb"},
}
AVATAR = "#be123c"

# -- the payloads, as the gem built them ---------------------------------------------------

FOOTER = "Error Signal 1.1.0 · shop · production"

ALERT = {
    "content": "@here",
    "embed": {
        "title": "[shop] [NEW] NoMethodError",
        "description": "```\nundefined method 'total_cents' for nil\n```",
        "color": 0xE74C3C,
        "fields": [
            ("Level", "error", True),
            ("Source", "application.action_dispatch", True),
            ("Request", "OrdersController#create", True),
            ("Route", "POST /orders", True),
            ("Request ID", "8c0e7f52-4b1a-4d3e-9f6a-2b7c1d9e0a14", True),
            ("User", "User#4410", True),
            ("Process", "web.1", True),
            ("Context", "```\ncart_id: 8812\ncoupon: BLACKFRIDAY\n```", False),
            ("Location", "app/services/checkout.rb:27:in 'Checkout#charge'", False),
            ("Code", "```\napp/services/checkout.rb:27\ntotal = order.cart.total_cents - discount\n```", False),
            ("Backtrace", "```\napp/services/checkout.rb:27:in 'Checkout#charge'\n"
                          "app/services/checkout.rb:12:in 'Checkout#call'\n"
                          "app/controllers/orders_controller.rb:18:in 'OrdersController#create'\n```", False),
            ("Release", "3f2a9c1", True),
        ],
        "footer": FOOTER,
    },
}

REPEAT = {
    "embed": {
        "title": "[shop] Payments::GatewayError - 8th time in 12 min · 5 people",
        "description": "```\ncapture failed: gateway returned 504\n```",
        "color": 0xE74C3C,
        "fields": [
            ("Level", "error", True),
            ("Source", "application.solid_queue", True),
            ("Job", "Payments::CaptureJob", True),
            ("Job ID", "5b3f0d2e-91c4-4a7b-b0e8-6d2c4f1a9e37", True),
            ("Process", "worker.1", True),
            ("Location", "app/services/payments/gateway.rb:44:in 'Payments::Gateway#capture'", False),
            ("Backtrace", "```\napp/services/payments/gateway.rb:44:in 'Payments::Gateway#capture'\n"
                          "app/jobs/payments/capture_job.rb:9:in 'Payments::CaptureJob#perform'\n```", False),
            ("Cause", "```\nNet::ReadTimeout: Net::ReadTimeout with #<TCPSocket:(closed)>\n"
                      "  app/services/payments/gateway.rb:41:in 'Payments::Gateway#post'\n```", False),
            ("Release", "3f2a9c1", True),
        ],
        "footer": FOOTER,
    },
}

SPIKE = {
    "content": "@here",
    "embed": {
        "title": "[shop] [SPIKE] Payments::GatewayError",
        "description": "More than 50 occurrences in 5 min.\n```\ncapture failed: gateway returned 504\n```",
        "color": 0x9B59B6,
        "fields": [
            ("Location", "app/services/payments/gateway.rb:44:in 'Payments::Gateway#capture'", False),
            ("Release", "3f2a9c1", True),
        ],
        "footer": FOOTER,
    },
}

DIGEST = {
    "embed": {
        "title": "[shop] Daily error report: 2026-11-06",
        "description": (
            "**104** errors in **4** groups.\n"
            "+22% vs the day before (2026-11-05: 85).\n"
            "\n"
            "**Top groups**\n"
            "**57** `NoMethodError` undefined method 'total\\_cents' for nil\n"
            "  app/services/checkout.rb:27:in 'Checkout#charge' · first seen 3 d ago, last seen 2 h ago\n"
            "**31** `Payments::GatewayError` capture failed: gateway returned <n>\n"
            "  app/services/payments/gateway.rb:44:in 'Payments::Gateway#capture' · first seen 45 h ago, "
            "last seen 9 h ago\n"
            "**12** `ActiveRecord::RecordNotFound` Couldn't find Order with 'id'=<n>\n"
            "  app/jobs/receipt\\_job.rb:6:in 'ReceiptJob#perform' · first seen 5 d ago, last seen 18 h ago\n"
            "**4** `KeyError` key not found: \"locale\"\n"
            "  app/mailers/order\\_mailer.rb:14:in 'OrderMailer#confirmation' · first seen 14 h ago, "
            "last seen 14 h ago"
        ),
        "color": 0x3498DB,
        "fields": [
            ("New", "**4** `KeyError` key not found: \"locale\"", False),
            ("Regressed", "**12** `ActiveRecord::RecordNotFound` Couldn't find Order with 'id'=<n> in release 3f2a9c1",
             False),
        ],
        "footer": FOOTER,
    },
}

MESSAGE = {
    "embed": {
        "title": "[shop] Refund waiting for the gateway for more than 2 h",
        "description": "The customer was told it would take minutes: check it in the gateway dashboard.",
        "color": 0xF39C12,
        "fields": [
            ("Order", "PED-48213", True),
            ("Customer", "m\u2022\u2022\u2022@gmail.com", True),
            ("CPF", "\u2022\u2022\u2022.456.789-\u2022\u2022", True),
            ("Amount", "R$ 189,90", True),
        ],
        "footer": FOOTER,
    },
}

# -- text measuring ------------------------------------------------------------------------

# Advance widths of a Helvetica-like font, in 1/1000 em. The system fonts differ by a few
# percent; every run but the last of a line is drawn with textLength, so the layout holds.
_WIDTHS = {
    " ": 278, "!": 278, '"': 355, "#": 556, "$": 556, "%": 889, "&": 667, "'": 191, "(": 333,
    ")": 333, "*": 389, "+": 584, ",": 278, "-": 333, ".": 278, "/": 278, ":": 278, ";": 278,
    "<": 584, "=": 584, ">": 584, "?": 556, "@": 1015, "[": 278, "\\": 278, "]": 278, "^": 469,
    "_": 556, "`": 333, "{": 334, "|": 260, "}": 334, "~": 584, "·": 278, "•": 350,
    "A": 667, "B": 667, "C": 722, "D": 722, "E": 667, "F": 611, "G": 778, "H": 722, "I": 278,
    "J": 500, "K": 667, "L": 556, "M": 833, "N": 722, "O": 778, "P": 667, "Q": 778, "R": 722,
    "S": 667, "T": 611, "U": 722, "V": 667, "W": 944, "X": 667, "Y": 667, "Z": 611,
    "a": 556, "b": 556, "c": 500, "d": 556, "e": 556, "f": 278, "g": 556, "h": 556, "i": 222,
    "j": 222, "k": 500, "l": 222, "m": 833, "n": 556, "o": 556, "p": 556, "q": 556, "r": 333,
    "s": 500, "t": 278, "u": 556, "v": 500, "w": 722, "x": 500, "y": 500, "z": 500,
}


def measure(text: str, size: float, style: str = "") -> float:
    if style == "code":  # inline code: a smaller monospace font and 3 px of padding each side
        return 0.6 * (size - 1.5) * len(text) + 6
    units = sum(_WIDTHS.get(ch, 556) for ch in text)
    return units * size / 1000 * (1.10 if style == "b" else 1.04)


# -- Discord's markdown, the part the gem uses ----------------------------------------------

def blocks(markdown: str):
    """Splits a value into ("code", lines) and ("text", line) blocks."""
    out = []
    for i, part in enumerate(re.split(r"```\n?(.*?)\n?```", markdown, flags=re.S)):
        if i % 2:
            out.append(("code", part.split("\n")))
        elif part:
            out.extend(("text", line) for line in part.strip("\n").split("\n"))
    return out


def runs(line: str):
    """**bold**, `code` and backslash escapes -> [(text, style)]."""
    out, buf, bold, i = [], "", False, 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and i + 1 < len(line) and line[i + 1] in "*_~`|\\":
            buf += line[i + 1]
            i += 2
        elif line.startswith("**", i):
            out.append((buf, "b" if bold else ""))
            buf, bold = "", not bold
            i += 2
        elif ch == "`":
            end = line.index("`", i + 1)
            out.append((buf, "b" if bold else ""))
            out.append((line[i + 1:end], "code"))
            buf = ""
            i = end + 1
        else:
            buf += ch
            i += 1
    out.append((buf, "b" if bold else ""))
    return [(t, s) for t, s in out if t]


# -- drawing -------------------------------------------------------------------------------

class Canvas:
    def __init__(self, theme: str):
        self.t = THEMES[theme]
        self.parts: list[str] = []
        self.y = 20

    def text(self, x, y, s, size=14, weight=400, color=None, family=FONT, length=None):
        fit = f' textLength="{length:.1f}" lengthAdjust="spacing"' if length else ""
        self.parts.append(f'<text x="{x:.1f}" y="{y:.1f}" font-family=\'{family}\' font-size="{size}" '
                          f'font-weight="{weight}" fill="{color or self.t["text"]}"{fit}>{escape(s)}</text>')

    def svg(self, title: str, desc: str) -> str:
        h = self.y + 6
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" viewBox="0 0 {W} {h}" '
                f'role="img" aria-labelledby="t d"><title id="t">{escape(title)}</title><desc id="d">'
                f'{escape(desc)}</desc><rect width="{W}" height="{h}" rx="10" fill="{self.t["bg"]}"/>'
                + "".join(self.parts) + "</svg>\n")


def layout(line: str, width: float, size=14):
    """Word-wraps one markdown line: a list of visual lines, each [(dx, text, style, w)]."""
    tokens = []  # (text, style), spaces kept as their own tokens
    for text, style in runs(line):
        for piece in re.split(r"( +)", text):
            # A word wider than the column breaks anywhere, as Discord does (a UUID).
            while piece and not piece.isspace() and measure(piece, size, style) > width:
                cut = len(piece)
                while cut > 1 and measure(piece[:cut], size, style) > width:
                    cut -= 1
                tokens.append((piece[:cut], style))
                piece = piece[cut:]
            if piece:
                tokens.append((piece, style))
    lines, current, x = [], [], 0.0
    for text, style in tokens:
        w = measure(text, size, style)
        if text.isspace():
            if current:  # leading spaces indent; spaces at a break vanish
                x += w
            elif not lines:
                x += w
            continue
        if x + w > width and current:
            lines.append(current)
            current, x = [], 0.0
        current.append([x, text, style, w])
        x += w
    if current:
        lines.append(current)
    merged = []  # same-style neighbours become one segment
    for visual in lines:
        segs = []
        for dx, text, style, w in visual:
            last = segs[-1] if segs else None
            if last and last[2] == style and style != "code":
                gap = dx - (last[0] + last[3])
                last[1] += " " * max(1, round(gap / measure(" ", size, style))) + text
                last[3] = dx + w - last[0]
            else:
                segs.append([dx, text, style, w])
        merged.append(segs)
    return merged


def draw_text_line(c: Canvas, x, y, line, width, size=14):
    """Draws one markdown line, wrapped; returns the height used."""
    t = c.t
    visual_lines = layout(line, width, size)
    for n, segs in enumerate(visual_lines):
        base = y + 15 + n * 20
        for i, (dx, text, style, w) in enumerate(segs):
            last = i == len(segs) - 1
            if style == "code":
                c.parts.append(f'<rect x="{x + dx:.1f}" y="{base - 13:.1f}" width="{w:.1f}" height="18" '
                               f'rx="3" fill="{t["code"]}"/>')
                c.text(x + dx + 3, base - 1, text, size=size - 1.5, color=t["code_text"], family=MONO, length=w - 6)
                continue
            weight, color = (700, t["strong"]) if style == "b" else (400, t["text"])
            c.text(x + dx, base, text, size=size, weight=weight, color=color, length=None if last else w)
    return 20 * len(visual_lines)


def draw_code_block(c: Canvas, x, y, lines, width):
    t = c.t
    size, step = 12.5, 18
    wrapped = []
    per_line = int((width - 16) / (0.6 * size))
    for line in lines:
        while len(line) > per_line:
            wrapped.append(line[:per_line])
            line = line[per_line:]
        wrapped.append(line)
    h = 14 + step * len(wrapped)
    c.parts.append(f'<rect x="{x}" y="{y + 4}" width="{width}" height="{h}" rx="4" fill="{t["code"]}" '
                   f'stroke="{t["line"]}"/>')
    for i, line in enumerate(wrapped):
        c.text(x + 8, y + 4 + 20 + i * step, line, size=size, color=t["code_text"], family=MONO)
    return h + 10


def draw_value(c: Canvas, x, y, markdown, width):
    used = 0
    for kind, content in blocks(markdown):
        if kind == "code":
            used += draw_code_block(c, x, y + used, content, width)
        elif content.strip():
            used += draw_text_line(c, x, y + used, content, width)
        else:
            used += 12
    return used


def rows_of(fields):
    """Discord's grid: up to three inline fields share a row; any other field has its own."""
    rows, current = [], []
    for field in fields:
        if field[2] and len(current) < 3:
            current.append(field)
            continue
        if current:
            rows.append(current)
            current = []
        if field[2]:
            current = [field]
        else:
            rows.append([field])
    if current:
        rows.append(current)
    return rows


def draw_embed(c: Canvas, e: dict, when: str):
    t = c.t
    x, w = 72, W - 72 - 24
    ix, iw = x + 16, w - 32
    top = c.y + 4
    mark = len(c.parts)  # the embed's background goes under what follows
    y = top + 10
    c.text(ix, y + 16, e["title"], size=16, weight=700, color=t["strong"])
    y += 26
    y += draw_value(c, ix, y, e["description"], iw)
    for row in rows_of(e["fields"]):
        y += 8
        gap = 8
        col = (iw - gap * (len(row) - 1)) / len(row)
        heights = []
        for k, (name, value, _inline) in enumerate(row):
            fx = ix + k * (col + gap)
            c.text(fx, y + 15, name, size=14, weight=700, color=t["strong"])
            heights.append(20 + draw_value(c, fx, y + 20, value, col))
        y += max(heights)
    y += 8
    c.text(ix, y + 14, f'{e["footer"]} • {when}', size=12, color=t["muted"])
    bottom = y + 26
    c.parts.insert(mark, f'<rect x="{x}" y="{top}" width="{w}" height="{bottom - top}" rx="4" fill="{t["embed"]}"/>'
                         f'<path d="M{x + 4} {top} a4 4 0 0 0 -4 4 v{bottom - top - 8} a4 4 0 0 0 4 4 z" '
                         f'fill="#{e["color"]:06x}"/>')
    c.y = bottom


def message(c: Canvas, when: str, payload: dict):
    """A webhook message: avatar, name, APP badge, time, the mention, then the embed."""
    t = c.t
    top = c.y
    cy = top + 20
    c.parts.append(f'<circle cx="36" cy="{cy}" r="20" fill="{AVATAR}"/>'  # a bolt: the signal
                   f'<path d="M38.5 {cy - 12} L27 {cy + 2} H35 L33 {cy + 12} L45 {cy - 3} H37 Z" fill="#fff" '
                   'stroke="#fff" stroke-width="1.2" stroke-linejoin="round"/>')
    c.text(72, top + 14, "Error Signal", size=15, weight=600, color=t["strong"])
    bx = 72 + measure("Error Signal", 15, "") + 8
    c.parts.append(f'<rect x="{bx:.1f}" y="{top + 2}" width="34" height="16" rx="4" fill="{t["badge"]}"/>')
    c.text(bx + 6, top + 14, "APP", size=10, weight=700, color="#ffffff")
    c.text(bx + 44, top + 14, when, size=12, color=t["muted"])
    c.y = top + 24
    if payload.get("content"):  # the mention, highlighted the way Discord shows it
        content = payload["content"]
        width = measure(content, 14, "") + 4
        c.parts.append(f'<rect x="70" y="{c.y + 1}" width="{width:.1f}" height="19" rx="3" fill="{t["mention"]}"/>')
        c.text(73, c.y + 15, content, weight=500, color=t["mention_text"])
        c.y += 24
    draw_embed(c, payload["embed"], when)
    c.y += 18


IMAGES = {
    "alert": (
        [("Today at 10:42", ALERT)],
        "An Error Signal alert on Discord",
        "The first occurrence of a new error, marked NEW and with an @here mention: the exception "
        "message, the level, the source, the controller action, the route, the request id, the logged-in user and the process, "
        "the context the app passed, the location with its line of code, the app lines of the backtrace "
        "and the release.",
    ),
    "repeat": (
        [("Today at 14:15", REPEAT), ("Today at 14:27", SPIKE)],
        "Repetition and spike messages from Error Signal on Discord",
        "An error in a job posted on its 8th occurrence in 12 minutes, reaching 5 people, with the "
        "job class and id, the process and the timeout that caused it; "
        "below it, the SPIKE message with an @here mention when the same error passes 50 "
        "occurrences in 5 minutes.",
    ),
    "message": (
        [("Today at 16:08", MESSAGE)],
        "A message sent by the app with ErrorSignal.message",
        "A warning the app posts by hand: the first line in the title, the rest below it, and four "
        "fields; the customer's e-mail and CPF arrive partly masked, the order number whole.",
    ),
    "digest": (
        [("Today at 09:00", DIGEST)],
        "The Error Signal daily report on Discord",
        "The daily report: the total of errors and groups, the comparison with the day before, the "
        "top groups with their location and when they were first and last seen, and the new and "
        "regressed groups of the day.",
    ),
}


def main():
    for name, (messages, title, desc) in IMAGES.items():
        for theme in ("light", "dark"):
            c = Canvas(theme)
            for when, payload in messages:
                message(c, when, payload)
            (OUT / f"{name}-{theme}.svg").write_text(c.svg(title, desc))
    print("written:", ", ".join(sorted(p.name for p in OUT.glob("*.svg"))))


if __name__ == "__main__":
    main()
