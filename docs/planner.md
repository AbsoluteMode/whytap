# Whytap Planner

Open **Search all tools → To-do** for a compact list inside hover.
**Calendar** opens today’s agenda inside Hover, with a visible **Connect** button.
The tools can also be added from Settings → Toolbox; adding this
feature does not change existing saved tool layouts or positional shortcuts.

## Tasks and Whytap events

In hover, type a task and press Return. Click a row to complete or reopen it.
Completed rows move below active tasks for this opening; reopening To-do hides
them from the active list. **History** shows completed tasks with their local
completion date and time; click one to reopen it. Older completed tasks show
“Completion time unknown”. Hover a truncated row to read its full native tooltip.
The draft survives closing the panel. Whitespace-only input does not block restore
or update restart. Escape or a click outside dismisses it;
Back returns to tools. Like other inline tools, To-do follows Hover visibility and
meeting/agent priority: temporarily unavailable Hover does not open a second window,
and interrupted input is retained for the next opening. Existing local tasks and
Whytap events retain their archive format. This change does not delete local
content or existing calendar connections. The former Planner editor remains an
internal compatibility surface; normal Calendar entry points no longer open it.

## Adding tasks from agents and scripts

Coding agents and scripts add tasks with the helper inside the installed app,
without restarting Whytap:

```sh
/Applications/Whytap.app/Contents/Helpers/whytap todo add "Send the deck to Anna" "Book the review"
printf '%s\n' "First task" "Second task" | /Applications/Whytap.app/Contents/Helpers/whytap todo add -
/Applications/Whytap.app/Contents/Helpers/whytap todo list          # active tasks
/Applications/Whytap.app/Contents/Helpers/whytap todo list --all    # with completed
```

Each call prints one JSON object. Exit code 0 means the tasks are saved:
`delivery` is `app` when the running Whytap saved them (they appear in To-do at
once) or `file` when Whytap was closed and the helper wrote the planner file
(they appear on the next launch). `tasks` lists each title with its ID and
`added` or `existing`. An active task with the same title is not duplicated,
so retrying is safe. One batch takes 1–100 tasks of 1–500 characters each;
line breaks inside a task become spaces, and one invalid task rejects the whole
batch (exit 2). Exit 1 reports `code`/`message`: `unconfirmed` (check with
`todo list`, then retry), `planner_unreadable` (the file is left unchanged),
`unknown_operation` (the running Whytap predates this command; update it).
The helper never launches Whytap. `open whytap://tool/tasks` shows the list.

MCP hosts get the same operations as `whytap_todo_add` / `whytap_todo_list`
from `whytap app mcp` (see `docs/customization/app-control.md`), so an agent can
split a meeting note into tasks on any Mac with Whytap installed. Meeting notes
are local Markdown files in Application Support/Sidekey/Meetings.

The local planner is stored privately in Application Support/Sidekey/Planner.
Changes persist atomically before appearing in the interface. A newer file
saved by the helper or another local writer is adopted before every save and
shown as soon as the folder changes; it is never overwritten. Unreadable or
unsupported archives block writes and retain the original file; Retry loads a
restored file. A failed save keeps the editor/draft and reports an error.
Local tasks and events are not uploaded by calendar connections.
Encrypted backups include the Planner archive, calendar account settings and saved
OAuth credentials. The local content has its own To-do & calendar archive section;
connection metadata travels with settings and sign-in travels with credentials.
Token rotation alone does not create settings versions or full archive uploads;
the next ordinary or manual backup captures the current refresh token. A restored
calendar connection can ask you to sign in again if its saved token has expired
or been replaced by the provider.
Restore keeps the previous local archive for rollback. Archives from before
Planner support preserve connections already configured on the target Mac.

## Unified calendar

Calendar opens on **today** inside Hover. The header’s **Connect** opens provider
selection and the same connection flow used by Settings → Integrations. It does
not create a Whytap account. Previous/next day and Today stay in the panel;
opening Calendar again always returns to today. Click an event for full details
inside Hover. A meeting/original link opens only when explicitly clicked.

**Calendars** chooses which local/connected feeds are shown. Account removal is
in Settings → Integrations. Event times use the Mac’s current time zone. Matching
external iCalendar UIDs with identical occurrence bounds collapse into one agenda
item; unrelated events are never merged by title. Events spanning midnight and
all-day events appear on each applicable day with an exclusive end boundary.

Events are read-only in Hover. Whytap fetches the selected day on opening, day
changes, account changes, Refresh, and every minute while visible. Native
calendar-change notifications update EventKit feeds. Errors retain the last
loaded data and offer connection details through Calendars. Closing Hover stops
polling; there is no background sync or persistent external-event cache.

