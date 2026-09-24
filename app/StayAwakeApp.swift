import SwiftUI
import UserNotifications

// The privileged half of this lives in /usr/local/sbin/stayawaked. This app
// never touches pmset: it reads the helper's state file and writes small files
// the helper picks up on its next check, which is why it needs no password.

enum Paths {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stayawake")
    static let state = dir.appendingPathComponent("state")
    static let config = dir.appendingPathComponent("config")
    static let lease = dir.appendingPathComponent("lease")
    static let veto = dir.appendingPathComponent("veto")
    static let disabled = dir.appendingPathComponent("disabled")
    static let heartbeat = dir.appendingPathComponent("app-alive")
    static let schedule = dir.appendingPathComponent("schedule")
}

struct Status {
    var updated: Double = 0
    var sleepDisabled = false
    var holders = 0
    var holderNames = ""
    var manual = false
    var veto = false
    var latched = ""
    var holdSince: Double = 0
    var idleSince: Double = 0
    var batteryPct = 0
    var batteryState = "ac"
    var idleWindow = 3600
    var remindEvery = 21600
    var batteryFloor = 15
    var nextWake = ""
    var off = false

    var daemonAlive: Bool { updated > 0 && Date().timeIntervalSince1970 - updated < 30 }
    var onBattery: Bool { batteryState == "discharging" }
}

enum Mode: String, CaseIterable {
    case automatic = "Automatic"
    case keepAwake = "Keep awake"
    case letSleep = "Let it sleep"
}

/// One line of the schedule file: a time, and the days it applies to.
struct WakeEntry: Identifiable, Equatable {
    let id = UUID()
    var hour: Int
    var minute: Int
    var days: Set<Int>          // 1 = Monday ... 7 = Sunday

    static let letters = ["M", "T", "W", "R", "F", "S", "U"]
    static let labels = ["M", "T", "W", "T", "F", "S", "S"]

    var fileLine: String {
        let d = (1...7).filter { days.contains($0) }.map { WakeEntry.letters[$0 - 1] }.joined()
        return String(format: "%02d:%02d %@", hour, minute, d)
    }

    var date: Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }

    static func parse(_ line: String) -> WakeEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let hm = parts[0].split(separator: ":")
        guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
        var days = Set<Int>()
        for ch in parts[1] {
            if let i = letters.firstIndex(of: String(ch)) { days.insert(i + 1) }
        }
        guard !days.isEmpty else { return nil }
        return WakeEntry(hour: h, minute: m, days: days)
    }
}

func readKeyValues(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces)
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { out[key] = val }
    }
    return out
}

