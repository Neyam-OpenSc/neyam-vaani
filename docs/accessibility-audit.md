# Accessibility Audit — WCAG 2.2 AA against the current skeleton

**Status: static/code-level audit only. Nothing here has been validated on
hardware or with a screen reader yet — that is Phase 9 work and is listed
as such below.** This document is the honest baseline: what the code
already satisfies, what it cannot claim without devices, and what is
plainly still open.

Scope: `app/` at the time of the Phase 9 prep sprint (l10n tables for 9
languages, calm error/loading widgets, settings/conversation/home
skeleton, voice session state machine).

---

## 1. What the code already satisfies

| WCAG 2.2 criterion | How the code satisfies it |
|---|---|
| 2.3.1 Three flashes (or below threshold) | Loading states animate slowly by design: `ListeningIndicator` is a single dot pulsing over ~2.4s; `SpeakingIndicator` waves bar heights (never opacity) over ~3.6s. Nothing approaches 3 Hz. |
| 2.3.3 Animation from interactions | `ListeningIndicator` and `SpeakingIndicator` honor `MediaQuery.disableAnimations` and render fully static when the OS "remove animations" setting is on (widgets/loading_states.dart). |
| 3.3.1 / 3.3.3 Error identification & suggestion in kind language | `ErrorMessage` shows one plain localized sentence plus an optional "Try again" — no error codes, no blame (TENDER_UX_PRINCIPLES.md: "All errors are kind"). `failureToMessageKey` maps every failure kind to a kind sentence. |
| 3.1.2 Language of parts (partial) | All UI strings resolve per the selected language for 9 languages, including endonyms in the picker; key parity across languages is enforced by `test/l10n_strings_test.dart`. |
| 1.4.1 Use of color | Errors are icon + text, never color alone; selected language uses a check icon, not color alone. |
| 4.1.2 Name, role, value (code level) | Loading indicators expose localized `Semantics` labels; status texts in the conversation screen are `liveRegion`s; `PermissionExplainer` labels its content and both buttons, styled equally. |
| 2.5.1 Pointer gestures | The primary action (talk) is a tap, not a press-and-hold or swipe; no path requires multipoint gestures. |
| 2.5.8 Target size (minimum) | The mic button is large; language options are full-width `ListTile`s (>= 48dp). Needs visual confirmation on small screens (below). |
| 1.4.2 Audio control | Spoken output is interruptible from the state machine (`stopSpeaking`/`endSession` are always reachable). Needs device confirmation for real latency. |

## 2. What Phase 9 must verify on real devices

These cannot be claimed from code alone:

- **1.4.3 / 1.4.6 / 1.4.11 Contrast.** All colors come from Material theme
  roles; the actual ratios (especially `outline`-colored status text on
  background, and light/dark variants of the final palette) must be
  measured on the shipping theme, at the setting screens and the
  conversation status text.
- **1.4.4 / 1.4.10 Text resize 200% and reflow.** Run every screen at
  200% font scale on a 720p low-end device with real Indic fonts —
  Tamil and Devanagari line heights are taller than Latin and clip in
  `AppBar`/`ListTile` subtitles in unexpected places.
- **2.4.3 / 2.4.7 Focus order & focus visible.** TalkBack linear
  navigation and visible focus with keyboard/Switch Access across
  settings -> language pick -> conversation loop; confirm nothing
  custom has suppressed the default Material focus highlight.
- **4.1.2 on-device.** TalkBack announcement order for the voice session
  states (idle -> listening -> thinking -> speaking), politeness of the
  live regions, and whether the pulsing dot is announced as "listening"
  in Tamil/Hindi when the system language is English.
- **2.3.3 on-device.** Confirm Android's "remove animations" toggle
  actually reaches the app (`MediaQuery.disableAnimations`) on the
  target API levels.
- **TalkBack end-to-end paths.** The full grandmother path: change
  language, grant a permission via the explainer dialog, interrupt
  speech, clear history — each navigable and announced sensibly.
- **Performance as accessibility.** Jank on the $200/2GB target device
  (voice + LLM active) that truncates or stutters TTS/animation is an
  accessibility failure for this user base; measure with real model
  files.

## 3. Open items in code (known gaps)

- `MaterialApp` does not yet set `locale` from `selectedLanguageProvider`,
  so system-level locale (and per-platform font selection) does not
  follow the in-app language choice. Wire in Phase 9.
- The home and conversation screens still carry some hard-coded English
  strings behind `TODO(l10n)` — they have keys waiting in
  `l10n/app_strings.dart`; swap them over as screens are touched.
- No large-text layout QA pass has happened; treat `MediaQuery.textScale`
  edge cases as untested.
- Keyboard/D-pad traversal is untested (voice-first, but Switch Access
  users depend on it).

## 4. Rule for PRs from here on

Every new screen or state must arrive with: localized strings (9
languages, key parity), semantics labels on anything non-textual, calm
(non-flashing) animation with a `disableAnimations` static fallback, and
kind error text. "We'll add accessibility later" is how Phase 9 becomes
Phase 90.
