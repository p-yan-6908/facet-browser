# Facet

A minimal macOS web browser. A tiny ~1–2 MB native app bundle, no package-manager
runtime, no bundled engine, and no background services.

Built because Chrome ships its own entire copy of Chromium plus a GPU process, a
network service, extension hosts, an updater and telemetry daemons — on an 8 GB
machine that is most of your RAM before you open a tab. Facet renders with the
WebKit already resident in macOS and adds the two things Chrome will not do by
default.

![Facet](docs/screenshot.png)

## Facet vs Google Chrome, measured

> **Same five pages, same order, same machine.** Facet used **701 MB** where
> Chrome used **1.93 GB** — and once the background tabs went to sleep, **236 MB**
> against Chrome's **1.91 GB**. Chrome never gave the memory back.

| | Facet | Chrome 151 | |
|---|---|---|---|
| **Memory — 5 tabs loaded** | 701 MB | 1.93 GB | **2.8x less** |
| **Memory — same 5 tabs after idling** | 236 MB | 1.91 GB | **8.3x less** |
| Memory — idle, one empty tab | 28 MB | 403 MB | **14.2x less** |
| Processes for those 5 tabs | 8 | 47 | **5.9x fewer** |
| CPU while idling on those 5 tabs | 0.04% of a core | 0.11% of a core | **3.1x less** |
| Cold launch to a window on screen | 0.34 s | 0.41 s | **1.2x faster** |
| App on disk *(benchmark build)* | 904 KB | 2.0 GB | **~2,400x smaller** |

Isolating the ad blocker, since that is the obvious objection — the same five pages in Facet with blocking **switched off**:

| | Memory, 5 tabs loaded |
|---|---|
| Facet, blocker on | 701 MB |
| Facet, blocker off | 822 MB |
| Chrome (no blocking, no extensions) | 1.93 GB |

So blocking accounts for part of it, but Facet with the blocker off still uses **2.4x less** memory than Chrome. The bulk of the win is architectural.

### How this was measured

Every number above comes from `./tools/bench.sh`, which you can run yourself. It
opens the **same five pages in the same order** in each browser
— Wikipedia, Hacker News, GitHub Trending, The Verge and CNN — waits for them to
settle, then reads `phys_footprint` and CPU time per process straight from the
kernel. That is the same figure Activity Monitor's Memory column shows, and helper
processes are attributed to their parent app exactly the way Activity Monitor does
it (`responsibility_get_pid_responsible_for_pid`). The table in this README is
generated from the raw measurement file by `tools/bench-table.py`, not typed by
hand.

Things that are deliberately **generous to Chrome**, so you can trust the gap:

- Chrome runs on a **throwaway `--user-data-dir`**, so it has **no extensions**
  loaded. A real Chrome with an ad blocker, a password manager and a long history is
  heavier than what is measured here. All browsing data for the run — history,
  cookies, cache — goes to that throwaway directory, not your real profile. (Chrome
  still writes some of its own machine-level metadata, such as crash and metrics
  caches, to the default location on any launch; that is Chrome's behaviour, not
  something the benchmark controls.) The script refuses to measure at all unless it
  can confirm Chrome is on the throwaway profile, and refuses to start if another
  Chrome is already running, so it can never fold your real session into the numbers.
- Chrome's **first-run launch is discarded** before timing, so startup is measured
  warm, not cold-from-install.
- The third table isolates ad blocking: Facet with its blocker **switched off**
  still uses far less memory, so the win is architectural, not just "it blocks ads".

And the honest caveats:

- **One machine, one run** (M1, 8 GB, macOS 26.5). Expect variance, especially on
  the ad-heavy pages, whose weight changes with whatever ads happen to be served.
- Chrome's high process count is partly **site isolation**, a real security feature
  that costs memory. Facet does not match it; WebKit isolates less aggressively.
- Chrome has a **Memory Saver** that discards inactive tabs, but it works on a much
  longer timescale than this test and did not trigger. Over hours, Chrome's idle
  number would improve.
- For a short test the sleep threshold was lowered to **1 minute**
  (`hibernateAfterMinutes`); the shipped default is 5.
- **CPU at rest is deliberately not reported.** Facet destroys tab processes during
  that window, and summing per-process CPU counters loses the time used by processes
  that no longer exist, so the figure would come out negative and meaningless.
