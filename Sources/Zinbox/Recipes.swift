import AppKit

// The services Zinbox knows by name. A recipe is a start page, the hosts that
// belong to it, a brand colour for the fallback icon, and an optional script
// that reads the unread count from the page. Anything else is a custom URL.

struct Recipe: Identifiable {
    let id: String
    let name: String
    let url: URL
    /// Hosts that belong to the service. Subdomains count.
    let hosts: [String]
    let tint: NSColor
    /// JS function body returning a number. Empty: read "(3)" from the title.
    let unread: String
    /// Teams is built for Chrome and scrolls poorly in WebKit.
    var engine: Engine = .webkit

    var isCustom: Bool { id == Recipes.customID }
}

enum Recipes {
    static let customID = "custom"

    static func named(_ id: String) -> Recipe? {
        id == customID ? custom : all.first { $0.id == id }
    }

    static let custom = Recipe(
        id: customID, name: "Custom website", url: URL(string: "https://example.com")!,
        hosts: [], tint: NSColor(white: 0.45, alpha: 1), unread: ""
    )

    static let all: [Recipe] = [
        Recipe(id: "whatsapp", name: "WhatsApp", url: URL(string: "https://web.whatsapp.com/")!,
               hosts: ["whatsapp.com", "whatsapp.net"], tint: rgb(0x25D366), unread: whatsapp),
        Recipe(id: "messenger", name: "Messenger", url: URL(string: "https://www.messenger.com/")!,
               hosts: ["messenger.com", "facebook.com", "fbcdn.net", "fbsbx.com"], tint: rgb(0x0084FF), unread: messenger),
        Recipe(id: "telegram", name: "Telegram", url: URL(string: "https://web.telegram.org/a/")!,
               hosts: ["telegram.org", "t.me"], tint: rgb(0x229ED9), unread: telegram),
        Recipe(id: "slack", name: "Slack", url: URL(string: "https://app.slack.com/client")!,
               hosts: ["slack.com", "slack-edge.com", "slack-files.com"], tint: rgb(0x4A154B), unread: slack),
        Recipe(id: "discord", name: "Discord", url: URL(string: "https://discord.com/app")!,
               hosts: ["discord.com", "discordapp.com", "discord.gg"], tint: rgb(0x5865F2), unread: discord),
        Recipe(id: "teams", name: "Microsoft Teams", url: URL(string: "https://teams.microsoft.com/")!,
               hosts: ["teams.microsoft.com", "teams.live.com", "microsoft.com", "microsoftonline.com", "office.com", "live.com", "skype.com", "sharepoint.com", "teams.cloud.microsoft", "cloud.microsoft"],
               tint: rgb(0x5B5FC7), unread: teams, engine: .chromium),
        Recipe(id: "gmail", name: "Gmail", url: URL(string: "https://mail.google.com/mail/u/0/")!,
               hosts: ["mail.google.com", "accounts.google.com"], tint: rgb(0xEA4335), unread: gmail),
        Recipe(id: "googlechat", name: "Google Chat", url: URL(string: "https://chat.google.com/")!,
               hosts: ["chat.google.com", "mail.google.com", "accounts.google.com"], tint: rgb(0x00AC47), unread: ""),
        Recipe(id: "outlook", name: "Outlook", url: URL(string: "https://outlook.office.com/mail/")!,
               hosts: ["outlook.office.com", "outlook.office365.com", "outlook.live.com", "office.com", "live.com", "microsoftonline.com", "outlook.cloud.microsoft", "cloud.microsoft"],
               tint: rgb(0x0078D4), unread: outlook),
        Recipe(id: "zalo", name: "Zalo", url: URL(string: "https://chat.zalo.me/")!,
               hosts: ["zalo.me", "zdn.vn", "zaloapp.com"], tint: rgb(0x0068FF), unread: zalo),
        Recipe(id: "linkedin", name: "LinkedIn", url: URL(string: "https://www.linkedin.com/messaging/")!,
               hosts: ["linkedin.com", "licdn.com"], tint: rgb(0x0A66C2), unread: linkedin),
        Recipe(id: "instagram", name: "Instagram", url: URL(string: "https://www.instagram.com/direct/inbox/")!,
               hosts: ["instagram.com", "cdninstagram.com", "facebook.com"], tint: rgb(0xE1306C), unread: ""),
    ]

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // MARK: - Unread readers
    //
    // Each returns a number, or 0 to fall back on the "(n)" in the page title.

