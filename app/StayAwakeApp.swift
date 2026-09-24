import SwiftUI
import UserNotifications

// The privileged half of this lives in /usr/local/sbin/nosleepd. This app never
// touches pmset: it reads the daemon's state file and writes small files the
// daemon picks up on its next check, which is why it needs no password.

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
    var maxHold = 28800
    var batteryFloor = 15
    var grace = 900
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

@MainActor
final class Model: ObservableObject {
    @Published var s = Status()
    @Published var maxHoldHours: Double = 8
    @Published var batteryFloor: Double = 15
    @Published var notifyOn = true
    @Published var enabled = true

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
        new.maxHold = Int(kv["max_hold"] ?? "") ?? 28800
        new.batteryFloor = Int(kv["battery_floor"] ?? "") ?? 15
        new.grace = Int(kv["grace"] ?? "") ?? 900
        new.off = kv["off"] == "1"
        s = new

        // Tells the daemon an app is running, so it does not also post its own
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
            case "deadline": content.body = "It had been awake for a long time, so the Mac can sleep again."
            default: content.body = s.off ? "Stay Awake is turned off." : "Nothing is working now."
            }
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: settings

    func loadConfig() {
        let kv = readKeyValues(Paths.config)
        if let v = Int(kv["MAX_HOLD"] ?? "") { maxHoldHours = max(1, Double(v) / 3600) }
        if let v = Int(kv["BATTERY_FLOOR"] ?? "") { batteryFloor = Double(v) }
        notifyOn = (kv["NOTIFY"] ?? "all") != "none"
    }

    func saveConfig() {
        var kv = readKeyValues(Paths.config)
        kv["MAX_HOLD"] = String(Int(maxHoldHours * 3600))
        kv["BATTERY_FLOOR"] = String(Int(batteryFloor))
        kv["NOTIFY"] = notifyOn ? "all" : "none"
        let text = """
        # Settings for stayawake. The app writes this file; the helper re-reads it every few seconds.

        POLL=\(kv["POLL"] ?? "5")
        MAX_HOLD=\(kv["MAX_HOLD"]!)
        BATTERY_FLOOR=\(kv["BATTERY_FLOOR"]!)
        GRACE=\(kv["GRACE"] ?? "900")
        NOTIFY=\(kv["NOTIFY"]!)
        MATCH=\(kv["MATCH"] ?? "caffeinate")

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
            lines.append("Awake \(mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m") so far, stops after \(s.maxHold / 3600)h")
        }
        if s.idleSince > 0 {
            let left = Int((Double(s.grace) - (Date().timeIntervalSince1970 - s.idleSince)) / 60)
            lines.append("Sleeping in about \(max(0, left))m")
        }
        if s.veto { lines.append("You asked to let it sleep") }
        switch s.latched {
        case "battery": lines.append("Stopped: battery below \(s.batteryFloor)%")
        case "deadline": lines.append("Stopped: reached the \(s.maxHold / 3600)h limit")
        default: break
        }
        lines.append("Battery \(s.batteryPct)%, \(s.onBattery ? "on battery" : "on power")")
        return lines.joined(separator: "\n")
    }

    var iconName: String {
        if s.off || !s.daemonAlive { return "moon.zzz" }
        return s.sleepDisabled ? "eye.fill" : "moon"
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
                Text(model.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if model.enabled {
                HStack(spacing: 8) {
                    Menu("Keep awake") {
                        Button("for 1 hour") { model.keepAwake(hours: 1) }
                        Button("for 2 hours") { model.keepAwake(hours: 2) }
                        Button("for 4 hours") { model.keepAwake(hours: 4) }
                        Button("until I turn it off") { model.keepAwake(hours: nil) }
                    }
                    .frame(width: 120)
                    Button("Let it sleep") { model.letSleep(hours: 1) }
                }
                if model.s.manual || model.s.veto {
                    Button("Back to automatic") { model.backToAutomatic() }
                        .buttonStyle(.link)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Stop after").frame(width: 92, alignment: .leading)
                    Slider(value: $model.maxHoldHours, in: 1...24, step: 1) { editing in
                        if !editing { model.saveConfig() }
                    }
                    Text("\(Int(model.maxHoldHours))h").frame(width: 32, alignment: .trailing).monospacedDigit()
                }
                HStack {
                    Text("Battery limit").frame(width: 92, alignment: .leading)
                    Slider(value: $model.batteryFloor, in: 5...80, step: 5) { editing in
                        if !editing { model.saveConfig() }
                    }
                    Text("\(Int(model.batteryFloor))%").frame(width: 32, alignment: .trailing).monospacedDigit()
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
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
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
