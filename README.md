# GetMyIP

[![CI](https://github.com/akominch/get-my-ip/actions/workflows/ci.yml/badge.svg)](https://github.com/akominch/get-my-ip/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/akominch/get-my-ip)](https://github.com/akominch/get-my-ip/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

GetMyIP is a tiny macOS menu-bar app that shows **which country your public IP belongs to**: as a flag 🇩🇪, a country code `DE`, or both. When you connect or disconnect a VPN, it updates within a second or so. When the country changes, it posts a notification with the new flag, country name and IP.

It is written in Swift with AppKit and Network.framework and has no third-party dependencies. At idle it uses about 18 MB of memory and close to 0% CPU.

## Features

- **Flag or country code** in the menu bar: flag only, code only, or flag + code.
- **Flag styles**: Apple system emoji, Twemoji, OpenMoji, Noto Color Emoji, rectangular flags (flagcdn) and Circle Flags. Image styles are downloaded once and cached.
- **9 IP/geo services**, plus a separate **fallback** service that is used when the primary one fails.
- **Update interval** from 1 second to 10 minutes: presets, or any value via *Custom…*.
- **Instant refresh on network changes.** GetMyIP listens to system events instead of polling:
  - VPN *connecting / connected / disconnecting / disconnected* for every VPN in System Settings (WireGuard, Tailscale, IKEv2, other Network Extension VPNs);
  - primary interface and route changes;
  - interfaces appearing or disappearing.

  While a VPN is switching, the menu bar shows `Resolving… 🏳️`.
- **Interface selection**: *Automatic* follows system routing, including the VPN. Picking a specific interface (e.g. `en0`) binds the lookups to it, so you can see your real IP even while a VPN is up.
- **Notifications** on country change: 🇪🇸 *Spain — Country changed from 🇩🇪 Germany — New IP: 212.102.48.216*.
- **Resilient**: if the network is down or both services fail, it shows `Resolving… 🏳️` and retries with backoff (2 s → 30 s).
- **Launch at Login** and **automatic updates** from GitHub Releases. Both can be turned off.

## Install

1. Download `GetMyIP-x.y.z.zip` from the [latest release](https://github.com/akominch/get-my-ip/releases/latest) and unzip it.
2. Move `GetMyIP.app` to `/Applications`.
3. Open it. The app is ad-hoc signed, not notarized by Apple, so on first launch macOS will block it.
   - Open **System Settings → Privacy & Security** and click **Open Anyway** next to the GetMyIP message.
   - Or run once in Terminal: `xattr -dr com.apple.quarantine /Applications/GetMyIP.app`
4. Allow notifications when asked.

GetMyIP has no Dock icon and no window. Look for the flag in the menu bar. If you don't see it, the menu bar may be full or managed by a tool like Bartender, Ice or Hidden Bar. ⌘-drag icons around or reveal hidden items to make room.

Requirements: macOS 14 Sonoma or newer, Apple Silicon or Intel.

## Usage

Click the flag to open the menu.

| Menu item | What it does |
| --- | --- |
| Country / `IP: …` | Current country and IP. Click the IP (or press ⌘C) to copy it. |
| Refresh Now (⌘R) | Look up the IP immediately. |
| Show | Flag, Country code, or Flag + country code. |
| Flag Style | Apple emoji or one of the image sets. |
| Service / Fallback Service | Primary lookup service and the one used when it fails (or *None*). |
| Update Interval | 1 s … 10 min, or *Custom…* (1–600 seconds). |
| Interface | *Automatic* or a specific interface (Wi-Fi, Ethernet, VPN tunnel …). |
| Notify on Country Change | Turn notifications on or off. |
| Launch at Login | Start GetMyIP when you log in. |
| Automatically Install Updates | Daily update check and silent install (see below). |
| Check for Updates / Install Update … | Manual update check. |

### Services

| Service | Endpoint | Notes |
| --- | --- | --- |
| Cloudflare (default) | `https://www.cloudflare.com/cdn-cgi/trace` | Fast, no rate limit, plain-text |
| ipwho.is (default fallback) | `https://ipwho.is/` | |
| ipapi.co | `https://ipapi.co/json/` | ~1000 requests/day free |
| IPinfo | `https://ipinfo.io/json` | ~50k requests/month free |
| IP-API | `http://ip-api.com/json/` | HTTP only on the free tier, 45 requests/min |
| country.is | `https://api.country.is/` | |
| GeoJS | `https://get.geojs.io/v1/ip/geo.json` | |
| ipwhois.app | `https://ipwhois.app/json/` | |
| ip.sb | `https://api.ip.sb/geoip` | |

With very short intervals (1–5 s), prefer Cloudflare. Some free services rate-limit aggressive polling.

## Privacy

GetMyIP only talks to:
- the service you selected, plus the fallback when needed, to learn your IP and country;
- the flag image CDN, once per flag, only if you pick an image style (`cdn.jsdelivr.net`, `flagcdn.com`);
- `api.github.com` and `github.com`, once a day, only if automatic updates are on.

It has no analytics or telemetry and does not track you. Settings stay in `~/Library/Preferences/com.akominch.GetMyIP.plist`. Flag images are cached in `~/Library/Caches/com.akominch.GetMyIP`.

## Automatic updates

When **Automatically Install Updates** is on (the default), GetMyIP checks the [latest GitHub release](https://github.com/akominch/get-my-ip/releases/latest) once a day. If a newer version is available, it:
1. downloads the release zip;
2. checks that the bundle identifier and version match and that the code signature is valid;
3. replaces the app in place and relaunches.

Turn it off in the menu, or with `defaults write com.akominch.GetMyIP autoUpdate -bool false`. You can still check manually with **Check for Updates**. If the app sits in a folder you can't write to, GetMyIP opens the release page instead.

Forks can point updates at their own repository by changing `GMIUpdateRepository` in `Resources/Info.plist`. Leave it empty to disable the updater entirely.

## Build from source

Requires Xcode 16+ (Swift 5.10+ toolchain).

```sh
git clone https://github.com/akominch/get-my-ip.git
cd get-my-ip
swift test                 # unit tests
./build.sh                 # -> build/GetMyIP.app (universal, ad-hoc signed)
open build/GetMyIP.app
```

`build.sh` options (environment variables):
- `VERSION=1.2.0` sets `CFBundleShortVersionString`;
- `BUILD_NUMBER=42` sets `CFBundleVersion`;
- `ZIP=1` also writes `build/GetMyIP-<version>.zip` and a `.sha256` file.

The app icon is drawn in code. Regenerate it with:

```sh
swift scripts/make-icon.swift icon.png 1024
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests and builds the app on every push and pull request. To publish a version, push a tag:

```sh
git tag v1.2.0
git push origin v1.2.0
```

`.github/workflows/release.yml` then tests, builds a universal app with that version, and creates a GitHub Release with `GetMyIP-1.2.0.zip` and its SHA-256. Installed copies pick it up within a day.

## How it works

| File | Role |
| --- | --- |
| `AppDelegate.swift` | Status item, menu, refresh scheduling, retries, VPN-transition handling |
| `NetworkWatcher.swift` | `NWPathMonitor` + `SCDynamicStore` (routes/interfaces) + `SCNetworkConnection` (VPN status), debounced into change events |
| `HTTPClient.swift` | Minimal HTTP/1.1 client on `NWConnection`, so requests can be bound to a specific interface |
| `IPServices.swift` | Service catalog, response parsers, primary → fallback lookup |
| `FlagImageProvider.swift` | Downloads, normalizes and caches flag images |
| `Notifier.swift` | Country-change notifications |
| `Updater.swift` | GitHub Releases self-updater |

## Troubleshooting

- **No flag in the menu bar.** See the menu bar note under [Install](#install).
- **Notifications show no icon or the old one.** macOS caches app icons for notifications. Run `killall usernoted NotificationCenter` once; both restart automatically.
- **Stuck on `Resolving… 🏳️`.** Hover the item to see the error in the tooltip. Check your connection, or pick another service or fallback.
- **Logs.** `log stream --level info --predicate 'subsystem == "com.akominch.GetMyIP"'`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Alexey Kominch
