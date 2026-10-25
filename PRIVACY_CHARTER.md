# 🔒 Neyam Vaani — Privacy Charter

> **This charter is immutable. No feature, sponsor, or roadmap item may
> violate it. Any PR that conflicts with it will be rejected.**

> **Neyam Vaani is private by default. The user is the only person who ever
> sees their data. There is no cloud, no account, no telemetry, no
> advertising, no third-party APIs. Every byte of user data lives on their
> device, encrypted. If they uninstall the app, the data is gone — and
> that's how it should be.**

## The guarantees

| Data type | Storage | Retention | Cloud? |
|---|---|---|---|
| Voice recordings | RAM only | Never persisted | Never |
| Transcriptions | Encrypted SQLite | User-deletable, 30 days default | Never |
| Conversation history | Encrypted SQLite | User-deletable, 30 days default | Never |
| Documents scanned | RAM only | Only if user saves → encrypted file | Never |
| Notes & reminders | Encrypted SQLite | Until user deletes | Never |
| Contacts accessed | RAM only, for the requested action | Never stored | Never |
| Location | RAM only, for the requested action | Never stored | Never |
| App usage analytics | None | None | Never |

## The "never" list

These are permanent product decisions, not v1 limitations:

- ❌ No advertising — ever, in any form.
- ❌ No selling or sharing user data — we never collect it in the first place.
- ❌ No telemetry, crash reporting, or usage analytics — not even "anonymized."
- ❌ No accounts, sign-ins, or phone-number verification.
- ❌ No cloud AI calls — unless the user explicitly opts in for a specific action.
- ❌ No SDKs that phone home. Every dependency is audited for network behavior.

## Permissions (minimal, just-in-time)

Permissions are requested only when needed for a specific user action, and
always with a one-sentence explanation **in the user's language**:

| Permission | When requested | Why (as spoken to the user) |
|---|---|---|
| Microphone | First voice use | "To hear you" |
| Camera | First document scan | "To photograph your document" |
| Storage | First document save | "To save your document" |
| SMS | First SMS action | "To send the message you asked for" |
| Phone | First call action | "To make the call you asked for" |
| Location | First location action | "To find what's nearby" |
| Notifications | First reminder set | "To remind you when you asked" |

## Security implementation

- All SQLite databases encrypted with **SQLCipher** (AES-256).
- Encryption key stored in the **Android Keystore** (hardware-backed where available).
- The only network traffic is **language pack updates** — over TLS 1.3,
  GPG-signed, verified before install, and always opt-in.
- If the device is rooted, we warn the user once, then respect their choice.
- Documents are never uploaded. Photos exist in RAM only unless the user saves them.

## How this is enforced

1. Every release is audited with a network monitor: **zero unexpected traffic**.
2. Every new dependency requires a PR review that documents its network behavior.
3. Any charter violation is grounds for immediate revert, regardless of who merged it.