- The blocker-off row is **memory only**. It was captured in the same session but
  before a fix to which tab gets focus, and focus materially changes CPU.
- Which tab is in the **foreground** matters more than you would guess: with an
  ad-heavy page focused instead of a static one, Facet's idle CPU measured 1.07%
  rather than 0.04%. Both browsers are given the same foreground page.
- Facet cannot win a like-for-like *rendering* benchmark — it is the same WebKit
  everyone else's Safari uses. The gains here are in what a browser wraps around an
  engine, not the engine.

## What actually makes it light

**1. No engine of its own.** Rendering is `WKWebView`, i.e. the same Safari engine
already loaded in the OS and shared with every other app. Facet's own UI process
measures ~30 MB. There is no updater, no telemetry, no extension host, no sync.

**2. Tabs that really sleep.** A background tab idle for 5 minutes has its WebKit
content process *destroyed*, not throttled. What survives is the URL, the title and
`interactionState` — a WebKit blob holding the full back/forward list and scroll
position, a couple of KB. Click the tab and it comes back where you left it. Chrome
and Safari only throttle timers; the ~50–300 MB per tab stays resident.

Sleeping also happens immediately when macOS reports memory pressure, so Facet
gives memory back to the system instead of competing for it. A window nobody can see
(minimized, hidden, or fully covered) lets even its front tab sleep after the same idle
time, and wakes it the moment the window is visible again. When macOS kills a background
renderer to reclaim memory, Facet leaves that tab asleep instead of instantly reloading it
and spending the memory the system just asked for.

**3. Ad and tracker blocking in the network layer.** 214 domain rules are compiled
once into a WebKit bytecode program that runs inside the networking process, so
blocked requests never reach the renderer at all. This is cheaper *and* stronger
than an extension: no JS, no per-request callback, nothing to run per page. Verified
with `tools/run-blocktest.sh`. When a site breaks, click the shield and untick **Block Ads
on *site***: blocking stops for that site and its subdomains, and only its pages reload.

**4. A new tab costs nothing.** The new-tab page is drawn with AppKit, so an empty
tab allocates no web process. Restoring a session is lazy too — a 20-tab window
comes back with exactly one live renderer.

Autoplay is off, which removes most background CPU and video decode memory. Favicons are
redrawn into one 32px bitmap before they are kept (a site's 512px touch icon would
otherwise pin megabytes per tab) and cached as tiny PNGs, so restored sleeping tabs show
their icons without a renderer or a network request. Tab context menus are built when they
open, not on every page-load progress tick.

**5. An app-global adaptive RAM budget.** **Facet → Settings… → Memory** sets a target across every
Facet window (750 MB, 1 GB, 1.5 GB, 2 GB, 3 GB, or off). Facet now measures
what each hibernation actually gives back: it sleeps one LRU background tab, waits briefly
for WebKit/XPC teardown, resamples total footprint, and updates a bounded EWMA estimate.
It stops as soon as the hysteresis target is reached instead of assuming every page costs the
same amount. The learned estimate is also used to reserve room before waking a sleeping tab.
Tabs playing/capturing media, tabs marked **Keep Tab Awake**, visible tabs, and active agent
leases are protected. The selected number is a target rather than an absolute OS kill-limit; a
single foreground site can itself exceed it.

**6. A RAM-aware browser agent.** *Currently parked:* builds hide the agent's menu item, toolbar
button, sidebar, context-menu entries and Settings pane while work focuses on the browser
itself. Set `Config.agentFeatureAvailable` to `true` in `Sources/Config.swift` and rebuild to
bring it back; the regression suite keeps testing it either way. When enabled,
**View → AI Agent…** (⌘⇧K) toggles a native AppKit sidebar
inside the active browser window—there is no extra WebKit renderer for the assistant UI. The
model runs in the cloud while Facet exposes lightweight tools for tabs, navigation, compact
semantic page snapshots, click/fill/key/scroll actions, and an on-demand viewport screenshot
fallback. Element refs are automatically re-snapshotted and conservatively recovered when a
page mutates. Agent page leases remain bounded by `agentMaxLiveTabs` (default 1), and tabs that
were asleep before an agent lease return to sleep when released. Private windows are never
exposed to the agent.

