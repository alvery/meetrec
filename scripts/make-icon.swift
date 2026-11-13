// Рисует иконку приложения (кольцо-отсчёт + точка записи) в AppIcon.iconset — для build-app.sh.
// Использование: swift scripts/make-icon.swift <папка.iconset>
// Сетка — как у иконок macOS: холст 1024, тело 824×824 со скруглением 185.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255,
                                         CGFloat(hex & 0xff) / 255, a])!
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024) // дальше всё в координатах 1024 (y вверх)
    let small = px <= 32 // в 16/32 px: без тени, кольцо и точка крупнее — иначе мылится
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    let center = CGPoint(x: 512, y: 512)

    if !small { // тень под телом
        ctx.saveGState()
        // Тень CG не масштабирует вместе с CTM — задаём в пикселях.
        let k = CGFloat(px) / 1024
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 32 * k, color: rgb(0x000000, 0.28))
        ctx.addPath(body); ctx.setFillColor(rgb(0x11141c)); ctx.fillPath()
        ctx.restoreGState()
    }
    // Тело: графитовый градиент сверху вниз.
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2a3142), rgb(0x11141c)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    if !small { // тонкий светлый край
        ctx.addPath(body); ctx.setStrokeColor(rgb(0xffffff, 0.08)); ctx.setLineWidth(2); ctx.strokePath()
    }

    // Кольцо: дорожка + дуга 75% по часовой от 12 часов (как отсчёт в строке меню).
    let r: CGFloat = small ? 250 : 238
    let lw: CGFloat = small ? 100 : 70
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(rgb(0xffffff, 0.14))
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.strokePath()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xf4f6fa))
    ctx.addArc(center: center, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 1.5 * .pi, clockwise: true)
    ctx.strokePath()

    // Красная точка записи с мягким свечением.
    let dotR: CGFloat = small ? 118 : 96
    if !small {
        let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xff453a, 0.45), rgb(0xff453a, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 150, options: [])
    }
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - dotR, y: center.y - dotR, width: 2 * dotR, height: 2 * dotR))
    ctx.clip()
    let dot = CGGradient(colorsSpace: cs, colors: [rgb(0xff6b5e), rgb(0xd9261c)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(dot, startCenter: CGPoint(x: center.x - dotR * 0.2, y: center.y + dotR * 0.3), startRadius: 0,
                           endCenter: center, endRadius: dotR * 1.2, options: [.drawsAfterEndLocation])
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
