# Architecture and implementation status

The delivery contract is the [final assignment](spec/assignment.txt). This document describes the current implementation and its limits; it does not turn a test name or a planned cluster run into acceptance evidence. Per-case status and run evidence are in [acceptance.md](acceptance.md).

## Component boundaries

- `RutviExercise.HTTP.Router` handles JSON, server-derived identity, request IDs, input bounds, status codes, and the public course/task endpoints. It delegates every task operation to the runtime API.
- `RutviExercise.Runtime` owns routing, caller-scope checks, stable IDs, parent/child links, idempotency, checkpoints, task state, event cursors, wait, resume, cancel, and restart recovery.
- `RutviExercise.Store` is the durable transaction boundary. It persists one serialized application snapshot in SQLite, using `BEGIN IMMEDIATE` and a single GenServer writer. The configured database file must be on the local PVC/volume.
- `RutviExercise.Runtime.Dispatcher` schedules attempts under OTP supervision. Work handlers and evaluator work use separate Task Supervisors. A single active application replica is supported; SQLite and the in-process dispatcher do not coordinate multiple replicas.
- `RutviExercise.Course` registers the course roles/services. The workflow handles research, planning, parallel lessons, review, targeted revision, and human checkpoints. The deterministic adapter selects results from task/role/lesson/revision inputs, never scheduling order.
- Vendored Synaptic supplies the workflow runner. It is not the task database, authorization layer, or recovery mechanism. Source revision and copy boundaries are recorded in [synaptic-source.md](synaptic-source.md).

The application supervisor uses `:rest_for_one`, ordered as Store, worker supervisors, Bootstrap, Dispatcher, then HTTP listener. A Store restart therefore restarts later execution and HTTP children against the same SQLite file. Bootstrap registers configured services after Store/worker startup and before Dispatcher/HTTP startup. The stored definitions reference workflow modules but do not pin a workflow-code version. Liveness answers without consulting the store; readiness requires the Store and Dispatcher to be alive.

## Persistence and recovery

The database currently stores the application state map as one SQLite BLOB row. Each mutation calculates a new state, writes it inside an immediate transaction, and replies after commit. This keeps the prototype atomic at the application-store boundary and makes process restart recovery simple. It also rewrites the full state snapshot for each mutation; history growth, lock duration, and migration strategy have not been measured. This is suitable for the assignment's one-active-replica scope, not a multi-node or high-volume production store.

The app persists service definitions, task inputs and scope, run/request IDs, parentage, idempotency keys, attempts, step outputs, checkpoints and accepted responses, counters, and ordered events. Dispatcher/recovery code treats persisted results and attempts as authoritative and rejects stale attempt completion. Provider calls remain outside the SQLite transaction. A crash after a remote side effect and before its result commit can still leave an unknown outcome, as allowed by the assignment.

Replay depends on explicit `Step.run` boundaries and stable delegation keys. It resumes durable outputs, but it has no version-pinned workflow definition or state migration for changed workflow code. The event list is currently retained in the serialized snapshot without a bounded retention/compaction policy. This is acceptable only for the measured single-run exercise; growth and upgrade behavior are not verified.

## HTTP and runtime configuration

The supervised `RutviExercise.HTTP.Server` listens on `HTTP_PORT` (default 4000). `GET /live` is liveness; `GET /ready` checks Store and Dispatcher. The router accepts a bearer token and resolves it to `namespace_id`, `user_id`, and `session_id` from `HTTP_IDENTITIES`; caller-looking JSON fields are ignored. Development/test builds include fixed demo tokens only when no identity map is configured. A production release without `HTTP_IDENTITIES` rejects protected requests with `authentication_not_configured`.

The browser Studio is disabled unless `RUTVI_STUDIO_DEMO=true`. When enabled, `/` and `/studio/*` serve the UI; `/studio-api/*` uses an HttpOnly SameSite=Strict signed session, a server-assigned demo identity and CSRF checks on mutations. It does not expose bearer tokens or relax the `/v1` API boundary. The local Kind ConfigMap enables this mode with `RUTVI_STUDIO_NAMESPACE=A`; its stable signing key is a separate Kubernetes Secret. A completed Kind Studio course used actual `gpt-6.1-sol` at medium reasoning through an authenticated loopback-only host gateway; the [latest verification](verification-2026-10-05-sol.md) records its model usage, recovered retries, quizzes, citations, and checkpoint resumes.