func shortDuration(_ seconds: Int) -> String {
    if seconds >= 3600 {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    return "\(seconds / 60)m"
}

func clockString(_ epoch: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

@MainActor
final class Model: ObservableObject {
    @Published var s = Status()
    @Published var idleWindowMinutes: Double = 60
    @Published var remindEveryHours: Double = 6      // 0 means never
    @Published var batteryFloor: Double = 15
    @Published var notifyOn = true
    @Published var enabled = true
    @Published var holdUntil = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
    @Published var entries: [WakeEntry] = []
    @Published var leaseExpiry: Double = 0

    private var timer: Timer?
    private var lastDisabled: Bool?
    private var notificationsAllowed = false

    init() {
        loadConfig()
        loadSchedule()
        enabled = !FileManager.default.fileExists(atPath: Paths.disabled.path)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { ok, _ in
            Task { @MainActor in self.notificationsAllowed = ok }
        }
    }

    // MARK: reading

    func tick() {
        let kv = readKeyValues(Paths.state)
        var new = Status()
        new.updated = Double(kv["updated"] ?? "") ?? 0
        new.sleepDisabled = kv["sleep_disabled"] == "1"
        new.holders = Int(kv["holders"] ?? "") ?? 0
        new.holderNames = kv["holder_names"] ?? ""
        new.manual = kv["manual"] == "1"
        new.veto = kv["veto"] == "1"
        new.latched = kv["latched"] ?? ""
        new.holdSince = Double(kv["hold_since"] ?? "") ?? 0
        new.idleSince = Double(kv["idle_since"] ?? "") ?? 0
        new.batteryPct = Int(kv["battery_pct"] ?? "") ?? 0
        new.batteryState = kv["battery_state"] ?? "ac"
        new.idleWindow = Int(kv["idle_window"] ?? "") ?? 3600
        new.remindEvery = Int(kv["remind_every"] ?? "") ?? 0
        new.batteryFloor = Int(kv["battery_floor"] ?? "") ?? 15
        new.nextWake = kv["next_wake"] ?? ""
        new.off = kv["off"] == "1"
        s = new

        leaseExpiry = Double((try? String(contentsOf: Paths.lease, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0

        // Tells the helper an app is running, so it does not also post its own
        // notifications from osascript.
        try? String(Int(Date().timeIntervalSince1970)).write(to: Paths.heartbeat, atomically: true, encoding: .utf8)

        if let was = lastDisabled, was != new.sleepDisabled {
            announce(nowHolding: new.sleepDisabled)
        }
        lastDisabled = new.sleepDisabled
    }

    private func announce(nowHolding: Bool) {
        guard notifyOn, notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        if nowHolding {
            content.title = "Staying awake"
            content.body = s.holders > 0
                ? "\(s.holders) thing\(s.holders == 1 ? "" : "s") working. You can close the lid."
                : "You set the Mac to stay awake."
        } else {
            content.title = "Sleeping normally again"
            switch s.latched {
            case "battery": content.body = "The battery got low, so the Mac can sleep."
            default: content.body = s.off ? "Stay Awake is switched off." : "Nothing has happened for a while, so the Mac can sleep."
            }
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: settings

    func loadConfig() {
        let kv = readKeyValues(Paths.config)
        if let v = Int(kv["IDLE_WINDOW"] ?? kv["GRACE"] ?? "") { idleWindowMinutes = max(15, Double(v) / 60) }
        if let v = Int(kv["REMIND_EVERY"] ?? "") { remindEveryHours = Double(v) / 3600 }
        if let v = Int(kv["BATTERY_FLOOR"] ?? "") { batteryFloor = Double(v) }
        notifyOn = (kv["NOTIFY"] ?? "all") != "none"
    }

    func saveConfig() {
        let kv = readKeyValues(Paths.config)
        let text = """
        # Settings for stayawake. The app writes this file; the helper re-reads it
        # every few seconds, so changes take effect without a restart.
        # Wake times live in the `schedule` file next to this one.

        POLL=\(kv["POLL"] ?? "5")
        IDLE_WINDOW=\(Int(idleWindowMinutes * 60))
        REMIND_EVERY=\(Int(remindEveryHours * 3600))
        BATTERY_FLOOR=\(Int(batteryFloor))
        NOTIFY=\(notifyOn ? "all" : "none")
        MATCH=\(kv["MATCH"] ?? "caffeinate")

        """
        try? text.write(to: Paths.config, atomically: true, encoding: .utf8)
    }

    // MARK: schedule

    func loadSchedule() {
        let text = (try? String(contentsOf: Paths.schedule, encoding: .utf8)) ?? ""
        entries = text.split(separator: "\n").compactMap {
            let line = $0.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : WakeEntry.parse(line)
        }
    }

    func saveSchedule() {
        let body = entries.filter { !$0.days.isEmpty }.map(\.fileLine).joined(separator: "\n")
        let text = """
        # Times to wake this Mac, one per line: a time and the days it applies to.
        # Days are M T W R F S U, where R is Thursday and U is Sunday.
        \(body)

        """
        try? text.write(to: Paths.schedule, atomically: true, encoding: .utf8)
    }

    func addEntry() {
        entries.append(WakeEntry(hour: 8, minute: 0, days: [1, 2, 3, 4, 5]))
        saveSchedule()
    }

    func removeEntry(_ entry: WakeEntry) {
        entries.removeAll { $0.id == entry.id }
        saveSchedule()
    }

    // MARK: mode

    var mode: Mode {
        if s.veto { return .letSleep }
        if s.manual { return .keepAwake }
        return .automatic
    }

    func setMode(_ m: Mode) {
        switch m {
        case .automatic: backToAutomatic()
        case .keepAwake: keepAwake(hours: nil)
        case .letSleep: letSleep(hours: 1)
        }
    }

    private func write(_ url: URL, expiry: Double) {
        try? String(Int(expiry)).write(to: url, atomically: true, encoding: .utf8)
    }

    func keepAwake(hours: Double?) {
        try? FileManager.default.removeItem(at: Paths.veto)
        write(Paths.lease, expiry: hours.map { Date().timeIntervalSince1970 + $0 * 3600 } ?? 0)
    }

    /// Holds until the next time it is that hour and minute, today or tomorrow.
    func keepAwakeUntil(_ time: Date) {
        let c = Calendar.current
        let parts = c.dateComponents([.hour, .minute], from: time)
        var target = c.date(bySettingHour: parts.hour ?? 8, minute: parts.minute ?? 0, second: 0, of: Date()) ?? Date()
        if target <= Date() { target = c.date(byAdding: .day, value: 1, to: target) ?? target }
        try? FileManager.default.removeItem(at: Paths.veto)
        write(Paths.lease, expiry: target.timeIntervalSince1970)
    }

    func letSleep(hours: Double) {
        try? FileManager.default.removeItem(at: Paths.lease)
        write(Paths.veto, expiry: Date().timeIntervalSince1970 + hours * 3600)
    }

    func backToAutomatic() {
        try? FileManager.default.removeItem(at: Paths.lease)
        try? FileManager.default.removeItem(at: Paths.veto)
    }

    func setEnabled(_ on: Bool) {
        if on {
            try? FileManager.default.removeItem(at: Paths.disabled)
        } else {
            backToAutomatic()
            try? "1".write(to: Paths.disabled, atomically: true, encoding: .utf8)
        }
    }

    // MARK: wording

    var headline: String {
        if !s.daemonAlive { return "Not working" }
        if s.off { return "Switched off" }
        return s.sleepDisabled ? "Staying awake" : "Sleeping normally"
    }

    var detail: String {
        if !s.daemonAlive { return "The background service is not running, so nothing is being kept awake." }
        if s.off { return "The Mac sleeps as it normally would, including when you close the lid." }
        var lines: [String] = []
        if s.holders > 0 {
            let names = s.holderNames.isEmpty ? "" : " (\(s.holderNames.split(separator: " ").joined(separator: ", ")))"
            lines.append("\(s.holders) thing\(s.holders == 1 ? "" : "s") working now\(names)")
        } else if s.manual {
            lines.append(leaseExpiry > 0
                ? "You set it to stay awake until \(clockString(leaseExpiry))"
                : "You set it to stay awake until you switch it back")
        } else {
            lines.append("Nothing is working right now")
        }
        if s.sleepDisabled && s.holdSince > 0 {
            let mins = Int((Date().timeIntervalSince1970 - s.holdSince) / 60)
            lines.append("Awake \(mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"). Nothing will interrupt it.")
        }
        if s.idleSince > 0 {
            let left = Int((Double(s.idleWindow) - (Date().timeIntervalSince1970 - s.idleSince)) / 60)
            lines.append("Quiet so far. It sleeps in about \(max(0, left))m unless something starts.")
        }
        if s.veto { lines.append("You allowed it to sleep, even while work is running") }
        if s.latched == "battery" { lines.append("Stopped: the battery is below \(s.batteryFloor)%") }
        lines.append("Battery \(s.batteryPct)%, \(s.onBattery ? "on battery" : "on power")")
        return lines.joined(separator: "\n")
    }

    var iconName: String {
        if s.off || !s.daemonAlive { return "moon.zzz" }
        return s.sleepDisabled ? "eye.fill" : "moon"
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct NowTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.headline).font(.title3).fontWeight(.semibold)
                Text(model.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.enabled {
                Picker("", selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Caption("Automatic stays awake while something is working. The other two are yours to set and stay until you change them back.")

                HStack(spacing: 6) {
                    Text("Keep awake until").font(.callout)
                    DatePicker("", selection: $model.holdUntil, displayedComponents: .hourAndMinute)
                        .labelsHidden().frame(width: 76)
                    Button("Set") { model.keepAwakeUntil(model.holdUntil) }
                }
                Caption("Best for work you start deliberately, such as something left running overnight.")
            }
            Spacer()
        }
    }
}

struct SettingsTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Sleep after nothing happens for").font(.callout)
                    Spacer()
                    Text(shortDuration(Int(model.idleWindowMinutes) * 60)).monospacedDigit()
                }
                Slider(value: $model.idleWindowMinutes, in: 15...240, step: 15) { editing in
                    if !editing { model.saveConfig() }
                }
                Caption("Short pauses are normal while work is running, so the Mac waits this long before sleeping.")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Remind me every").font(.callout)
                    Spacer()
                    Text(model.remindEveryHours == 0 ? "never" : "\(Int(model.remindEveryHours))h").monospacedDigit()
                }
                Slider(value: $model.remindEveryHours, in: 0...24, step: 1) { editing in
                    if !editing { model.saveConfig() }
                }
                Caption("A reminder that the Mac is still awake. It never stops anything.")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Let it sleep if the battery falls below").font(.callout)
                    Spacer()
                    Text("\(Int(model.batteryFloor))%").monospacedDigit()
                }
                Slider(value: $model.batteryFloor, in: 5...80, step: 5) { editing in
                    if !editing { model.saveConfig() }
                }
                Caption("If the battery drops this low, the Mac may sleep even if work is running.")
            }

            Toggle("Notify me when this changes", isOn: Binding(
                get: { model.notifyOn },
                set: { model.notifyOn = $0; model.saveConfig() }
            ))
            .font(.callout)
            Spacer()
        }
    }
}

