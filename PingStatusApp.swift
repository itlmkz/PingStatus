//
//  PingStatusApp.swift
//  PingStatus
//
//  A macOS menu bar app that pings google.com every 5 seconds and shows a
//  green dot (connected) or red dot (disconnected) in the status bar.
//
//  Build & run:  make run        (builds build/PingStatus.app and opens it)
//
//  NOTE — file name: Swift forbids `@main` in a top-level file named
//  `main.swift` ("'main' attribute cannot be used in a top-level file named
//  'main.swift'"), so the single source file is named PingStatusApp.swift.
//
//  NOTE — ping flags: on macOS, `ping -W` takes MILLISECONDS (on Linux it
//  takes seconds). The Linux command `ping -c 1 -W 1` is therefore
//  `-c 1 -W 1000` on macOS: one echo request, waiting up to 1 second for
//  the reply. See `PingMonitor.pingArguments`.
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Model

/// Connectivity as measured by the most recent completed ping.
enum ConnectionState: Equatable {
    /// No result yet (app just launched).
    case checking
    /// Last ping succeeded.
    case connected
    /// Last ping failed.
    case disconnected
}

/// Outcome of a single ping attempt.
enum PingOutcome: Equatable {
    /// Exit status 0. Carries the parsed round-trip time in milliseconds
    /// (nil if the time could not be parsed from the output).
    case success(responseMillis: Double?)
    /// Non-zero exit status or launch failure, with a human-readable reason.
    case failure(String)
}

/// How a target is checked.
///
/// - `https`: fetch `https://host/` with curl (browser User-Agent,
///   redirects followed). Any final HTTP status below 400 is connected —
///   this sees what the *browser* sees, including region blocks (403/451),
///   TLS resets, and DNS poisoning that leave ICMP ping green.
/// - `ping`: classic ICMP echo via `/sbin/ping`. Right tool for VPN
///   gateways, LAN hosts, and raw reachability.
enum CheckMethod: String, CaseIterable {
    case https
    case ping

    var label: String {
        switch self {
        case .https: return "HTTPS"
        case .ping: return "ping"
        }
    }
}

/// A built-in target offered in the popover picker.
struct PresetHost: Equatable {
    let host: String
    let method: CheckMethod
}

// MARK: - Check monitor

/// Checks a host every `interval` seconds on a background queue — an
/// HTTPS fetch via `/usr/bin/curl` (browser-like) or an ICMP echo via
/// `/sbin/ping` — and publishes the results on the main thread.
final class PingMonitor: ObservableObject {

    // MARK: Configuration

    /// One echo request, waiting up to 1 s for the reply.
    /// (macOS `ping -W` is in milliseconds — see file header note.)
    private static let pingArguments = ["-c", "1", "-W", "1000"]

    private static let pingExecutablePath = "/sbin/ping"
    private static let defaultHost = "google.com"

    /// Built-in targets. All use HTTPS: it is the layer the browser
    /// actually experiences (a plain ping can be green while the site is
    /// region-blocked, and ICMP is often deprioritized or ignored).
    static let presetHosts = [
        PresetHost(host: "google.com", method: .https),
        PresetHost(host: "claude.ai", method: .https),
        PresetHost(host: "x.com", method: .https),
    ]

    /// Method for the current host. Presets carry a fixed method; custom
    /// hosts persist theirs per-host (`Method.<host>`, default HTTPS).
    @Published private(set) var method: CheckMethod = .https

    // MARK: Published state (main thread only)

    @Published private(set) var state: ConnectionState = .checking
    /// Round-trip time of the most recent successful ping, in milliseconds.
    @Published private(set) var lastResponseMillis: Double?
    /// When the most recent ping ran, successful or not.
    @Published private(set) var lastAttemptDate: Date?
    /// When the most recent successful ping ran.
    @Published private(set) var lastSuccessDate: Date?
    /// Consecutive failed pings (0 while healthy).
    @Published private(set) var consecutiveFailures = 0
    /// Human-readable reason for the latest failure, if any.
    @Published private(set) var failureDescription: String?

    // MARK: Private

    /// Set while a ping is in flight so overlapping attempts are skipped
    /// (e.g. if a ping somehow outlives `interval`). Main thread only.
    private var isPinging = false
    /// Bumped on every `pingNow()` and on host changes; a completion whose
    /// generation no longer matches is stale and triggers a re-ping.
    private var pingGeneration = 0
    private var timer: Timer?
    private let pingQueue = DispatchQueue(label: "dev.mm.pingstatus.ping", qos: .utility)