Each request tells the model which tab you are looking at (as data, never as instructions),
so "summarize this page" works without an extra tool call. The sidebar has one-click
**Summarize page**, **Key facts**, and **Compare tabs** actions; right-clicking a selection
offers **Ask Assistant About Selection**, and right-clicking a page offers **Summarize Page
with Assistant**. Replies render inline Markdown, and their links open as background tabs.
The agent can also go back in a tab's history and choose `<select>` options by their visible
text. With Anthropic providers, each tool step marks the conversation as a prompt-cache
breakpoint, so later steps do not pay full price to resend earlier page snapshots.

Conversation context is multi-turn but session-only: it stays in memory for follow-up requests
until **Clear** or quit, is bounded by count/size, and is rolled back when a task is stopped or
fails. Password, one-time-code, and payment-field values are redacted from semantic snapshots.
The screenshot fallback is generated only when requested, sent for that visual inspection, and
not persisted to disk or transcript history.

Browser-changing actions support **Deny**, **Allow Once**, **Allow This Site**, and **Allow Safe
Actions This Task**. Only clicks on plain web links count as safe: clicks on buttons and form
controls, filling fields, key presses and closing tabs ask every time. Safe-action approval
covers sites already approved in the task, so opening a new site still asks, because a URL the
model writes could carry page text to that site. There is also an explicit **YOLO This Task** mode with a second critical
warning; when enabled, future browser-changing actions for that one task no longer prompt. YOLO
resets before the next task and still cannot expose private windows, reveal redacted credential
fields, bypass URL-scheme/credential safety checks, or undo completed actions.

Agent provider and credential configuration lives under **Facet → Settings… → Agent**. Facet supports four modes: **OpenAI-compatible API key**,
**Anthropic-compatible API key**, **OpenAI OAuth (PKCE)**, and **Anthropic OAuth (PKCE)**.
API-key providers accept a custom base URL or full endpoint plus a session-only key; keys are
never written to `config.json`. Inference endpoints must use HTTPS (HTTP is allowed for
localhost/loopback providers), without embedded credentials, query strings, or fragments.
Choose a model ID available from your provider. OAuth uses the native-app Authorization Code flow with PKCE,
returns through `facet://oauth/callback`, stores access/refresh tokens in the macOS Keychain,
and refreshes them when the authorization server supplies a refresh token. OAuth client metadata
(client ID, authorization URL, token URL and scopes) is configurable because Facet deliberately
does not embed or imitate private first-party Codex/Claude client credentials.

A ChatGPT or Claude consumer subscription does **not currently imply a public third-party OAuth
grant for model inference**. OpenAI's public Sign in with ChatGPT flow is identity-only for supported
partners, and Anthropic documents Claude Pro/Max subscription OAuth for Claude Code rather than a
general third-party inference client. If either provider issues Facet/you an approved native-app
OAuth client, the PKCE plumbing is ready to use it directly without a coding CLI.

## Everyday browsing, Chrome-style

The things people reach for in Chrome, done natively and without extra processes:

- **Omnibox.** A dropdown with search, the typed address, matching **open tabs (Switch to
  Tab)**, bookmarks and history, ranked by frequency and recency. It also completes inline:
  type `gi` and it offers `github.com` with the rest selected. Inline completion only
  suggests addresses you have visited more than once or bookmarked, so a search is never
  hijacked by a one-off visit. Arrow keys move through the list, Escape reverts, and ⌘Return
  opens the result in a new tab. No keystrokes go to a suggestion server.
- **Downloads.** Files the page cannot display, `Content-Disposition: attachment`,
  `<a download>`, ⌥-click, and the context menu all download to ~/Downloads. A toolbar button
  with a progress ring opens a list where you can cancel, resume, retry, open, or show files
  in Finder. Finished files are quarantined so Gatekeeper checks downloaded apps, as Safari
  and Chrome do, and the Dock's Downloads stack bounces. A tab that only existed to start a
  download closes itself.
- **Pages that work.** File uploads (`<input type=file>`), HTTP Basic/Digest sign-in
  prompts, fullscreen video, Print (⌘P), Save Page As (web archive), Export as PDF, and Web
  Inspector (⌥⌘I).
