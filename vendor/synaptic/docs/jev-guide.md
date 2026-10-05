# Jev judgments and routing

Synaptic includes a native client for [TypeSafe Jev](https://docs.typesafe.ai/introduction).
Jev evaluates typed questions against shared state; it does not produce prose,
tool calls, or a chain of reasoning. The client is opt-in and independent of
`Synaptic.Tools.chat/2`. No additional package or provider SDK is required.

## Configuration

Set `TYPESAFE_API_KEY`, or configure the client in your runtime configuration:

```elixir
config :synaptic, Synaptic.Jev,
  api_key: System.fetch_env!("TYPESAFE_API_KEY"),
  model: "jev-1.13.0",
  timeout: 30_000,
  max_retries: 2
```

Per-call options override client configuration. The default model is pinned to
`jev-1.13.0`. You can explicitly use `jev-latest`, but re-evaluate your questions
and thresholds when the model changes. Results retain the returned model ID.

## Ask several questions in one request

```elixir
alias Synaptic.Jev

questions = %{
  "category" => Jev.choice("What is the main request in `ticket`?", %{
    "billing" => "Charges, invoices, refunds, or subscriptions",
    "technical" => "Broken or malfunctioning software",
    "other" => "Anything outside billing or technical issues"
  }),
  "severity" => Jev.score("How severe is the software issue reported in `ticket`?", [
    "No software malfunction is reported",
    "Software malfunctions, but a workaround exists",
    "Software is unusable and no workaround is available"
  ]),
  "refund" => Jev.noul("Does `ticket` explicitly request a refund?")
}

case Jev.evaluate(%{ticket: "I was charged twice. Please refund one charge."}, questions) do
  {:ok, result} ->
    category = result.answers["category"]
    # This example threshold is policy, not a guarantee of correctness.
    if category.confidence >= 0.8 do
      {:ok, %{category: category.choice, judgment: result}}
    else
      {:ok, %{needs_review: true, judgment: result}}
    end

  {:error, reason} ->
    {:error, reason}
end
```

All questions are sent together and evaluated independently. They cannot read
each other's answers. Only issue a second request when it depends on new data
or options determined by an earlier answer. Select relevant fields before
calling the client instead of exporting the entire workflow context.

The helpers return `%Synaptic.Jev.Question{}` structs. Raw question maps using
the same `type`, `instructions`, and `criteria` fields are also accepted.
Question IDs are nonempty strings. Instructions and criterion descriptions
can be strings, JSON objects, arrays, or null; their structure is preserved.
Noul criteria may describe either or both of `"true"` and `"false"`.
Jev 1.13 allows 64k tokens per request and 32k for state plus the longest
question. The provider enforces token limits; the client never silently
truncates state or splits a shared-state request.

Answers are `%Synaptic.Jev.ChoiceAnswer{}`, `%Synaptic.Jev.ScoreAnswer{}`, or
`%Synaptic.Jev.NoulAnswer{}` within `%Synaptic.Jev.Result{}`:

| Answer | Fields | Interpretation |
| --- | --- | --- |
| Choice | `choice`, `probabilities`, `confidence` | A label from the supplied alternatives |
| Score | `score`, `probabilities`, `confidence`, `legend` | A probability-weighted mean over rubric indices |
| Noul | `noul` | Probability of true; near 0.5 means uncertainty |

Score is not automatically normalized. Divide by `length(criteria) - 1` when
your policy needs a normalized rubric score, and retain the distribution.
Noul has no separate confidence field. The client never invents one.

## Route a workflow

`jev_router` uses the same branch-list and state-block shape as `llm_router`:

```elixir
defmodule SupportWorkflow do
  use Synaptic.Workflow

  jev_router :triage,
    [
      {"Questions about charges, invoices, or refunds", :billing},
      {"Any other request", :general}
    ],
    prompt: "Which category fits the main request in `message`?",
    min_confidence: 0.8,
    fallback: :review,
    result_key: :triage_judgment do
    %{message: context.message}
  end

  step :billing do
    {:route, :finish, %{queue: :billing}}
  end

  step :general do
    {:route, :finish, %{queue: :general}}
  end

  step :review, suspend: true, resume_schema: %{queue: :string} do
    case context[:human_input] do
      nil -> suspend_for_human("Choose a queue for this request.")
      %{"queue" => queue} -> {:ok, %{queue: queue}}
      %{queue: queue} -> {:ok, %{queue: queue}}
    end
  end

  step :finish do
    {:ok, %{ready: true}}
  end

  commit()
end
```

There must be at least two branches. Branch and fallback targets are checked
when the workflow compiles. Normal routing jumps to a step and then follows
the workflow's declared sequence; route to a common finish step when branches
must not fall through into one another.

`:min_confidence` defaults to 0.6. Confidence equal to the threshold passes.
Below the threshold, the router uses `:fallback`. Without a fallback it returns
`{:error, {:jev_low_confidence, result}}`. A catch-all Choice branch addresses
unmatched content; the fallback addresses uncertainty. They serve different purposes.
Thresholds must be evaluated against labeled examples from your domain.

`:result_key` defaults to `:jev_result`. The retained result includes
`metadata.routing` with `selected_target`, `target`, `min_confidence`, and
`used_fallback`. Choice labels are `branch_1`, `branch_2`, etc.; they map only
to the explicitly declared targets. The client never turns remote values into atoms.

## Other uses

Call the same `Jev.evaluate/3` client from ordinary steps to verify an extracted
field against its source, evaluate passage relevance, classify a transcript,
or score a candidate on several dimensions. Code owns arithmetic, weights,
thresholds, and actions. Observational checks can also call the client from a
`Synaptic.Scorer`; attached scorers run after step completion and cannot block
the next action. Use an ordinary step for blocking checks.

## Errors, retries, and testing

The client validates requests locally and checks response IDs, answer types,
option/level membership, numeric ranges, legends, and probability distributions.
Malformed responses return `:invalid_jev_response`; low confidence is valid data.
Unknown/chat-only options are rejected rather than silently ignored.

HTTP errors return `{:jev_http_error, status}` without upstream response bodies,
which may echo sensitive input. HTTP 408, 429, 500, 502, 503, 504, and 529 and
transient connection errors can be retried. Retry-After supports integer seconds
and standard HTTP dates, within the remaining timeout budget. Other responses
use exponential backoff with jitter. Authorization, policy, and validation
failures are not retried. Client retries never retry uncertainty. Avoid a workflow
`:retry` budget on low-confidence routes; route to review or gather new evidence.

`:timeout` is the HTTP budget across attempts and backoff (30 seconds by default).
`:receive_timeout` defaults to 15 seconds and `:pool_timeout` to 5 seconds.
`:endpoint`, `:finch`, and `:max_retries` can be overridden for Bypass tests.
Test wire handling separately from model quality: use labeled cases, boundary
cases, and adversarial state to measure false acceptances and review rates.
Jev is not a source of authorization and confidence is not proof of correctness.

## Privacy, policy, and monitoring

`Synaptic.explain_security(:judgment, security_profile: :high_assurance)` shows
the applicable boundaries. Judgment profiles reuse the existing profiles'
privacy, sanitization, model-export policy, egress, gateway, and audit defaults.
They do not apply chat history compaction, prose factuality checks, or tool policies.

Privacy and sanitization traverse state and question values. Configured field
dropping or derived facts can change state fields. If preparation removes
questions or changes the available answer options, the client fails explicitly
with `:jev_answer_space_changed_by_policy`. Keep identifiers and field names
free of sensitive data. Redaction can change the evidence available to a judgment;
evaluate questions under the privacy settings used in production.

Outbound requests use `Synaptic.OutboundHTTP` with egress surface `:jev`
(default host `api.typesafe.ai`) and connector `:typesafe`. `:run_id`, `:step_name`,
and `:tenant` are inherited inside workflow steps or may be supplied explicitly.
For example, configure an egress override under `egress: [jev: [...]]`.

Telemetry events are `[:synaptic, :jev, :start | :stop | :exception]`. They record
question counts/types, status, model, request ID, duration, and native
`input_tokens`/`output_tokens`, without raw state or answers. Missing token counts
remain nil. The monitor records `:judgment_call` events and leaves cost unknown
instead of applying an unrelated model's pricing. Full answers are retained in
workflow context only when your step or router puts them there; normal workflow
snapshot/event policies still apply. Optional audit/security metadata lives in
`result.metadata`, preserving the stable `{:ok, result}` return shape.
