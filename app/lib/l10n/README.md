# l10n — localization for Neyam Vaani

Strings for all 9 languages (Tamil, Hindi, Bengali, Kannada, Telugu,
Marathi, Bhojpuri, Maithili, English) live here.

## The dual system (and why)

This folder intentionally carries **two parallel copies of every string**:

1. **`app_strings.dart` — what the app reads today.** A codegen-free
   `static const` map of tables, keyed by language code, with English as
   the base. Zero codegen, zero extra dependencies, trivially readable
   in review, and `flutter test` can verify key parity across languages
   (`test/l10n_strings_test.dart`).
2. **`app_*.arb` — the migration path.** The same keys and the exact
   same values in ARB format, ready for `flutter gen-l10n` when the
   project grows into placeholders/pluralization. When that day comes,
   code swaps `AppStrings.of(...)` for `AppLocalizations.of(...)` and
   this folder loses the Dart map — not the other way around.

**The invariant:** `.arb` values must mirror `app_strings.dart` exactly.
If you change one, change the other in the same commit. (The parity test
covers the Dart table today; extend it to parse the `.arb` files when a
JSON parser dependency is ever allowed.)

## Steward review — no machine translation ships unreviewed

Every non-English table in `app_strings.dart` sits behind a
`// steward review pending` comment. That marker means exactly this:

> The strings are a genuine human-considered draft, **not** a sign-off.
> A native-speaker steward for that language must review every sentence
> (tone, respect, natural everyday phrasing, correct register for elders)
> before the language counts as shipped.

Workflow for a language to graduate:

1. A native speaker opens (or claims) the steward issue for their
   language (see CONTRIBUTING.md, "language stewards").
2. They review every value in `app_strings.dart` **and** the matching
   `.arb` file, and suggest corrections as PRs or issue comments.
3. Once every sentence is approved, the PR removing the
   `// steward review pending` comment for that language merges, and the
   language is listed as steward-reviewed in the README.
4. New keys added later re-open review for **all** languages — the
   marker comes back until each steward signs off again.

Tone rules that reviewers enforce (TENDER_UX_PRINCIPLES.md): calm,
feminine voice persona, simple everyday words, respectful to elders,
**no exclamation marks**, honest states. Example register:
`listening` → `கேட்குது…` (ta) / `सुन रही हूँ…` (hi).

## How to add a key

1. Add the English sentence to the `'en'` table in `app_strings.dart`,
   plus a typed getter (`String get yourKey => resolve('yourKey');`).
2. Add a genuine draft translation to **every** other language table in
   `app_strings.dart`. Never paste English into a non-English table, and
   never leave a key out — `l10n_strings_test.dart` fails the build on
   any missing or extra key. New keys keep the
   `// steward review pending` state for all languages.
3. Mirror the same keys and values in all nine `app_*.arb` files
   (`app_en.arb` may also carry a `@key` note for translators).
4. Run `flutter test test/l10n_strings_test.dart` — key parity,
   non-empty values, and spot checks must pass.
5. Update every screen that should show it. Grep before deleting a key;
   resolution falls back to English, so a missing table entry is a
   review-visible bug, not a crash.

## Fallback behavior (by design)

`AppStrings.of(code)` falls back to English for unknown codes, and
`resolve(key)` falls back to English for missing keys, then to the calm
generic English sentence — a grandmother never sees a blank screen, a
raw key, or an error code.
