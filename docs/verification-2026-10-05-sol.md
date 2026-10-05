# GPT-6.1 Sol verification — 5 October 2026

The local Codex adapter, authenticated host gateway, remote adapter, and Kind configuration select **`gpt-6.1-sol` with medium reasoning**. The runtime records the requested effort in model settings. The remote adapter rejects a different model or reasoning effort; it does not fall back.

## Automated checks

`scripts/check.sh` passed formatting, compilation with warnings treated as errors, **58 Elixir tests** (seed `274845`), **3 JavaScript UI tests**, shell syntax checks, and Git whitespace checks. Adapter tests verify the exact CLI model/effort arguments and reject gateway responses with the old Luna model or Sol at low/high reasoning.

The watchdog-timeout regression reproduced three finish events for two starts before the fix. After making lease release transactional and idempotent, the focused protocol suite passed **6 tests** (seed `402991`); the regression verifies two finishes and no remaining active lease after the retry succeeds.

## Real provider probe

The initial probe using CLI 0.158.0 was rejected as model unavailable. After updating the official installed CLI to **0.160.0**, a real structured-output call returned `{"answer":"ready"}` using `gpt-6.1-sol` at medium reasoning. It reported 16,298 prompt tokens and 15 completion tokens. The call used ChatGPT authentication, a read-only sandbox, an ephemeral session, and no tools or API credentials.

The host gateway explicitly selects this installed CLI through `SYNAPTIC_CODEX_BIN`. Its authentication and loopback binding remain in place. The desktop app's bundled CLI and global model preference were not changed.

## Completed real-AI course in Kubernetes

The authenticated local Kind application completed run `kJEQb4j6B1JCUJivL9CzTKpk` using Sol at medium reasoning. It produced two Czech lessons, two learning objectives, and three quiz questions. The [course](evidence/2026-10-05-sol-course.json) and [redacted trace](evidence/2026-10-05-sol-trace.json) preserve the actual output and ordered event timestamps. The trace includes the course checksum and omits prompts, raw model responses, identity fields, credentials, and detailed error text.

The run started at **14:48:01.876235 UTC** and completed at **14:55:08.254063 UTC** on 5 October 2026. Its **426.377-second** wall duration includes two human checkpoint waits and a pod replacement. Deleting the exact app pod at the first checkpoint preserved the same run ID, checkpoint ID, and earlier history on the PVC. Both checkpoints resumed successfully. Two unauthorized task reads returned 403.

There were **14 model responses**: 10 successful, 3 retryable invalid outputs, and 1 timeout. Successful responses reported **178,674 prompt tokens** and **4,573 completion tokens** (183,247 total). Failed responses supplied no usage, and no currency total was available. These totals are reported usage for successful calls, not a complete billing record. Peak external concurrency was two.

The captured run preceded the timeout-cleanup fix above and records **32 external starts and 33 finishes**. The extra finish came from both the watchdog and the waiting caller releasing the same lease. The raw evidence retains that event; the regression verifies the corrected behavior. Kubernetes recovery here verifies pod replacement at a human checkpoint, not every possible crash point during active model work.

## Final deployment checks

After the cleanup fix, the Docker image rebuilt successfully and was loaded into the dedicated `rutvi` Kind cluster. The deployment rolled out on the same PVC. `/live`, `/ready`, `/`, `/studio/app.js`, and `/studio-api/session` returned 200 at `http://127.0.0.1:4018/`; the session reported Sol, and the completed course remained accessible after replacement. The rebuilt image ID is `sha256:fa405f8f9312347e1df0380f4ba3e4f15b3da52162ee1059e716aca7369eec4d`; the Ready pod's imported image digest is `sha256:bef8fafdf18eb0e22bb75f73d23571906fc021cd619b1c3d3edfad4c36179afc`.

All Kubernetes operations used `/Users/jankrajnak/.kube/config-rutvi-kind` with explicit context `kind-rutvi`. Credentials stayed in the existing private files and Kubernetes Secrets. The completed real-provider run predates this final logging-only fix; that fix is covered by the regression and full suite rather than a second full model run.