    /// `time=23.4 ms` → captures "23.4". Fixed literal pattern, cannot fail.
    private static let latencyRegex = try! NSRegularExpression(
        pattern: #"time=(\d+(?:\.\d+)?)\s*ms"#
    )

    /// Host to check. The current value persists in UserDefaults (`Host`);
    /// override for testing with `defaults write dev.mm.pingstatus Host 127.0.0.1`.

    /// Seconds between checks. Persisted (`IntervalSeconds`), default 5;
    /// set from the popover's frequency editor (seconds / per minute /
    /// per hour), always snapped to an integer number of seconds.
    @Published private(set) var interval: TimeInterval = 5
    @Published private(set) var host: String

    init(host: String? = nil) {
        self.host = host
            ?? UserDefaults.standard.string(forKey: "Host")
            ?? Self.defaultHost
        method = Self.method(forHost: self.host)
        let storedInterval = UserDefaults.standard.integer(forKey: "IntervalSeconds")
        if (1...3600).contains(storedInterval) {
            interval = TimeInterval(storedInterval)
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Control

    /// Switches the ping target, persists it, and re-checks immediately.
    /// A ping still in flight for the old host is discarded (generation
    /// mismatch) so its result can never be attributed to the new host.
    func setHost(_ rawHost: String) {
        let newHost = Self.sanitizeHost(rawHost)
        guard !newHost.isEmpty, newHost != host else { return }
        host = newHost
        method = Self.method(forHost: newHost)
        UserDefaults.standard.set(newHost, forKey: "Host")
        pingGeneration += 1
        state = .checking
        consecutiveFailures = 0
        failureDescription = nil
        lastResponseMillis = nil
        lastSuccessDate = nil
        pingNow()
    }

    /// Switches the check method for a *custom* host (presets are fixed),
    /// persists it, and re-checks immediately.
    func setMethod(_ newMethod: CheckMethod) {
        guard Self.preset(for: host) == nil, newMethod != method else { return }
        method = newMethod
        UserDefaults.standard.set(newMethod.rawValue, forKey: "Method.\(host)")
        state = .checking
        pingNow()
    }

    /// The preset whose host matches, if any.
    private static func preset(for host: String) -> PresetHost? {
        presetHosts.first { $0.host == host }
    }

    /// Method for a host: the preset's fixed method if it is one, otherwise
    /// the per-host stored choice, defaulting to HTTPS.
    private static func method(forHost host: String) -> CheckMethod {
        if let preset = preset(for: host) { return preset.method }
        if let stored = UserDefaults.standard.string(forKey: "Method.\(host)"),
           let parsed = CheckMethod(rawValue: stored) {
            return parsed
        }
        return .https
    }

    /// Updates the ping cadence in whole seconds (clamped to 1...3600),
    /// persists it, and reschedules the timer on the new cadence.
    func setInterval(seconds: Int) {
        let clamped = min(max(seconds, 1), 3600)
        guard clamped != Int(interval) else { return }
        interval = TimeInterval(clamped)
        UserDefaults.standard.set(clamped, forKey: "IntervalSeconds")
        rescheduleTimer()
    }

    /// Replaces the repeating timer, keeping the current cadence. The next
    /// tick fires one full interval from now.
    private func rescheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pingNow()
        }
    }

    /// Trims pasted URLs down to a bare host: strips whitespace, an optional
    /// http(s):// scheme, and any path or query suffix.
    private static func sanitizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"]
        where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts the repeating ping timer and fires the first ping immediately.
    func start() {
        guard timer == nil else { return }
        pingNow()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pingNow()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs a single ping on the background queue and applies the result on
    /// the main thread. Safe to call while a ping is already in flight —
    /// the request is simply coalesced away.
    func pingNow() {
        guard !isPinging else { return }
        isPinging = true
        pingGeneration += 1
        let generation = pingGeneration
        let currentHost = host
        let currentMethod = method
        pingQueue.async { [weak self] in
            let outcome = currentMethod == .https
                ? Self.performHTTPS(host: currentHost)
                : Self.performPing(host: currentHost)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPinging = false
                guard generation == self.pingGeneration else {
                    // The host changed while this ping was in flight; its
                    // result is stale — immediately re-ping the new host.
                    self.pingNow()
                    return
                }
                self.apply(outcome, at: Date())
            }
        }
    }

    // MARK: Ping execution (background queue)

