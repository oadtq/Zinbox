# Architecture

One macOS window. Each service is the site itself in a `WKWebView`. `references/Search` is the shell, the WebKit setup, and the visual language. `references/franz` is the model for a service row: one cookie jar, a small unread script, notifications forwarded out of the page. Patterns taken from Franz are at the bottom of `franz-architecture.md`.

## Stack

Swift package, no dependencies. Swift 6 toolchain, language mode v5, because the window and the web views are main-thread. Minimum macOS 14, for `WKWebsiteDataStore(forIdentifier:)`.

SwiftUI draws the shell. AppKit hosts `WKWebView`, the open panel, and window dragging from the rail.

`swift build` runs the app. A later `build.sh` can wrap a `.app`. There is no updater in this version.

## Services

Compiled into the app. A row points at one of these.

| id | Start URL | Hosts that stay in the app |
|---|---|---|
| whatsapp | `https://web.whatsapp.com` | `web.whatsapp.com`, `whatsapp.com` |
| slack | `https://app.slack.com` | `slack.com`, `slack-edge.com` |
| telegram | `https://web.telegram.org/a/` | `web.telegram.org`, `telegram.org` |
| discord | `https://discord.com/app` | `discord.com`, `discordapp.com` |
| gmail | `https://mail.google.com` | `mail.google.com`, `accounts.google.com` |
| outlook | `https://outlook.office.com/mail/` | `outlook.office.com`, `outlook.live.com`, `office.com`, `live.com`, `microsoft.com`, `microsoftonline.com` |
| teams | `https://teams.microsoft.com` | `teams.microsoft.com`, `microsoft.com`, `microsoftonline.com`, `office.com`, `live.com` |
| messenger | `https://www.messenger.com` | `messenger.com`, `facebook.com`, `fbcdn.net` |
| zalo | `https://chat.zalo.me` | `zalo.me`, `zdn.vn` |

`applicationNameForUserAgent` is `Version/<Safari version> Safari/605.1.15`, the same string Search sets in `Tab.swift`. Gmail and the other Google login steps need that string. A bare WebKit token gets the old page.

Each recipe has an unread script in the app bundle. It runs in a named `WKContentWorld`, on a `setInterval` of a few seconds, and posts `{ count }` through a `WKScriptMessageHandler`. The sidebar keeps the last count. A throw leaves that count as it was. The script will break when a site changes its DOM; it is the only place that knows that site’s markup.

## Rows

`~/Library/Application Support/Zinbox/services.json`

- id
- service id, from the table above
- display name
- data store UUID
- muted
- asleep
- last unread count
- order
- last focused row, once, on the file

One `WKWebsiteDataStore(forIdentifier:)` per row, created with the row and reused on the next launch. Removing a row calls `WKWebsiteDataStore.remove(forIdentifier:)` and that is the logout.

Two rows of Slack are two UUIDs. WebKit’s own process model stays as it is. The data store is the isolation boundary.

## Pages

One `WKWebView` per row that is not asleep. The view on screen is visible. The others stay in the same window, hidden. They are not removed, and they are not moved to a second window.

Every configuration sets `preferences.inactiveSchedulingPolicy = .none`. The default throttles a view that is not visible, which drops timers and the connection the unread count and the notification depend on.

While any row is awake, hold a `ProcessInfo` activity with `.userInitiated` so App Nap does not freeze the process when the window is hidden. Release it when every row is asleep, or on quit.

`applicationShouldTerminateAfterLastWindowClosed` returns false. Closing the window hides it and leaves the views inside it. A Dock click shows it again.

Launch shows the window, loads the last focused row, then starts the other awake rows a few hundred milliseconds apart. An asleep row creates no view.

Sleep releases that `WKWebView`. Loading `about:blank` is not enough: WebKit can keep the document in the back-forward cache. Wake builds a new view on the same data store. The last count remains. A slept row does not notify.