The explicitly opened panel survives pointer exit; Escape/outside click closes
it. During provider authorization the panel stays open so clicking the browser
or macOS prompt does not cancel the connection. Meeting/agent priority may
hide Hover, while the connection continues. Opening Calendar again resumes the
active connection; completion activates Hover only if it is visible. Failures
retain a retry path. Connections begun in Settings do not pin Hover.
Explicit Cancel/Back cancels the operation.
A visible Calendar defers restore and update restart; ordinary backups still run.
Disconnect removes local credentials/events, keeping the original provider data.

**Apple Calendar:** Connect account → Apple Calendar requests the macOS calendar
permission. It shows the calendars available through EventKit, including iCloud.
macOS requires full event permission even for reading; Whytap only reads.
This connection does not require a Whytap backend or a new Apple OAuth client.
When the same Google/Exchange account is also available through macOS, use the
feed checkboxes to select the desired source. UID-based collapse cannot identify
copies for which the providers return unrelated identifiers.

**Google:** connects directly to Google Calendar API using a Desktop OAuth
client, `https://www.googleapis.com/auth/calendar.calendarlist.readonly` and
`https://www.googleapis.com/auth/calendar.events.readonly`. These only allow
listing subscribed calendars and reading events; calendar settings and sharing
permissions are not requested.

**Outlook and Teams:** connects directly to Microsoft Graph calendars using
delegated `Calendars.Read` and `offline_access`. Teams meeting links come from
the Outlook event's `onlineMeeting.joinUrl`; this is not a separate Teams chat or
meeting-bot integration. Organizational policies can require administrator consent.

**Zoom:** connects directly to **Zoom Calendar Service**, using
`calendar:read:list_calendar_lists` and `calendar:read:list_events`. This requires
that service and API permissions on the account. It is not a replacement for the
Zoom Meetings API: a Zoom client merely displaying a linked Google or Microsoft
calendar should connect that calendar's provider here. Zoom links on events from
any supported source remain joinable.

## OAuth app registration

Settings → **Integrations** lists **Google Calendar**, **Outlook Calendar**,
**Apple Calendar** and **Zoom Calendar** with separate permission descriptions,
account controls and direct provider authorization. Google and Zoom show
their pending review/publication state and do not start new shared-client sign-in
before public approval. Existing accounts can still be disconnected. Hover keeps
feed selection and its compact source list; Connect starts the provider browser
or macOS prompt directly, without an intermediate form or account-name field. Repeated accounts receive
distinct provider-based names automatically.

Use **Whytap** as the application name and public consent-screen brand.

The application owner registers native OAuth clients once. Packaged client
configuration is loaded from WhytapCalendarOAuthClients in the app Info.plist;
ordinary users choose an account in the provider browser and sign in. Source
users supply their own client at build time. A build without a registered client
shows an inline unavailable reason; it does not open an app-setup form or pretend
to have a working shared sign-in.
Live consent, organizational restrictions and provider-account compatibility
require acceptance with real accounts. Fixture tests do not prove live sign-in.
Provider registration and public verification remain separate external steps.
For shared Google and Zoom clients, `publicAccessApproved` must be the string
`"true"` in the private native-client packaging configuration after actual
approval. An absent, false or malformed value keeps new sign-in blocked in both
Integrations and Hover. Microsoft does not use this Google/Zoom review gate;
its organizational restrictions still apply. Source users can supply an
independent native client at build time.

