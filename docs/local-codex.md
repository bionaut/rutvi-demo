# Local Codex development model

For current startup commands, see the [README](../README.md#run-with-real-ai) and [Kubernetes guide](kubernetes.md). Probe results below are historical evidence; references to the €5 ceiling describe the older assignment.

`RutviExercise.Models.Codex` calls the vendored `Synaptic.Tools.CodexExec` adapter. It does not call an OpenAI API adapter, read API credentials, or silently switch providers. Runtime settings are fixed to model `gpt-6-luna` and reasoning effort `low`; failures return structured errors.

Each call runs `codex exec` as a noninteractive, ephemeral local subprocess with approval set to `never`, the read-only sandbox, and a 30-second default timeout capped at 120 seconds. The adapter uses a dedicated temporary scratch directory as the process working directory, writes the supplied JSON Schema there for `--output-schema`, and removes that temporary schema after the call. It does not add the application repository as a writable directory. The caller must provide only the prompt/messages and facts permitted for that model request.

CodexExec supports a single final response, not Synaptic/OpenAI tool calls or MCP calls. It returns an error if tool calls are supplied. Tool execution, multi-turn tool loops, and authorization remain with the application runtime. A final response must decode as a JSON object and pass local JSON Schema validation before it is returned.

The low-level request API is:

```elixir
RutviExercise.Models.Codex.generate(
  %{
    messages: [%{role: :system, content: "Return a compact answer."},
               %{role: :user, content: "Answer the supplied question."}],
    output_schema: %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "additionalProperties" => false
    }
  }
)
```

A plain `prompt` string can replace `messages`. Success has the shape `{:ok, %{output: map, model: "gpt-6-luna", reasoning_effort: "low", usage: map | nil}}`. Errors have `{:error, %{code: atom, message: string, retryable: boolean, details: map}}`. Usage appears only when reported by Codex.

The smoke probe should use a tiny synthetic prompt, no tools, and a schema that requests one short string. This proves the local authenticated Codex CLI selected the requested model and structured output path; it does not establish assignment completion, course quality, or a cost estimate for a full run.

The GPT-6 Luna catalog also permits `none`; this integration fixes effort at `low` to match the selected cheap-mode profile. Model facts are from [official GPT-6 Luna documentation](https://developers.openai.com/api/docs/models/gpt-6-luna): Luna supports low reasoning effort and structured outputs. The actual local CLI integration uses the installed Codex CLI and Synaptic's local CodexExec source; it is separate from sending an OpenAI API request.

## Local probe result

The first bounded probe on 2026-09-28 used Codex CLI `0.144.5`, an existing ChatGPT login, and the exact requested `gpt-6-luna` model with low reasoning. It failed with HTTP 400 `invalid_request_error`: “The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account.” There was no valid response or usage record. CLI output also warned that it used fallback metadata for an unknown model; this was metadata fallback, not generation by another model.

Local inspection found that CLI `0.144.5`'s bundled model catalog did not list `gpt-6-luna`, while the installed package had been published through the OpenAI Codex npm package. The official `@openai/codex` package was updated in the user's NVM installation from `0.144.5` to `0.158.0` with:

```sh
npm install --global @openai/codex@0.158.0
```

The rollback command is `npm install --global @openai/codex@0.144.5`. The desktop app's separate bundled CLI and the user's Codex login/configuration were not changed. CLI `0.158.0`'s bundled and refreshed catalogs include `gpt-6-luna` and list low reasoning effort. This catalog difference is consistent with a stale CLI being the cause of the initial rejection; it is an inference from the before/after evidence, not a documented changelog attribution.

After the update, the app adapter made one bounded, read-only, no-tools structured-output probe from a fresh `/tmp` scratch directory. The CLI returned `{"answer":"ready"}` as `gpt-6-luna` at `low`, reporting 18,208 prompt tokens, 15 completion tokens, and 18,223 total tokens. No API-key environment credentials were used, and the model did not fall back.

The first actual course attempt with the normal runtime profile reached the tool-using research role but timed out on three 10-second provider attempts. The runtime owner then replaced the root `anyOf` provider schema with a closed envelope (`kind` plus serialized payload) and kept local validation against the original final-output schema. Focused protocol/model/adapter tests passed (16 tests, 0 failures, owner-reported).

After that fix, a bounded course run with an in-memory-only 60-second service timeout produced four valid model responses and one invalid output before failing. The `course.research` responses took about 9.6, 30.0, and 41.3 seconds; the planning response took about 10.9 seconds. The final research response was rejected as `invalid_output` after about 20.0 seconds. Reported usage for the four successful responses was 138,220 prompt tokens and 950 completion tokens (139,170 total). Parallel lesson generation then exceeded the course workflow's fixed 60-second `Task.await_many/2` wait; the root course failed without producing an artifact. The provider retry ceiling is fixed at three attempts. No source timeout was changed, no course was accepted as complete, and the CLI returned token counts but no currency-spend measurement. At that point, T8's successful full-course trace and spend evidence remained pending. The unit tests use an injected command runner and make no model calls.

## Host gateway for the local Kind UI

The Linux Kind image has no host Codex CLI or ChatGPT login. For local development only, `RutviExercise.CodexGateway.Router` exposes a narrow HTTP bridge on the Mac host; it calls the same local `RutviExercise.Models.Codex` adapter and fixed `gpt-6-luna`/`low` settings. It does not add an API-key provider or copy Codex credentials into the image.

The gateway binds only to `127.0.0.1:4041`. Docker Desktop's `host.docker.internal` route was verified from the app pod to reach both a temporary host-loopback server and this gateway's `GET /health` (HTTP 200). `POST /v1/generate` requires a bearer token and accepts exactly a JSON object with `messages` and `output_schema`; the body is capped at 256 KiB. It rejects model, timeout, command, tool, filesystem, and other control fields. Responses preserve the Codex adapter's model, reasoning, usage, and structured error values. Provider execution is read-only, uses an ephemeral scratch directory, has a fixed 90-second timeout, and does not execute tool calls. The host accepts at most two simultaneous model calls plus four queued calls; excess queue wait is capped at five seconds. Client cancellation cannot stop an already running local CLI process, which remains bounded by the provider timeout.

The authenticated remote adapter is `RutviExercise.Models.RemoteCodex`. It sends only the runtime Codex transport's `messages` and closed `output_schema` envelope. Its URL and bearer token are process configuration (`RUTVI_CODEX_GATEWAY_URL` and `RUTVI_CODEX_GATEWAY_TOKEN`); only the server deployment receives the token. Select it with `RUTVI_MODEL_PROVIDER=remote_codex` and use `RUTVI_MODEL_PROFILE=codex_local` for the explicit 90-second workflow model budget. The strict profile remains the default. The pod must not receive the host token through browser JavaScript, an image layer, a source file, or a ConfigMap.

For the developer's local setup, the gateway process reads a mode-0600 token file at `$HOME/.config/rutvi-exercise/codex-gateway.token`; its parent directory is mode 0700. This path is only a local secret source for creating a development Kubernetes Secret and is not part of the repository. Start the host bridge from the exercise checkout with:

```sh
RUTVI_CODEX_GATEWAY_TOKEN_FILE="$HOME/.config/rutvi-exercise/codex-gateway.token" \
RUTVI_CODEX_GATEWAY_BIND=127.0.0.1 RUTVI_CODEX_GATEWAY_PORT=4041 \
MIX_ENV=dev mix run --no-start scripts/start-codex-gateway.exs
```

Do not print the token or pass it to a browser. Never bind this development gateway to a public or unauthenticated interface.

## Successful native course proof

Before the final v4 role-contract adjustment (which moved quiz generation from planning to the lesson authors), the runtime owner completed one bounded native Luna course run in 128.167 seconds. The run generated two objectives, two lessons (181 and 157 words), three model-written quiz questions with valid citations, and an accepted reviewer result. The human audience/style checkpoint was resumed, and invalid research and a short author response recovered on attempts two and three. This supersedes the earlier failed native course attempts described above; those are retained as debugging history, not current acceptance status. The run verifies the preceding native full-course path, but predates the final author-owned quiz path and separate Kind bridge. The final Kind/Studio run below verifies those current paths.

## Gateway validation

The remote adapter's focused tests verify the exact outbound field allowlist, bearer header construction, timeout bound (provider timeout plus five seconds, capped at 120 seconds), response model/effort checks, structured failure mapping, and no-fallback behavior; they use injected HTTP transport and make no model calls. The gateway tests verify bearer authentication happens before model dispatch, reject extra control fields, reclaim a slot when an active request process dies, and discard dead queued request owners. These tests passed 7/7. `mix compile --warnings-as-errors` passed. The live gateway health endpoint returned HTTP 200 and the host listener was observed only on `127.0.0.1:4041`. Kind-side health and an authenticated no-model invalid-schema probe passed through `host.docker.internal:4041`; the final UI course result follows.

### File-backed secret line ending

The local hex token file ends in a newline because it is written as a text file. The host launcher trims the file; Kubernetes `--from-file` retains its bytes and the pod environment therefore also includes the newline. `RemoteCodex` now trims terminal CR/LF before validating the 64-character hex token and constructing the Authorization header. The regression test supplies that newline-terminated environment value and asserts it is absent from the outbound header. This fixes malformed HTTP header construction without changing or logging the token.

### Kind transport failure and credential rotation

The first authenticated UI course failed during three research calls. Core inspection found the release had not packaged Erlang `:inets`/`:httpc` and `:ssl`; calls failed with an immediate `UndefinedFunctionError` (observed durations 31, 59, and 20 ms), which the runtime surfaced as a timeout. A diagnostic exception path also caused sensitive Authorization arguments to appear in a BEAM crash diagnostic. The old gateway credential was therefore revoked by replacement: the private local token file and `rutvi-codex-gateway` development Secret now contain a fresh 64-character token. The host gateway was restarted with that token. The runtime owner added the HTTP applications to release startup and hardened the adapter to check HTTP client availability and return generic transport errors without raw exception details. The rebuilt Kind image passed a no-model authenticated invalid-schema probe. Do not use or reproduce the prior diagnostic output.

### Final Kind/Studio course through local Codex

The final Kind/Studio course completed durably through the authenticated host gateway using `gpt-6-luna` at low effort. History recorded 12 model-response events: 8 successful and 4 retryable `invalid_output` responses. Successful responses reported 165,223 total tokens; no currency amount was reported, so spend and the assignment's €5 ceiling remain unverified. The run reached peak external concurrency of two, generated two Czech lessons, three quiz questions from the lesson-author tasks, and six citations, and completed both human checkpoints. The UI course and artifact/download path succeeded. This is the current full-course evidence; the earlier native run predates the final quiz-ownership contract.
