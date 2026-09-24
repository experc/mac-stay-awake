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
    var wakeDaily = ""
    var off = false

    var daemonAlive: Bool { updated > 0 && Date().timeIntervalSince1970 - updated < 30 }
    var onBattery: Bool { batteryState == "discharging" }
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

@MainActor
final class Model: ObservableObject {
    @Published var s = Status()
    @Published var idleWindowMinutes: Double = 60
    @Published var remindEveryHours: Double = 6      // 0 means never
    @Published var batteryFloor: Double = 15
    @Published var notifyOn = true
    @Published var enabled = true
    @Published var wakeEnabled = false
    @Published var wakeTime = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
    @Published var holdUntil = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()

    private var timer: Timer?
    private var lastDisabled: Bool?
    private var notificationsAllowed = false

    init() {
        loadConfig()
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
        new.wakeDaily = kv["wake_daily"] ?? ""
        new.off = kv["off"] == "1"
        s = new

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
                ? "\(s.holders) thing\(s.holders == 1 ? "" : "s") working. The lid can stay closed."
                : "You asked to keep the Mac awake."
        } else {
            content.title = "Back to normal sleep"
            switch s.latched {
            case "battery": content.body = "Battery got low, so the Mac can sleep again."
            default: content.body = s.off ? "Stay Awake is turned off." : "Everything has been quiet, so the Mac can sleep again."
            }
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: settings

    private func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func date(fromHHMM s: String) -> Date? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return Calendar.current.date(from: DateComponents(hour: h, minute: m))
    }

    func loadConfig() {
        let kv = readKeyValues(Paths.config)
        if let v = Int(kv["IDLE_WINDOW"] ?? kv["GRACE"] ?? "") { idleWindowMinutes = max(15, Double(v) / 60) }
        if let v = Int(kv["REMIND_EVERY"] ?? "") { remindEveryHours = Double(v) / 3600 }
        if let v = Int(kv["BATTERY_FLOOR"] ?? "") { batteryFloor = Double(v) }
        notifyOn = (kv["NOTIFY"] ?? "all") != "none"
        let wake = kv["WAKE_DAILY"] ?? ""
        wakeEnabled = !wake.isEmpty
        if let d = date(fromHHMM: wake) { wakeTime = d }
    }

    func saveConfig() {
        let kv = readKeyValues(Paths.config)
        let text = """
        # Settings for stayawake. The app writes this file; the helper re-reads it
        # every few seconds, so changes take effect without a restart.

        POLL=\(kv["POLL"] ?? "5")
        IDLE_WINDOW=\(Int(idleWindowMinutes * 60))
        REMIND_EVERY=\(Int(remindEveryHours * 3600))
        BATTERY_FLOOR=\(Int(batteryFloor))
        NOTIFY=\(notifyOn ? "all" : "none")
        MATCH=\(kv["MATCH"] ?? "caffeinate")
        WAKE_DAILY=\(wakeEnabled ? hhmm(wakeTime) : "")

        """
        try? text.write(to: Paths.config, atomically: true, encoding: .utf8)
    }