`RUTVI_MODEL_PROVIDER` selects a configured adapter (`codex`, `deterministic`, or `remote_codex`); unknown values fail configuration instead of silently selecting a fallback. Release runtime defaults to Codex; the standard Docker image and Compose path use deterministic/offline explicitly. Test configuration also uses deterministic. The `codex` adapter calls the host Codex CLI through vendored `Synaptic.Tools.CodexExec`. `remote_codex` sends the structured request to an authenticated host gateway, which uses the same local CLI with `gpt-6.1-sol` at medium reasoning. The Kind app receives only a server-side gateway token through a Kubernetes Secret; the image has no CLI or host credentials. `codex_local` is an explicit 90-second profile for this local course path; the default strict profile remains unchanged.

The API returns JSON error codes with stable statuses: `unauthorized` 401, `forbidden` 403, `not_found` 404, conflicts/ambiguity 409, `validation_error` 422, bounded `limit_exceeded` 429, and `unavailable` 503. Wait requests are bounded to 30 seconds and do not cancel on timeout. API paths and request examples are in [README.md](../README.md).

The current public service contracts are broad object schemas; the course role/model boundaries validate more specific outputs, but the compiled course workflow does not expose a complete domain-level graph with all step inputs, outputs, and timeout metadata. Lesson and question schemas validate citation IDs, but citations are attached to each lesson/question rather than mapped and checked against every factual claim. The optional evaluator is an asynchronous observer: it samples the pre-step task, reads the post-step task later, stores the evaluator's return value without score/reason validation, and isolates failure. It is not the fully specified scored evaluator with an atomic before/after snapshot pair.

Possible future extensions: strict public request/result schemas and complete workflow introspection; claim-to-passage provenance and semantic checks; a scored evaluator with atomic immutable pre/post snapshots, validated score/reason, timeout/failure and replay semantics; versioned workflow/snapshot migrations; bounded history retention and load limits. The current version has none of those guarantees beyond its narrower implemented checks.

## Local operations

The Docker build copies `vendor/synaptic` into its build context and creates a Mix release without a developer path dependency. Both stages pin the official Elixir 1.18.3-slim multi-architecture image digest (OTP27), which compiled the vendored Synaptic version used by this app. The entrypoint caps inherited open-file limits at 65,536 only when they are higher; Kind otherwise passes a value over one billion and BEAM allocates until OOM. `/data` stores SQLite. Compose uses deterministic/offline; the dedicated local Kind ConfigMap selects `remote_codex` and `codex_local`, with the gateway bearer secret sourced from a private file and stored in a Kubernetes Secret. Kubernetes uses a single-replica `Recreate` deployment, PVC, resource limits, and health probes. Scripts require an explicit recognized local context; they reject `engeto-prod-v2`, and each `kubectl` command specifies `--context`.

The native Mix release and Docker release were both built and exercised. A local Kind cluster validated liveness/readiness, authorization, checkpoint survival across app-pod replacement, root-scoped HTTP resume, completion, and durable event history. The final Kind Studio course also completed through the actual host Luna gateway, with lesson-author questions, citations, recoverable invalid outputs, and human checkpoint resumes. Successful-response usage was recorded, but failed responses had no usage payload and currency spend was unavailable; currency cost cannot be verified. Docker Compose was not started. See [acceptance evidence](acceptance.md).

## Known limits and follow-up

- One active application replica and one SQLite writer. Multi-replica leases, distributed limits, failover ownership, and remote discovery are not implemented.
- SQLite schema evolution is currently an opaque serialized snapshot rather than a versioned migration set.
- Provider calls outside the transaction can have uncertain external effects after a crash.
- The standard container remains offline and has no Codex CLI or user credentials. `remote_codex` is a development-only authenticated bridge to a host CLI; it is loopback-bound and is not a general remote deployment adapter.
- During a host-managed child checkpoint, Synaptic logged `step course failed permanently: :waiting_for_children` although the durable parent remained suspended and completed after resume. This is a misleading inner-runner diagnostic for intentional suspension; acceptance follows the persisted task state and HTTP result.
- T7 has a successful local Kind pod-replacement/recovery run; this verifies the assignment's single-node local path, not remote-cluster or production operations. T8 has a completed actual-model course and recorded selected settings, retries, concurrency, token usage, and artifact. Currency spend is unavailable, so no currency total is claimed.
- The Synaptic checkout declares MIT in package metadata but the copied upstream tree had no tracked license text. See the provenance note before redistribution.
