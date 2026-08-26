# PingStatus

A macOS menu bar app that shows a **green dot** when `ping google.com`
succeeds and a **red dot** when it doesn't. Single Swift file, SwiftUI +
AppKit, no dependencies.

| State            | Icon                |
| ---------------- | ------------------- |
| Connected        | green `circle.fill` |
| Disconnected     | red `circle`        |
| Checking (startup) | gray `circle.dashed` |

Click the icon for a popover with connection status, host, response time
(ms), last-check / last-success timestamps, failure count + reason, and a
Quit button. Pings run every 5 s via `/sbin/ping` in a background `Process`.

## Build & run

```bash
make run     # builds build/PingStatus.app (ad-hoc signed) and opens it
make app     # just build
make smoke   # run raw binary for 6 s and verify it stays alive
make clean
```

## Install

Copy the built bundle to /Applications and add it to Login Items if you
want it at startup:

```bash
cp -R build/PingStatus.app /Applications/
open /Applications/PingStatus.app   # or launch via Spotlight
```

(Hide the dot's app from the Dock is automatic — `LSUIElement = true`.)

Requirements: macOS 12+, Xcode Command Line Tools (`xcrun swiftc`).

## License

[MIT](LICENSE) — free to use, modify, and redistribute.

## Design notes / deviations from a literal spec

1. **File name is `PingStatusApp.swift`, not `main.swift`.**
   Swift forbids `@main` in a top-level file named `main.swift`
   (`error: 'main' attribute cannot be used in a top-level file named
   'main.swift'`). Since the spec explicitly requires `@main` +
   `NSApplicationDelegateAdaptor`, the single source file is renamed.

2. **Ping flag is `-W 1000`, not `-W 1`.**
   On macOS, `ping -W` takes **milliseconds** (Linux: seconds). The Linux
   command `ping -c 1 -W 1` ("1 second timeout") translates to
   `ping -c 1 -W 1000` on macOS. The literal `-W 1` makes every ping fail
   (~1 ms reply wait), which was verified on this machine.

3. **Dock icon hidden twice.** `LSUIElement = true` in the bundled
   `Info.plist` (primary), plus `NSApp.setActivationPolicy(.accessory)` in
   `applicationDidFinishLaunching` so the raw binary also stays out of the
   Dock when run outside the bundle.

## Testing on ICMP-blocked networks

Some networks (including this one) block outbound ICMP — the app will
correctly show red even though browsing works. To verify the app logic
against a reachable host:

```bash
# Bundled app (make run) — override persists via the bundle identifier:
defaults write dev.mm.pingstatus Host 127.0.0.1

# Raw binary (run directly) — the domain is the executable name instead:
defaults write PingStatus Host 127.0.0.1

defaults delete dev.mm.pingstatus Host   # restore google.com
defaults delete PingStatus Host
```

## Reliability details

- Pings run on a serial background `DispatchQueue`; results are applied on
  the main thread. An in-flight guard coalesces overlapping attempts.
- Pipe output for a single ping (< 1 KiB) is far below the 64 KiB pipe
  buffer, and is read **after** `waitUntilExit`, so no deadlock is possible.
- Timer blocks and Combine sinks capture `[weak self]`; the timer is
  invalidated in `deinit`; the status item is removed in `deinit`.
- All failures (ping timeout, DNS failure, `/sbin/ping` missing) surface as
  a `.failure` outcome with a human-readable reason shown in the popover.
- If SF Symbols were unavailable, the menu bar dot falls back to a
  hand-drawn `NSBezierPath` circle.
