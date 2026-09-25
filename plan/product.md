# Product

macOS app. One window. The messaging sites you keep open, each with its own login, switched from a sidebar.

Native SwiftUI shell. System WebKit for the pages. No account of ours, no sync, no AI.

## Services

WhatsApp, Slack, Telegram, Discord, Gmail, Outlook, Teams, Messenger, Zalo.

Add a row from that list. Two accounts of one site are two rows, each with its own login. Sign in on the real site, inside the page. The login stays on this Mac.

## Window

A narrow icon rail and the open page. The page is the rest of the window.

Every row stays loaded, including the ones not on screen, so a new message can raise a macOS notification and update the unread count. Closing the window hides it. The app keeps running. Quit is what stops the pages.

Sleep is on the row’s menu. It releases that page, keeps the login and the last count, and that row stays quiet until you wake it.

Mute skips the banner. The count still shows. The Dock badge is the sum of unmuted counts.

Reload one row. If a page crashes, that row reloads on its own.

A sign-in window stays in the app, in that row’s login. A link that leaves the service opens in Safari. Attachments and downloads work.

Settings are a local file: name, order, mute, sleep. No server.

## Done when

You can add two accounts of one site, sign in to both, see counts, get a notification from a row that is not on screen, hide the window without quitting and still get it, quit, reopen, and still be logged in. A row you put to sleep uses no page until you wake it.