A crash is `webViewWebContentProcessDidTerminate` on that view. Reload it, with a short backoff.

Memory is part of the design. A heavy site is often 150–400 MB, and the nine can be a couple of gigabytes together. Sleep is how a row gives that back.

## Notifications

A user script replaces `window.Notification`, as Franz does in `references/franz/src/webview/notifications.js`. The constructor posts the title, body, and an id to native code. Native posts a `UNNotificationRequest` tagged with the row id. A click shows the window, selects that row, and runs the page’s `onclick` when the view is still there.

`permission` is `granted` after the user allows notifications for the app, and `default` before that. Ask once, the first time a service is added.

Mute does not post the request. It leaves the sidebar count. The Dock badge is the sum of counts on rows that are not muted.

The bridge runs only while the view exists. This version does not use Web Push.

## Navigation and files

`javaScriptCanOpenWindowsAutomatically` is false, so a popup needs a click.

`WKUIDelegate.createWebViewWith` builds a temporary view on the same data store. That is the sign-in window. Dismiss it when the site closes it.

A main-frame navigation to a host outside the recipe’s list opens in Safari and is cancelled. `mailto:` and other non-http schemes go to the system.

`runOpenPanel` presents the file picker. `WKDownloadDelegate` saves to `~/Downloads`. Camera and microphone use the permission delegates, with `com.apple.security.device.camera` and `com.apple.security.device.audio-input`. The call UI is the site’s.

Inspect Element uses the same developer-extras preference Search sets, on ⌥⌘I.

Messages accepted from the page are a count, or a notification title and body. The native side does not fetch a URL, open a path, or run a command because a page asked.

## Interface

Search’s palette and window, narrowed to an icon rail.

- Hidden title bar. Traffic lights in the top of the rail. That band drags the window. A double-click zooms it.
- Rail about 52 points. Icon, unread count, selected wash. Hover shows the name. A slept row is dimmed.
- The page has no toolbar and no address field. Reload is ⌘R and the row menu.
- Colors are light/dark pairs in `Design.swift`, taken from the window appearance. The app follows the system.
- Empty state: add a service.
- Row menu: reload, mute, sleep or wake, rename, remove.
- Keys: ⌘1–⌘9 select, ⌘R reload, ⌘, settings, ⌘S hide the rail, ⌥⌘I inspector.

Settings is a sheet with the notification permission status. The row list is edited from the rail.

## Files

`Sources/Zinbox/`, one type per file.

- `App.swift` — scene, commands, hide on close
- `Design.swift` — palette
- `Sidebar.swift` — the rail
- `Stage.swift` — the visible page; hidden pages stay mounted
- `Service.swift` — row, show, sleep, crash reload
- `Recipes.swift` — the nine services and their scripts
- `Page.swift` — web view, user agent, scheduling, user scripts
- `Shell.swift` — navigation, popups, open panel, downloads, capture
- `Notify.swift` — permission, banners, Dock badge
- `Store.swift` — `services.json`

## Build order

1. Window, rail, empty state, JSON store, add and remove a row.
2. One web view, its data store, the Safari user agent, reload, crash reload.
3. A second row of the same service. Two logins survive relaunch.
4. Hide on close, scheduling policy, activity token. A hidden row still runs its timer.
5. Unread script and sidebar count, starting with Slack.
6. Notification bridge, Dock badge, click focuses the row.
7. Sign-in popup, open panel, downloads, Safari for hosts outside the list.
8. Sleep releases the view. Wake comes back logged in.
9. The other eight services, each after a sign-in on this Mac. A service whose login fails in WebKit stays on the list and is fixed, or is pulled if it cannot be made to work.

## Done when

- Two rows of one site, two accounts, both signed in after quit and relaunch.
- A row that is not on screen updates its count and raises a notification.
- Hiding the window does not stop that.
- Sleep releases the web view. Wake is still logged in.
- A crash reloads that row only.
- The app makes no request to a server of ours.
