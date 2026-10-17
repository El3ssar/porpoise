# CASA preparation for Porpoise (W-74)

CASA (Cloud Application Security Assessment) is the security assessment Google requires for some apps that use
restricted scopes. It is built on OWASP ASVS with "no proprietary requirements" (https://appdefensealliance.dev/casa).
Porpoise is a **desktop app with no backend**: all user data stays on the Mac, and the only parties it talks to are
Google's APIs (for Drive) and GitHub (for updates). This document covers:
- whether CASA applies to us at all;
- what an assessor would ask, with our answers and evidence;
- which scans to run.

All official pages were fetched on 2026-10-17. Points marked **(uncertain)** are inferences.

## 1. Does CASA apply? Probably not, and here is why

Google ties the assessment to servers:
- "Every app that requests access to Google users' restricted data **and has the ability to access data from or
  through a third-party server** must go through a security assessment from Google-empanelled security assessors." Same
  page: "If you store or transmit restricted scope data on servers, then you need to complete a security assessment."
  (https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification, last
  updated 2026-08-19)
- "If you store restricted scope data on servers (or transmit), then you must go through a security assessment."
  (https://developers.google.com/workspace/drive/api/guides/api-specific-auth, last updated 2026-09-03)

Porpoise has no server. Restricted data flows only between Google and the user's Mac, and the code shows it:
- **Hosts.** The only Google hosts in `Sources` are `accounts.google.com`, `oauth2.googleapis.com`,
  `www.googleapis.com` and Google image hosts (`grep -rnoE 'https?://…' Sources`; REVIEW.md, TLS).
- **Other connections.** The only non-Google network uses are the Sparkle update feed on github.com
  (`scripts/make-app.sh:105`), the optional adb download from dl.google.com
  (`Sources/PorpoiseServices/Remote/AndroidTools.swift:7`), and servers the user connects to themselves.
- **No telemetry.** There is no analytics, crash-reporting or telemetry SDK. `Package.swift` has two dependencies,
  Sparkle and a vendored SwiftTerm, and `grep -rliE 'telemetry|analytics|sentry|firebase' Sources` finds nothing.
- **Loopback only.** Both local listeners bind 127.0.0.1 only (`DriveLoopback.swift:18`, `LocalFileServer.swift:37`).

**Caveat (uncertain).** No Google page says outright "client-only apps are exempt". Two pages state the assessment
without the server condition:
- the User Data Policy: "must pass an annual security assessment… depending on the API being accessed and number of
  user grants or users" (https://developers.google.com/terms/api-services-user-data-policy);
- the support article: "Applications requesting access to restricted scopes must undergo an annual security
  assessment" (https://support.google.com/cloud/answer/13465431).

**Plan:**
- State "no server; data stays on the device; no third-party server access" in the scope justification
  (VERIFICATION.md) and in any reply to Google's review email.
- If Google still sends a CASA notification, answer it with the quotes above and this document's evidence before
  engaging a lab.
- Be ready to do the assessment if Google insists.

## 2. If an assessment is required

**Lab and level**
- Google, not the developer, decides the level.
- CASA now names its levels AL1/AL2. Both are "Lab Tested - Lab Verified", and AL2 also tests deployment infrastructure
  and data storage (https://appdefensealliance.dev/casa/casa-tiering, last updated 2026-06-27). Google's FAQ still uses
  "Tier 2/Tier 3" (https://support.google.com/cloud/answer/13463817).
- The assessment is renewed at least every 12 months from the Letter of Assessment date (restricted-scope page).

**Who does it and what it costs**
- An authorized lab: https://www.appdefensealliance.org/certification/authorized-labs (ISO/IEC 17025 accredited). The
  list we fetched shows Bishop Fox, DEKRA, Eydle, Leviathan Security, NCC Group, Netsentries, NowSecure, Prescient
  Security, TAC Security and ValueMentor. It loads dynamically, so it may be incomplete.
- Google charges nothing; the lab does. No official price is published.

**Self-scan**
- Deprecated: "The CASA self scanning process is deprecated. For CASA compliance follow instructions provided in your
  notification. You can continue to use this process to check your application readiness"
  (https://appdefensealliance.dev/casa/tier-2/tier2-overview).
- The scans in section 4 are therefore **readiness evidence**, not a substitute.

## 3. Likely questions, our answers and evidence

The questions are ASVS-oriented. Line numbers are at `eff9783`; REVIEW.md has the details. A "Fix pending" item should
land before an assessment, so its answer can be a plain "yes".

| Area | Likely question | Our answer | Evidence |
|---|---|---|---|
| Architecture | Where is restricted data stored and processed? | Only on the user's Mac. No backend, no third-party processors | §1; `Package.swift` dependencies; no telemetry |
| Architecture | Data-flow diagram | Mac ⇄ Google APIs (HTTPS). Mac → github.com (update feed, no user data). Nothing else | Draw from §1 for the submission |
| V51 OAuth | Which flow? PKCE? state? | Authorization code with a loopback redirect, PKCE S256 and a random `state`, as Google's desktop guidance says (https://developers.google.com/identity/protocols/oauth2/native-app) | `DriveOAuth.swift:94-146`; `DriveLoopback.swift:18-92` |
| V51 OAuth | Is the client secret treated as confidential? | No. Desktop clients are public; the secret comes from CI secrets and is not in git | `make-app.sh:77-86`; `release.yml:128-131`; `.gitignore:9`; no history (`git log --all -- .google-oauth.json` is empty) |
| V3 Sessions/tokens | Where are tokens stored? | Refresh token in the macOS Keychain, `AfterFirstUnlockThisDeviceOnly`, not synced. Access token in memory only | `DriveOAuth.swift:37-62,151-179` |
| V3 | Revocation and sign-out | Disconnect deletes the local token, then calls `oauth2.googleapis.com/revoke` with a POST body | `DriveOAuth.swift:224-236`; `DriveAccountStore.swift:171-194` |
| V7 Logging | Are tokens or user data logged? | No. No log call mentions tokens or credentials; errors omit response bodies | `grep` over `Sources` (REVIEW, Done right); `DriveHTTP.swift:9-33` |
| V8 Data protection | Local storage protection | Offline copies, the metadata cache and journals use 0700 folders and 0600 files; offline copies are excluded from backups. FileVault is the OS layer | `CloudOfflineStore.swift:38-46,279-282`; `DriveMetadataCache.swift:110-112`; `DriveMutationJournal.swift:82-85`. **Fix pending:** REVIEW L9 (a few caches at 0644 under 0700 parents) |
| V8 | Deletion on sign-out / on request | Disconnect wipes the token, offline copies, the metadata cache, previews and the avatar. **Fix pending:** REVIEW L1/L2 (`Edits/`, journal and partials, upload-session items, the HTTP cache) | W-sec-2 acceptance test |
| V8 | Data retention | Cached data is kept until Disconnect, Remove Download or cache eviction (an LRU with a user-set limit) | `docs/design/CLOUD_OFFLINE.md`; Settings › Accounts |
| V9 Communications | TLS everywhere? Any ATS exceptions or pinning overrides? | HTTPS only; no `NSAppTransportSecurity` exceptions; no custom trust evaluation | `make-app.sh:88-118`; no `SecTrust`/`didReceive challenge` in `Sources` |
| V5 Input validation | Remote names, queries, paths | Drive IDs allowlisted; search text escaped; remote names validated (code points). **Fix pending:** REVIEW H1 (folder names when copying from Drive), L4 | `DriveModels.swift:122`; `DriveChanges.swift:87`; `RemoteParsing.isSafeName` |
| V12 Files | Path traversal, file serving | The media server serves only its folder: decodes, refuses `..`/NUL/`\`, resolves symlinks, checks the prefix; random secret path; 127.0.0.1 | `Escaping.swift:27-38`; `LocalFileServer.swift:27,37,177-191` |
| V13/V12 Local services | Local listeners | Two loopback-only listeners: OAuth callback (single use, 180 s, 8 KB cap) and media server (secret path, 16 KB head cap, 10 s head timeout). **Fix pending:** REVIEW L3/L8 timeouts and caps | as cited |
| V14 Config | Debug features in production? | **Fix pending:** REVIEW M4. The debug bridge is runtime-gated but compiled in; W-sec-3 compiles it out | `AppDelegate.swift:30` |
| V14 Build | Dependency management and integrity | Two Swift packages pinned; ffmpeg, fd and ripgrep SHA-256 pinned; updates EdDSA-signed. **Fix pending:** REVIEW L5 (adb) and M3 (helper built from source) | REVIEW, Dependencies |
| V14 Build | Code signing and hardened runtime | Hardened runtime is on. Self-signed, not notarized (REVIEW M1, an operator decision: Developer ID) | `Resources/Porpoise.entitlements`; `make-app.sh` |
| V1/V10 | Privileged components | A root helper with an XPC code-signing requirement, an admin check per request, an allowlisted argv and no shell. **Fix pending:** REVIEW H2, M2 | `Sources/PorpoiseHelper/main.swift`; `HelperRequests.swift`; SECURITY.md |
| Process | Vulnerability disclosure | GitHub private advisories; only the latest release is supported, and it auto-updates | `SECURITY.md` |
| Process | Secure SDLC | Every change runs CI: `swift format lint --strict`, the full test suite, a coverage gate ≥ 92 %. Releases are built by a public workflow, with `SHA256SUMS.txt` | `.github/workflows/ci.yml`, `release.yml` |
| Process | Incident response / breach notification | We hold no user data, so there is nothing we can leak. A vulnerability in the app is fixed and shipped through the signed update channel, and the advisory is published | SECURITY.md (add one sentence on response time) |

## 4. Readiness scans to run (and how)

Run these from a clean checkout. Keep the outputs under `artifacts/p5/security/scans/` as evidence. None of the tools
was installed on the review machine, and I didn't install them (review-only item), so nothing below has been run yet
except the secrets grep at the end.

1. **SAST, Semgrep** (supports Swift). CASA's old scanning guide used FluidAttacks and OWASP ZAP with configurations of
   CWEs mapped to ASVS 4.0. Other tools must show they cover those CWEs, plus OWASP Benchmark results
   (https://appdefensealliance.dev/casa/tier-2/ast-guide).
   ```sh
   brew install semgrep
   semgrep scan --config p/swift --config p/secrets --config p/owasp-top-ten --sarif -o semgrep.sarif Sources
   ```
2. **SAST, FluidAttacks scanner** (the tool CASA's guide uses; the "local" application type is supported). Follow the
   configuration from the CASA AST guide above, with `Sources/` as the target. Docker is required.
   **(uncertain)** The current image name and config keys are in the guide.
3. **Dependencies, OSV-Scanner** (reads `Package.resolved`):
   ```sh
   brew install osv-scanner
   osv-scanner scan source -r . --format markdown > osv.md
   ```
   OSV-Scanner doesn't see vendored or downloaded binaries, so check these by hand against https://osv.dev and NVD:
   - SwiftTerm: record its upstream commit first;
   - FFmpeg 8.0;
   - fd 10.5.0;
   - ripgrep 15.2.0.
4. **Secrets, gitleaks** over the full history:
   ```sh
   brew install gitleaks
   gitleaks git --redact -v . > gitleaks.txt
   ```
5. **DAST.** There is no web app or API of ours to scan. The only HTTP surfaces are the two loopback listeners. If an
   assessor wants DAST evidence, point OWASP ZAP at the media server while a test instance plays a preview:
   - get the base URL, with its secret, from a debug build;
   - run `zap-baseline.py -t http://127.0.0.1:<port>/<secret>/`;
   - add the unit tests for range parsing and traversal (`LocalFileServer` and `Escaping` tests) as evidence.
6. **Binary checks** on the release app:
   ```sh
   codesign -dvvv --entitlements - Porpoise.app    # hardened runtime flag, entitlements
   spctl -a -vv Porpoise.app                      # Gatekeeper verdict (will say rejected until Developer ID)
   strings Porpoise.app/Contents/MacOS/Porpoise | grep -i debugbridge   # should be empty after W-sec-3
   ```

**Already run (evidence).** A secrets search over all 649 commits of history, for Google OAuth client secrets
(`GOCSPX-`), API keys (`AIza…`), access tokens (`ya29.`), refresh tokens (`1//0…`), private-key headers and GitHub
tokens. It found nothing, test fixtures included:
```sh
git grep -nIE 'GOCSPX-[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}|1//0[0-9A-Za-z_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{36}' $(git rev-list --all)
# → no output
git log --all --format=%H -- .google-oauth.json | wc -l
# → 0
```

## 5. Before any assessment

Land W-sec-1 to W-sec-3 from REVIEW.md, so every "Fix pending" row above becomes a plain yes. Then run section 4, keep
the outputs, and attach this document's table, with fresh line numbers, to the questionnaire.
