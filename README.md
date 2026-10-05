# Rutvi Creator Studio

An Elixir/OTP application that turns supplied learning sources into a short Czech course. Research, planning, lesson-writing, and review agents work through a durable task runtime. The browser Studio shows progress, collects human input at checkpoints, and exports the completed course as JSON.

The repository includes an offline deterministic adapter and real AI through an authenticated local Codex CLI. Synaptic is vendored in `vendor/synaptic`; no other source checkout is needed.

- [Assignment (PDF)](docs/spec/assignment.pdf) · [Searchable text](docs/spec/assignment.txt)
- [HTTP API](docs/api.md) · [Local Kubernetes](docs/kubernetes.md)
- [Architecture and limitations](docs/implementation-plan.md) · [Recorded acceptance evidence](docs/acceptance.md)

## Prerequisites

Use **Elixir 1.18.3 and Erlang/OTP 27**, matching the tested container. OTP 28 is not supported by this vendored framework version. Install Node.js 22 or newer for the UI tests; there are no npm dependencies. Initial dependency installation needs network access, Git, and a C compiler/build tools for SQLite if a precompiled NIF is unavailable (Xcode Command Line Tools on macOS, `build-essential` on Ubuntu).

```sh
mix local.hex --force
mix local.rebar --force
mix deps.get
```

Run all commands below from the repository root.

## Quick start: offline Studio

```sh
RUTVI_MODEL_PROVIDER=deterministic RUTVI_STUDIO_DEMO=true mix run --no-halt
```

Open **http://localhost:4000/**. Enter a topic and audience, create a course, and inspect the lessons, quiz, sources, and history. Enable the audience/style checkpoints in the form to try human approval. Download the final JSON using the export control. Stop the app with Ctrl+C twice.

Offline responses are fixtures: this mode verifies the workflow and UI, not AI quality or arbitrary-topic research. The exercise uses six built-in source passages, not open-web research.

SQLite state is saved in `data/rutvi.sqlite3`. Restarting with the same database preserves tasks. To try a separate empty workspace, set `RUTVI_DATABASE=data/another-demo.sqlite3`. The default Studio signing key changes on startup, so set a stable `RUTVI_STUDIO_SECRET` of at least 64 characters to preserve browser access across restarts.

Studio demo mode gives visitors a server-assigned demo identity; it has no public sign-in. The native HTTP listener binds all interfaces, and development API tokens are fixed fixtures. Run it on a trusted development machine/network. The Docker and Kubernetes recipes expose the browser only through loopback.

## Run with real AI

Install and authenticate the Codex CLI on the host. The recorded successful run used CLI `0.158.0`, model `gpt-6-luna`, and low reasoning. Your account must have access to that model. See [provider details and recorded verification](docs/local-codex.md).

```sh
codex --version
codex login status
RUTVI_MODEL_PROVIDER=codex RUTVI_MODEL_PROFILE=codex_local \
  RUTVI_STUDIO_DEMO=true mix run --no-halt
```

Open the same Studio URL and create a course. The `codex_local` profile allows 90 seconds per model request; the default strict profile allows 10 seconds and is usually too short for this local CLI flow. Real generation consumes account usage and can take several minutes, plus time waiting for checkpoint input. Errors are surfaced; the app never silently substitutes offline output.

The app runs the CLI in a temporary directory with read-only execution and low reasoning. Keep account credentials on the host. Containers contain neither the CLI nor credentials. For real AI in Kubernetes, use the authenticated host gateway described in [Local Kubernetes](docs/kubernetes.md).

## Test and verify

```sh
scripts/check.sh
```

This runs formatting, compilation with warnings treated as errors, the Elixir suite, UI unit tests, shell syntax checks, and whitespace checks. It forces the offline provider and a separate temporary test database. No Codex login, model calls, Docker, or Kubernetes are required. GitHub Actions runs the same command on pushes and pull requests.

