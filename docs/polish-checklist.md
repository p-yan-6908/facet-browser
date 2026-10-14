# Browser polish acceptance ledger

Scope: preserve the existing fork and native, RAM-conscious architecture. Verification uses synthetic profiles, a temporary Facet store, local HTML, and in-process provider responses—not real browser profiles or credentials.

## Verified

- Import: committed SQLite WAL history is included without modifying source database/WAL bytes; uncommitted rows are excluded; nested bookmarks deduplicate and omit non-web URLs; Chrome, Firefox, and Safari history timestamps parse correctly; repeated merges do not inflate visit counts; huge counts cannot trap integer conversion; partial failures warn and total failures throw. Asynchronous completion returns on the main thread.
- Import integration (code inspection): custom-profile menu indices come from the rebuilt source list; custom selections survive refresh; refresh and duplicate import actions are guarded while importing. SQLite linkage is present in both build scripts.
- Assistant: both OpenAI and Anthropic loops handle cancellation, concurrent-run rejection, restart after Stop, denied/late approvals, multi-turn in-memory context, visual fallback registration, and API errors. Approval scopes include Allow Once, per-site safe actions, safe actions for the task, and task-scoped YOLO; YOLO resets before the next task. Missing approval UI fails closed.
- Assistant UI: the real native in-browser sidebar is exercised; Run becomes Stop while working, prompt/Clear are disabled and restored, Clear removes model conversation context, and hiding the sidebar cancels active work.
- Browser: address resolution handles localhost, IPv4/IPv6, ports, queries/fragments, and search fallback. Multi-window sessions persist/restore with backward migration from the original single-window format. Agent URLs exclude local files and embedded credentials. Provider endpoints reject remote plaintext HTTP and malformed credential-bearing URLs.
- WebKit privacy: private titles do not update normal history; private favicons do not use the persistent shared URLSession cache; password/OTP/payment field values are absent from snapshots while ordinary input values remain available. Already-cancelled snapshots never wake a sleeping tab.

## Evidence

- `bash tools/run-polish-tests.sh --webkit`: **162/162 checks passed**, including adaptive-memory, multi-window session, YOLO scope, sidebar, privacy, and Chrome session-import checks.
- Optimized `build.sh` compilation and strict code-signature verification pass. The build script also supports universal arm64/x86_64 output, version/build-number injection, Developer ID signing, and hardened runtime for releases.
- `git diff --check` and shell syntax validation passed.

## Remaining manual checks / boundaries

- Import picker with real user profile permissions, selecting the same custom profile repeatedly, and pane switches during an import. A disposable real Chrome 152 profile is covered separately by `tools/chrome-compat-smoke.sh`.
- Manual real-page verification of the approval sheets (including YOLO warning), stale-ref recovery, screenshot vision fallback, and sleeping-page lease cleanup under sustained browsing/memory pressure.
- Live API-key/OAuth provider compatibility, provider-specific model availability, and Safari Full Disk Access. No live credentials were used.
- Stop prevents further actions but does not undo completed actions or cancel account-level OAuth flows. Page text can still contain sensitive information; field-value redaction is not a general-purpose data-loss-prevention system.
- Provider-native token streaming is not implemented yet; final provider text is currently delivered incrementally to the sidebar after the JSON response completes.
