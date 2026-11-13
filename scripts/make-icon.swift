// Рисует иконку приложения «Спектр» (переливающееся кольцо-отсчёт + точка записи) в AppIcon.iconset.
// Использование: swift scripts/make-icon.swift <папка.iconset>   (вызывает build-app.sh)
// Сетка — как у иконок macOS: холст 1024, тело 824×824 со скруглением 185. Координаты CG: y вверх.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

struct RGB { var r, g, b: CGFloat }
func hex(_ v: UInt32) -> RGB { RGB(r: CGFloat(v >> 16 & 0xff) / 255, g: CGFloat(v >> 8 & 0xff) / 255, b: CGFloat(v & 0xff) / 255) }
func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [c.r, c.g, c.b, a])! }

// Цвета дуги по градусам от 12 часов по часовой: коралл → малиновый → фиолетовый → синий → голубой.
let stops: [(CGFloat, RGB)] = [(0, hex(0xff5a3c)), (95, hex(0xff2e7e)), (190, hex(0x9b5cff)), (255, hex(0x3d8bff)), (300, hex(0x2fd6ff))]
let sweep: CGFloat = 300

func arcColor(_ deg: CGFloat) -> RGB {
    for i in 1..<stops.count where deg <= stops[i].0 {
        let (d0, c0) = stops[i - 1], (d1, c1) = stops[i]
        let t = (deg - d0) / (d1 - d0)
        return RGB(r: c0.r + (c1.r - c0.r) * t, g: c0.g + (c1.g - c0.g) * t, b: c0.b + (c1.b - c0.b) * t)
    }
    return stops.last!.1
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024 // тени CG задаются в пикселях, не в координатах CTM
    ctx.scaleBy(x: k, y: k)
    let small = px <= 32 // 16/32 px: без свечения и тени, дуга и точка толще — иначе мыло
    let center = CGPoint(x: 512, y: 512)
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)

    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -20 * k), blur: 48 * k, color: color(hex(0), 0.3))
        ctx.addPath(body); ctx.setFillColor(color(hex(0x0b0d12))); ctx.fillPath()
        ctx.restoreGState()
    }
    // Основа: графит со светом сверху.
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(hex(0x2e3342)), color(hex(0x151820)), color(hex(0x0b0d12))] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 924), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 924), endRadius: 880, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    if !small {
        ctx.addPath(body); ctx.setStrokeColor(color(hex(0xffffff), 0.1)); ctx.setLineWidth(3); ctx.strokePath()
    }

    // Кольцо: тусклая дорожка + дуга 300° по часовой от 12 часов с переходом цвета.
    let lw: CGFloat = small ? 100 : 72
    let r: CGFloat = small ? 250 : 236
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(color(hex(0xffffff), small ? 0.1 : 0.07))
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.strokePath()

    func point(_ deg: CGFloat) -> CGPoint {
        let a = (90 - deg) * .pi / 180 // 0° — 12 часов, растёт по часовой
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
    if !small { ctx.setShadow(offset: .zero, blur: 28 * k, color: color(hex(0xff4f8c), 0.38)) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil) // свечение — один раз на всю дугу, а не на каждый отрезок
    ctx.setLineCap(.butt)
    let step: CGFloat = 0.5
    var d: CGFloat = 0
    while d < sweep {
        let a0 = (90 - d) * .pi / 180, a1 = (90 - min(sweep, d + step * 1.6)) * .pi / 180
        ctx.addArc(center: center, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.setStrokeColor(color(arcColor(d + step / 2)))
        ctx.strokePath()
        d += step
    }
    for deg in [0, sweep] { // скруглённые концы
        let p = point(deg)
        ctx.setFillColor(color(arcColor(deg)))
        ctx.fillEllipse(in: CGRect(x: p.x - lw / 2, y: p.y - lw / 2, width: lw, height: lw))
    }
    ctx.endTransparencyLayer()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Точка записи: свечение + объёмный красный.
    let dotR: CGFloat = small ? 100 : 80
    if !small {
        let glow = CGGradient(colorsSpace: cs, colors: [color(hex(0xff3b30), 0.5), color(hex(0xff3b30), 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: dotR * 0.6, endCenter: center, endRadius: dotR * 2.1, options: [])
    }
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - dotR, y: center.y - dotR, width: 2 * dotR, height: 2 * dotR))
    ctx.clip()
    let dot = CGGradient(colorsSpace: cs, colors: [color(hex(0xff8a73)), color(hex(0xff3b30)), color(hex(0xc81e14))] as CFArray,
                         locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(dot, startCenter: CGPoint(x: center.x - dotR * 0.24, y: center.y + dotR * 0.36), startRadius: 0,
                           endCenter: center, endRadius: dotR * 1.15, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).write(to: out.appendingPathComponent(name))
    }
}
