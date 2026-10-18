# Register Box for a Porpoise build

For the Porpoise maintainer/operator. Register one Box OAuth 2.0 application for the distributed build; ordinary users
authorize it in their browser with their own Box account. A free Box account can create the application and nothing is
paid for. Porpoise signs in with the authorization code flow, a loopback callback on this Mac and PKCE S256. No hosted
callback service is needed.

Box differs from Dropbox and OneDrive here: its token endpoint requires the application's **client secret** for every
code exchange and refresh, desktop apps included
([OAuth 2.0 without SDKs](https://developer.box.com/guides/authentication/oauth2/without-sdk/)). The secret therefore
ships inside the app, as Google Drive's desktop client secret does. Anyone who downloads the app can read it, so it only
identifies the application. It protects no user data: each person's access still needs their own browser sign-in and
consent, and their tokens stay in their Keychain. Treat it like the other build keys: keep it out of the repository.

## Create and configure the application

1. Sign in to Box and open the [Developer Console](https://app.box.com/developers/console). Choose **New App**, then
   **User** (OAuth 2.0 user authentication) as the type, name it (for example "Porpoise"), and **Create**
   ([OAuth 2.0 setup](https://developer.box.com/guides/authentication/oauth2/oauth2-setup/)).
2. On **Configuration → OAuth 2.0 Redirect URIs**, add exactly:

   ```text
   http://127.0.0.1/oauth/callback
   ```

   Box lets a loopback redirect use any port as long as the scheme, host, path and query match, and allows `http` only
   for loopback addresses. Porpoise listens on a free ephemeral port, so this one entry covers every sign-in. Use
   `127.0.0.1`, not `localhost`: that is the address Porpoise listens on and sends as `redirect_uri`.
3. Under **Application Scopes**, check only **Read and write all files and folders stored in Box** (`root_readwrite`).
   It covers browsing, search, download, upload, edit save-back, moving to and restoring from the trash, and items
   others shared with the person (they appear in All Files once accepted). Leave every admin, user, group, webhook
   and enterprise scope unchecked.
4. Copy the **Client ID** and **Client Secret** from **Configuration → OAuth 2.0 Credentials**. Do not create JWT keys
   or a client-credentials grant; Porpoise doesn't use them.

Box enterprises can restrict which applications their users may authorize (Admin Console → Integrations → Platform
Apps Manager). Someone in such an enterprise sees an authorization error until their administrator enables Porpoise.
That approval, and any publishing to the Box App Center, are operator or customer actions outside this repository.

## Supply the client ID and secret

Porpoise resolves the first source that has a client ID and takes both values from that same source, so an ID is never
paired with another application's secret:

1. `PORPOISE_BOX_CLIENT_ID` and `PORPOISE_BOX_CLIENT_SECRET` in the app process environment (test instances only).
2. **Porpoise Settings → Accounts → Sign-in configuration → Box client ID** and **Box client secret** (a person's own
   application).
3. `BoxClientID` and `BoxClientSecret` in the app's Info.plist.

Values are trimmed. Without both values the Box tile stays **Coming soon**. To embed them in a local build, use
`PORPOISE_BOX_CLIENT_ID='…' PORPOISE_BOX_CLIENT_SECRET='…' scripts/make-app.sh`, or put the client ID on the first line
and the secret on the second of the git-ignored `.box-oauth` file. For releases, set the repository Actions secrets
`BOX_CLIENT_ID` and `BOX_CLIENT_SECRET`. `release.yml` passes them to `make-app.sh` and checks that the bundle carries
them. If they are unset, Box is unavailable in that release.

An account remembers the client ID it signed in with. Changing the configured application later doesn't break existing
accounts until they need to sign in again.

## What the engine does on the wire

- Sign-in: `https://account.box.com/api/oauth2/authorize` with `response_type=code`, `state`, `redirect_uri` and a PKCE
  challenge, then `https://api.box.com/oauth2/token` with the client ID and secret. Box refresh tokens are single use:
  each refresh's new one replaces the stored one. Signing out revokes the refresh token at
  `https://api.box.com/oauth2/revoke` (best effort) and forgets every credential and local copy here.
- Bearer tokens go only to `api.box.com` and `upload.box.com`. A download is a redirect from `/files/{id}/content` to a
  pre-authenticated `dl.boxcloud.com` URL. Porpoise reads the redirect without following it and fetches the bytes
  without the bearer. The events long poll uses Box's realtime server URL, also without the bearer. Download URLs are
  kept in memory only. Chunked upload session IDs are kept in the credential store, never in journals.
- Changes come from the user's event stream (`/events`, starting at `now`) and Box's long poll. Deleting moves items to
  Box's trash and Undo restores them; Box refuses a restore when the name is taken, so nothing is replaced.

## Validation boundary

Automated tests use `scripts/fake-box-server.py` and memory credentials only. This guide and the wire contracts were
checked against Box's developer documentation, not by registering an application or probing a real account.
Registration and any operator-approved real-account acceptance remain operator actions.
