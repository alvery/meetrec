import SwiftUI

@main
struct MeetrecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Иконка в строке меню: идёт запись — таймер; скоро встреча — минуты до неё.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.isRecording {
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                Text(Format.timer(state.elapsed)).monospacedDigit()
            }
        } else if state.promptEvent != nil {
            Image(systemName: "bell.badge")
        } else if let e = state.event, e.start > Date(), e.start.timeIntervalSinceNow < 3600 {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                Text("\(Int(e.start.timeIntervalSinceNow / 60))м")
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EventSection()
            Divider()
            RecordSection()
            Divider()
            RecentSection()
            Divider()
            FooterSection()
        }
        .padding(12)
        .frame(width: 320)
    }
}

// MARK: - Встреча из календаря

struct EventSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if !state.calendarAuthorized {
            HStack {
                Label("Нет доступа к календарю", systemImage: "calendar.badge.exclamationmark")
                Spacer()
                Button("Разрешить") { state.openCalendarPrivacy() }
            }
        } else if let e = state.event {
            VStack(alignment: .leading, spacing: 4) {
                Label(e.title, systemImage: "calendar").font(.headline).lineLimit(2)
                HStack {
                    Text(Format.when(e)).foregroundStyle(.secondary)
                    Spacer()
                    if e.joinURL != nil {
                        Button("Подключиться") { state.join(e) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        } else {
            Label("Встреч в ближайшие сутки нет", systemImage: "calendar").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Запись

struct RecordSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = state.promptEvent, !state.isRecording {
                HStack {
                    Image(systemName: "bell.badge")
                    Text("Начался «\(e.title)»").lineLimit(1)
                    Spacer()
                    Button("Записать") { state.startRecording(for: e) }
                }
            }
            if state.isRecording {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text(Format.timer(state.elapsed)).monospacedDigit()
                    if let t = state.recordingTitle { Text(t).lineLimit(1).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Стоп") { state.stopRecording() }
                }
                LevelRow(label: "я", level: state.levelMe)
                LevelRow(label: "они", level: state.levelThem)
            } else {
                Button {
                    state.startRecording(for: nil)
                } label: {
                    Label(state.isStarting ? "Запускаю…" : "Записать", systemImage: "record.circle")
                }
                .disabled(state.isStarting)
            }
            if let w = state.warningText { Text(w).font(.caption).foregroundStyle(.orange) }
            if let err = state.errorText { Text(err).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct LevelRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 28, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Float(i) < level * 12 ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 10, height: 6)
                }
            }
        }
    }
}

// MARK: - Недавние встречи

struct RecentSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Недавние").font(.caption).foregroundStyle(.secondary)
            if state.meetings.isEmpty {
                Text("Пока нет записей").foregroundStyle(.secondary)
            }
            ForEach(state.meetings) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).lineLimit(1)
                        Text(Format.day(m.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.processing.contains(m.url) {
                        ProgressView().controlSize(.small).help("Обрабатывается")
                    } else if m.hasNotes {
                        Button { state.open(m.notes) } label: { Image(systemName: "doc.text") }
                            .buttonStyle(.borderless).help("Открыть заметки")
                    } else {
                        Button { state.process(m.url, title: m.title) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Обработать")
                    }
                    Button { state.open(m.url) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Открыть папку")
                }
            }
        }
        .onAppear { state.refreshMeetings() }
    }
}

// MARK: - Низ окна

struct FooterSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            Menu {
                Toggle("Запускать при входе", isOn: Binding(get: { state.launchAtLogin },
                                                            set: { state.launchAtLogin = $0 }))
                Button("Открыть ~/Meetings") { state.open(state.meetingsRoot) }
                Button("Открыть файл настроек") { state.openConfig() }
            } label: {
                Label("Настройки", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Выйти") { state.quit() }
        }
    }
}

// MARK: - Форматирование

enum Format {
    static func timer(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func when(_ e: MeetingEvent, now: Date = Date()) -> String {
        if e.isInProgress(at: now) { return "идёт, ещё \(minutes(e.end.timeIntervalSince(now)))" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "в \(f.string(from: e.start)), через \(minutes(e.start.timeIntervalSince(now)))"
    }

    static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int(t / 60))
        return m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин"
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}
