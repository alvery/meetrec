import AppKit
import RecorderKit
import SwiftUI

/// Что показывает плашка.
enum PanelKind: Equatable {
    case join(MeetingEvent)   // встреча через минуту — «Подключиться»
    case prompt(MeetingEvent) // встреча идёт, микрофон занят — «Записать?»
    case stop(StopSuggestion) // идёт запись, а созвон закончился / началась следующая встреча

    var id: String {
        switch self {
        case .join(let e): return "join-\(e.id)"
        case .prompt(let e): return "prompt-\(e.id)"
        case .stop(let s): return "stop-\(s.key)"
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
        // Экран, где сейчас курсор (там, скорее всего, и Zoom), иначе главный.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
    }

    func hide() {
        shownID = nil
        panel?.orderOut(nil)
        panel?.contentView = nil // скрытая плашка не должна перерисовываться на каждое обновление AppState
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

/// «🎤 MacBook Pro · 🎧 AirPods» + предупреждение, если с микрофоном что-то не так.
struct RouteLine: View {
    let route: AudioRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("🎤 \(route.input) · 🎧 \(route.output)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if route.inputMuted {
                Label("Микрофон выключен — тебя не услышат", systemImage: "mic.slash.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if route.inputBluetooth {
                Label("Bluetooth-микрофон: звук в наушниках станет хуже (режим гарнитуры)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var state: AppState
    let kind: PanelKind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if case .join(let e) = kind {
                    if let route = state.joinRoute { RouteLine(route: route) }
                    if let b = state.joinBriefing, b.eventID == e.id { BriefingView(briefing: b).padding(.top, 2) }
                }
            }
            Spacer(minLength: 8)
            switch kind {
            case .stop(let s):
                if let next = s.next, next.joinURL != nil {
                    Button { state.stopRecording(reason: "плашка: \(s.key)"); state.join(next) } label: {
                        Label("Стоп и подключиться", systemImage: "video")
                    }
                    .controlSize(.large)
                }
                Button { state.stopRecording(reason: "плашка: \(s.key)") } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { state.dismissStop() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).controlSize(.large)
                    .help("Продолжить запись").accessibilityLabel("Продолжить запись")
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
        .frame(width: wide ? 520 : 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
    }

    /// Три кнопки («Стоп и подключиться», «Остановить», ✕) в 400 pt не влезают.
    private var wide: Bool {
        if case .stop(let s) = kind, s.next?.joinURL != nil { return true } else { return false }
    }

    private var headline: String {
        switch kind {
        case .join(let e), .prompt(let e): return e.title
        case .stop: return "Остановить запись?"
        }
    }

    private var icon: String {
        switch kind {
        case .prompt: return "record.circle"
        case .join: return "video.circle"
        case .stop: return "stop.circle"
        }
    }

    private var iconColor: Color {
        if case .join = kind { return .accentColor } else { return .red }
    }

    private var subtitle: String {
        switch kind {
        case .stop(let s): return s.text
        case .prompt: return "Встреча идёт, микрофон занят — записать?"
        case .join(let e):
            let t = e.start.timeIntervalSinceNow
            return (t > 0 ? "Через \(Format.minutes(t))" : "Уже идёт") + " · \(Format.details(e))"
        }
    }
}
