# Franz architecture (reference)

The repo in `references/franz` is Franz 5.11.0. Franz 6 features in the README are not in this source.

Franz is an Electron shell. Each service is the official website in its own Chromium view. Franz does not use Slack, WhatsApp, or Gmail APIs.

## Pieces

- **Electron main** (`src/index.js`). Window, tray, one `BrowserView` per service.
- **React shell** (MobX). Sidebar and settings. The chat UI is not React. `ServiceView` only shows loaders and errors.
- **Franz API** (`api.franzinfra.com`). Account, service list (`/me/services`), recipe catalog, plan limits. Chat and cookies stay on disk.
- **Recipe.** Tarball from `/recipes/download/:id`, unpacked to `userData/recipes/<id>`. `package.json` has the URL. `webview.js` reads the page.
- **Session.** `persist:service-<id>` unless the recipe sets a shared partition. Two accounts do not share cookies.



## How a service opens

1. Shell sends the service list to main (`browserViewManager`).
2. Main creates a `BrowserView` for each enabled service in the workspace.
3. Preload is `src/webview/recipe.js`. It loads the recipe script inside the page.
4. The view loads the website. You log in there.
5. Every 2 seconds main sends `poll`. The script calls `setBadge`. The shell shows the count.
6. `window.Notification` is replaced and forwarded to the app.

Views are stacked with `setTopBrowserView`. Hidden ones stay loaded. JavaScript, sockets, and the poll keep running.

## What does not free memory

Hibernation sets `isHibernating` after 5 idle minutes. The view stays loaded. The poll continues.

Memory drops only when a service leaves the list: disabled, or in another workspace while “keep all workspaces loaded” is off. Those views are removed and killed with `forcefullyCrashRenderer()`.

## Security, for contrast

Service views run with `sandbox: false` and `contextIsolation: false`, so the recipe can `require()` and touch the DOM. The main window has `nodeIntegration`. Site isolation is disabled.

## Taken from this

- One live view per service, so the page can notify.
- One cookie jar per account (`persist:service-<id>`).
- A small per-site script that reads the unread count and calls `setBadge`.
- `window.Notification` replaced in the page and forwarded to the system (`src/webview/notifications.js`).
- The sidebar is the chrome. The site draws itself.

The service list in this repo is not ours. v1 is the nine in `architecture.md`.

Sleep, when the user chooses it, releases the view. Franz’s hibernate flag leaves the `BrowserView` loaded and does not free the memory. Node in the page, `sandbox: false`, and the Franz account API stay in Franz.

