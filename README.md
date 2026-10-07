# Zinbox

**All your messaging apps in one native macOS window.**

Zinbox is a lightweight, native alternative to [Franz](https://meetfranz.com): WhatsApp, Slack, Teams, Gmail, Telegram, Discord and any other web app side by side in tabs, each with its own login. It is written in Swift with AppKit and uses the system WebKit engine — no Electron, no bundled Chromium, no account, no telemetry.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## Features

- **Tabs across the top**, one per service, with the site's icon, name and unread badge. Drag to reorder; right-click for reload, open in browser, notifications on/off, mute audio, disable, edit and remove.
- **Built-in services**: WhatsApp, Messenger, Telegram, Slack, Discord, Microsoft Teams, Gmail, Google Chat, Outlook, Zalo, LinkedIn, Instagram — plus **any website** by URL.
- **Multiple accounts**: every service has its own isolated website data store, so you can add the same service twice and stay signed in to both.
- **Always-on background services**: services keep running when their tab isn't visible or the window is closed, so unread counts and notifications keep working.
- **Native notifications**: page notifications become macOS notifications; clicking one opens the service at that conversation. **Do Not Disturb** pauses them all.
- **Unread badges** per tab, with the total on the Dock icon.
- **Disable** a service to free its memory while keeping its login.
- Sign-in popups stay inside the app; links to other sites open in your default browser.
- Downloads, file uploads, camera and microphone, per-service zoom, Web Inspector, light and dark mode.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or the Swift 6 toolchain (to build)

## Build and run

```sh
git clone https://github.com/oadtq/Zinbox.git
cd Zinbox
./build.sh            # release build → build/Zinbox.app
open build/Zinbox.app
```

`./build.sh debug` builds faster while iterating. To install, drag `build/Zinbox.app` to `/Applications`.

The build is ad-hoc signed. macOS may ask again for notification, camera or microphone permission after you rebuild.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘1 … ⌘9 | Go to service |
| ⌃⇥ / ⌃⇧⇥, ⌥⌘→ / ⌥⌘← | Next / previous service |
| ⌘N | Add a service |
| ⌘R / ⇧⌘R | Reload / reload ignoring cache |
| ⇧⌘H | Go to the service's home page |
| ⌘[ / ⌘] | Back / forward |
| ⌘+ / ⌘- / ⌘0 | Zoom in / out / actual size (remembered per service) |
| ⇧⌘M | Do Not Disturb |
| ⌥⌘I | Web Inspector |
| ⌘, | Settings |
| ⌘W | Close the window (services keep running) |

## How it works

| File | Role |
|---|---|
| `AppModel.swift` | The service list, selection, unread totals, persistence |
| `ServiceController.swift` | One service's `WKWebView`: navigation, popups, downloads, crash recovery |
| `Scripts.swift` | Injected JS: Notification API bridge and unread counter |
| `Recipes.swift` | Built-in services: start URL, hosts, unread reader |
| `TabBar.swift`, `MainWindow.swift` | The window and its tab strip |
| `Notifier.swift` | macOS notifications |

- Each service gets a `WKWebsiteDataStore(forIdentifier:)`, so cookies and storage never mix between services.
- Pages run with `inactiveSchedulingPolicy = .none`, so hidden tabs aren't throttled.
- WKWebView has no Web Notification API, so Zinbox injects a small `Notification` implementation into each page. It forwards notifications to an isolated script world, and only that world can talk to the app.
- Unread counts come from a per-service DOM reader, falling back to the `(n)` in the page title.

Settings are stored in `~/Library/Application Support/Zinbox/services.json`.

## Adding a service

Add an entry to `Recipes.all` in `Sources/Zinbox/Recipes.swift`: an id, name, start URL, the hosts that belong to it, a brand colour, and optionally a JS snippet that returns the unread count. Pull requests are welcome.

## Testing

Launching with `ZINBOX_PROBE=<name>` uses a separate data folder and enables a test-only remote control (`Sources/Zinbox/Probe.swift`). Commands are JSON strings posted as the distributed notification `app.zinbox.probe`, and replies are written to `$ZINBOX_PROBE_OUT`. The probe can add and edit services, run JavaScript in a page, inject clicks and key presses, and snapshot the window.

## Contributing

Issues and pull requests are welcome. Please keep the app dependency-free and native, and match the style of the surrounding code.

## License

[MIT](LICENSE) © 2026 Bao Tran

Zinbox is not affiliated with Franz or with any of the services it can display. All trademarks belong to their respective owners.