Public integration information is available at
[whytap.ai/planner](https://whytap.ai/planner/), with a separate
[calendar privacy notice](https://whytap.ai/calendar-privacy/) linked from the
Integrations settings. The pages describe the feature as being prepared and do not
claim provider approval or a generally available release.

1. **Google Cloud:** enable Calendar API, configure the consent screen and create
   a **Desktop app** OAuth client. Add the account as a test user while the app is
   in testing. Enter the client ID and generated desktop client secret when
   required by Google. The desktop client uses a dynamically assigned
   `http://127.0.0.1:<port>/callback` redirect. Public distribution may require
   Google's OAuth verification. The shared Whytap registration is intended for
   public use: testing is a preparation stage, not a personal-only integration.
   Before submitting for verification, publish an accurate app homepage and
   calendar privacy notice on a verified domain, declare the two read scopes,
   and record the real browser-consent and in-app calendar flow for reviewers.
   A client ID alone does not mean that public access has been approved.
2. **Microsoft Entra:** register a public native app with the appropriate account
   audience and delegated `Calendars.Read` and `offline_access`. Register
   **Mobile and desktop applications → http://localhost/callback**. Whytap uses
   an ephemeral port; Microsoft's documented localhost exception ignores it.
   Leave **Allow public client flows** disabled: this browser-based authorization
   code flow uses PKCE and the native redirect type. The additional toggle is for
   flows such as device code and direct username/password authentication, which
   Whytap does not use.
   No client secret is embedded or required.
3. **Zoom Marketplace:** create a user-managed General app and enable **Use public
   client OAuth**. Set **PKCE OAuth Redirect URL** and **OAuth allow lists** to
   `http://127.0.0.1/callback`. This is separate from the ordinary confidential
   **OAuth redirect URL**, which rejects loopback URLs. Enable the two granular
   read scopes above and use the **Public client ID**, not the confidential
   Client ID or client secret. Development and Production have separate public
   IDs and PKCE configuration; configure the intended environment. Explain that
   the native app uses S256 PKCE and a temporary loopback listener with an
   ephemeral port. A public distribution requires Zoom's review. No confidential
   client secret is embedded or required.

Authorization opens the default browser; a temporary receiver binds only
127.0.0.1. Microsoft uses a localhost redirect, with that same numeric listener.
State validation, S256 PKCE, a three-minute timeout, cancellation, bounded request
sizes and listener cleanup apply. Account tokens and the configuration used for each connected account are
stored in the login Keychain under the existing channel's service. Short-lived
access tokens stay in memory and are excluded from backup. An access-only refresh
does not create a settings version or request a full backup; rotated refresh
tokens are persisted before an API call resumes. Disconnect cancels pending
refreshes so they cannot restore a deleted credential. Private responses use an
ephemeral URLSession without cookies/cache; requests reject redirects, and API
pagination rejects foreign hosts before sending authorization. No account
passwords, tokens or event content are logged.

## Verification

Tests use temporary archives, isolated defaults, an in-memory credential store,
fake provider responses and loopback callbacks; they never connect real accounts.
Offscreen fixtures use synthetic content and never show or register an app.
Native macOS compositor effects and real pointer/keyboard behavior still need
acceptance in the one shared installed application.

```sh
swift test --filter 'Planner|CalendarProviderTests|CalendarConnectionTests'
EXODIA_PLANNER_RENDER_DIR=/tmp/exodia-planner-preview swift test --filter PlannerRenderTests
```

Implementation entry points: `Sources/Sidekey/Planner/PlannerStore.swift`,
`PlannerWindowController.swift`, `PlannerView.swift`, `PlannerCalendarView.swift`,
`CalendarConnectView.swift`, `CalendarConnections.swift`, `CalendarRemoteClient.swift`,
`CalendarOAuth.swift`, `CalendarProvider.swift` and `CalendarHTTP.swift`.

Provider contracts checked on 2026-10-19:
[Apple event access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
[Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app),
[Google Calendar scopes](https://developers.google.com/workspace/calendar/api/auth),
[Microsoft native OAuth](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow),
[Microsoft redirect rules](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url),
[Microsoft public-client settings](https://learn.microsoft.com/en-us/entra/identity-platform/msal-client-applications),
[Microsoft publisher verification](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview),
[Graph calendarView](https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview?view=graph-rest-1.0),
[Teams meeting links](https://learn.microsoft.com/en-us/graph/outlook-calendar-online-meetings),
[Zoom OAuth and loopback](https://developers.zoom.us/docs/integrations/oauth/),
[Zoom Calendar API](https://developers.zoom.us/docs/api/calendar/).

## Packaging registered clients

Keep the owner's native-client configuration in the Git common directory as
`whytap-calendar-clients.plist`, outside version control. It is a plist dictionary
keyed by `google`, `microsoft` and `zoom`; each entry contains `clientID`. Only
Google's public Desktop client may include `clientSecret`; confidential web-app
secrets, access tokens and refresh tokens are refused.

Both packaging scripts run `scripts/configure-calendar-clients.py` before signing.
`WHYTAP_CALENDAR_CLIENTS_PLIST` can select another local configuration file. Use
`--require-all` on that helper to verify a candidate intended for all three direct
connections. Its output names providers only. Registration values never belong
in logs, public PRs or source documentation.
Discovery is relative to the helper's source checkout, independent of the shell's
current directory. A source ZIP without Git metadata can build with custom client
setup or an explicit configuration; `--require-all` still fails without registration.

Closing Planner stops calendar polling. Reopening refreshes the visible range.
EventKit change notifications are debounced and refresh only Apple calendars;
they do not restart remote-account requests. Disconnecting an account or removing
a calendar prunes its hidden-feed IDs. Visibility supports up to 256 hidden
calendars with the same bound in settings backup validation.
An open editor keeps its draft when another tool hotkey brings Planner forward.
An active calendar connection flow also defers Sparkle restart and backup restore,
even if its Settings window closes. Planner or inline To-do being visible, or a retained new-task draft, defers Sparkle
restart and backup restore. Ordinary backups continue to capture saved content while Planner is open.
Backup work, a staged restore and pending backup maintenance also block new
calendar connection changes with an explanation until that work finishes.

## Public verification preparation

As checked on 2026-10-21, the shared Google Desktop registration exists, Calendar
API is enabled, and the two narrow read scopes are declared. Its public native
configuration is saved privately for packaging. The Whytap logo, homepage and
calendar privacy URL are saved in Google Auth Platform. Ownership of whytap.ai is
verified as a DNS-level Domain property in Google Search Console. Google publishing
status is **In production**, with an **External** audience. Branding has been
verified and published. Calendar data access is not yet verified: until approved,
Google retains its unverified-app warning and lifetime cap of 100 users for the
requested sensitive scope. Production status and verified branding do not approve
access to calendar events. The calendar data-access review has not been submitted:
a real demonstration video is still missing. A live check on 2026-10-21 reached
the warning and was cancelled without granting access after the user rejected it
for public use. New shared Google sign-in is gated in the candidate implementation.
The form text and recording storyboard are prepared in
[Google verification](google-calendar-verification.md).
The shared Microsoft native registration has been created in the separate owner
directory for personal Microsoft accounts and accounts in any Entra tenant. Its
Mobile and desktop callback is `http://localhost/callback`; only delegated
`Calendars.Read` and `offline_access` are configured. The unused default
`User.Read` permission was removed. The browser flow uses PKCE; additional public
client flows remain disabled. No client secret or tenant-wide admin consent was
created. The public native client ID is saved privately for packaging, preserving
the Google configuration. The Whytap logo, Planner homepage and calendar privacy
URL are saved. After explicit approval, the Microsoft association file was
published on whytap.ai and Azure confirmed whytap.ai as the publisher domain.
The owner chose to keep this registration under their own account and proceed
without Partner Center business verification for now. Publisher-domain
association does not establish a verified publisher. A future verified-publisher
application requires its separate business/domain/account prerequisites.
Live consent remains untested. Organizational policies, including risk-based
consent restrictions for unverified publishers, can block users in other tenants;
registration alone does not establish general public availability.
The working app has not been updated by registration or website changes.

The Zoom user-managed General app has been created. Development and Production
each have public-client OAuth enabled, the numeric loopback PKCE callback and
allow list saved, and separate public client IDs retained privately. The two
calendar read scopes, production PKCE justification, privacy notice and Planner
support links are saved. The IDs are staged separately from the active packaging
configuration; neither live consent nor public approval has been established.

Zoom submission remains incomplete. Its current console requires an ordinary
confidential redirect URL even with the separate PKCE callback configured. Resolve
that native-only submission requirement before claiming readiness. App listing
metadata, a current native-app terms page, Zoom-specific add/use/remove
instructions, EU/discoverability information and technical-design review also
remain. Public and unlisted distributions both require Zoom review; choosing an
unlisted app does not waive those requirements. Do not fill placeholder endpoints
or certify unverified security or legal claims to pass the form.

For Google's verification form, justify each requested scope from the actual UI:

| Scope | Required behavior |
| --- | --- |
| `calendar.calendarlist.readonly` | List subscribed calendars by name so the user can choose the feeds to display. |
| `calendar.events.readonly` | Read events for the selected day, show the agenda and inline details, and open its meeting/original link. |

The review video must show the real app and browser flow in English: open the
calendar, choose Google, show the consent screen and requested permissions,
finish sign-in, display a calendar containing synthetic example events, change
visible feeds, and disconnect. Use a dedicated test calendar/account without
private events. Offscreen fixtures and a client-creation screenshot do not replace
this evidence. Submit the real unlisted video and only confirm statements that
have been verified. A public registration does not imply organizational admin
approval or Zoom Calendar Service availability for every account.

Provider review requirements:
[Google sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification),
[Google domain verification](https://support.google.com/cloud/answer/13804266?hl=en),
[Zoom app review](https://developers.zoom.us/docs/distribute/app-review-process/),
[Zoom listing and discoverability](https://developers.zoom.us/docs/build-flow/before-you-build/).
