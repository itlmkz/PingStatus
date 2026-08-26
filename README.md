# PingStatus

> A tiny, elegant circle in your macOS menu bar that tells you whether your
> internet **actually works** — green when pings go through, red when they don't.

You're in an airport lounge. Your VPN app says *Connected*. Your browser
spins anyway. Is it the Wi-Fi? The VPN tunnel? A dead DNS resolver? A
captive portal you already "signed in" to?

PingStatus cuts through all of it with one glance:

- 🟢 **Green dot** — packets are flowing. Whatever chain of Wi-Fi, VPN, and
  DNS you're on, it works.
- 🔴 **Red dot** — pings are dying. Your VPN can *claim* you're connected,
  but if the tunnel isn't routing, the dot knows.
- ⚪ **Gray dot** — first check still running.

No windows, no Dock icon, no settings page to hunt for. Just a circle that
lives in your menu bar and tells the truth about your connection.

## Why it exists

Built for people who travel with a VPN always on:

- **Hotel & airport Wi-Fi** that silently drops packets while looking
  "connected"
- **Half-dead VPN states** — the app shows green, the tunnel black-holes
  everything
- **Captive portals** that let one request through then trap the rest
- **Flaky DNS** that resolves once and never again

Most connectivity indicators (including macOS's own Wi-Fi icon) only tell
you about your *local link*. PingStatus tells you whether data actually
reaches the internet and comes back — the thing you actually care about.

## Features

| State | Icon |
| ------------------- | ------------------- |
| Connected | green `circle.fill` |
| Disconnected | red `circle` |
| Checking (startup) | gray `circle.dashed` |

- **Zero dependencies** — one Swift file, SwiftUI + AppKit, ~600 lines
- **Click the dot** for a popover: pick the ping target (google.com,
  claude.ai, x.com, or a custom host/IP stored locally), toggle **launch
  at login**, set the **check frequency** (seconds, per minute, or per
  hour), and see connection status, response time (ms), last-check /
  last-success timestamps, failure count and reason
- **Launch at login** toggle (macOS 13+, via `SMAppService` — no helper
  process, no login-item scripts)
- **Configurable frequency** — every 5 s by default; express it in seconds
  ("every 10 s"), rate ("30 per minute"), or hourly rate ("4 per hour").
  Any value snaps to whole seconds, 1 s to 1 h
- Pings every 5 s via macOS's own `/sbin/ping` in a background process
- **Pure menu bar app** — `LSUIElement = true`, never appears in the Dock
- Tiny: ad-hoc signed `.app` bundle you build yourself in seconds
- MIT licensed

## Install

Requires macOS 12+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/itlmkz/PingStatus.git
cd PingStatus
make run        # builds and opens it
```

To keep it around permanently:

```bash
cp -R build/PingStatus.app /Applications/
open /Applications/PingStatus.app    # or launch via Spotlight
```

Optional — start at login: use the **Launch at login** toggle in the
popover (macOS 13+), or System Settings → General → Login Items.

## Build & run

```bash
make run     # builds build/PingStatus.app (ad-hoc signed) and opens it
make app     # just build
make smoke   # run raw binary for 6 s and verify it stays alive
make clean
```

The app icon (`Contents/Resources/AppIcon.icns`) is generated at build
time from `AppIcon.png` with the macOS built-ins `sips` + `iconutil` —
replace the PNG and rebuild to change it.

## Configuration

Click the menu bar dot and pick a **Ping target** from the dropdown:

- `google.com` (default)
- `claude.ai`
- `x.com`
- **Custom…** — type any host or IP (e.g. `1.1.1.1` or your VPN gateway)
  and hit Return or Save

The choice is stored locally (UserDefaults) and survives relaunches.
Selecting a target re-checks immediately. Pasted URLs are sanitized
automatically — `https://example.com/foo` becomes `example.com`.

### Launch at login

Flip the **Launch at login** switch in the popover (macOS 13+). It uses
`SMAppService`, so the app manages itself as a login item — no helper
processes and nothing to configure in System Settings. On macOS 12 the
toggle is hidden; add the app to Login Items manually instead.

### Check frequency

The **Check frequency** row accepts an integer plus a unit:

| You enter | Resulting interval |
| --- | --- |
| `5` seconds | every 5 s |
| `30` per minute | every 2 s |
| `4` per hour | every 15 min |

Any rate is snapped to the nearest whole second (minimum 1 s, maximum
1 h — i.e. `1` per hour). The current cadence is always shown underneath,
e.g. "Every 5 s · 12×/min · 720×/hr". Applies immediately; persisted
across relaunches.

You can also set it from the terminal:

```bash
# Bundled app — override persists via the bundle identifier:
defaults write dev.mm.pingstatus Host 127.0.0.1

# Raw binary — the domain is the executable name instead:
defaults write PingStatus Host 127.0.0.1

defaults delete dev.mm.pingstatus Host   # restore google.com
```

## How it tells "no internet" from "slow internet"

Each check runs `ping -c 1 -W 1000 <host>` (1 s timeout). Any outcome other
than a successful reply — timeout, DNS failure, or the ping binary missing —
surfaces as a failure with a human-readable reason in the popover. Response
time is shown in the popover, so "500 ms but working" (slow VPN hop) is easy
to distinguish from "no reply" (dead tunnel).

## Reliability details

- Pings run on a serial background `DispatchQueue`; results are applied on
  the main thread. An in-flight guard coalesces overlapping attempts.
- Pipe output for a single ping (< 1 KiB) is far below the 64 KiB pipe
  buffer, and is read **after** `waitUntilExit`, so no deadlock is possible.
- Timer blocks and Combine sinks capture `[weak self]`; the timer is
  invalidated in `deinit`; the status item is removed in `deinit`.
- If SF Symbols were unavailable, the menu bar dot falls back to a
  hand-drawn `NSBezierPath` circle.

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

Some networks block outbound ICMP — the app will correctly show red even
though browsing works. Use the `Host` override above to point it at a
reachable host (e.g. `1.1.1.1` or your VPN gateway) on such networks.

## License

[MIT](LICENSE) — free to use, modify, and redistribute.

---

*PingStatus — macOS menu bar internet connectivity indicator for travelers
and VPN users: a menu bar app that monitors your connection with a periodic
ping and shows a green or red dot so you always know if your network (or
VPN tunnel) actually works.*
