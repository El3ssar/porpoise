# Register OneDrive for a Porpoise build

For the Porpoise maintainer/operator. Register one Microsoft Entra application for the distributed build; ordinary users
authorize it in their browser with a personal Microsoft account or a work or school account. Porpoise is a **public
client**: authorization code with PKCE S256, no client secret, and a loopback callback on this Mac. No hosted callback
service is needed.

## Create and configure the application

1. Get a Microsoft Entra tenant. Microsoft no longer lets an application be registered outside a directory: a
   personal Microsoft account needs a tenant first ([Create a Microsoft Entra tenant](https://learn.microsoft.com/entra/identity-platform/quickstart-create-new-tenant)).
   - If the account already has one (through Microsoft 365 or Azure), sign in to the
     [Microsoft Entra admin center](https://entra.microsoft.com): the tenant's name shows under your account name.
   - Otherwise create a [free Azure account](https://azure.microsoft.com/pricing/purchase-options/azure-account), which
     comes with a tenant on the Entra ID Free tier. Registering an application and signing users in to it cost
     nothing, and Porpoise uses no paid Azure resource. Sign-up verifies identity by phone and card; whether that is
     acceptable is the operator's decision.
   Then open **Entra ID → App registrations → New registration**, and name the application (for example "Porpoise").
2. Choose **Accounts in any organizational directory and personal Microsoft accounts** (sign-in audience
   `AzureADandPersonalMicrosoftAccount`). Porpoise signs in through the `common` endpoint, so both kinds of account work.
3. Add the redirect URI under the **Mobile and desktop applications** platform:

   ```text
   http://127.0.0.1/oauth/callback
   ```

   Microsoft ignores the port of a loopback redirect, so Porpoise listens on a free ephemeral port and the one
   registration covers it; the path must match exactly. The portal's text box refuses `http` loopback URIs: add it in the
   application **Manifest**, in `replyUrlsWithType`, as `{"url": "http://127.0.0.1/oauth/callback", "type":
   "InstalledClient"}`. See [Redirect URI restrictions](https://learn.microsoft.com/entra/identity-platform/reply-url#localhost-exceptions).
   Register one loopback URI only: Microsoft picks one arbitrarily when several differ only by port.
4. Under **API permissions → Microsoft Graph → Delegated**, add exactly:

   | Permission | Porpoise use |
   |---|---|
   | `offline_access` | A refresh token, so the account stays signed in |
   | `User.Read` | The person's identity (same-account checks) |
   | `Files.ReadWrite.All` | Browse, search, download, upload, edit save-back, and items others shared |

   This list matches `OneDriveConfiguration.scopes`. `Files.ReadWrite.All` (not `Files.ReadWrite`) is what reaches
   shared items and share links. No application permissions and no admin-only permissions are requested.
5. Do not create a client secret or certificate. Copy only the **Application (client) ID** from Overview.

Work or school accounts in organizations that restrict user consent see "Need admin approval" until an administrator
consents, or until the application has a verified publisher. Publisher verification is an operator action and is
outside this repository.

## Supply the public application ID

Porpoise resolves the first nonblank value in this order:

1. `PORPOISE_ONEDRIVE_CLIENT_ID` in the app process environment (test instances only).
2. **Porpoise Settings → Accounts → Sign-in configuration → OneDrive application (client) ID**.
3. `OneDriveClientID` in the app's Info.plist.

Values are trimmed. Without a resolved ID the OneDrive tile stays **Coming soon**. To embed the ID in a local build,
use `PORPOISE_ONEDRIVE_CLIENT_ID='…' scripts/make-app.sh` or the git-ignored `.onedrive-client-id` file. For releases,
set the repository Actions secret `ONEDRIVE_CLIENT_ID`; `release.yml` passes it as `PORPOISE_ONEDRIVE_CLIENT_ID` and
checks that the bundle carries it. It is the public application ID, never a secret value. An unset secret leaves
OneDrive unavailable in that release.

## What the engine does on the wire

- Sign-in: `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` and `/token`, `prompt=select_account`,
  `response_mode=query`. Microsoft rotates refresh tokens; each new one replaces the stored one. Signing out forgets all
  credentials here. Microsoft offers a public client no single-token revocation (`revokeSignInSessions` would sign the
  person out of every device), so none is sent.
- Bearer tokens go to `graph.microsoft.com` only, including Graph's own paging and delta links (a link on another host
  is refused). Download URLs (`@microsoft.graph.downloadUrl`), upload-session URLs, copy monitors and thumbnail URLs are
  pre-authenticated and are requested without the bearer. Download URLs are kept in memory only; upload-session URLs
  are kept in the credential store, never in journals.

## Validation boundary

Automated tests use `scripts/fake-graph-server.py` and memory credentials only. This guide and the wire contracts were
checked against Microsoft's documentation, not by registering an application or probing a real account. Registration
and any operator-approved real-account acceptance remain operator actions.