    /// Runs one `/sbin/ping -c 1 -W 1000 <host>` synchronously and returns
    /// the outcome. Must be called off the main thread. Never throws — all
    /// failures are reported through `.failure`.
    private static func performPing(host: String) -> PingOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pingExecutablePath)
        process.arguments = pingArguments + [host]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure("Could not launch \(pingExecutablePath): \(error.localizedDescription)")
        }

        // A single ping produces well under 1 KiB on both pipes, far below
        // the 64 KiB pipe buffer, so reading after exit cannot deadlock.
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            if !errorOutput.isEmpty {
                return .failure(errorOutput)
            }
            return .failure("No reply from \(host) (request timed out)")
        }
        return .success(responseMillis: parseResponseMillis(in: output))
    }

    /// Extracts the round-trip time from standard ping output such as
    /// `64 bytes from 142.250.74.46: icmp_seq=0 ttl=118 time=23.4 ms`.
    private static func parseResponseMillis(in output: String) -> Double? {
        let text = output as NSString
        guard let match = latencyRegex.firstMatch(
            in: output,
            range: NSRange(location: 0, length: text.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        return Double(text.substring(with: match.range(at: 1)))
    }

    // MARK: HTTPS check (curl)

    private static let curlExecutablePath = "/usr/bin/curl"
    private static let curlUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    /// Total budget for the whole fetch, redirects included (seconds).
    private static let curlTimeoutSeconds = 5.0

    /// Fetches `https://<host>/` with curl — browser User-Agent, redirects
    /// followed, shared 5 s budget — and maps the final HTTP status to an
    /// outcome: below 400 is connected; 403/451 (region/bot block), timeouts,
    /// resets, and DNS failures are failures with a readable reason.
    /// Must be called off the main thread. Output is under 1 KiB, read
    /// after `waitUntilExit`, so no pipe deadlock is possible.
    private static func performHTTPS(host: String) -> PingOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: curlExecutablePath)
        process.arguments = [
            "-s", "-o", "/dev/null", "-L",
            "-m", String(curlTimeoutSeconds),
            "--connect-timeout", String(curlTimeoutSeconds - 1),
            "-A", curlUserAgent,
            "-w", "%{http_code} %{time_total}",
            "https://\(host)/",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure("Could not launch \(curlExecutablePath): \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            return .failure(curlFailureReason(
                exitCode: Int(process.terminationStatus), host: host))
        }

        // "301 0.456" → status 301, total time 0.456 s.
        let parts = output.split(separator: " ")
        guard let code = parts.first.flatMap({ Int($0) }), code > 0 else {
            return .failure("Could not read HTTP status from curl output")
        }
        let millis = parts.count > 1 ? Double(parts[1]).map { $0 * 1000 } : nil

        guard code < 400 else {
            return .failure(httpFailureReason(code: code))
        }
        return .success(responseMillis: millis)
    }

    private static func curlFailureReason(exitCode: Int, host: String) -> String {
        switch exitCode {
        case 6: return "Could not resolve \(host) (DNS)"
        case 7: return "Could not connect to \(host)"
        case 28: return "Timed out reaching \(host)"
        case 35: return "TLS handshake failed for \(host)"
        case 47, 54, 56: return "Connection reset while loading \(host)"
        case 60: return "TLS certificate problem for \(host)"
        default: return "curl exited with status \(exitCode)"
        }
    }

    private static func httpFailureReason(code: Int) -> String {
        switch code {
        case 401, 403: return "HTTP \(code) — blocked (region or bot check)"
        case 451: return "HTTP 451 — unavailable in this region"
        case 404: return "HTTP 404 — not found"
        case 500...599: return "HTTP \(code) — server error"
        default: return "HTTP \(code)"
        }
    }

    // MARK: State application (main thread)

    private func apply(_ outcome: PingOutcome, at date: Date) {
        lastAttemptDate = date
        switch outcome {
        case .success(let millis):
            state = .connected
            if let millis { lastResponseMillis = millis }
            lastSuccessDate = date
            consecutiveFailures = 0
            failureDescription = nil
        case .failure(let reason):
            state = .disconnected
            consecutiveFailures += 1
            failureDescription = reason
        }
    }
}

// MARK: - Menu bar UI

