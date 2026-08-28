# PingStatus

> A tiny, elegant circle in your macOS menu bar that tells you whether your
> internet **actually works** — green when your target answers like a
> browser, red when it doesn't.

You're in an airport lounge. Your VPN app says *Connected*. Your browser
spins anyway. Is it the Wi-Fi? The VPN tunnel? A dead DNS resolver? A
captive portal you already "signed in" to?

PingStatus cuts through all of it with one glance:

- 🟢 **Green dot** — your target answers over HTTPS, like a browser.
  Whatever chain of Wi-Fi, VPN, and DNS you're on, it works.
- 🔴 **Red dot** — the check is dying: timeout, reset, DNS failure, or a
  403/451 region block. Your VPN can *claim* you're connected, but if the
  tunnel isn't routing, the dot knows.
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
you about your *local link*. PingStatus checks the layer your browser
actually uses — whether an HTTPS request reaches the site and comes back
with a usable answer.

## HTTPS checks, not just ping

Plain ICMP ping measures the wrong thing for modern sites:

| Situation | `ping` says | HTTPS check says |
| --- | --- | --- |
| Site region-blocked for you (403/451) | 🟢 reachable | 🔴 `HTTP 403 — blocked` |
| VPN tunnel black-holes traffic | 🔴 (or 🟢 to the VPN's edge) | 🔴 `Timed out` |
| DNS poisoning / wrong resolver | 🟢 (resolves somewhere) | 🔴 `TLS handshake failed` |
| Site ignores ICMP (many CDNs) | 🔴 unreachable | 🟢 fine |

That's why all built-in targets — `google.com`, `claude.ai`, `x.com` — are
checked over **HTTPS**: same fetch a browser performs (redirects followed,
realistic User-Agent, 5 s budget), final status below 400 = green. Custom
targets can also use classic **ping** — the right tool for VPN gateways,
LAN hosts, and `1.1.1.1`-style reachability.

## Features

| State | Icon |
| ------------------- | ------------------- |
| Connected | green `circle.fill` |
| Disconnected | red `circle` |
| Checking (startup) | gray `circle.dashed` |

- **Zero dependencies** — one Swift file, SwiftUI + AppKit, ~600 lines
- **Click the dot** for a popover: pick the target (google.com, claude.ai,
  x.com, or a custom host/IP stored locally) and its check method (HTTPS or
  ping for custom targets), toggle **launch at login**, set the **check
  frequency** (seconds, per minute, or per hour), and see connection status,
  response time (ms), last-check / last-success timestamps, failure count
  and a human-readable reason (`HTTP 403 — blocked`, `Timed out`, `TLS
  handshake failed`…)
- **Speed test** (on demand) — one click measures real download
  throughput through your current network/VPN via Cloudflare's free
  public endpoint; the last result and its age stay in the popover
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

Click the menu bar dot and pick a **Target** from the dropdown:

- `google.com` (default) — HTTPS
- `claude.ai` — HTTPS
- `x.com` — HTTPS
- **Custom…** — type any host or IP (e.g. `1.1.1.1` or your VPN gateway),
  pick the check method (**HTTPS | ping**), and hit Return or Save

The choice is stored locally (UserDefaults) and survives relaunches; each
custom host remembers its own method. Selecting a target re-checks
immediately. Pasted URLs are sanitized automatically —
`https://example.com/foo` becomes `example.com`.

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
defaults write dev.mm.pingstatus Method.127.0.0.1 ping   # ping instead of HTTPS

# Raw binary — the domain is the executable name instead:
defaults write PingStatus Host 127.0.0.1

defaults delete dev.mm.pingstatus Host   # restore google.com
```

## How a check works

- **HTTPS mode** — `curl -sL -m 5` with a browser User-Agent fetches
  `https://<host>/`; the final HTTP status after redirects decides the
  verdict (below 400 = connected). Total time is shown as the response
  time, so "800 ms but working" (slow VPN hop) is easy to distinguish from
  a hard failure.
- **ping mode** — `ping -c 1 -W 1000 <host>` (1 s timeout). Any outcome
  other than a successful reply — timeout, DNS failure, or the binary
  missing — is a failure with a readable reason.

## Speed test

The popover's **Speed test** button measures real download throughput —
the number a green dot can't tell you ("connected" at 2 Mbps is not the
same as usable):

- Two-stage curl download from `speed.cloudflare.com` — the same free,
  keyless, no-account endpoint that powers Cloudflare's own speed test
- A 1 MB probe sizes the real burst for ~5 s of data (2–50 MB): fast
  links aren't wasted on, slow VPNs still get an accurate figure
- Result persists across launches: "↓ 24 Mbps · 3 min ago"
- Number is tinted: green ≥ 25 Mbps, orange ≥ 5, red below — a quick
  "is my VPN degraded?" read
- Never runs on a schedule: each test moves real megabytes through your
  link (relevant on metered hotel/airplane Wi-Fi)

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

4. **Popover close is belt and braces.** The popover uses AppKit's
   `.transient` behavior, plus explicit local + global mouse-down monitors
   so *any* click outside the popover closes it deterministically — even
   when a focused text field or an open dropdown menu would defeat the
   default behavior. Clicks on menu windows (picker dropdowns) and on the
   status icon itself (which toggles) are exempted.

## Testing on ICMP-blocked networks

Some networks block outbound ICMP — in **ping** mode the app will show red
even though browsing works (the table above's last row, inverted). Switch
the target to HTTPS mode, or use HTTPS-mode presets, on such networks; keep
**ping** for targets you know answer ICMP (your VPN gateway, LAN hosts).

## License

[MIT](LICENSE) — free to use, modify, and redistribute.

---

*PingStatus — macOS menu bar internet connectivity indicator for travelers
and VPN users: a menu bar app that monitors your connection with a periodic
ping and shows a green or red dot so you always know if your network (or
VPN tunnel) actually works.*
