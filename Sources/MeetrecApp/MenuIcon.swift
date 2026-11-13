import AppKit
import SwiftUI

/// Состояние иконки в строке меню. Всё — в одном 18×18 кольце, без текста:
/// на MacBook с вырезом широкая метка пропадает целиком.
enum IconState: Hashable {
    case idle                 // приглушённое кольцо + полоски «Я / Они»
    case soon(step: Int)      // встреча ≤ 60 мин: дуга заполняется по часовой (0…steps)
    case now(step: Int)       // встреча идёт: сектор оставшегося времени тает (0…steps)
    case prompt(blink: Bool)  // «Записать?»: мигающая точка
    case recording(step: Int?, late: Bool) // красная точка; кольцо — остаток встречи (nil — без встречи),
                                           // late — ≤ 5 мин до конца или уже дольше: кольцо жёлтое
    case marked               // ★ — метка поставлена (на секунду)
    case processing           // три точки
    case done                 // ✓ — заметки готовы, окно ещё не открывали
    case failed               // ! — обработка упала

    static let steps = 24     // шаг дуги ≈ 2,5 мин на часе — перерисовка не чаще раза в минуту

    /// Цветная (не template): запись видно издалека, а жёлтое кольцо — «пора закругляться».
    var isColored: Bool { if case .recording = self { return true } else { return false } }
}

@MainActor
enum MenuIcon {
    private static var cache: [IconState: NSImage] = [:]

    /// Template-картинка: macOS сама красит её под светлую/тёмную строку меню (кроме записи — она красная).
    static func image(_ state: IconState) -> NSImage {
        if let cached = cache[state] { return cached }
        let renderer = ImageRenderer(content: IconGlyph(state: state).frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = !state.isColored // запись — цветная, остальное красит macOS
        cache[state] = image
        return image
    }
}

private struct IconGlyph: View {
    let state: IconState

    var body: some View {
        Canvas { ctx, size in
            let lw: CGFloat = 1.6
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lw / 2 + 0.6, dy: lw / 2 + 0.6)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2
            let red = Color(red: 1, green: 0.23, blue: 0.19)
            var ink = state.isColored ? red : Color.black

            func ring(_ opacity: Double) {
                ctx.stroke(Path(ellipseIn: rect), with: .color(ink.opacity(opacity)), lineWidth: lw)
            }
            func arc(_ fraction: Double) {
                guard fraction > 0 else { return }
                var p = Path()
                p.addArc(center: c, radius: r, startAngle: .degrees(-90),
                         endAngle: .degrees(-90 + 360 * min(1, fraction)), clockwise: false)
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            func pie(_ fraction: Double) {
                guard fraction > 0 else { return }
                var p = Path()
                p.move(to: c)
                p.addArc(center: c, radius: r - lw - 0.4, startAngle: .degrees(-90),
                         endAngle: .degrees(-90 + 360 * min(1, fraction)), clockwise: false)
                p.closeSubpath()
                ctx.fill(p, with: .color(ink))
            }
            func dot(_ radius: CGFloat, _ opacity: Double = 1) {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(ink.opacity(opacity)))
            }
            func bars() { // «Я» и «Они» — две полоски уровня
                let w: CGFloat = 1.8
                for (dx, h) in [(-1.7, r * 0.75), (1.7, r * 1.1)] {
                    let b = CGRect(x: c.x + dx - w / 2, y: c.y - h / 2, width: w, height: h)
                    ctx.fill(Path(roundedRect: b, cornerRadius: w / 2), with: .color(ink))
                }
            }

            switch state {
            case .idle:
                ring(0.45); bars()
            case .soon(let step):
                ring(0.3); arc(Double(step) / Double(IconState.steps)); bars()
            case .now(let step):
                ring(1); pie(Double(step) / Double(IconState.steps))
            case .prompt(let blink):
                ring(1); dot(r * 0.45, blink ? 1 : 0.3)
            case .recording(let step, let late):
                if late { ink = Color(red: 1, green: 0.72, blue: 0) }
                if let step { ring(0.35); arc(Double(step) / Double(IconState.steps)) } else { ring(1) }
                ink = red
                dot(r * 0.5)
            case .marked:
                var p = Path() // пятиконечная звезда
                for i in 0..<10 {
                    let a = Double(i) * .pi / 5 - .pi / 2
                    let rr = i % 2 == 0 ? r : r * 0.45
                    let pt = CGPoint(x: c.x + rr * CGFloat(cos(a)), y: c.y + rr * CGFloat(sin(a)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
                ctx.fill(p, with: .color(ink))
            case .processing:
                ring(0.45)
                for dx in [-2.6, 0, 2.6] as [CGFloat] {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x + dx - 0.9, y: c.y - 0.9, width: 1.8, height: 1.8)), with: .color(ink))
                }
            case .done:
                ring(1)
                var p = Path()
                p.move(to: CGPoint(x: c.x - r * 0.42, y: c.y + r * 0.02))
                p.addLine(to: CGPoint(x: c.x - r * 0.1, y: c.y + r * 0.35))
                p.addLine(to: CGPoint(x: c.x + r * 0.45, y: c.y - r * 0.32))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            case .failed:
                ring(1)
                let w: CGFloat = 1.8
                ctx.fill(Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - r * 0.5, width: w, height: r * 0.62),
                              cornerRadius: w / 2), with: .color(ink))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1, y: c.y + r * 0.3, width: 2, height: 2)), with: .color(ink))
            }
        }
    }
}
