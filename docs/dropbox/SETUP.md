# Register Dropbox for a Porpoise build

For the Porpoise maintainer/operator. Register one app for the distributed build; ordinary users authorize that app in their browser. Dropbox’s getting-started guide allows a [free Dropbox account](https://docs.dropboxapi.com/dropbox-api/docs/get-started/tutorial/overview). These steps use the App Console and Porpoise’s local callback; no hosted callback service is needed.

## Create and configure the app

1. Sign in at the [Dropbox App Console](https://www.dropbox.com/developers/apps), then choose **Create app**.
2. Select **Scoped access**, then **Full Dropbox**. Porpoise browses existing folders throughout the user’s account, so App folder access is insufficient. Choose a unique app name that follows Dropbox’s branding rules, then create the app. See the official [App Console walkthrough](https://docs.dropboxapi.com/dropbox-api/docs/get-started/tutorial/app-console) and [content-access explanation](https://docs.dropboxapi.com/dropbox-api/docs/oauth#content-access).
3. In **Permissions**, enable the following exact scopes and submit/save the changes:

   | Scope | Porpoise use |
   |---|---|
   | `account_info.read` | Account identity and namespace roots |
   | `files.metadata.read` | Browse, changes and search |
   | `files.metadata.write` | File/folder metadata operations |
   | `files.content.read` | Downloads, thumbnails and previews |
   | `files.content.write` | Uploads, file/folder mutations and conditional edit saves |
   | `sharing.read` | Shared files and folders |

   This list matches `DropboxConfiguration.scopes`. No team administrator scopes are requested. Dropbox explains the Permissions tab and scope selection in its [OAuth guide](https://docs.dropboxapi.com/dropbox-api/docs/oauth#scopes).
4. In **Settings → OAuth 2 → Redirect URIs**, add all three exact values below, including each port and path, with no trailing slash:

   ```text
   http://127.0.0.1:61843/oauth/callback
   http://127.0.0.1:61844/oauth/callback
   http://127.0.0.1:61845/oauth/callback
   ```

   Porpoise tries 61843, then 61844, then 61845 if the previous port is busy. The base port is `DropboxConfiguration.registeredLoopbackPort`. Dropbox [requires an exact registered redirect](https://docs.dropboxapi.com/dropbox-api/docs/oauth#implementing-code-flow); do not substitute `localhost`, HTTPS, a wildcard port, or a different path. The listener binds only the local Mac. If all three are occupied, sign-in shows which ports are in use and asks you to close other sign-in windows or apps using them before retrying. It never silently selects an unregistered port. Drive still uses an ephemeral port, and loopback test fixtures explicitly select port zero.
   The selected ports are in IANA’s [dynamic/private range](https://www.iana.org/assignments/service-names-port-numbers), not assigned service ports. They avoid [rclone’s documented 53682 OAuth listener](https://rclone.org/faq/). This does not guarantee another local app cannot use them; the two fallbacks handle collisions.
5. Porpoise uses **authorization code + PKCE S256** and requests `token_access_type=offline`. Copy only the **App key** from Settings. Do not copy, embed or distribute the App secret, and do not use a generated access token. PKCE is Dropbox’s recommended client flow when a desktop app cannot keep a secret. Leave **Allow public clients (Implicit Grant & PKCE)** set to **Allow**: that one switch also enables PKCE, so disallowing it breaks sign-in. See [PKCE and refresh tokens](https://docs.dropboxapi.com/dropbox-api/docs/oauth).

## Supply the public app key

Porpoise resolves the first nonblank value in this order:

1. `PORPOISE_DROPBOX_APP_KEY` in the app process environment.
2. **Porpoise Settings → Accounts → Sign-in configuration → Dropbox app key**.
3. `DropboxAppKey` in the app’s Info.plist.

Values are trimmed. Blank environment/Settings values allow the next source. Reopen Connect after changing the Settings field; no app restart is needed. Without a resolved key, the Dropbox tile stays **Coming soon** and cannot start sign-in. Its Settings field remains present so it can be configured.

To embed the public key in a local build:

```sh
PORPOISE_DROPBOX_APP_KEY='YOUR_PUBLIC_APP_KEY' scripts/make-app.sh
```

For the release workflow, configure repository Actions secret `DROPBOX_APP_KEY`; `release.yml` passes it as `PORPOISE_DROPBOX_APP_KEY`. Despite the Actions storage name, this is the public app key, never the App secret. An unconfigured release intentionally leaves Dropbox unavailable. User refresh credentials are stored separately through CredentialStores and never enter the bundle.

## Development and production status

New apps start in **Development**, initially usable by the owner. In Settings, **Enable additional users** permits testing with other accounts. Dropbox documents a 500-user development ceiling; once 50 users are linked, there is a two-week window to obtain production approval before further linking is frozen. This is not a promise that every development app can onboard 500 users indefinitely. See [Production approval](https://docs.dropboxapi.com/dropbox-api/docs/developer-resources/developer-guide#production-approval).

Before public rollout, complete Branding, app website and privacy information, then choose **Apply for Production** in the app’s Settings. Describe Porpoise’s file-manager behavior, requested scopes and Full Dropbox need, and provide its icon and requested review details. Standard review starts at 50 linked users; a justified **Request early review** is possible. Approval allows unrestricted user linking; approval timing is controlled by Dropbox. Follow the official [production application guidance](https://docs.dropboxapi.com/dropbox-api/docs/developer-resources/developer-guide#applying-for-production-status).

## Validation boundary

Automated tests use the fake Dropbox server and memory credentials only. This guide was checked against official documentation, not by registering or probing a real Dropbox account. App registration and any operator-approved real-account acceptance remain operator actions.
