#!/usr/bin/env python3
"""Генерирует docs/cover.svg — обложку README в стиле иконки «Спектр».

Использование: python3 docs/make-cover.py   (пишет docs/cover.svg рядом со скриптом)
SVG не умеет конический градиент — дуга собирается из коротких отрезков, как в scripts/make-icon.swift.
"""
import math
import os

W, H = 1280, 640
STOPS = [(0, (0xFF, 0x5A, 0x3C)), (95, (0xFF, 0x2E, 0x7E)), (190, (0x9B, 0x5C, 0xFF)),
         (255, (0x3D, 0x8B, 0xFF)), (300, (0x2F, 0xD6, 0xFF))]
SWEEP = 300
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Helvetica, Arial, sans-serif"


def color(deg):
    for (d0, c0), (d1, c1) in zip(STOPS, STOPS[1:]):
        if deg <= d1:
            t = (deg - d0) / (d1 - d0)
            return "#%02x%02x%02x" % tuple(round(a + (b - a) * t) for a, b in zip(c0, c1))
    return "#%02x%02x%02x" % STOPS[-1][1]


def pt(cx, cy, r, deg):  # 0° — 12 часов, по часовой
    a = math.radians(deg - 90)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def arc(cx, cy, r, width, step=2.0):
    parts = []
    d = 0.0
    while d < SWEEP:
        x0, y0 = pt(cx, cy, r, d)
        x1, y1 = pt(cx, cy, r, min(SWEEP, d + step * 1.5))
        parts.append(f'<path d="M{x0:.2f} {y0:.2f} A{r} {r} 0 0 1 {x1:.2f} {y1:.2f}" stroke="{color(d + step / 2)}"/>')
        d += step
    caps = "".join(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{width / 2}" fill="{color(deg)}"/>'
                   for deg in (0, SWEEP) for x, y in [pt(cx, cy, r, deg)])
    return f'<g fill="none" stroke-width="{width}" stroke-linecap="butt">{"".join(parts)}</g>{caps}'


def icon(x, y, size):
    """Иконка приложения: тело 824/1024, скругление 185/1024, кольцо и точка — как в make-icon.swift."""
    k = size / 1024
    bx, by, bw = x + 100 * k, y + 100 * k, 824 * k
    cx, cy = x + 512 * k, y + 512 * k
    return f'''
  <g filter="url(#iconShadow)">
    <rect x="{bx:.1f}" y="{by:.1f}" width="{bw:.1f}" height="{bw:.1f}" rx="{185 * k:.1f}" fill="url(#iconBg)"/>
  </g>
  <rect x="{bx + 1:.1f}" y="{by + 1:.1f}" width="{bw - 2:.1f}" height="{bw - 2:.1f}" rx="{185 * k - 1:.1f}" fill="none" stroke="#fff" stroke-opacity=".1" stroke-width="2"/>
  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{236 * k:.1f}" fill="none" stroke="#fff" stroke-opacity=".07" stroke-width="{72 * k:.1f}"/>
  <g filter="url(#arcGlow)">{arc(cx, cy, round(236 * k, 2), round(72 * k, 2))}</g>
  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{168 * k:.1f}" fill="url(#dotGlow)"/>
  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{80 * k:.1f}" fill="url(#dot)"/>'''


def menubar_ring(cx, cy):
    """Кольцо из строки меню: встреча скоро — дуга заполняется."""
    r = 7.5
    x0, y0 = pt(cx, cy, r, 0)
    x1, y1 = pt(cx, cy, r, 250)
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="1.8"/>'
            f'<path d="M{x0:.2f} {y0:.2f} A{r} {r} 0 1 1 {x1:.2f} {y1:.2f}" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/>'
            f'<rect x="{cx - 2.6:.1f}" y="{cy - 3:.1f}" width="1.8" height="6" rx=".9" fill="#fff"/>'
            f'<rect x="{cx + 0.8:.1f}" y="{cy - 4.2:.1f}" width="1.8" height="8.4" rx=".9" fill="#fff"/>')


def chip(x, y, text, dot=None):
    w = 22 + len(text) * 9.6 + (16 if dot else 0)
    d = f'<circle cx="{x + 18}" cy="{y + 18}" r="5" fill="{dot}"/>' if dot else ""
    tx = x + (32 if dot else 16)
    return (f'<rect x="{x}" y="{y}" width="{w:.0f}" height="36" rx="18" fill="#fff" fill-opacity=".06" stroke="#fff" stroke-opacity=".12"/>'
            f'{d}<text x="{tx}" y="{y + 24}" font-size="17" fill="#c9cede">{text}</text>'), w


