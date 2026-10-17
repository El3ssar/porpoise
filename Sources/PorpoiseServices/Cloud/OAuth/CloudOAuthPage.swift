import Foundation

/// The page the browser shows after signing in through the loopback: self-contained (no external resources, the app
/// icon inline), light or dark as the system is.
public enum CloudOAuthPage: Equatable, Sendable {
    /// Signed in: "You're signed in to Google Drive as me@example.com."
    case signedIn(provider: String, account: String)
    /// Sign-in didn't finish: the reason, in the app's words.
    case failed(provider: String, reason: String)
    /// The response arrived but Porpoise didn't say how it ended (cancelled, or the flow ended elsewhere).
    case received

    public var title: String {
        switch self {
        case .signedIn: return "Signed in"
        case .failed: return "Couldn’t sign in"
        case .received: return "Sign-in response received"
        }
    }

    public var html: String {
        let (heading, detail, mark): (String, String, String)
        switch self {
        case .signedIn(let provider, let account):
            heading = "You’re signed in to \(Self.escape(provider))"
            detail = "as <strong>\(Self.escape(account))</strong>. You can close this tab and go back to Porpoise."
            mark = "ok"
        case .failed(let provider, let reason):
            heading = "Couldn’t sign in to \(Self.escape(provider))"
            detail = "\(Self.escape(reason)) You can close this tab and try again in Porpoise."
            mark = "error"
        case .received:
            heading = "Sign-in response received"
            detail = "You can close this tab and go back to Porpoise."
            mark = "ok"
        }
        return """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark"><title>\(Self.escape(title)) · Porpoise</title>
            <style>
            :root { --bg: #f5f6f8; --card: #ffffff; --text: #1d1d1f; --quiet: #6e6e73; --ok: #248a3d; --error: #d70015; --line: #e3e4e8; }
            @media (prefers-color-scheme: dark) {
              :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --quiet: #a1a1a6; --ok: #30d158; --error: #ff453a; --line: #3a3a3c; }
            }
            * { box-sizing: border-box; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px; background: var(--bg); color: var(--text);
              font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
            main { width: 100%; max-width: 440px; background: var(--card); border: 1px solid var(--line); border-radius: 18px;
              padding: 36px 32px 32px; text-align: center; box-shadow: 0 12px 40px rgba(0,0,0,.08); }
            svg.icon { width: 96px; height: 96px; display: block; margin: 0 auto 18px; }
            .mark { display: inline-flex; align-items: center; justify-content: center; width: 26px; height: 26px; border-radius: 50%;
              color: #fff; font-weight: 700; font-size: 15px; margin-bottom: 10px; }
            .mark.ok { background: var(--ok); } .mark.error { background: var(--error); }
            h1 { font-size: 20px; font-weight: 600; margin: 0 0 6px; letter-spacing: -.01em; }
            p { margin: 0; color: var(--quiet); overflow-wrap: anywhere; } strong { color: var(--text); font-weight: 600; }
            </style></head>
            <body><main>
            \(Self.icon)
            <div class="mark \(mark)" aria-hidden="true">\(mark == "ok" ? "✓" : "!")</div>
            <h1>\(heading)</h1>
            <p>\(detail)</p>
            </main></body></html>
            """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Resources/AppIcon.svg, inline (a test keeps the two the same).
    static let icon = """
        <svg class="icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Porpoise">
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#6aaef5"/>
              <stop offset="1" stop-color="#2d6cc9"/>
            </linearGradient>
            <linearGradient id="front" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#ffffff"/>
              <stop offset="1" stop-color="#e3edf9"/>
            </linearGradient>
            <linearGradient id="shine" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#ffffff" stop-opacity=".22"/>
              <stop offset=".5" stop-color="#ffffff" stop-opacity="0"/>
            </linearGradient>
            <filter id="sh" x="-20%" y="-20%" width="140%" height="140%">
              <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#0b2f66" flood-opacity=".35"/>
            </filter>
          </defs>
          <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
          <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#shine)"/>
          <g filter="url(#sh)">
            <path d="M300 318 h150 c14 0 26 6 34 17 l30 41 h210 c22 0 40 18 40 40 v250 H260 V358 c0-22 18-40 40-40z" fill="#ffffff" fill-opacity=".62"/>
            <rect x="306" y="392" width="412" height="200" rx="18" fill="#ffffff" fill-opacity=".9"/>
            <path d="M286 448 h452 c26 0 46 21 44 47 l-18 214 c-2 22-20 39-42 39 H302 c-22 0-40-17-42-39 l-18-214 c-2-26 18-47 44-47z" fill="url(#front)"/>
            <rect x="452" y="500" width="120" height="16" rx="8" fill="#2d6cc9" fill-opacity=".28"/>
          </g>
        </svg>
        """
}