    // MARK: actions

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
        if !s.daemonAlive { return "Helper not running" }
        if s.off { return "Turned off" }
        return s.sleepDisabled ? "Staying awake" : "Sleeping normally"
    }

    var detail: String {
        if !s.daemonAlive { return "Nothing is managing sleep right now." }
        if s.off { return "The Mac sleeps as it normally would, lid close included." }
        var lines: [String] = []
        if s.holders > 0 {
            let names = s.holderNames.isEmpty ? "" : " (\(s.holderNames.split(separator: " ").joined(separator: ", ")))"
            lines.append("\(s.holders) thing\(s.holders == 1 ? "" : "s") working\(names)")
        } else if s.manual {
            lines.append("You asked to keep it awake")
        } else {
            lines.append("Nothing is working")
        }
        if s.sleepDisabled && s.holdSince > 0 {
            let mins = Int((Date().timeIntervalSince1970 - s.holdSince) / 60)
            lines.append("Awake \(mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m") so far, no time limit")
        }
        if s.idleSince > 0 {
            let left = Int((Double(s.idleWindow) - (Date().timeIntervalSince1970 - s.idleSince)) / 60)
            lines.append("Quiet: sleeping in about \(max(0, left))m unless work resumes")
        }
        if s.veto { lines.append("You asked to let it sleep") }
        if s.latched == "battery" { lines.append("Stopped: battery below \(s.batteryFloor)%") }
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
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            VStack(alignment: .leading, spacing: 4) {
                Text(model.headline).font(.title3).fontWeight(.semibold)
                Text(model.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.enabled {
                HStack(spacing: 8) {
                    Menu("Keep awake") {
                        Button("for 1 hour") { model.keepAwake(hours: 1) }
                        Button("for 2 hours") { model.keepAwake(hours: 2) }
                        Button("for 4 hours") { model.keepAwake(hours: 4) }
                        Button("until I turn it off") { model.keepAwake(hours: nil) }
                    }
                    .frame(width: 118)
                    Button("Let it sleep") { model.letSleep(hours: 1) }
                    if model.s.manual || model.s.veto {
                        Button("Automatic") { model.backToAutomatic() }
                    }
                }
                HStack(spacing: 6) {
                    Text("or until").font(.callout)
                    DatePicker("", selection: $model.holdUntil, displayedComponents: .hourAndMinute)
                        .labelsHidden().frame(width: 76)
                    Button("Hold") { model.keepAwakeUntil(model.holdUntil) }
                }
                Caption(text: "For a run you start deliberately, holding until a set time is surer than relying on detection.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Sleep when quiet for").frame(width: 130, alignment: .leading)
                        Slider(value: $model.idleWindowMinutes, in: 15...240, step: 15) { editing in
                            if !editing { model.saveConfig() }
                        }
                        Text(shortDuration(Int(model.idleWindowMinutes) * 60))
                            .frame(width: 42, alignment: .trailing).monospacedDigit()
                    }
                    Caption(text: "Work stops and restarts constantly, so only this much continuous quiet counts as finished.")
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Remind me every").frame(width: 130, alignment: .leading)
                        Slider(value: $model.remindEveryHours, in: 0...24, step: 1) { editing in
                            if !editing { model.saveConfig() }
                        }
                        Text(model.remindEveryHours == 0 ? "never" : "\(Int(model.remindEveryHours))h")
                            .frame(width: 42, alignment: .trailing).monospacedDigit()
                    }
                    Caption(text: "Nothing is ever cut off. This just tells you the Mac is still being kept awake.")
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Battery limit").frame(width: 130, alignment: .leading)
                        Slider(value: $model.batteryFloor, in: 5...80, step: 5) { editing in
                            if !editing { model.saveConfig() }
                        }
                        Text("\(Int(model.batteryFloor))%")
                            .frame(width: 42, alignment: .trailing).monospacedDigit()
                    }
                    Caption(text: "The one limit that does end a hold, so an unplugged Mac cannot run itself flat.")
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Toggle("Wake the Mac daily at", isOn: Binding(
                            get: { model.wakeEnabled },
                            set: { model.wakeEnabled = $0; model.saveConfig() }
                        ))
                        DatePicker("", selection: $model.wakeTime, displayedComponents: .hourAndMinute)
                            .labelsHidden().frame(width: 76)
                            .disabled(!model.wakeEnabled)
                            .onChange(of: model.wakeTime) { model.saveConfig() }
                    }
                    Caption(text: "Sleep ends a run rather than pausing it. A daily wake gives overnight work a chance to resume.")
                }

                Toggle("Tell me when it changes", isOn: Binding(
                    get: { model.notifyOn },
                    set: { model.notifyOn = $0; model.saveConfig() }
                ))
                .font(.callout)
            }

            Divider()

            HStack {
                Text(model.s.daemonAlive ? "Helper running" : "Helper not running")
                    .font(.caption).foregroundStyle(model.s.daemonAlive ? Color.secondary : Color.red)
                Spacer()
                Text("Quit closes this window only").font(.caption2).foregroundStyle(.secondary)
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 380)
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
