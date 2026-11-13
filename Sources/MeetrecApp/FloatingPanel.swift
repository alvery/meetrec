import AppKit
import SwiftUI

/// Что показывает плашка.
enum PanelKind: Equatable {
    case join(MeetingEvent)   // встреча через минуту — «Подключиться»
    case prompt(MeetingEvent) // встреча идёт, микрофон занят — «Записать?»

    var id: String {
        switch self {
        case .join(let e): return "join-\(e.id)"
        case .prompt(let e): return "prompt-\(e.id)"
        }
    }
}

/// Плашка в правом верхнем углу экрана вместо системного уведомления: кнопки в один клик
/// (у уведомлений macOS с двумя действиями они прячутся в меню «Параметры»), не глушится
/// «Не беспокоить», видна поверх полноэкранного Zoom и не попадает в демонстрацию экрана.
@MainActor
final class FloatingPanel {
    static let shared = FloatingPanel()
    private var panel: NSPanel?
    private var shownID: String?

    func show(_ kind: PanelKind) {
        guard shownID != kind.id else { return } // уже показана — не пересоздаём каждые 5 с
        shownID = kind.id
        let hosting = ClickThroughHostingView(rootView: PanelView(kind: kind).environmentObject(AppState.shared))
        let size = hosting.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = hosting
        p.setContentSize(size)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
    }

    func hide() {
        shownID = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.sharingType = .none // не попадать в демонстрацию экрана / скриншоты
        return p
    }
}

/// Кнопки должны срабатывать с первого клика, хотя панель не становится активным окном.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PanelView: View {
    @EnvironmentObject var state: AppState
    let kind: PanelKind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.headline).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            switch kind {
            case .prompt(let e):
                Button { state.startRecording(for: e) } label: {
                    Label("Записать", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { state.dismissPrompt() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).controlSize(.large)
                    .help("Не записывать").accessibilityLabel("Не записывать")
            case .join(let e):
                Button { state.join(e) } label: {
                    Label("Подключиться", systemImage: "video")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { state.dismissJoin() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).controlSize(.large)
                    .help("Скрыть").accessibilityLabel("Скрыть")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }

    private var event: MeetingEvent {
        switch kind { case .join(let e), .prompt(let e): return e }
    }

    private var icon: String {
        if case .prompt = kind { return "record.circle" } else { return "video.circle" }
    }

    private var iconColor: Color {
        if case .prompt = kind { return .red } else { return .accentColor }
    }

    private var subtitle: String {
        switch kind {
        case .prompt: return "Встреча идёт, микрофон занят — записать?"
        case .join(let e): return "Через \(Format.minutes(e.start.timeIntervalSinceNow)) · \(Format.details(e))"
        }
    }
}