- **Tabs.** Pin tabs (they persist), mute tabs from the speaker icon, open links next to
  the page that opened them, return to the opener when you close its last child tab, move a
  tab to a new window without reloading it, close tabs to the right, and duplicate a tab with
  its history. Drag a tab off the strip to give it its own window, or onto another window's
  strip to move it there; the page moves live, without reloading. **Search Tabs** (⌘⇧A) finds
  any open tab by title or address across windows, sleeping tabs included, without waking
  them. ⌘⇧T reopens closed windows as well as tabs, and **History → Recently Closed** lists
  both. Hold or right-click Back/Forward to see the history list.
- **Task Manager.** **Window → Task Manager**, or a click on the memory pill, lists the browser,
  every tab with the memory its WebKit process is using, and the helpers all tabs share. Select
  tabs to **Sleep** or **Close** them. Hovering a tab shows its site and memory, like Chrome's
  hover cards. The Task Manager samples only while it is open, every two seconds.
- **Site information.** Click the lock in the address bar for the connection's security and
  certificate, the permissions you gave the site (set each to Allow, Block or Ask), ad
  blocking for that site, its zoom, and **Clear Cookies and Site Data** for that site alone.
- **Finding things.** Find as you type, with a match count. ⌘E finds the current selection.
  History (⌘Y) and Bookmarks (⌥⌘B) open in a native, searchable window.
- **Bookmarks with folders, like Chrome's.** A Bookmarks Bar and Other Bookmarks, with any
  folders inside. ⌘D or the star bookmarks the page at once and shows a bubble to rename it,
  choose its folder (or make a new one), or remove it; the next bookmark goes to the folder
  you chose last. ⌘⇧D saves every tab in the window as a new folder. The bar (⌘⇧B) shows
  folders as menus, with **Open All**, and a » menu for what does not fit. The Bookmark
  Manager shows the tree: drag to reorder or move between folders, drag a link in from a
  page, rename in place, New Folder, Delete, and search. Open All opens the first page and
  leaves the rest as sleeping tabs that use no memory until you click them. Folder menus are
  built only when opened, so a large imported collection costs almost nothing.
- **Per-site memory.** Zoom uses Chrome's steps and is remembered per site. Camera and
  microphone decisions can be remembered per site. Pages that try to open another app
  (`zoommtg:`, `mailto:`, ...) ask first, with an "always allow" option.
- **Clear Browsing Data (⌘⇧⌫).** Time ranges from the last hour to all time. Choose any of
  history, cookies and site data, cached files, and site settings.
- **Polish.** Hovering a link shows its address bottom-left. Context menus offer Open Link
  in New Tab/Window/Private Window, and search the selection with your engine. Error pages
  name the host, and Reload retries the real address. Repeated JavaScript dialogs can be
  suppressed, and a page crashing in a loop stops reloading itself. Private windows share
  one ephemeral session, like incognito, which is discarded when the last one closes. The
  address bar's menu has **Paste and Go** (or **Paste and Search**), **File → Share** sends
  the page to AirDrop, Messages or Mail, and **Edit** has the standard Spelling and Grammar,
  Substitutions, Transformations and Speech menus.

The link-hover and context-menu details come from a script in WebKit's isolated
`defaultClient` world. Page scripts see the same DOM events but cannot reach its message
handler, so a page cannot spoof what the status bubble shows or what a menu command acts on.

### Compare it against your own browser

```sh
./tools/kmem                 # Facet, Chrome and Safari side by side, right now
./tools/bench.sh             # the full comparison above, reproduced
```

Heavy sites cost what they cost — that is the page, not the browser. The win is
that you only pay for the tab you are actually looking at.

## Install

### Download the built app

Tagged GitHub releases are built as a universal macOS archive. When the repository release
secrets are configured, the release workflow signs Facet with **Developer ID**, enables the
**hardened runtime**, submits it to Apple notarization, staples the ticket, and publishes both the
ZIP and its SHA-256 checksum. Download the `Facet-<version>-macOS-universal.zip` asset and drag
`Facet.app` to `/Applications`.

Local builds remain ad-hoc signed. Gatekeeper behavior for an ad-hoc/local copy is therefore
different from an official notarized tagged build; see `docs/releasing.md` for the release setup.

### Or build it yourself

```sh
./build.sh /Applications      # compile, bundle, ad-hoc sign, install
open /Applications/Facet.app
```

Requires only the Xcode Command Line Tools. Build takes a few seconds, and a
locally built app needs no quarantine step.

