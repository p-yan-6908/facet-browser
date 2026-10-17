# Sign-in session import (experimental)

## Use

Facet offers this on first launch, alongside bookmarks and history, for the browser you use; it is also in **Settings → Import**. It is **experimental and best-effort**. Close the source browser and avoid browsing in Facet during migration. In Settings, choose a profile, explicitly check **Sign-in sessions — Experimental**, and click **Import Selected Data**. Review the confirmation and choose **Import Sessions**. Reload sites after completion.

| Browser | Source | Protection | Notes |
|---|---|---|---|
| Google Chrome, Brave, Microsoft Edge, Arc, Vivaldi, Opera, Chromium | `Network/Cookies` or `Cookies` (SQLite) | `v10` AES-128-CBC with the browser's own Keychain item: `Chrome Safe Storage`, `Brave Safe Storage`, `Microsoft Edge Safe Storage`, `Arc Safe Storage`, `Vivaldi Safe Storage`, `Opera Safe Storage`, `Chromium Safe Storage` | A hand-picked profile folder is recognised by its location. Opera GX, Aside and unknown Chromium browsers are not offered sign-ins. |
| Firefox | `cookies.sqlite` (`moz_cookies`) | none (plaintext) | Container, partitioned and other non-default `originAttributes` cookies are skipped. Expiry in seconds or milliseconds is accepted. Unset or `None` SameSite becomes Lax. |
| Safari | `Cookies.binarycookies` in `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/` (or `~/Library/Cookies/` on older macOS) | macOS Full Disk Access | Located only after consent, so detection never touches Safari's container. The file records no SameSite, so it becomes Lax. Damaged records are counted and skipped; a damaged file is refused. |

The option is off by default in Settings and resets when switching profiles, refreshing, cancelling, or finishing. The first-launch sheet ticks it when the suggested browser has sign-ins, names what is copied, and says which macOS permission may be requested; choosing **Import** there is the consent.

## Implemented acceptance checks

- Explicit opt-in plus confirmation precedes reading cookie rows or requesting Keychain access: in Settings, an off-by-default checkbox and a consent dialog; on first launch, the import sheet that names what is copied and what macOS will ask. Only the chosen browser's own Safe Storage item is requested, by service name; no key creation, ACL modification, fallback key, or protection bypass is implemented.
- A short-lived read-only SQLite transaction reads metadata, schema, and committed WAL rows consistently. No temporary plaintext exports are written. The adapter supports macOS `v10` AES-128-CBC, PBKDF2-HMAC-SHA1 (`saltysalt`, 1003 rounds), and verifies schema-v24+ SHA256 host binding.
- Domain/path, Secure, HttpOnly, expiry, and session-only lifetime are retained. Explicit SameSite None/Lax/Strict are represented; unspecified Chrome SameSite is tightened to Lax because WebKit maps a nil Foundation policy to None. Foundation's Secure/Discard presence-flag behavior is explicitly handled.
- Expired, partitioned, malformed, unknown-encryption, nonstandard-port, and HTTP-source-bound records are skipped. HTTPS source metadata never becomes an insecure cookie. At most 5,000 records are considered; when the profile is larger, Facet deterministically prioritizes the most recently accessed/updated records using the recency columns available in that Chrome schema, then applies stable scope/name tie-breakers. Additional skipped records are counted.
- Cookies are installed in the normal WebKit store. Existing Facet cookie identities, including host/domain-scope conflicts, are preserved rather than switching accounts. Installation is read back to verify the representable security attributes; rejected records are reported. Private windows remain separate.
- Cookie values, keys, and raw database/crypto diagnostics never appear in import status or logs. Results count cookies and hosts, not guaranteed authenticated accounts.

## Compatibility boundary

Session cookies can carry existing logins; saved passwords alone cannot. This is not a password vault and does not import Chrome's saved-password database, passkeys, client certificates, localStorage, IndexedDB, extensions, or device-bound credentials. Some sites require reauthentication or MFA regardless of cookie migration. Existing Facet cookies can also prevent a Chrome session from replacing the site's current state.

This is a best-effort migration between engines, not a clone of Chrome's security policy. WebKit has no Chrome source-port field; only conventional origins and legacy unbound cookies are attempted. Chrome-specific per-port isolation and other engine policies cannot be reproduced. Applications relying on those policies should use a fresh login instead. Chrome formats or Keychain protection that Facet cannot read are not bypassed.

## Verification

- `bash tools/run-polish-tests.sh --webkit`: **381/381 checks passed**, including the Chromium, Firefox and Safari sign-in fixtures in `tools/session-import-tests.swift`.
- Independent OpenSSL PBKDF2 vector; v23/v24/newer host-bound crypto fixtures; wrong key/host/version and malformed ciphertext rejection.
- Synthetic WAL-backed cookie-only profiles; one injected key lookup; denied-access and unsupported-only failures; no Keychain request for plaintext-only data; source database/WAL bytes unchanged.
- Nonpersistent WebKit round trips for SameSite, security flags, expiry, session lifetime, and host-only scope; repeated imports and conflicting account tokens preserve existing cookies.
- A loopback-only mock site receives the imported synthetic authentication cookie and renders **Signed in without login**. No credential submission or real website is involved.
- Native settings probes confirm default-off behavior, reset on browser switch/refresh, detailed consent, and cancel-before-import. Discovery is injected, so tests never scan real profiles.
- Optimized `build.sh` compilation and strict code-signature verification passed in an isolated `build/session-package.*/Facet.app`. The existing root app bundle was not replaced. Shell syntax and `git diff --check` passed.

A disposable real Google Chrome 152.0.7977.76 profile was also exercised through `tools/chrome-compat-smoke.sh`: Facet read the real History database, Chrome cookie schema 24 contained the required fields, and the test cookie used the supported `v10` storage prefix. The smoke test never opens the normal Chrome profile or reads Chrome Safe Storage by default. For an explicit developer-only crypto check, run `FACET_ALLOW_CHROME_KEYCHAIN_TEST=YES tools/chrome-compat-smoke.sh`; that opt-in path requests Chrome Safe Storage through the normal macOS prompt, decrypts only the known disposable fixture cookie, compares it to the expected fixture value, and never prints the secret or decrypted value. Manual follow-up remains for each real site's acceptance of migrated sessions.

## Upstream format references

- https://github.com/chromium/chromium/blob/main/components/os_crypt/async/browser/keychain_key_provider.mm
- https://github.com/chromium/chromium/blob/main/components/os_crypt/async/common/encryptor.cc
- https://github.com/chromium/chromium/blob/main/components/os_crypt/common/keychain_password_mac.mm
- https://github.com/chromium/chromium/blob/main/net/extras/sqlite/sqlite_persistent_cookie_store.cc
- https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/network/cocoa/CookieCocoa.mm
