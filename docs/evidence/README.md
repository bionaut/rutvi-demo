# Sanitized local-model run evidence

These files record the completed Kind Studio run with reference `iBlFNHzltjBBB1T0I4tzBQdo`.

- `iBlFNHzltjBBB1T0I4tzBQdo-course.json` is the stored completed course artifact. It contains the course content and its source citations, but no model prompts or credentials.
- `iBlFNHzltjBBB1T0I4tzBQdo-trace.json` is a field-whitelisted extraction from the durable task history. It includes ordered event IDs/sequences/timestamps, task/service relationships, model outcome codes, settings, and reported usage. It omits request inputs, prompts, raw model responses, user/session identity fields, authorization data, and secrets.

The stored root timestamps are 2026-09-28 16:24:46.751097 UTC and 16:28:37.616883 UTC. The 230.865-second wall duration includes both human checkpoint waits and should not be read as model compute time. The trace records 12 model-response events: 8 successful, 4 retryable `invalid_output`; successful responses reported 161,941 prompt and 3,282 completion tokens. Failed responses had no usage payload. No currency total was available, so these files do not prove a €5 spend ceiling.

This evidence was extracted read-only from the dedicated local Kind app's persisted SQLite-backed store. It is an assignment evidence artifact, not a synthetic test fixture. The exact T1+T3 Kubernetes recovery scenario from historical v4 is still not verified; see `docs/acceptance.md` for that distinction.