To make it your default browser: **Facet → Make Facet the Default Browser**.

## Keyboard

| | |
|---|---|
| `⌘L` | address bar (inline completion, open tabs, bookmarks, history; no network suggestions) |
| `⌘Return` (in the address bar) | open in a new tab |
| `⌘T` / `⌘W` | new tab / close tab |
| `⌘⇧T` | reopen the tab or window you just closed |
| `⌘⇧A` | search open tabs |
| `⌘N` / `⌘⇧N` | new window / new private window |
| `^⇥` / `^⇧⇥` | next / previous tab (also `⌘⌥→` / `⌘⌥←`) |
| `⌘1`–`⌘9` | jump to tab |
| `⌘[` / `⌘]` | back / forward (or two-finger swipe; hold the button for history) |
| `⌘R` / `⌘⇧R` / `⌘.` | reload / reload bypassing the cache / stop |
| `⌘F` / `⌘G` / `⌘⇧G` / `⌘E` | find as you type, next, previous, find the selection |
| `⌘D` / `⌘⇧D` | bookmark this page (then name it and pick a folder) / bookmark all tabs as a folder |
| `⌘⇧B` / `⌥⌘B` | bookmarks bar / bookmark manager |
| `⌘Y` | history |
| `⌘⇧⌫` | clear browsing data |
| `⌘+` / `⌘-` / `⌘0` | zoom (remembered per site) |
| `⌘P` / `⌘S` | print / save page as |
| `⌥⌘I` | Web Inspector |
| `⌘⇧H` | put all background tabs to sleep now |
| `⌘⇧J` / `⌥⌘L` | downloads list / Downloads folder |
| `⌘⇧K` | open the RAM-aware AI agent (while the agent is enabled; it is currently parked) |
| `⌘,` | open the native Settings window |

**Mouse.** Middle-click or ⌘-click a link opens it in a background tab next to the
current one; ⌥-click downloads it. Middle-click a tab closes it. **Drag a tab** to reorder
it; pinned tabs stay at the front. Click a tab's speaker icon to mute it. **Right-click a
tab** to reload, duplicate, pin, mute, copy its address, keep it awake, put it to sleep, move
it to a new window, or close it, other tabs, or tabs to the right. Double-click
empty space in the tab strip for a new tab. Right-click a page → Inspect Element
opens Web Inspector.

Tabs shrink to fit however many you have open, so the last tab and the `+` button
stay reachable instead of sliding off the edge of the window.

Sleeping tabs are dimmed in the strip and say so in their tooltip, so a tab
reloading when you return to it is never a surprise. The pill on the right of the
toolbar is live total memory across every Facet process, plus how many tabs are
currently asleep — hover it for the per-process breakdown.

## Settings and configuration

**Facet → Settings…** (⌘,) opens the native settings window with **General**, **Memory**,
**Import**, and **Privacy** sections (plus **Agent** while the agent is enabled). Most changes apply immediately. The underlying
`~/Library/Application Support/Facet/config.json` remains a plain-text backing store
for advanced/manual editing, while API keys stay in memory and OAuth tokens stay in Keychain.

### Import from another browser

**Settings → Import** detects profiles from Chrome, Brave, Edge, Chromium, Arc, Vivaldi,
Aside, Opera, Firefox and Safari, then lets you import **bookmarks**, **history**, or both.
Chromium-family profiles are discovered individually (including Default/Profile 1/etc.),
and there is a manual profile-folder picker for other Chromium-based browsers. Bookmarks
keep their folders: the source's bookmarks bar (Safari's Favorites, Firefox's toolbar) goes
to Facet's bar, everything else to Other Bookmarks, with mobile bookmarks and Safari's
Reading List in folders of their own. Imports are merged by URL and folders by name, so
repeating an import does not duplicate bookmarks or folders, or inflate visit counts. History uses short-lived read-only SQLite queries, including committed WAL records,
so recent visits are not lost just because the source browser is still open. No temporary
copy of your history is written. If a database is locked or inaccessible, close the source
browser and retry. Partial imports identify the failed category; fully failed imports are
reported as failures. Custom profiles remain selectable when refreshing the pane.

#### Keep Chrome sites signed in (experimental, best effort)

1. Close Chrome. Avoid browsing in Facet while importing.
2. Open **Settings → Import**, select your **Google Chrome** profile, and explicitly enable
   **Sign-in sessions — Experimental (Chrome only)**. This is off by default.