def main():
    chips, cx = [], 520
    for text, dot in [("Я / Они — две дорожки", "#ff5a3c"), ("whisper на Mac", "#9b5cff"), ("без подписки", "#2fd6ff")]:
        svg, w = chip(cx, 452, text, dot)
        chips.append(svg)
        cx += w + 12

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{FONT}">
  <defs>
    <radialGradient id="bg" cx="50%" cy="-10%" r="120%">
      <stop offset="0" stop-color="#262b38"/><stop offset=".55" stop-color="#12151c"/><stop offset="1" stop-color="#090b10"/>
    </radialGradient>
    <radialGradient id="iconBg" cx="50%" cy="0%" r="105%">
      <stop offset="0" stop-color="#2e3342"/><stop offset=".55" stop-color="#151820"/><stop offset="1" stop-color="#0b0d12"/>
    </radialGradient>
    <radialGradient id="dot" cx="38%" cy="32%" r="75%">
      <stop offset="0" stop-color="#ff8a73"/><stop offset=".55" stop-color="#ff3b30"/><stop offset="1" stop-color="#c81e14"/>
    </radialGradient>
    <radialGradient id="dotGlow"><stop offset=".45" stop-color="#ff3b30" stop-opacity=".45"/><stop offset="1" stop-color="#ff3b30" stop-opacity="0"/></radialGradient>
    <filter id="arcGlow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="0" stdDeviation="9" flood-color="#ff4f8c" flood-opacity=".45"/></filter>
    <filter id="iconShadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity=".55"/></filter>
    <filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="70"/></filter>
    <filter id="panelShadow" x="-20%" y="-40%" width="140%" height="200%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity=".45"/></filter>
    <linearGradient id="word" x1="0" x2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#dfe4f2"/></linearGradient>
  </defs>

  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <!-- цветное свечение за иконкой -->
  <circle cx="300" cy="360" r="190" fill="#ff2e7e" opacity=".22" filter="url(#blur)"/>
  <circle cx="380" cy="420" r="150" fill="#3d8bff" opacity=".2" filter="url(#blur)"/>

  <!-- строка меню macOS -->
  <rect width="{W}" height="34" fill="#fff" fill-opacity=".055"/>
  <line x1="0" y1="34" x2="{W}" y2="34" stroke="#fff" stroke-opacity=".07"/>
  <text x="24" y="23" font-size="14.5" fill="#fff" fill-opacity=".85" font-weight="600">Zoom</text>
  <text x="84" y="23" font-size="14.5" fill="#fff" fill-opacity=".6">Встреча</text>
  <text x="160" y="23" font-size="14.5" fill="#fff" fill-opacity=".6">Вид</text>
  {menubar_ring(986, 17)}
  <text x="1002" y="23" font-size="14.5" fill="#fff" fill-opacity=".9">Sync платформы · 3 мин</text>
  <text x="1212" y="23" font-size="14.5" fill="#fff" fill-opacity=".9">14:57</text>

  <!-- плашка «Подключиться» -->
  <g filter="url(#panelShadow)">
    <rect x="812" y="54" width="444" height="96" rx="16" fill="#2a2d36" fill-opacity=".92" stroke="#fff" stroke-opacity=".12"/>
  </g>
  <circle cx="852" cy="90" r="16" fill="none" stroke="#3d8bff" stroke-width="2.5"/>
  <path d="M845 84h9a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2zm11 5 5-3v12l-5-3z" fill="#3d8bff"/>
  <text x="880" y="84" font-size="16.5" font-weight="600" fill="#fff">Sync платформы</text>
  <text x="880" y="106" font-size="14" fill="#a8afc0">Через 1 мин · Meet</text>
  <text x="880" y="131" font-size="13" fill="#8b93a7">🎤 MacBook Pro · 🎧 AirPods Pro</text>
  <rect x="1104" y="72" width="134" height="36" rx="9" fill="#3d7bff"/>
  <text x="1171" y="96" font-size="15" font-weight="600" fill="#fff" text-anchor="middle">Подключиться</text>

  {icon(70, 140, 440)}

  <!-- название и смысл -->
  <text x="516" y="300" font-size="104" font-weight="800" letter-spacing="-3" fill="url(#word)">meetrec</text>
  <text x="520" y="358" font-size="27" fill="#c3c8d6">Записывает созвоны в Zoom и Meet,</text>
  <text x="520" y="394" font-size="27" fill="#c3c8d6">расшифровывает на Mac и делает заметки.</text>
  {"".join(chips)}

  <text x="520" y="560" font-size="15" fill="#6f778a">macOS 14.2+ · Apple Silicon · строка меню · календарь · заметки через твой AI-шлюз</text>
</svg>
'''
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cover.svg")
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)
    print(path)


if __name__ == "__main__":
    main()