/// Owns the status item and the detail popover; mirrors monitor state into
/// the menu bar icon.
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let monitor: PingMonitor
    private var stateCancellable: AnyCancellable?
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    init(monitor: PingMonitor) {
        self.monitor = monitor
        super.init()
        installStatusItem()
        installPopover()
        observeMonitor()
    }

    deinit {
        stateCancellable?.cancel()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    // MARK: Installation

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "PingStatusItem"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateIcon(for: monitor.state)
    }

    private func installPopover() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView().environmentObject(monitor)
        )
        popover.delegate = self
    }

    private func observeMonitor() {
        // $state fires with the current value on subscribe, so the icon is
        // rendered immediately and on every change thereafter.
        stateCancellable = monitor.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
    }

    // MARK: Icon

    private func updateIcon(for state: ConnectionState) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let color: NSColor
        let label: String
        switch state {
        case .checking:
            (symbolName, color, label) = ("circle.dashed", .systemGray, "Checking connection…")
        case .connected:
            (symbolName, color, label) = ("circle.fill", .systemGreen, "Connected")
        case .disconnected:
            (symbolName, color, label) = ("circle", .systemRed, "Disconnected")
        }

        button.image = Self.dotImage(symbolName: symbolName, color: color)
        button.toolTip = "PingStatus — \(label)"
    }

    /// A colored SF Symbol dot for the menu bar. `isTemplate = false` is
    /// essential: template images are forced to monochrome by the system.
    private static func dotImage(symbolName: String, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            symbol.isTemplate = false
            return symbol
        }
        // Fallback if the SF Symbol is unavailable: draw a plain dot.
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 10, height: 10)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }
}

// MARK: - Popover content (SwiftUI)

/// The picker's selection: one of the presets, or free-form entry.
enum HostChoice: Hashable {
    case preset(String)
    case custom
}

/// Frequency entry units offered in the popover. Whatever the user picks,
/// the resulting interval is snapped to whole seconds (min 1 s, max 1 h).
enum FrequencyUnit: String, CaseIterable, Identifiable {
    case seconds = "seconds"
    case perMinute = "per minute"
    case perHour = "per hour"

    var id: String { rawValue }

    /// Integer seconds for `count` checks in this unit, rounded to the
    /// nearest whole second (never below 1 s).
    func seconds(forCount count: Int) -> Int {
        switch self {
        case .seconds: return max(1, count)
        case .perMinute: return max(1, Int((60.0 / Double(count)).rounded()))
        case .perHour: return max(1, Int((3600.0 / Double(count)).rounded()))
        }
    }
}

struct StatusPopoverView: View {
    @EnvironmentObject private var monitor: PingMonitor