struct DayPicker: View {
    @Binding var days: Set<Int>
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { d in
                let on = days.contains(d)
                Button(WakeEntry.labels[d - 1]) {
                    if on { days.remove(d) } else { days.insert(d) }
                    onChange()
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(on ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .font(.caption)
            }
        }
    }
}

struct ScheduleTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption("While the Mac sleeps, nothing scheduled runs. Waking it lets work carry on by itself.")

            if model.entries.isEmpty {
                Text("No wake times set.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($model.entries) { $entry in
                            HStack(spacing: 8) {
                                DatePicker("", selection: Binding(
                                    get: { entry.date },
                                    set: { newDate in
                                        let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                        entry.hour = c.hour ?? 8
                                        entry.minute = c.minute ?? 0
                                        model.saveSchedule()
                                    }
                                ), displayedComponents: .hourAndMinute)
                                .labelsHidden().frame(width: 76)

                                DayPicker(days: $entry.days) { model.saveSchedule() }

                                Button {
                                    model.removeEntry(entry)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }

            Button("Add a wake time") { model.addEntry() }

            if !model.s.nextWake.isEmpty {
                Text("Next wake: \(model.s.nextWake)").font(.callout).foregroundStyle(.secondary)
            }
            Caption("Only wake times added here are touched. Anything else that schedules power events on this Mac is left alone.")
            Spacer()
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stay Awake").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.enabled },
                    set: { model.enabled = $0; model.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            TabView(selection: $tab) {
                NowTab(model: model).padding(.top, 8).tabItem { Text("Now") }.tag(0)
                SettingsTab(model: model).padding(.top, 8).tabItem { Text("Settings") }.tag(1)
                ScheduleTab(model: model).padding(.top, 8).tabItem { Text("Schedule") }.tag(2)
            }
            .frame(height: 300)

            HStack {
                Text(model.s.daemonAlive ? "Background service running" : "Background service not running")
                    .font(.caption).foregroundStyle(model.s.daemonAlive ? Color.secondary : Color.red)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link).font(.caption)
            }
            Caption("Quit hides the icon. The Mac keeps whatever is set here.")
        }
        .padding(14)
        .frame(width: 400)
    }
}

@main
struct StayAwakeApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
