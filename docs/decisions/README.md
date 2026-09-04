# Decision records

Each file captures why a non-obvious choice was made: the context, the
options that were tried, what was rejected, and a pointer to the change.
Code that depends on one of these carries a `// WHY: docs/decisions/<file>`
anchor; read the record before changing that code.

Records dated before September 2026 were written while Whytap still had a
cloud backend, accounts and paid tiers. Those parts of the product were
removed (see `../plans/2026-09-02-fully-local-open-source.md`), so mentions
of JWT, `api.whytap.ai`, Pro gating or server-side processing in older
records are historical context, not a description of the current app.
