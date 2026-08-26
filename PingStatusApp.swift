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

// MARK: - Ping monitor

/// Pings a host every `interval` seconds on a background queue using
/// `/sbin/ping` and publishes the results on the main thread.
final class PingMonitor: ObservableObject {

    // MARK: Configuration

    /// One echo request, waiting up to 1 s for the reply.
    /// (macOS `ping -W` is in milliseconds — see file header note.)
    private static let pingArguments = ["-c", "1", "-W", "1000"]

    private static let pingExecutablePath = "/sbin/ping"
    private static let defaultHost = "google.com"
    static let interval: TimeInterval = 5

    /// Host to ping. Override for testing with
    /// `defaults write dev.mm.pingstatus Host 127.0.0.1`
    let host: String

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
    private var timer: Timer?
    private let pingQueue = DispatchQueue(label: "dev.mm.pingstatus.ping", qos: .utility)

    /// `time=23.4 ms` → captures "23.4". Fixed literal pattern, cannot fail.
    private static let latencyRegex = try! NSRegularExpression(
        pattern: #"time=(\d+(?:\.\d+)?)\s*ms"#
    )

    init(host: String? = nil) {
        self.host = host
            ?? UserDefaults.standard.string(forKey: "Host")
            ?? Self.defaultHost
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Control

    /// Starts the repeating ping timer and fires the first ping immediately.
    func start() {
        guard timer == nil else { return }
        pingNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
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
        pingQueue.async { [weak self] in
            let outcome = Self.performPing(host: self?.host ?? Self.defaultHost)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPinging = false
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

struct StatusPopoverView: View {
    @EnvironmentObject private var monitor: PingMonitor

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

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Host") { Text(monitor.host) }
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
        Text("Pinging \(monitor.host) every \(Int(PingMonitor.interval)) s")
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
