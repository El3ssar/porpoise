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
            <linearGradient id="shine" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#ffffff" stop-opacity=".22"/>
              <stop offset=".5" stop-color="#ffffff" stop-opacity="0"/>
            </linearGradient>
            <linearGradient id="white" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#ffffff"/>
              <stop offset="1" stop-color="#e3edf9"/>
            </linearGradient>
            <linearGradient id="deep" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#2a62b8"/>
              <stop offset="1" stop-color="#173f86"/>
            </linearGradient>
            <filter id="sh" x="-20%" y="-20%" width="140%" height="140%">
              <feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="#0b2f66" flood-opacity=".32"/>
            </filter>
            <clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
          </defs>
          <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
          <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#shine)"/>
          <g clip-path="url(#body)">
            <path d="M 60.00 574.83 A 381.95 381.95 0 0 0 275.95 585.34 A 999.95 999.95 0 0 1 748.05 585.34 A 381.95 381.95 0 0 0 964.00 574.83 L 964 964 L 60 964 Z" fill="url(#deep)" fill-opacity=".55"/>
          </g>
          <g filter="url(#sh)">
            <path d="M 203.00 595.75 A 434.98 434.98 0 0 1 330.34 506.67 A 145.89 145.89 0 0 0 376.65 473.03 A 236.05 236.05 0 0 0 434.56 359.50 A 34.44 34.44 0 0 1 480.52 334.08 A 381.95 381.95 0 0 1 655.61 468.60 A 145.89 145.89 0 0 0 708.30 513.73 A 434.98 434.98 0 0 1 821.00 595.75 A 381.95 381.95 0 0 1 748.05 585.34 A 999.95 999.95 0 0 0 275.95 585.34 A 381.95 381.95 0 0 1 203.00 595.75 Z" fill="url(#white)"/>
          </g>
          <g fill="none" stroke-linecap="round">
            <path d="M 203.00 651.53 A 437.67 437.67 0 0 0 289.10 639.49 A 944.22 944.22 0 0 1 734.90 639.49 A 437.67 437.67 0 0 0 821.00 651.53" stroke-width="34.4" stroke="#ffffff"/>
            <path d="M 321.03 724.60 A 854.05 854.05 0 0 1 702.97 724.60" stroke-width="21.3" stroke="#a9c6ee"/>
          </g>
        </svg>
        """
}