For focused checks:

```sh
MIX_ENV=test RUTVI_MODEL_PROVIDER=deterministic mix test test/recovery_test.exs
node --test test/studio_ui_test.js
```

The Elixir suite covers routing/ownership, idempotency, coordination, model/tool validation, checkpoints, retries, cancellation, persistence, HTTP routes, and gateway behavior. UI tests check rendering helpers; they are not a browser end-to-end suite. Tests named `real_course_reliability` use fake adapters and do not call a real model. Vendored upstream tests are retained as source but are not part of the root application suite.

Manual acceptance:

1. Create an offline course; verify two lessons, three quiz questions, sources, and JSON export.
2. Enable checkpoints; submit audience/style and verify the run resumes.
3. Restart while a checkpoint is waiting; inspect the saved task and resume it. Use a stable Studio secret to keep the browser session.
4. Run a real-AI course separately and inspect its output and model history.
5. Follow the Kubernetes recipe to verify pod replacement against the same PVC.

Historical results and sanitized real-AI output are in [acceptance evidence](docs/acceptance.md) and [sample course/trace](docs/evidence/README.md). Those records do not replace a fresh run on another machine.

## Docker Compose: offline Studio

Docker Desktop or Docker Engine with Compose is required. Generate local runtime secrets in your current shell:

```sh
HTTP_TOKEN=$(openssl rand -hex 24)
export HTTP_IDENTITIES="{\"$HTTP_TOKEN\":{\"namespace_id\":\"A\",\"user_id\":\"u1\",\"session_id\":\"s1\"}}"
export RUTVI_STUDIO_SECRET=$(openssl rand -hex 48)
unset HTTP_TOKEN
docker compose up --build
```

Open http://localhost:4000/. Compose uses the offline provider and saves SQLite in the `rutvi-data` volume. Keep the same signing secret for browser sessions across restarts. Stop with `docker compose down`; this preserves the volume. `docker compose down --volumes` also deletes saved courses. Never commit secret values.

## Configuration

| Variable | Purpose / default |
|---|---|
| `HTTP_PORT` | HTTP port; `4000` |
| `HTTP_IDENTITIES` | Production bearer-token map with server-owned namespace/user/session IDs; see [API](docs/api.md) |
| `RUTVI_DATABASE` | SQLite file; `data/rutvi.sqlite3` natively |
| `RUTVI_MODEL_PROVIDER` | `codex`, `remote_codex`, or `deterministic`; native default is `codex`, tests/container default to offline |
| `RUTVI_MODEL_PROFILE` | `strict` or `codex_local` |
| `RUTVI_STUDIO_DEMO` | Enable local browser demo; default `false` |
| `RUTVI_STUDIO_SECRET` | Stable session-signing secret, at least 64 characters; generated per start if omitted |
| `RUTVI_STUDIO_NAMESPACE` | Studio namespace; default `A` |

The application reads environment variables directly; it does not automatically load `.env` files. Compose supports its own `.env` handling. See [Kubernetes](docs/kubernetes.md) for gateway-specific variables and secret files.

## Architecture and delivery boundaries

One active replica owns a SQLite-backed durable state store. It persists task identity, scope, events, checkpoints, results, and service registration. OTP workers execute the agents and recover saved work. Kubernetes uses one replica, a PVC, `Recreate` rollout, and liveness/readiness probes. Multi-replica operation and migrations between workflow versions are outside this implementation.

`lib/` contains the application; `priv/studio/` contains the browser UI; `test/` contains offline checks; `scripts/` and `k8s/` contain local operations. `mix.lock` pins dependencies. Generated builds, downloaded dependencies, runtime databases, credentials, and local artifacts are excluded from Git and Docker build contexts.

See [vendored source provenance](docs/synaptic-source.md) for the framework revision and its license metadata. No license grant for the application is implied by this repository; redistribution terms must be supplied by its owner.
