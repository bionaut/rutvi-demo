# Sanitized local-model run evidence

## Current verification — 5 October 2026

- [Completed course](2026-10-05-course.json): two Czech lessons, two learning objectives, three quiz questions, and source citations.
- [Redacted history](2026-10-05-trace.json): actual ordered events, timestamps, agent relationships, artifact IDs, model settings, outcome codes, and reported usage. Inputs, prompts, raw model responses, identity fields, credentials, and detailed error text are omitted.

Run `snSY-g-z5wk0SGHLCZeT9Aqb` used real `gpt-6-luna` at low reasoning through the authenticated host gateway and the Kind application. It started at 14:31:13.341008 UTC and completed at 14:35:46.752399 UTC on 5 October 2026 (16:31–16:35 in Warsaw). Its 273.411-second wall duration includes two human checkpoint waits and a pod replacement. The same checkpoint, run ID, and earlier history survived the replacement; both checkpoints resumed successfully.

The trace records 12 model responses: 9 successful and 3 retryable `invalid_output` outcomes. Successful responses reported 196,100 prompt tokens and 3,732 completion tokens. Failed responses provided no usage, and currency spend was unavailable. All 24 external starts have corresponding finishes; peak concurrency was two. The trace includes a SHA-256 checksum of the course file.

See the [verification record](../verification-2026-10-05.md) for checks and limitations.

## Earlier verification

These files record the completed Kind Studio run with reference `iBlFNHzltjBBB1T0I4tzBQdo`.

- `iBlFNHzltjBBB1T0I4tzBQdo-course.json` is the stored completed course artifact. It contains the course content and its source citations, but no model prompts or credentials.
- `iBlFNHzltjBBB1T0I4tzBQdo-trace.json` is a field-whitelisted extraction from the durable task history. It includes ordered event IDs/sequences/timestamps, task/service relationships, model outcome codes, settings, and reported usage. It omits request inputs, prompts, raw model responses, user/session identity fields, authorization data, and secrets.

The stored root timestamps are 2026-09-28 16:24:46.751097 UTC and 16:28:37.616883 UTC. The 230.865-second wall duration includes both human checkpoint waits and should not be read as model compute time. The trace records 12 model-response events: 8 successful, 4 retryable `invalid_output`; successful responses reported 161,941 prompt and 3,282 completion tokens. Failed responses had no usage payload. No currency total was available, so these files do not prove a €5 spend ceiling.

This evidence was extracted read-only from the dedicated local Kind app's persisted SQLite-backed store. It is an assignment evidence artifact, not a synthetic test fixture. The exact T1+T3 Kubernetes recovery scenario from historical v4 is still not verified; see `docs/acceptance.md` for that distinction.