3. Click **Import Selected Data**, review the sensitive-data warning, and confirm
   **Import Sessions**. macOS may ask you to authorize access to **Chrome Safe Storage**.
4. Reload your sites in Facet. The result reports imported cookies, existing cookies kept,
   and skipped records—not a guaranteed number of signed-in accounts.

This experimental feature transfers supported cookies (including sign-in tokens and site preferences) into normal
Facet windows. Existing Facet cookies are preserved instead of overwriting another account;
private windows stay separate. No plaintext export files are created, and denied Keychain access
or unsupported encryption is never bypassed. Expired, partitioned, invalid, and known unsupported
origin-bound cookies are skipped.

**Some sites will still require login or MFA.** Saved passwords alone do not keep a browser
signed in. This feature does **not** import a password vault, passkeys, device-bound credentials,
localStorage/IndexedDB, extensions, or autofill data. WebKit's cookie policies differ from Chrome's;
this is not a complete clone of Chrome's profile or per-port isolation. See
[`docs/session-import.md`](docs/session-import.md) for compatibility details.

Safari's Library data is protected by macOS and may require granting Facet Full Disk Access
before Safari bookmarks/history can be read.

### Regression checks

```sh
bash tools/run-polish-tests.sh           # synthetic import + provider/URL regressions
bash tools/run-polish-tests.sh --webkit  # also privacy, sidebar UI, cookie round trips and local sign-in
tools/chrome-compat-smoke.sh              # disposable real-Chrome schema/encryption smoke test
```

These checks use a temporary Facet store, synthetic browser profiles, and in-process
provider fixtures—no real profiles, Keychain secrets, or API credentials. Cookie navigation
uses a loopback-only test site and a nonpersistent WebKit store. See
`docs/polish-checklist.md` and `docs/session-import.md` for verification scope and limits.

| key | default | |
|---|---|---|
| `searchTemplate` | Google | `%s` is the query; e.g. `https://duckduckgo.com/?q=%s` |
| `hibernateAfterMinutes` | `5` | `0` disables sleeping |
| `hibernateOnMemoryPressure` | `true` | sleep everything when macOS says it is low |
| `blockAdsAndTrackers` | `true` | also the shield menu in the toolbar, which can turn blocking off for one site |
| `restoreSessionOnLaunch` | `true` | |
| `showMemoryReadout` | `true` | |
| `enableDeveloperTools` | `true` | |
| `showBookmarksBar` | `false` | also **View → Always Show Bookmarks Bar** (⌘⇧B) |
| `memoryBudgetMB` | `1536` | app-global RAM target; `0` disables enforcement |
| `agentEnabled` | `true` | enable the native AI agent sidebar (has no effect while the agent is parked) |
| `agentProvider` | `openai` | `openai`, `anthropic`, `openai_oauth`, or `anthropic_oauth` |
| `agentBaseURL` | `https://api.openai.com/v1` | base URL or full Responses/Messages endpoint for direct API providers |
| `agentModel` | `gpt-5.6-luna` | model/alias for the selected provider |
| `agentMaxLiveTabs` | `1` | maximum simultaneously leased agent tabs (1–4) |
| `agentOpenAIOAuth*` / `agentAnthropicOAuth*` | blank | provider-issued authorization URL, token URL, client ID and scopes for OAuth modes |

Same folder holds `blocked-domains.txt` (one domain per line, `#` comments — add
your own and restart; hosts-file lines such as `0.0.0.0 ads.example.com` work too, so a
published hosts list can be pasted in), `history.json`, `bookmarks.json` (a tree of folders; the older flat format is migrated), `session.json`,
`site-settings.json` (per-site zoom, remembered permissions and sites with blocking off) and
`Favicons/` (32px PNGs). All plain files; nothing is a database. Set `FACET_PROFILE_DIR` to run Facet against
a throwaway profile folder instead.

## Layout

