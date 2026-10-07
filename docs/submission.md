# Submission notes

Author and responsible contributor: Ján Krajňák.

## Time spent and reused work

Approximately **11 hours of active work**, estimated by the author, on the exercise's implementation, testing, local deployment, and documentation. This is an estimate, not a time-tracking record. It is separate from the elapsed time of individual AI generation runs.

The exercise reuses the author's existing **Synaptic 0.3.0-alpha.13** framework, included as source under `vendor/synaptic`. Prior development of that framework is not included in the exercise estimate. Its source revision and copied inventory are documented in [source provenance](synaptic-source.md).

## AI assistance during development

**OpenAI Codex, including delegated AI coding agents**, assisted with planning, implementation, debugging, tests, documentation, and review. The author directed the work, selected the architecture and scope, and remains responsible for the delivered solution. AI assistance is disclosed rather than represented as unaided implementation.

## AI used by the application

The delivered real-model adapters select **`gpt-6.1-sol` with `medium` reasoning**, through an authenticated local **Codex CLI 0.160.0**. The CLI runs on the host and accesses OpenAI's hosted model; inference does not run inside the Kubernetes pod or locally on the CPU. Kubernetes calls the authenticated host gateway. Credentials are not included in the source archive.

Earlier development also used **`gpt-6-luna` with `low` reasoning**. Historical verification remains identified as such. The deterministic offline adapter is a test fixture and is not evidence of real AI generation.

## Libraries and tools

- Elixir/OTP and the vendored Synaptic workflow framework.
- Exqlite and SQLite for application-owned durable task state, checkpoints, and history.
- Plug/Cowboy for HTTP; Jason for JSON; ExJsonSchema for schema validation.
- Synaptic dependencies include Finch and Phoenix PubSub; exact dependency versions are in the lockfiles.
- HTML, CSS, and JavaScript for the Studio; Node.js's built-in test runner for UI helper tests.
- Docker and a local Kind Kubernetes cluster, with a persistent volume and authenticated host gateway.

Synaptic supplies workflow and model integration primitives. Durable application state, ownership enforcement, scheduling limits, and restart recovery in this exercise are implemented by Rutvi's application runtime. The framework's default in-memory stores alone do not provide these persistence guarantees.

## Verification of the delivered source

On **7 October 2026**, `scripts/check.sh` passed formatting, compilation with warnings treated as errors, **58 Elixir tests**, **3 JavaScript UI tests**, shell syntax checks, and Git whitespace checks. This check used the deterministic adapter and made no model requests.

The latest recorded real-model course was completed on **5 October 2026** with Sol at medium reasoning in local Kubernetes. Its actual course and redacted history are in [the evidence directory](evidence/README.md). The recorded 426.377-second duration includes human checkpoint waits and pod replacement. These files are historical evidence, not a claim of a new real-model run on 7 October. The [verification report](verification-2026-10-05-sol.md) describes retries, the subsequent logging correction, and the bounds of that verification.

## Delivery and limits

The offer identifies the full Git commit SHA and includes a source archive generated from that commit. The immutable archive is the submitted source snapshot; later repository changes do not redefine it.

The prototype uses six supplied source passages, creates two lessons and three quiz questions, and supports one active replica with SQLite and a persistent volume. It does not implement open-web research, multi-replica coordination, or migration of incomplete workflows between versions. See [architecture and limitations](implementation-plan.md) and [acceptance evidence](acceptance.md).
