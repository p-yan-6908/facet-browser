# Kestrel

A minimal macOS web browser. One 840 KB app bundle, no dependencies, no bundled
engine, no background services.

Built because Chrome ships its own entire copy of Chromium plus a GPU process, a
network service, extension hosts, an updater and telemetry daemons — on an 8 GB
machine that is most of your RAM before you open a tab. Kestrel renders with the
WebKit already resident in macOS and adds the two things Chrome will not do by
default.

## What actually makes it light

**1. No engine of its own.** Rendering is `WKWebView`, i.e. the same Safari engine
already loaded in the OS and shared with every other app. Kestrel's own UI process
measures ~30 MB. There is no updater, no telemetry, no extension host, no sync.

**2. Tabs that really sleep.** A background tab idle for 5 minutes has its WebKit
content process *destroyed*, not throttled. What survives is the URL, the title and
`interactionState` — a WebKit blob holding the full back/forward list and scroll
position, a couple of KB. Click the tab and it comes back where you left it. Chrome
and Safari only throttle timers; the ~50–300 MB per tab stays resident.

Sleeping also happens immediately when macOS reports memory pressure, so Kestrel
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

### Measured on this machine (M1, 8 GB, macOS 26.5)

| | footprint |
|---|---|
| Kestrel running, one new tab (no renderer at all) | **25 MB** |
| 5 tabs open, all awake (incl. theverge.com at 318 MB) | 530 MB |
| Same 5 tabs, 4 asleep, theverge.com still in front | **385 MB** |
| …of which the browser + 4 sleeping tabs | **59 MB** |

Heavy sites cost what they cost — that is the page, not the browser. The win is
that you only pay for the tab you are looking at.

Compare for yourself, with the same pages open in each:

```sh
./tools/kmem                      # Kestrel, Chrome and Safari side by side
```

It reports phys_footprint — the same number Activity Monitor's Memory column
shows — and attributes helper processes the way Activity Monitor does.

## Install

### Download the built app

Grab `Kestrel.zip` from [Releases](../../releases), unzip, and drag `Kestrel.app`
to `/Applications`.

Kestrel is ad-hoc signed and **not notarized by Apple**, so the first launch needs
one extra step — macOS quarantines anything downloaded from the internet:

```sh
xattr -dr com.apple.quarantine /Applications/Kestrel.app
open /Applications/Kestrel.app
```

(Or right-click the app → **Open** → **Open** in the dialog.) Without this you get
*"Kestrel is damaged"* or *"Apple could not verify..."* — that is Gatekeeper, not a
broken build. Notarizing would require a paid Apple Developer account.

### Or build it yourself

```sh
./build.sh /Applications      # compile, bundle, ad-hoc sign, install
open /Applications/Kestrel.app
```

Requires only the Xcode Command Line Tools. Build takes a few seconds, and a
locally built app needs no quarantine step.

To make it your default browser: **Kestrel → Make Kestrel the Default Browser**.

## Keyboard

| | |
|---|---|
| `⌘L` | address bar (history/bookmark autocomplete, no network suggestions) |
| `⌘T` / `⌘W` | new tab / close tab |
| `⌘N` / `⌘⇧N` | new window / new private window |
| `^⇥` / `^⇧⇥` | next / previous tab |
| `⌘1`–`⌘9` | jump to tab |
| `⌘[` / `⌘]` | back / forward (or two-finger swipe) |
| `⌘R` | reload |
| `⌘F` / `⌘G` / `⌘⇧G` | find, find next, find previous |
| `⌘D` | bookmark |
| `⌘+` / `⌘-` / `⌘0` | zoom |
| `⌘⇧H` | put all background tabs to sleep now |
| `⌘⇧J` | open Downloads folder |
| `⌘,` | settings (opens config.json) |

Middle-click or ⌘-click a link for a background tab. Right-click → Inspect Element
opens Web Inspector. The toolbar readout on the right is live total memory across
every Kestrel process, plus how many tabs are asleep.

## Configuration

`~/Library/Application Support/Kestrel/config.json` — edited with `⌘,`, applied on
restart.

| key | default | |
|---|---|---|
| `searchTemplate` | Google | `%s` is the query; e.g. `https://duckduckgo.com/?q=%s` |
| `hibernateAfterMinutes` | `5` | `0` disables sleeping |
| `hibernateOnMemoryPressure` | `true` | sleep everything when macOS says it is low |
| `blockAdsAndTrackers` | `true` | also the shield button in the toolbar |
| `restoreSessionOnLaunch` | `true` | |
| `showMemoryReadout` | `true` | |
| `enableDeveloperTools` | `true` | |

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
| `Sources/TabStrip.swift` | hand-drawn tab strip |
| `Sources/StartView.swift` | native new-tab page |
| `Sources/Store.swift` | history, bookmarks, session (flat JSON) |
| `tools/run-blocktest.sh` | functional test: are trackers actually blocked? |
| `tools/kmem` | memory comparison tool |

## Known limits

- **Not a new engine.** Site compatibility is Safari's. The rare site that only
  works in Chrome will not work here.
- **No extension support.** Ad blocking is built in; anything else is not available.
- **Multi-window sessions**: only the last window to close is restored.
- **Not notarized** (ad-hoc signed, built locally). Gatekeeper may ask on first
  launch; right-click → Open.
- Cosmetic ad rules are deliberately conservative, so some blocked slots leave a gap.

## License

MIT — see [LICENSE](LICENSE).
