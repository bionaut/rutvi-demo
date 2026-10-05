# Verification — 5 October 2026

Verification was performed on the local checkout and a dedicated Kind cluster, using Europe/Warsaw as the local timezone.

## Automated checks

`scripts/check.sh` passed formatting, compilation with warnings treated as errors, **57 Elixir tests**, **3 JavaScript UI tests**, shell syntax checks, and Git whitespace checks. The Elixir suite used seed `806221`. A second full Elixir run with seed `320954` also passed all 57 tests.

The initial rerun exposed an intermittent HTTP course-completion failure. A focused regression reproduced the underlying race: a completed parallel child could overwrite its parent's suspension on another child or erase a queued replay. The delegation layer now preserves both states and fences stale attempts. The regression failed before the fix and passed afterward.

The automated model tests use deterministic or fake adapters. Actual AI verification is recorded separately below.

## Local deployment

The production Docker release was rebuilt with Elixir 1.18.3 and OTP 27 and loaded into the dedicated `kind-rutvi` cluster. The application runs as one replica with its SQLite database on a bound 2 GiB PVC. Every Kubernetes operation used the dedicated kubeconfig and explicit context.

The image build ID was `sha256:4e0d312f6c2ee42e4c821c8f05864a8fc3b40a022ac15109c2be52e1dbf670f3`. The running pod reported imported image digest `sha256:46bd1fbea9919e2697eadc9cc20c072889589bdc2eaf2dc345ad7afeb3ce8197`.

The UI, JavaScript, stylesheet, session endpoint, `/live`, and `/ready` returned HTTP 200 through a loopback-only port-forward at `127.0.0.1:4018`. The session endpoint reported provider `codex` and model `gpt-6-luna`.

The application uses the authenticated host Codex gateway, CLI 0.158.0, model `gpt-6-luna`, low reasoning, and the `codex_local` timeout profile. Credentials remain outside the repository and submission artifacts.

## Actual AI and recovery

Run `snSY-g-z5wk0SGHLCZeT9Aqb` started at **14:31:13.341008 UTC** and completed at **14:35:46.752399 UTC** on 5 October 2026. The 273.411-second duration includes human input and a pod replacement. The output contains two Czech lessons (183 and 151 whitespace-separated words), two learning objectives, three quiz questions, and source citations.

At the first human checkpoint, the exact application pod was deleted. Its replacement used the same PVC. The run ID and checkpoint ID were unchanged, and all 25 earlier event IDs remained an identical history prefix. Recovery added three events. Both audience and style checkpoints were then resumed, and the root completed. Reads with another user in the same namespace and a user in another namespace each returned HTTP 403.

The run recorded 12 model responses: nine successful and three retryable `invalid_output` outcomes that recovered. Successful responses reported 196,100 prompt tokens and 3,732 completion tokens; failed responses had no usage payload. The trace records 24 external starts and finishes, with peak concurrency two.

The [course](evidence/2026-10-05-course.json) and [redacted history](evidence/2026-10-05-trace.json) were extracted from this completed run. The trace includes actual timestamps and a checksum of the course. It omits prompts, inputs, raw model responses, detailed errors, identity fields, and secrets.

## Limits of this verification

Pod replacement was tested while waiting for human input. A pod crash during lesson authoring was not tested in this Kubernetes run; process recovery after a saved lesson is covered by the offline suite. Currency spend is unavailable, so reported token usage does not establish a monetary spend ceiling. UI assets and session/health endpoints were checked over HTTP; this run was controlled through the authenticated HTTP API, not a browser end-to-end test.
