> **Superseded (2026-10-07):** the app was rewritten in AppKit with a Franz-style top tab bar. See README.md for the current feature set; the notes below describe the earlier SwiftUI rail version.

# Plan

Check items off as they land. Product rules are in `product.md`. How it is built is in `architecture.md`.

## App shell

- [x] Swift package, SwiftUI, language mode v5, macOS 14, no dependencies.
- [x] One window. Hidden title bar. Icon rail and the open page. Empty state: “Add a service”.
- [x] Light/dark pairs. System appearance.
- [x] Close hides the window. The process stays up. Dock click shows it again.
- [x] App icon, name, and About.
- [x] ⌘1–⌘9 select a row. ⌘R reloads. ⌘, settings. ⌘S hides the rail. ⌥⌘I inspector.

## Services

- [x] The nine: WhatsApp, Slack, Telegram, Discord, Gmail, Outlook, Teams, Messenger, Zalo. Name, start URL, host list, unread script, as in `architecture.md`.
- [x] Add a row from that list. Optional display name.
- [x] Reorder, rename, mute, remove.
- [x] Sleep and wake from the row menu. Sleep releases the web view.
- [x] `services.json` in Application Support.
- [x] Each row has its own `WKWebsiteDataStore` UUID, reused on next launch.
- [x] Removing a row deletes that data store.

## Page

- [x] `WKWebView` in the content area.
- [x] Safari user agent string from Search.
- [x] `inactiveSchedulingPolicy = .none` on every service view.
- [x] `ProcessInfo` activity while any row is awake.
- [x] Load the start URL in that row’s data store.
- [x] Unread script in its own `WKContentWorld`. Sidebar shows the count.
- [x] Awake rows stay mounted. The one on screen is the visible one.
- [x] Launch loads the last focused row first, then the other awake rows staggered.
- [x] Sleep destroys the view, keeps the data store and the last count. Wake creates a new view on the same store.
- [x] Reload. Crash reloads that view only, with backoff.
- [x] Sign-in popups and `target=_blank` stay in-app, on the same data store.
- [x] A host outside the recipe opens in Safari.
- [x] Open panel for attachments. Downloads go to `~/Downloads`.
- [x] Camera and microphone prompts.
- [x] A page notification becomes a macOS notification and focuses that row on click.
- [x] Mute skips the banner. Dock badge is the sum of unmuted counts.
- [x] A slept row does not notify.

## Check before calling it done

- [x] Two rows of the same site stay isolated (separate data stores, survive quit). Sign-in on this Mac still needed per account.
- [x] Quit and reopen. Rows, sleep, unread, and store UUIDs are still there.
- [x] A background row updates its count while another row is on screen.
- [ ] A page notification while another row is on screen, and while the window is hidden — allow notifications, then sign in and wait for a real message (or press Notify on a Probe row).
- [x] A slept row has no web view, keeps its last count, and wakes on the same store.
- [x] Crash reloads that view only, with backoff.
- [x] No request to a server of ours.
