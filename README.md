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
gives memory back to the system instead of competing for it.

**3. Ad and tracker blocking in the network layer.** 214 domain rules are compiled
once into a WebKit bytecode program that runs inside the networking process, so
blocked requests never reach the renderer at all. This is cheaper *and* stronger
than an extension: no JS, no per-request callback, nothing to run per page. Verified
with `tools/run-blocktest.sh`.

**4. A new tab costs nothing.** The new-tab page is drawn with AppKit, so an empty
tab allocates no web process. Restoring a session is lazy too — a 20-tab window
comes back with exactly one live renderer.

Autoplay is off, which removes most background CPU and video decode memory.

**5. An app-global adaptive RAM budget.** **Facet → Settings… → Memory** sets a target across every
Facet window (750 MB, 1 GB, 1.5 GB, 2 GB, 3 GB, or off). Facet now measures
what each hibernation actually gives back: it sleeps one LRU background tab, waits briefly
for WebKit/XPC teardown, resamples total footprint, and updates a bounded EWMA estimate.
It stops as soon as the hysteresis target is reached instead of assuming every page costs the
same amount. The learned estimate is also used to reserve room before waking a sleeping tab.
Tabs playing/capturing media, tabs marked **Keep Tab Awake**, visible tabs, and active agent
leases are protected. The selected number is a target rather than an absolute OS kill-limit; a
single foreground site can itself exceed it.

**6. A RAM-aware browser agent.** **View → AI Agent…** (⌘⇧K) toggles a native AppKit sidebar
inside the active browser window—there is no extra WebKit renderer for the assistant UI. The
model runs in the cloud while Facet exposes lightweight tools for tabs, navigation, compact
semantic page snapshots, click/fill/key/scroll actions, and an on-demand viewport screenshot
fallback. Element refs are automatically re-snapshotted and conservatively recovered when a
page mutates. Agent page leases remain bounded by `agentMaxLiveTabs` (default 1), and tabs that
were asleep before an agent lease return to sleep when released. Private windows are never
exposed to the agent.

Conversation context is multi-turn but session-only: it stays in memory for follow-up requests
until **Clear** or quit, is bounded by count/size, and is rolled back when a task is stopped or
fails. Password, one-time-code, and payment-field values are redacted from semantic snapshots.
The screenshot fallback is generated only when requested, sent for that visual inspection, and
not persisted to disk or transcript history.

Browser-changing actions support **Deny**, **Allow Once**, **Allow This Site**, and **Allow Safe
Actions This Task**. There is also an explicit **YOLO This Task** mode with a second critical
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
| `⌘L` | address bar (history/bookmark autocomplete, no network suggestions) |
| `⌘T` / `⌘W` | new tab / close tab |
| `⌘⇧T` | reopen the tab you just closed |
| `⌘N` / `⌘⇧N` | new window / new private window |
| `^⇥` / `^⇧⇥` | next / previous tab (also `⌘⌥←` / `⌘⌥→`) |
| `⌘1`–`⌘9` | jump to tab |
| `⌘[` / `⌘]` | back / forward (or two-finger swipe) |
| `⌘R` / `⌘.` | reload / stop |
| `⌘F` / `⌘G` / `⌘⇧G` | find, find next, find previous |
| `⌘D` | bookmark |
| `⌘+` / `⌘-` / `⌘0` | zoom |
| `⌘⇧H` | put all background tabs to sleep now |
| `⌘⇧J` | open Downloads folder |
| `⌘⇧K` | open the RAM-aware AI agent |
| `⌘,` | open the native Settings window |

**Mouse.** Middle-click or ⌘-click a link opens it in a background tab.
Middle-click a tab closes it. **Drag a tab** to reorder it. **Right-click a tab** for
reload, duplicate, copy address, put-to-sleep, close and close-others. Double-click
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
**Agent**, **Import**, and **Privacy** sections. Most changes apply immediately. The underlying
`~/Library/Application Support/Facet/config.json` remains a plain-text backing store
for advanced/manual editing, while API keys stay in memory and OAuth tokens stay in Keychain.

### Import from another browser

**Settings → Import** detects profiles from Chrome, Brave, Edge, Chromium, Arc, Vivaldi,
Aside, Opera, Firefox and Safari, then lets you import **bookmarks**, **history**, or both.
Chromium-family profiles are discovered individually (including Default/Profile 1/etc.),
and there is a manual profile-folder picker for other Chromium-based browsers. Imports
are merged by URL, so repeating an import does not duplicate bookmarks or inflate visit
counts. History uses short-lived read-only SQLite queries, including committed WAL records,
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
| `blockAdsAndTrackers` | `true` | also the shield button in the toolbar |
| `restoreSessionOnLaunch` | `true` | |
| `showMemoryReadout` | `true` | |
| `enableDeveloperTools` | `true` | |
| `memoryBudgetMB` | `1536` | app-global RAM target; `0` disables enforcement |
| `agentEnabled` | `true` | enable the native AI agent sidebar |
| `agentProvider` | `openai` | `openai`, `anthropic`, `openai_oauth`, or `anthropic_oauth` |
| `agentBaseURL` | `https://api.openai.com/v1` | base URL or full Responses/Messages endpoint for direct API providers |
| `agentModel` | `gpt-5.6-luna` | model/alias for the selected provider |
| `agentMaxLiveTabs` | `1` | maximum simultaneously leased agent tabs (1–4) |
| `agentOpenAIOAuth*` / `agentAnthropicOAuth*` | blank | provider-issued authorization URL, token URL, client ID and scopes for OAuth modes |

Same folder holds `blocked-domains.txt` (one domain per line, `#` comments — add
your own and restart), `history.json`, `bookmarks.json` and `session.json`. All
plain files; nothing is a database.

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
| `Sources/TabStrip.swift` | hand-drawn tab strip, tab context menu |
| `Sources/Controls.swift` | toolbar buttons, address bar, status pill |
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
- **Local builds are ad-hoc signed.** Tagged GitHub releases are notarized only when the
  repository has the required Apple Developer secrets configured; see `docs/releasing.md`.
- Cosmetic ad rules are deliberately conservative, so some blocked slots leave a gap.

## License

MIT — see [LICENSE](LICENSE).
