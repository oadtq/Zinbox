# Plan

Check items off as they land. Product rules are in `product.md`. How it is built is in `architecture.md`.

## App shell

- [ ] Swift package, SwiftUI, language mode v5, macOS 14, no dependencies.
- [ ] One window. Hidden title bar. Icon rail and the open page. Empty state: “Add a service”.
- [ ] Light/dark pairs. System appearance.
- [ ] Close hides the window. The process stays up. Dock click shows it again.
- [ ] App icon, name, and About.
- [ ] ⌘1–⌘9 select a row. ⌘R reloads. ⌘, settings. ⌘S hides the rail. ⌥⌘I inspector.

## Services

- [ ] The nine: WhatsApp, Slack, Telegram, Discord, Gmail, Outlook, Teams, Messenger, Zalo. Name, start URL, host list, unread script, as in `architecture.md`.
- [ ] Add a row from that list. Optional display name.
- [ ] Reorder, rename, mute, remove.
- [ ] Sleep and wake from the row menu. Sleep releases the web view.
- [ ] `services.json` in Application Support.
- [ ] Each row has its own `WKWebsiteDataStore` UUID, reused on next launch.
- [ ] Removing a row deletes that data store.

## Page

- [ ] `WKWebView` in the content area.
- [ ] Safari user agent string from Search.
- [ ] `inactiveSchedulingPolicy = .none` on every service view.
- [ ] `ProcessInfo` activity while any row is awake.
- [ ] Load the start URL in that row’s data store.
- [ ] Unread script in its own `WKContentWorld`. Sidebar shows the count.
- [ ] Awake rows stay mounted. The one on screen is the visible one.
- [ ] Launch loads the last focused row first, then the other awake rows staggered.
- [ ] Sleep destroys the view, keeps the data store and the last count. Wake creates a new view on the same store.
- [ ] Reload. Crash reloads that view only, with backoff.
- [ ] Sign-in popups and `target=_blank` stay in-app, on the same data store.
- [ ] A host outside the recipe opens in Safari.
- [ ] Open panel for attachments. Downloads go to `~/Downloads`.
- [ ] Camera and microphone prompts.
- [ ] A page notification becomes a macOS notification and focuses that row on click.
- [ ] Mute skips the banner. Dock badge is the sum of unmuted counts.
- [ ] A slept row does not notify.

## Check before calling it done

- [ ] Two rows of the same site stay logged into different accounts.
- [ ] Quit and reopen. Both logins are still there.
- [ ] A background row updates its count and posts a notification while another row is on screen.
- [ ] Hide the window. That notification still arrives.
- [ ] A slept row has no web view, and wakes still logged in.
- [ ] A crash in one page leaves the app and the other rows up.
- [ ] No request to a server of ours.
