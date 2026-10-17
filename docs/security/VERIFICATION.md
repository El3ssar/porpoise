# Google OAuth verification: checklist for Porpoise (W-74)

Porpoise asks for `openid email profile https://www.googleapis.com/auth/drive`
(`Sources/PorpoiseServices/Drive/DriveOAuth.swift:116`). `drive` is a **restricted** scope
(https://developers.google.com/workspace/drive/api/guides/api-specific-auth), so the app needs brand verification and
restricted-scope verification before more than 100 users can use it.

All official pages below were fetched on 2026-10-17. Points marked **(uncertain)** are not stated outright on any
official page.

## Where we stand today

- **Testing mode limits:**
  - An external app in **Testing** gets refresh tokens that expire after 7 days (https://developers.google.com/identity/protocols/oauth2).
  - An unverified app is capped at 100 new users in total (https://support.google.com/cloud/answer/7454865).
  - The CHANGELOG's "preview until Google's review" (eff9783) matches this.
- **Personal use:** an app used only by you or a few people you know personally needs no review
  (https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).
- **Timing:** brand verification "typically takes 2-3 business days". Restricted-scope review "can potentially take
  several weeks" (same page).

## Submission checklist

| # | Item | Requirement (source) | Our status / action |
|---|---|---|---|
| 1 | **Homepage** | Public, not behind login, clearly about the app; must link the privacy policy; on a verified domain you own (https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification, https://support.google.com/cloud/answer/13464321) | `docs/site/index.html` is published by `.github/workflows/pages.yml` at `https://el3ssar.github.io/porpoise/`. **Action:** add a Google Drive section and footer links to Privacy and Terms (the page doesn't mention Drive today) |
| 2 | **Domain** | Homepage and privacy policy on the same domain, verified in Google Search Console by a project Owner or Editor, and listed under Authorized domains (top private domain) (brand-verification page; https://support.google.com/cloud/answer/15549049) | **Recommended: a custom domain** (for example `porpoise.app`, if available, or similar). Point it at GitHub Pages (CNAME file + DNS) and verify it in Search Console with a DNS TXT record. **(uncertain)** Using `el3ssar.github.io` directly: `github.io` is on the Public Suffix List, so `el3ssar.github.io` can be verified as a URL-prefix property, but no Google page says it's acceptable, and developers report pushback on platform subdomains. A domain costs about USD 10–20/year and removes the risk. **Operator's decision** |
| 3 | **Privacy policy** | Same domain as the homepage, linked on the consent screen; discloses how the app "accesses, uses, stores, or shares Google user data"; complies with the User Data Policy, including Limited Use (brand-verification and restricted-scope pages) | Draft below, to publish as `/privacy/` |
| 4 | **Terms of service** | Link required for external production apps (https://support.google.com/cloud/answer/15549049) | Short page: the license (GPL), no warranty, and a link to Google's terms for Drive. Publish as `/terms/` |
| 5 | **App name** | Must not be confusable with Google's or other brands ("Google Drive for iOS" is the counter-example) (https://support.google.com/cloud/answer/15549049) | "Porpoise". Don't use "for Google Drive" in the name |
| 6 | **Logo** | Square 120×120 px; JPG, PNG or BMP; ≤ 1 MB; represents the app (same page). Submitting a logo triggers brand verification | Export `Resources/AppIcon.svg` as a 120×120 PNG. No Google marks in it. **(uncertain)** The trademark rule is explicit only for the name, but avoiding Google marks in the logo is the safe reading |
| 7 | **Support email** | Your Google account, a Google Group you manage, or a non-Gmail address that is a Google account with Owner/Editor on the project (same page) | Operator to choose, ideally a Google Group such as `porpoise-support@googlegroups.com` |
| 8 | **Developer contact** | Email(s) for Google's notices (same page) | Operator's email |
| 9 | **Scopes** | Least privilege; explain why narrower scopes don't work (restricted-scope page) | Justification below. `openid email profile` are non-sensitive and identify the account (`DriveAccountStore` keys accounts by `sub`) |
| 10 | **Demo video** | YouTube, **Unlisted**; English; shows the consent screen with the app name and the **client ID in the browser address bar**; demonstrates each sensitive or restricted scope's functionality; covers every OAuth client (restricted-scope page) | Script below |
| 11 | **Security assessment** | Required when the app stores or transmits restricted data on servers, or reaches it "from or through a third-party server" (restricted-scope page; Drive scopes page) | Porpoise has no server. See CASA-PREP.md: we should state this in the submission and expect, at most, a request to confirm it |
| 12 | **Limited Use disclosure** | Public statement, on the homepage or in the privacy policy (https://support.google.com/cloud/answer/13463817) | Included in the privacy policy draft and in the homepage footer |
| 13 | **OAuth client** | Desktop app client; loopback redirect and PKCE (https://developers.google.com/identity/protocols/oauth2/native-app) | Already done: `http://127.0.0.1:<ephemeral>/oauth/callback`, S256 (REVIEW.md, Done right). Keep **one** production client so the video covers it |
| 14 | **Accurate public docs** | Reviewers read the homepage and repository | Update `docs/drive/API.md` (it still says read-only) and make the site's license line match the repo (REVIEW I8) |
| 15 | **True to the code** | The policy must describe what the app actually does | Land fix **W-sec-2** (sign-out wipes everything, REVIEW L1) **before** publishing the policy's "Deleting your data" section, or soften that section |

## Scope justification (paste into the "How will the scopes be used?" field)

> Porpoise is an open-source file manager for macOS (like Finder). When a user connects their Google account, their
> Google Drive appears in Porpoise's sidebar as another location, next to their Mac's own folders. They browse My Drive,
> Shared with me and shared drives, and they copy, move, rename, upload, download, trash and organize files and
> folders anywhere in their Drive, with the same commands, drag and drop and keyboard shortcuts as local files. They
> can also keep chosen files or whole folders downloaded for offline use, and Porpoise keeps those copies in sync with
> Drive.
>
> This needs the `drive` scope:
> - `drive.file` only covers files the app created or the user opened with it one by one through the Picker. A file
>   manager must list every folder the user navigates into and show its existing contents, and it must work on files
>   created by other apps or other people (Shared with me, shared drives). It must also move or rename items it never
>   opened, and follow changes to kept folders through the Changes API. None of that is possible with `drive.file`,
>   and asking the user to pick each file in the Picker would defeat the purpose of a file manager.
> - `drive.readonly` is not enough, because the core actions (copy, move, rename, new folder, upload, trash) write to
>   Drive.
>
> All data stays on the user's Mac. Porpoise has no server: it talks directly to Google's APIs from the user's
> computer, and no Google user data is sent to us or to anyone else. Data is used only for the features above, which
> are visible in the app's interface, and is never used for advertising.

This fits Google's permitted categories for restricted Drive scopes. "Productivity and education: apps with a primary
user interface that might involve interaction with Drive files, metadata, or permissions" applies, and so does "Backup
and sync: platform-specific apps that provide local sync" for Keep Downloaded
(https://developers.google.com/workspace/drive/api/guides/api-specific-auth). Google doesn't name "file manager"
explicitly **(uncertain)**.

## Demo video script (about 4 minutes, English, unlisted on YouTube)

Record on a clean macOS user account with a test Google account (never the operator's real data), at 1080p or higher.
Turn on the "show clicks" option in the screen recorder.

1. **0:00 Intro (voice-over over the homepage).** "This is Porpoise, an open-source file manager for macOS. This video
   shows how Porpoise uses Google OAuth and the Google Drive scope."
2. **0:15 Sign-in.**
   - Open Settings › Accounts › Connect Google Drive.
   - The browser opens Google's consent screen. **Zoom in on the address bar** to show `client_id=<the production client
     ID>`, and say the client ID out loud or show it next to the Cloud Console's Clients page.
   - Show that the consent screen displays the app name **Porpoise** and the requested permissions.
   - Click Continue, and show the "You can return to Porpoise" page.
3. **0:50 Profile scopes.** Back in Porpoise, the account appears with its email and picture. "We use openid, email and
   profile only to identify the account and show which one is connected."
4. **1:05 Drive: browse.** Open My Drive from the sidebar, navigate into nested folders, open Shared with me and a shared
   drive. "Listing every folder the user opens needs the drive scope; drive.file could only see files created by
   Porpoise."
5. **1:40 Drive: change files.** Show each of these on screen:
   - copy a local file into Drive (upload);
   - copy a Drive file to the Mac (download);
   - create a folder;
   - rename an item;
   - move it between folders;
   - move it to Trash;
   - open a Google Doc in the browser.
6. **2:40 Offline.** Choose Keep Downloaded on a folder, show the badges change and open a file with the network off.
   Then Remove Download.
7. **3:15 Where data goes.** Show Activity or a statement: "Everything happens between this Mac and Google. Porpoise has
   no server. Files and tokens stay on this Mac; the sign-in token is in the macOS Keychain."
8. **3:35 Disconnect.** Settings › Accounts › Disconnect. "Disconnecting revokes Porpoise's access at Google and deletes
   the token and the offline copies from this Mac." Optionally show myaccount.google.com › Security › Third-party
   connections, where Porpoise is no longer listed.
9. **3:55 End.** Show the homepage URL and the privacy policy URL.

Don't edit out the consent screen. Keep the uncut sign-in sequence in a single take.

## Consent screen and branding fields (Google Auth Platform › Branding)

| Field | Value |
|---|---|
| App name | Porpoise |
| User support email | *operator: a Google Group or the project owner's address* |
| App logo | 120×120 PNG from `Resources/AppIcon.svg` |
| Application home page | `https://<domain>/` |
| Application privacy policy link | `https://<domain>/privacy/` |
| Application terms of service link | `https://<domain>/terms/` |
| Authorized domains | `<domain>` (and nothing else; the loopback redirect needs no domain) |
| Developer contact information | *operator's email* |
| Audience | External, then **Publish app** to move it out of Testing |
| Data access › Scopes | `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile`, `.../auth/drive`, with the justification above and the video link |

## Privacy policy draft (publish at `/privacy/`)

The draft is checked against the code at `eff9783`. The statements marked † become true once fix W-sec-2 lands (REVIEW
L1/L2).

> # Porpoise privacy policy
>
> *Last updated: <date>*
>
> Porpoise is an open-source file manager for macOS, published at <homepage> with its source code at
> https://github.com/El3ssar/porpoise. This policy explains what Porpoise does with your data, especially the data it
> receives from Google when you connect a Google account.
>
> ## The short version
> Porpoise runs entirely on your Mac. **We don't run any server, and we never receive your files, your Google data or
> anything about how you use Porpoise.** Porpoise has no analytics, tracking, advertising or crash reporting.
>
> ## Google user data
> When you choose **Connect Google Drive**, Porpoise asks Google for these permissions:
> - **Your email address, name and profile picture** (`openid`, `email`, `profile`): to tell your accounts apart and
>   show which account is connected.
> - **See, edit, create and delete your Google Drive files** (`drive`): to show your Drive in Porpoise and let you
>   browse, open, download, upload, copy, move, rename and trash files and folders, and keep the ones you choose
>   downloaded for offline use.
>
> **How it is used.** Porpoise uses this data only to provide those features, at your request and on your screen. It
> talks directly to Google's servers (`googleapis.com`, `accounts.google.com`, `oauth2.googleapis.com` and Google's
> image servers for thumbnails and your profile picture). Nothing is sent to us or to any third party.
>
> **What is stored on your Mac.**
> - The sign-in token is stored in your macOS Keychain, for this Mac only. It is never written to files, logs or
>   settings.
> - Your account's email, name, picture address and Google account ID are stored in Porpoise's settings.
> - File and folder information (names, sizes, dates, sharing details shown in Properties) is cached in
>   `~/Library/Application Support/Porpoise` to make browsing fast.
> - Copies of files you open, preview, edit or keep downloaded are stored there too. Folders are readable only by your
>   user account and are excluded from Time Machine where noted in the app.
> - Your profile picture is cached in `~/Library/Caches/Porpoise`.
>
> **Sharing.** Porpoise does not sell, rent, transfer or disclose Google user data to anyone. When you open a Drive file
> in another app, Porpoise gives that app a copy on your Mac, because you asked it to. No person reads your data: there
> is no one on our side who could.
>
> **Advertising.** Google user data is never used for advertising, and never to determine creditworthiness or for
> lending purposes.
>
> **Limited Use.** Porpoise's use of information received from Google APIs will adhere to the
> [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including
> the Limited Use requirements.
>
> ## Deleting your data
> - **Disconnect** the account in Porpoise › Settings › Accounts. Porpoise revokes its access at Google, then deletes
>   the token from the Keychain and all of that account's cached information, previews, edit copies, offline copies and
>   transfer records from your Mac.† Files you saved elsewhere on your Mac yourself are not touched.
> - You can also remove Porpoise's access at any time at https://myaccount.google.com/connections.
> - Deleting Porpoise and the folders above removes everything it stored.
>
> ## Other network connections
> - **Updates:** Porpoise checks `github.com` for new versions (the update feed). This request contains no personal
>   data beyond what any web request carries (your IP address, seen by GitHub), and you can turn automatic checks off
>   in Settings.
> - **Android support (optional):** if you ask Porpoise to install Android's platform tools, it downloads them from
>   `dl.google.com`.
> - **Other servers you connect to** (SFTP, FTP, network shares) are contacted only when you ask, with the credentials
>   you give. Passwords are kept in your Keychain.
>
> ## Security
> Connections to Google use HTTPS. Sign-in uses Google's recommended flow for desktop apps (a loopback redirect with
> PKCE). Report security problems privately as described in
> [SECURITY.md](https://github.com/El3ssar/porpoise/security/policy).
>
> ## Children
> Porpoise is a general-purpose tool and isn't directed at children under 13.
>
> ## Changes
> We'll update this page and its date when Porpoise's handling of data changes. The full history is in the repository.
>
> ## Contact
> <support email> · https://github.com/El3ssar/porpoise/issues

Notes for the operator before publishing:
- **Check the claims.** "You can turn automatic checks off" is backed by `Updates.automaticallyChecks`
  (`Sources/Porpoise/App/Updates.swift:25`); confirm the switch is visible in Settings. Verify "excluded from Time
  Machine" too: today it holds only for offline copies
  (`CloudOfflineStore.swift:279-282`), so either extend it or drop the phrase.
- **Fonts on the policy page.** The site loads Google Fonts (`docs/site/index.html:21-23`). Either self-host the fonts,
  so the page itself sends nothing to third parties, or add a line about it to the site section of the policy.
- **Update this page when the code changes.** Do it whenever a feature changes the data flow (for example, a second
  cloud provider).

## Homepage additions (minimum)

- **Drive section:** a short "Google Drive" section saying what the integration does, in the same words as the scope
  justification's first paragraph.
- **Footer:**
  - links: `Privacy` · `Terms` · `Source`;
  - the Limited Use sentence: "Porpoise's use of information received from Google APIs will adhere to the Google API
    Services User Data Policy, including the Limited Use requirements."
- **Accuracy:** the app name and logo must match the consent screen, and the license line must match the repository.
