# Google Drive, OneDrive and Dropbox: registering the apps

Folders signs in to each service as an app registered by its maker, so each
service needs a one-time registration. A build without a service's ids simply
doesn't offer that service.

| Build define | From |
| --- | --- |
| `FOLDERS_GOOGLE_CLIENT_ID` | Google Cloud console, "Desktop app" OAuth client |
| `FOLDERS_GOOGLE_CLIENT_SECRET` | the same client (Google needs it even with PKCE) |
| `FOLDERS_ONEDRIVE_CLIENT_ID` | Microsoft Entra app registration, "Application (client) ID" |
| `FOLDERS_DROPBOX_APP_KEY` | Dropbox App Console, "App key" (the app secret isn't used) |

None of these are confidential in an installed app (anyone can pull them out
of the binary, and the services know it), but keep them out of the repo all
the same: GitHub's secret scanning flags Google client secrets.

## How sign-in works

OAuth 2 with PKCE in the system browser, on every system. Folders listens on
this device for a moment and the browser comes back to it:

- Google Drive: `http://127.0.0.1:53682/` (Desktop clients accept any
  loopback port, so a busy port falls back to another).
- OneDrive: `http://localhost:53682/` (Microsoft ignores the port for
  localhost, so the same fallback works).
- Dropbox: `http://localhost:53682/` exactly; Dropbox only accepts the
  registered address. 53682 is rclone's port too; if rclone is signing in at
  that moment, Folders says so.

On Android the page opens in a Custom Tab over the app; once signed in, the
tab says it can be closed. The place is named after the account
("Google Drive (me@example.com)"); its tokens are kept with the place's other
secrets and renewed by themselves.

## Google Drive

1. In <https://console.cloud.google.com/> create a project (for example
   "Folders").
2. APIs & Services > Library: enable **Google Drive API**.
3. Google Auth Platform (the OAuth consent screen):
   - Branding: app name "Folders", support email, home page
     <https://www.folders.cyou>, privacy policy link, authorised domain
     `folders.cyou`.
   - Audience: **External**. While the app is in *Testing*, add your own
     account under Test users.
   - Data access: add the scope `https://www.googleapis.com/auth/drive`.
4. Clients > Create client > Application type **Desktop app**, name
   "Folders". Copy the client ID and client secret. There's no redirect URI to
   register for Desktop clients.

   The same Desktop client is used on Android: Google's Android client type
   can't come back to a browser page (it's meant for the Google Sign-In
   library, which would need a native plugin), while the loopback flow is
   allowed for Desktop clients.

**Verification.** `drive` is a *restricted* scope, because a file manager has
to see the whole Drive:

- In *Testing*, only the test users you list (up to 100) can sign in, and
  their sign-in expires after 7 days (Folders then asks to sign in again).
- *In production* but unverified: anyone can sign in after a "Google hasn't
  verified this app" warning, up to 100 users in total, and sign-ins don't
  expire after 7 days. Fine for yourself and a few people.
- Verified: brand verification, a privacy policy that covers Google user data,
  a demo video of the sign-in and of what the app does with Drive, and for a
  restricted scope a yearly **CASA security assessment** by a Google-approved
  assessor (paid, weeks of work).

`drive.file` (not restricted, no assessment) would not do: it only shows files
Folders created itself or that the user picked with Google's own picker, so
browsing My Drive would look empty. `drive.readonly` and the metadata scopes
are restricted too.

## OneDrive

1. In <https://entra.microsoft.com/> (or the Azure portal) go to App
   registrations > **New registration**.
   - Name: "Folders".
   - Supported account types: **Accounts in any organizational directory and
     personal Microsoft accounts**.
   - Redirect URI: platform **Public client/native (mobile & desktop)**,
     `http://localhost:53682/`.
2. API permissions > Add a permission > Microsoft Graph > **Delegated**:
   `Files.ReadWrite.All`, `User.Read`, `offline_access`. None of these needs
   an admin's consent, though some work or school organisations only let
   users approve apps from verified publishers, or none at all.
3. No client secret: Folders is a public client and uses PKCE. Copy the
   **Application (client) ID**.
4. Optional, for work and school accounts: Branding & properties > publisher
   verification, with a (free) Microsoft Cloud Partner Program ID. Without it
   the consent page shows "unverified", and some organisations refuse it.

## Dropbox

1. In <https://www.dropbox.com/developers/apps> choose **Create app** >
   **Scoped access** > **Full Dropbox**, and a name (it must be unique on
   Dropbox, for example "Folders file manager").
2. Settings > OAuth 2:
   - Redirect URIs: add exactly `http://localhost:53682/`.
   - Allow public clients (Implicit Grant & PKCE): **Allow**.
3. Permissions: tick `files.metadata.read`, `files.metadata.write`,
   `files.content.read`, `files.content.write` (`account_info.read` is on
   already) and press Submit. Changing them later means everyone signs in
   again.
4. Copy the **App key**.
5. A new app is in *Development*: up to 500 users can sign in. Apply for
   production from the same page when it's needed; Dropbox reviews the app.

## Giving the ids to a build

- **Android release APKs** (`python tool/build_release.py`): set the four as
  environment variables first, for example in PowerShell
  `$env:FOLDERS_DROPBOX_APP_KEY = '...'`. The script passes them to flutter
  through a temporary file (`build/cloud_defines.json`, deleted afterwards),
  never on the command line or in its output, and says which services are on.
- **Windows and Linux** (`.github/workflows/desktop-release.yml`): add them as
  repository secrets with the same names (Settings > Secrets and variables >
  Actions). Missing secrets just leave those services out.
- **macOS, `flutter run` and anything else**: keep a JSON file outside the
  repo, `{"FOLDERS_GOOGLE_CLIENT_ID": "...", ...}`, and pass
  `--dart-define-from-file=C:/path/to/cloud_ids.json`.

## Not tried yet

Everything above was built from the services' documentation and tested
against local fake servers that answer like them. Nothing has been tried
against the real Google Drive, OneDrive or Dropbox, so the first real sign-in
of each is the first real test.