    private static let whatsapp = """
      let n = 0;
      document.querySelectorAll('#pane-side [aria-label*="unread message"], #pane-side span[aria-label*="unread"]').forEach(function (el) {
        const v = parseInt((el.textContent || '').replace(/\\D/g, ''), 10);
        const row = el.closest('[role="listitem"], [role="row"]');
        if (row && row.querySelector('[data-icon="muted"]')) return;
        n += isNaN(v) ? 1 : v;
      });
      return n;
    """

    private static let messenger = """
      let n = 0;
      document.querySelectorAll('[role="navigation"] [aria-label*="unread" i], [data-testid="mwthreadlist-item"] [aria-label*="unread" i]').forEach(function () { n += 1; });
      return n;
    """

    private static let telegram = """
      let n = 0;
      document.querySelectorAll('.chat-list .ListItem .ChatBadge:not(.muted), .chatlist .rp:not(.is-muted) .unread').forEach(function (el) {
        const v = parseInt((el.textContent || '').replace(/\\D/g, ''), 10);
        if (!isNaN(v)) n += v;
      });
      return n;
    """

    private static let slack = """
      let n = 0;
      document.querySelectorAll('.p-channel_sidebar__badge, .c-mention_badge').forEach(function (el) {
        const v = parseInt((el.textContent || '').replace(/\\D/g, ''), 10);
        n += isNaN(v) ? 1 : v;
      });
      return n;
    """

    private static let discord = """
      let n = 0;
      document.querySelectorAll('[data-list-id="guildsnav"] [class*="numberBadge"]').forEach(function (el) {
        const v = parseInt((el.textContent || '').replace(/\\D/g, ''), 10);
        n += isNaN(v) ? 1 : v;
      });
      return n;
    """

    private static let teams = """
      let n = 0;
      document.querySelectorAll('[data-tid="app-bar-wrapper"] .fui-Badge, [data-tid="app-bar"] .fui-Badge, .activity-badge').forEach(function (el) {
        const v = parseInt((el.textContent || '').replace(/\\D/g, ''), 10);
        if (!isNaN(v)) n += v;
      });
      return n;
    """

    private static let gmail = """
      const inbox = document.querySelector('a[href$="#inbox"]');
      if (inbox) {
        const label = inbox.getAttribute('aria-label') || inbox.textContent || '';
        const m = label.match(/(\\d[\\d.,]*)/);
        if (m) return parseInt(m[1].replace(/[.,]/g, ''), 10) || 0;
      }
      const t = document.title.match(/\\((\\d[\\d.,]*)\\)/);
      return t ? parseInt(t[1].replace(/[.,]/g, ''), 10) : 0;
    """

    private static let outlook = """
      const inbox = document.querySelector('[data-folder-name="inbox"] [data-unread-count], div[title^="Inbox"] span[class*="unread" i]');
      if (inbox) {
        const v = parseInt(inbox.getAttribute('data-unread-count') || inbox.textContent, 10);
        if (!isNaN(v)) return v;
      }
      return 0;
    """

    private static let zalo = """
      const badge = document.querySelector('[data-translate-title="STR_TAB_MESSAGE"] [class*="unread"], #main-tab .tab-unread');
      if (badge) {
        const v = parseInt((badge.textContent || '').replace(/\\D/g, ''), 10);
        return isNaN(v) ? 1 : v;
      }
      return 0;
    """

    private static let linkedin = """
      const el = document.querySelector('#global-nav a[href*="/messaging/"] .notification-badge__count, a[href*="/messaging/"] .notification-badge__count');
      if (el) {
        const v = parseInt((el.textContent || '').replace(/\\D/g, ''), 10);
        return isNaN(v) ? 0 : v;
      }
      return 0;
    """
}