    @State private var selection: HostChoice = .preset(PingMonitor.presetHosts[0].host)
    @State private var customHostText = ""
    @State private var customMethod: CheckMethod = .https
    @State private var loginItemEnabled = false
    @State private var frequencyCount = ""
    @State private var frequencyUnit: FrequencyUnit = .seconds

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            hostPicker
            Divider()
            settingsSection
            Divider()
            detailRows
            Divider()
            footer
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit PingStatus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            alignSelectionWithMonitor()
            refreshLoginStatus()
            frequencyCount = String(Int(monitor.interval))
            frequencyUnit = .seconds
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusTitle)
                .font(.headline)
            Spacer()
        }
    }

    // MARK: Host picker

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Target", selection: selectionBinding) {
                ForEach(PingMonitor.presetHosts, id: \.host) { preset in
                    Text(preset.host).tag(HostChoice.preset(preset.host))
                }
                Text("Custom…").tag(HostChoice.custom)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            if selection == .custom {
                HStack(spacing: 8) {
                    TextField("example.com or 1.1.1.1", text: $customHostText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveCustomHost)
                    Button("Save", action: saveCustomHost)
                        .disabled(trimmedCustomHost.isEmpty)
                }
                Picker("Check with", selection: $customMethod) {
                    ForEach(CheckMethod.allCases, id: \.self) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
        .font(.callout)
    }

    /// Selecting a preset applies it immediately; selecting Custom… waits
    /// for the text field (Return or Save).
    private var selectionBinding: Binding<HostChoice> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                if case .preset(let host) = newValue {
                    monitor.setHost(host)
                }
            }
        )
    }

    private var trimmedCustomHost: String {
        customHostText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveCustomHost() {
        let host = trimmedCustomHost
        guard !host.isEmpty else { return }
        monitor.setHost(host)
        monitor.setMethod(customMethod)
    }

    /// Mirrors the persisted host into the picker: a preset if it matches,
    /// otherwise Custom… with the stored value shown in the text field.
    private func alignSelectionWithMonitor() {
        if let preset = PingMonitor.presetHosts.first(where: { $0.host == monitor.host }) {
            selection = .preset(preset.host)
            customHostText = ""
        } else {
            selection = .custom
            customHostText = monitor.host
            customMethod = monitor.method
        }
    }

    // MARK: Settings (login item + frequency)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if supportsLoginItem {
                Toggle("Launch at login", isOn: loginItemBinding)
                    .toggleStyle(.switch)
            }
            frequencyEditor
        }
        .font(.callout)
    }

    /// SMAppService needs macOS 13+ and a bundled .app (not the bare
    /// binary), so the toggle is hidden when unavailable.
    private var supportsLoginItem: Bool {
        if #available(macOS 13.0, *) { return Bundle.main.bundleURL.pathExtension == "app" }
        return false
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { setLoginItem(enabled: $0) }
        )
    }

    private func setLoginItem(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail (permission or bundle issues); revert
            // to whatever the system thinks the state is.
            NSSound.beep()
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        if #available(macOS 13.0, *) {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private var frequencyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Check frequency")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("5", text: $frequencyCount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .onChange(of: frequencyCount) { _ in sanitizeFrequencyText() }
                    .onSubmit(applyFrequency)
                Picker("Unit", selection: $frequencyUnit) {
                    ForEach(FrequencyUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button("Apply", action: applyFrequency)
                    .disabled(Int(trimmedFrequencyCount) == nil)
            }
            Text(frequencySummary)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var trimmedFrequencyCount: String {
        frequencyCount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Integer-only enforcement: anything that is not a digit is dropped.
    private func sanitizeFrequencyText() {
        let filtered = String(trimmedFrequencyCount.filter(\.isNumber))
        if filtered != frequencyCount {
            frequencyCount = filtered
        }
    }

    private func applyFrequency() {
        sanitizeFrequencyText()
        guard let count = Int(trimmedFrequencyCount), count >= 1 else { return }
        monitor.setInterval(seconds: frequencyUnit.seconds(forCount: count))
    }

    /// "Every 5 s (12×/min, 720×/hr)" — fractional rates get one decimal.
    private var frequencySummary: String {
        let seconds = monitor.interval
        func rate(_ perInterval: Double) -> String {
            let value = perInterval / seconds
            return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        }
        var parts = ["Every \(seconds < 60 ? String(Int(seconds)) + " s" : Self.durationText(seconds))"]
        parts.append("\(rate(60))×/min")
        if seconds >= 60 { parts.append("\(rate(3600))×/hr") }
        return parts.joined(separator: " · ")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600, s % 3600 == 0 { return "\(s / 3600) h" }
        if s >= 60, s % 60 == 0 { return "\(s / 60) min" }
        return "\(s) s"
    }

    // MARK: Detail rows

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Check") { Text(monitor.method.label) }
            row("Response") {
                if let millis = monitor.lastResponseMillis {
                    Text(String(format: "%.1f ms", millis))
                } else {
                    Text("—").foregroundColor(.secondary)
                }
            }
            row("Last check") { timeText(monitor.lastAttemptDate) }
            row("Last success") { timeText(monitor.lastSuccessDate) }
            if monitor.consecutiveFailures > 0 {
                row("Failed pings") {
                    Text("\(monitor.consecutiveFailures) in a row")
                        .foregroundColor(.orange)
                }
            }
            if monitor.state == .disconnected, let reason = monitor.failureDescription {
                row("Reason") {
                    Text(reason)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        Text("\(monitor.method == .https ? "Checking" : "Pinging") \(monitor.host) every \(Int(monitor.interval)) s")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Helpers

    private var statusColor: Color {
        switch monitor.state {
        case .checking: return .gray
        case .connected: return .green
        case .disconnected: return .red
        }
    }

    private var statusTitle: String {
        switch monitor.state {
        case .checking: return "Checking…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            value()
        }
    }

    private func timeText(_ date: Date?) -> Text {
        if let date {
            return Text(Self.timeFormatter.string(from: date))
        }
        return Text("—").foregroundColor(.secondary)
    }
}

// MARK: - App bootstrap

@main
struct PingStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A menu-bar-only app still needs at least one scene; an empty
        // Settings scene provides one without adding windows or a Dock icon.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = PingMonitor()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: keep the app out of the Dock even when the binary
        // runs outside the bundle (the bundled Info.plist also sets
        // LSUIElement = true, which is the primary mechanism).
        NSApp.setActivationPolicy(.accessory)

        menuBarController = MenuBarController(monitor: monitor)
        monitor.start()
    }
}
