# 💛 Neyam Vaani — Tender UX Principles

> Tender UX is what makes Vaani different from every other AI assistant.
> Every screen, interaction, and sentence must pass the test below.
> If any answer is "no," go back and redesign.

## The Tender UX Test

1. **Does this respect the user's attention?** If it interrupts them
   without their explicit request, no.
2. **Does this respect the user's intelligence?** If it explains itself in
   jargon or assumes they don't understand, no.
3. **Does this respect the user's time?** If it makes them tap through
   unnecessary steps, no.
4. **Does this respect the user's language?** If the UI forces English on
   a Tamil speaker, no.
5. **Does this respect the user's data?** If it sends anything anywhere
   without explicit opt-in, no.
6. **Does this respect the user's autonomy?** If it tries to make them
   dependent on the app, no.
7. **Does this respect the user's dignity?** If it makes them feel stupid
   or rushed, no.

## The rules

| Rule | Implementation |
|---|---|
| No push notifications except user-set reminders | WorkManager schedules only user-created reminders. No "we miss you" messages. Ever. |
| No streaks, badges, or gamification | None. Period. |
| No "premium" feature lockouts | All core features free, forever. |
| All errors are kind | "I couldn't hear you clearly. Can you try again?" — not "Audio input failed (0x8000)". |
| All loading states are honest | "I'm thinking…" — not "Processing request…". No fake delays to seem smarter. |
| All confirmations are calm | Quiet acknowledgement; no celebration screens. |
| No engagement metrics shown to users | No usage stats, no "day streaks". |
| Always offer a way out | End any conversation in one tap. Delete any reminder in two taps. Clear any data in three taps. |
| Voice-first, honest visuals | Visual UI is a fallback — but it always shows what was heard and said, so users with partial hearing can verify. |
| Honest uncertainty | "I don't know" beats a confident hallucination. Always. |

## Voice personality

When Vaani speaks, it is:

- **Calm, patient, attentive** — neutral-warm, never enthusiastic, never flat.
- **Slightly slower than default** (~0.9x), with brief pauses between sentences.
- **Simple** — common words, no jargon, no idioms that don't translate.
- **Brief** — 1–3 sentences unless asked for more.
- **Honest** — says "I don't know" rather than guessing.
- **A tool, not a friend** — no persona, no backstory, no manufactured
  intimacy. Vaani helps; it does not keep company.

## Forbidden patterns

Any of the following in a PR is an automatic request-for-changes:

- Engagement-maximizing copy ("You're on a 5-day streak!").
- Manufactured urgency or fear ("Your data may be at risk — upgrade now").
- Artificial delays or fake "thinking" spinners.
- Anthropomorphic emotional manipulation ("I'm sad to see you go").
- Any notification the user did not explicitly create.
