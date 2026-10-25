## What does this PR do?

One or two sentences. Link the issue it closes (e.g., "Closes #12").

## Principle compliance checklist

Every PR answers these. If any box is honestly "no", explain why.

- [ ] **Offline** — works with zero internet (or is clearly labeled online-only, opt-in)
- [ ] **Cheap hardware** — no new memory/perf cost beyond the model budget
      (see [docs/architecture.md](../docs/architecture.md))
- [ ] **Voice-first** — usable without typing
- [ ] **Vernacular-first** — no English-only strings; user-facing text
      goes through `.arb` files
- [ ] **Private** — no network calls, no telemetry, no new data collected
      (see [PRIVACY_CHARTER.md](../PRIVACY_CHARTER.md))
- [ ] **Tender** — no dark patterns, no unrequested notifications, kind
      error messages (see [TENDER_UX_PRINCIPLES.md](../TENDER_UX_PRINCIPLES.md))
- [ ] **In scope** — serves one of the [top 20 use cases](../docs/use-cases.md)
      (or is infrastructure/docs)

## Testing

- [ ] `flutter analyze` is clean
- [ ] Tests added or updated (domain changes need 90% coverage)
- [ ] Tested on a real device (note which one — low-end devices count extra)

## Reviewer notes

Anything that needs special attention?