| | |
|---|---|
| `Sources/Tab.swift` | tab model, hibernate/wake, WebKit delegates |
| `Sources/BrowserWindowController.swift` | window chrome, tab switching, timers |
| `Sources/ContentBlocker.swift` | domain list → compiled WebKit rule list |
| `Sources/MemoryMonitor.swift` | per-process footprint, Activity-Monitor-style attribution |
| `Sources/MemoryBudgetController.swift` | app-global RAM budget, pre-wake reservation, LRU eviction |
| `Sources/BrowserAgent.swift` | bounded tab leases, browser tools, provider-neutral agent loop |
| `Sources/AgentProviders.swift` | OpenAI/Anthropic protocol adapters for API-key and OAuth bearer auth |
| `Sources/AgentOAuth.swift` | OAuth 2.0 Authorization Code + PKCE, refresh, Keychain token storage |
| `Sources/AgentModels.swift` | compact page/tab representations and approval decisions |
| `Sources/AgentSidebarView.swift` | native in-browser multi-turn assistant sidebar |
| `Sources/AgentVision.swift` | ephemeral viewport screenshot fallback for OpenAI/Anthropic providers |
| `Sources/SettingsWindowController.swift` | General / Memory / Agent / Import / Privacy native settings UI |
| `Sources/BrowserImportService.swift` | bookmark/history migration and optional Chrome session import |
| `Sources/BrowserSQLite.swift` | short-lived read-only WAL snapshots for browser imports |
| `Sources/ChromeSessionImport.swift` | authorized Chrome cookie decryption, filtering, and WebKit installation |
| `Sources/TabStrip.swift` | hand-drawn tab strip: pinned tabs, audio/mute, drag to reorder |
| `Sources/Controls.swift` | toolbar buttons (with history menus), address bar, status pill, link status |
| `Sources/Omnibox.swift` | address-bar ranking, inline completion, dropdown |
| `Sources/WebView.swift` | isolated-world page bridge, context-menu hook, closure menu items |
| `Sources/Downloads.swift` / `DownloadsView.swift` | download tracking, quarantine, toolbar popover |
| `Sources/BookmarksBar.swift` | bookmarks bar, folder menus, shared bookmark prompts |
| `Sources/BookmarkEditor.swift` | the ⌘D bubble: name, folder, remove |
| `Sources/BookmarkManager.swift` | the bookmark manager's folder tree, drag and drop |
| `Sources/LibraryWindowController.swift` | native History and Bookmarks window |
| `Sources/TaskManagerWindowController.swift` | per-tab memory, Sleep and Close |
| `Sources/TabSearch.swift` | ⌘⇧A tab search across windows |
| `Sources/PageInfo.swift` | the lock's site information popover, per-site data clearing |
| `Sources/RecentlyClosed.swift` | closed tabs and windows for ⌘⇧T and History → Recently Closed |
| `Sources/SiteSettings.swift` | per-site zoom and permission memory |
| `Sources/FaviconStore.swift` | bounded in-memory and on-disk favicon cache |
| `Sources/StartView.swift` | native new-tab page |
| `Sources/Store.swift` | history, bookmarks, session (flat JSON) |
| `tools/run-blocktest.sh` | functional test: are trackers actually blocked? |
| `tools/kmem` | footprint of Facet / Chrome / Safari, right now |
| `tools/bench.sh` | the full Chrome comparison, reproducible |
| `tools/bench-table.py` | turns raw results into the table above |
| `tools/waitwindow.swift` | cold-launch timing via the window server |
| `tools/chrome-compat-smoke.sh` | disposable real-Chrome compatibility check; never opens the normal profile |
| `.github/workflows/ci.yml` | build/regressions/blocker/current-Chrome checks on push, PR, and weekly |
| `.github/workflows/release.yml` | universal Developer ID signing, notarization, stapling, and GitHub Release |

## Known limits

- **Not a new engine.** Site compatibility is Safari's. The rare site that only
  works in Chrome will not work here.
- **No extension support.** Ad blocking is built in; anything else is not available.
- **No password manager, autofill, sync, or web notifications.** WKWebView does not expose
  iCloud Keychain AutoFill or Web Push to third-party browsers, and Facet does not store
  passwords itself.
- **Dragging the only tab of a window does not move the window**, as Chrome's does. Drag the
  window by its tab strip instead.
- **Local builds are ad-hoc signed.** Tagged GitHub releases are notarized only when the
  repository has the required Apple Developer secrets configured; see `docs/releasing.md`.
- Cosmetic ad rules are deliberately conservative, so some blocked slots leave a gap.

## License

MIT — see [LICENSE](LICENSE).
