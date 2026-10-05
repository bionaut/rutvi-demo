# Synaptic Security Guide

This guide explains the security capabilities built into `synaptic` in practical
terms.

The important mental model is simple:

- `synaptic` gives you layered security boundaries around workflows, LLM calls,
  tools, MCP, and runtime state.
- most boundaries are optional and off by default.
- if you want a bundled setup, use a `security_profile`.
- if something gets blocked, use `Synaptic.explain_security/2` and
  `Synaptic.explain_error/1` before guessing.

## Alpha.11 Security Posture

`0.3.0-alpha.11` hardens the security branch for alpha production trials:

- built-in OpenAI, Gemini, ElevenLabs, MCP, and Gemini Live traffic passes
  through outbound policy enforcement
- response limits are enforced while bytes are received, including streamed
  responses
- allowlisted DNS names are rejected when they resolve to non-public addresses
- audit, spill, idempotency, and connector state is owned by a supervised
  process and pruned on a schedule
- audit-chain appends and destructive-action idempotency are serialized across
  concurrent callers
- runtime, router-monitor, tuple, and struct redaction paths cover PII-bearing
  failure and result values
- security profiles passed to routed workflow calls propagate to the spawned
  workflow; service-owned workflow settings still take precedence

These controls are defense-in-depth, not a compliance certification. Prompt
injection and sensitive-data detection are heuristic and must be combined with
least-privilege tools, approvals, tenant isolation, provider controls, and
application-specific policy.

## Quick Start

See the built-in posture profiles:

```elixir
Synaptic.security_profiles()
```

Inspect the effective security posture without running anything:

```elixir
Synaptic.explain_security(:chat, security_profile: :high_assurance)
Synaptic.explain_security(:workflow, security_profile: :regulated)
```

Run a chat call with a coherent bundled posture:

```elixir
Synaptic.Tools.chat(messages,
  security_profile: :high_assurance
)
```

Attach a caller-visible explanation of what was active:

```elixir
{:ok, content, %{security: report}} =
  Synaptic.Tools.chat(messages,
    security_profile: :production,
    security_explain: true
  )
```

Turn posture/config mistakes into hard failures:

```elixir
Synaptic.Tools.chat(messages,
  security_profile: :regulated,
  security_diagnostics: [on_error: :error]
)
```

Explain a blocked action or guardrail failure:

```elixir
case Synaptic.Tools.chat(messages, security_profile: :high_assurance) do
  {:error, reason} ->
    Synaptic.explain_error(reason)

  other ->
    other
end
```

## Capability Index

### Security posture profiles

What it does:
- bundles multiple boundaries into one coherent operating mode
- adds explainability and startup diagnostics
- reduces misconfiguration risk

You may use this when:
- you want a safe baseline quickly
- different environments need different default postures

Ideal when:
- teams do not want to hand-wire every boundary

### Validation boundary

What it does:
- validates workflow input, step input, step output, resume payloads, tool args,
  and MCP args
- supports required fields, enums, regexes, length limits, numeric bounds, and
  canonicalized validation checks

You may use this when:
- malformed input should fail closed before it changes state or triggers actions

Ideal when:
- human input, external integrations, and resumable workflows matter

### Sanitization boundary

What it does:
- neutralizes risky HTML, Markdown, URLs, filenames, and shell-like strings
  before they reach prompts or tools

You may use this when:
- untrusted text comes from users, retrieval, docs, or tool results

Ideal when:
- prompts or tools ingest arbitrary text from outside your codebase

### Prompt security boundary

What it does:
- marks user content, MCP resources, retrieval results, and tool outputs as
  untrusted
- injects trust-boundary instructions
- detects instruction override, jailbreak, data exfiltration, and privilege
  escalation patterns

You may use this when:
- the model sees external content and can call tools

Ideal when:
- you are building agentic or MCP-heavy flows

### Privacy / PII boundary

What it does:
- detects common PII locally
- masks, tokenizes, drops, or allows fields before model calls
- supports safe rehydration for tool execution outside the model boundary

You may use this when:
- the model should not see raw identifiers

Ideal when:
- customer support, regulated workflows, and sensitive business data are involved

### Tool policy and approvals

What it does:
- decides `allow | deny | ask`
- uses tool metadata like `destructive`, `needs_approval`, `risk`, and
  `data_class`
- can require approval before risky actions run

You may use this when:
- some tools are safe to read from but not safe to write with

Ideal when:
- you have external actions, mutations, or sensitive integrations

### Action controls

What it does:
- adds idempotency, retry policy, rate limits, and blast-radius limits
- wraps actions that are already authorized

You may use this when:
- allowed actions still need operational safety limits

Ideal when:
- tools call external APIs or perform writes

### Central security policy

What it does:
- adds tenant-aware and sensitivity-aware rules for prompt release and tool use
- can enforce things like "restricted PII cannot go to this model" or "tenant is
  required here"

You may use this when:
- policy spans more than one boundary

Ideal when:
- the same runtime serves multiple tenants or sensitivity tiers

### Policy hooks and MCP governance

What it does:
- allows `pre_prompt`, `post_output`, `pre_tool`, `post_tool`, and `pre_mcp`
  hooks
- controls MCP servers by name, URL, command, and managed-only mode

You may use this when:
- platform teams need enterprise policy without forking the runtime

Ideal when:
- central teams manage shared deployments or controlled integrations

### Context hygiene

What it does:
- separates static and dynamic prompt sections
- compacts old tool history
- spills oversized tool results into retrievable handles

You may use this when:
- prompts get large, stale, or sensitive

Ideal when:
- long-running tool loops or research flows build a lot of history

### Factuality and output controls

What it does:
- requires evidence, citations, or provenance when configured
- detects unsupported claims
- can abstain or fail instead of releasing weak answers

You may use this when:
- the answer itself needs release-time checks

Ideal when:
- user-facing answers have higher trust requirements

### Audit and telemetry

What it does:
- emits sanitized audit records and safe telemetry
- supports retention-managed inspection and deletion

You may use this when:
- you need operational visibility without raw prompt logging

Ideal when:
- compliance, support, or incident review matter

### Runtime security

What it does:
- redacts workflow history, events, and snapshots
- caps retained history
- can purge terminal context

You may use this when:
- workflow state itself can hold sensitive values

Ideal when:
- human-in-the-loop or long-lived workflow runs matter

### Outbound egress control

What it does:
- allowlists outbound hosts
- blocks localhost/private-network access by default, including DNS names that
  resolve to non-public addresses
- checks schemes, redirects, MIME types, content length, and cumulative body
  size while receiving a response

You may use this when:
- outbound network access should be intentional, not implicit

Ideal when:
- remote OpenAI, voice, or MCP traffic needs a hard boundary

### Connector / MCP gateway

What it does:
- blocks raw credential passthrough headers
- supports managed-only remote connectors
- adds session-binding headers and connector rate limits
- can require HTTPS

You may use this when:
- remote connectors should pass through a hardened gate

Ideal when:
- MCP or external connector usage is growing in scope or sensitivity

### Troubleshooting surface

What it does:
- explains security and guardrail failures in developer-facing terms

You may use this when:
- a request is denied and you want the fastest path to understanding why

Ideal when:
- teams are onboarding or tightening policy over time

## Recommended Starting Point

If you want a low-friction starting point:

```elixir
config :synaptic, Synaptic.Security,
  profile: :production,
  diagnostics: [
    enabled: true,
    on_error: :warn,
    emit_warnings: true,
    emit_on_startup: true
  ]
```

If you want a stricter default:

```elixir
config :synaptic, Synaptic.Security,
  profile: :high_assurance,
  diagnostics: [
    enabled: true,
    on_error: :warn,
    emit_warnings: true,
    emit_on_startup: true
  ]
```

If you want full explicit control and no bundled posture:

```elixir
Synaptic.Tools.chat(messages, security_profile: false)
```

## Detailed Capabilities

### Security Posture Profiles

Use this when you want `synaptic` to feel opinionated instead of bare.

Built-in profiles:
- `:developer`
- `:production`
- `:high_assurance`
- `:regulated`

Inspect them:

```elixir
Synaptic.security_profiles()
Synaptic.explain_security(:chat, security_profile: :high_assurance)
```

Apply them:

```elixir
Synaptic.Tools.chat(messages,
  security_profile: :high_assurance
)

Synaptic.start(MyWorkflow, input,
  security_profile: :regulated
)
```

Practical note:
- explicit per-call boundary settings still win
- explicit step-level workflow validation still wins over posture-provided
  defaults

### Validation Boundary

Use this when incorrect shape should stop execution early.

Workflow example:

```elixir
defmodule SignupWorkflow do
  use Synaptic.Workflow

  step :collect,
    input: %{
      email: [type: :string, regex: ~r/^[^\s]+@[^\s]+\.[^\s]+$/, required: true],
      plan: [type: :string, enum: ["free", "pro"], required: true]
    },
    validation: [input: :strict, output: :strict] do
    {:ok, %{accepted: true}}
  end

  commit()
end
```

Tool validation example:

```elixir
Synaptic.Tools.chat(messages,
  validation: [tools: true],
  tools: [
    %{
      name: "search_docs",
      description: "Search internal docs",
      schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", minLength: 3}
        },
        required: ["query"]
      },
      handler: fn %{"query" => query} -> {:ok, %{results: [query]}} end
    }
  ]
)
```

You may want this especially for:
- `Synaptic.start/3`
- `Synaptic.resume/2`
- tool-heavy flows
- `llm_router` steps that return structured data

### Sanitization Boundary

Use this when untrusted text should be normalized before it reaches prompts or
tools.

Example:

```elixir
Synaptic.Tools.chat(messages,
  sanitization: [
    enabled: true,
    prompt: [enabled: true, roles: ["user"], types: [:html, :markdown]],
    tools: [enabled: true],
    tool_results: [enabled: true]
  ]
)
```

Practical effect:
- HTML can be stripped
- Markdown can be flattened
- unsafe URL schemes can be dropped
- filename-like values can be reduced to a basename
- shell-like strings can be neutralized before they hit tools

Ideal when:
- user-entered text goes into prompts
- tool args contain filenames, URLs, or free-form text

### Prompt Security Boundary

Use this when the model sees untrusted content and can do things with it.

Example:

```elixir
Synaptic.Tools.chat(messages,
  prompt_security: [
    enabled: true,
    response: [on_detection: :error]
  ]
)
```

Practical effect:
- untrusted content is treated as data, not instructions
- common prompt-injection and jailbreak patterns are detected before model
  invocation
- tool calls can be blocked when the surrounding context attempts exfiltration,
  privilege escalation, or instruction override

Ideal when:
- user input, retrieval, MCP resources, and tool results all mix in one prompt

### Privacy / PII Boundary

Use this when the model should reason over sensitive input without seeing raw
identifiers.

Example:

```elixir
Synaptic.Tools.chat(messages,
  privacy: [
    enabled: true,
    prompt: [
      enabled: true,
      default_action: :tokenize,
      derived_facts: true
    ],
    output: [
      enabled: true,
      default_action: :mask,
      rehydrate: false
    ]
  ]
)
```

Practical effect:
- emails, phones, SSNs, cards, auth tokens, DOBs, and addresses can be handled
  locally
- prompts can receive placeholders or derived facts instead of raw values
- tool execution can still receive rehydrated values outside the model boundary

Ideal when:
- you need model assistance but not raw PII exposure

### Tool Policy and Approvals

Use this when some tools are harmless and others are risky.

Tool definition example:

```elixir
tool = %Synaptic.Tools.Tool{
  name: "delete_invoice",
  description: "Delete one invoice by id",
  schema: %{
    type: "object",
    properties: %{invoice_id: %{type: "string"}},
    required: ["invoice_id"]
  },
  handler: fn %{"invoice_id" => id} -> {:ok, %{deleted: id}} end,
  destructive: true,
  needs_approval: true,
  risk: :high,
  data_class: :customer_data
}
```

Policy example:

```elixir
Synaptic.Tools.chat(messages,
  tools: [tool],
  policy: [
    enabled: true,
    require_approval: [destructive: true, risk_at_or_above: :high],
    return_decisions: true
  ]
)
```

Ideal when:
- read-only and destructive tools should be treated differently

### Action Controls

Use this when allowed actions still need runtime guardrails.

Example:

```elixir
Synaptic.Tools.chat(messages,
  action_controls: [
    enabled: true,
    idempotency: [
      enabled: true,
      require_for: [destructive: true]
    ],
    retries: [
      enabled: true,
      max_attempts: 2,
      sources: [:mcp]
    ]
  ]
)
```

Practical effect:
- duplicate destructive actions can be blocked or cached
- MCP failures can retry under explicit rules
- repeated actions can be rate-limited or capped

### Central Security Policy

Use this when prompt and tool policy should share one tenant-aware or
sensitivity-aware rule layer.

Example:

```elixir
Synaptic.Tools.chat(messages,
  tenant: "acme",
  security_policy: [
    enabled: true,
    tenant: [required_surfaces: [:prompt, :tool]],
    pii: [
      model_export: [
        enabled: true,
        sensitivity_at_or_above: :restricted_pii,
        allow_models: ["gpt-4o-mini"]
      ]
    ]
  ]
)
```

Ideal when:
- model choice, tenant, and data sensitivity all matter at the same time

### Hooks and MCP Governance

Use this when a platform team wants central policy logic without patching core
runtime code.

Example:

```elixir
Synaptic.Tools.chat(messages,
  hooks: [
    enabled: true,
    pre_prompt: [
      fn payload ->
        {:ok, update_in(payload.messages, fn msgs ->
          [%{role: "system", content: "Company prompt preamble"} | msgs]
        end)}
      end
    ]
  ],
  mcp: [:docs],
  mcp_governance: [
    enabled: true,
    managed_only: true
  ]
)
```

Ideal when:
- deployments must distinguish centrally managed MCP from inline ad hoc MCP

### Context Hygiene

Use this when prompts get large or retain too much raw tool output.

Example:

```elixir
Synaptic.Tools.chat(messages,
  context_hygiene: [
    enabled: true,
    tool_results: [
      spill_oversized: true,
      compact_older: true,
      keep_recent: 2,
      max_inline_chars: 2_000
    ]
  ]
)
```

Fetch a spilled result later:

```elixir
Synaptic.fetch_spilled_tool_result(handle)
```

Ideal when:
- tools return large payloads
- long chat/tool loops should stay compact

### Factuality and Output Controls

Use this when the final answer needs stronger release-time checks.

Example:

```elixir
Synaptic.Tools.chat(messages,
  factuality: [
    enabled: true,
    checks: [
      require_provenance: true,
      detect_unsupported_claims: true
    ],
    response: [on_violation: :abstain]
  ]
)
```

With a custom verifier:

```elixir
Synaptic.Tools.chat(messages,
  factuality: [
    enabled: true,
    verification: [
      enabled: true,
      verifier: fn payload ->
        if String.contains?(payload.content, "verified") do
          :ok
        else
          {:error, %{code: :custom_verifier_failed, message: "Missing verifier marker"}}
        end
      end
    ]
  ]
)
```

Ideal when:
- high-risk responses need explicit support before release

### Audit and Telemetry

Use this when you need sanitized operational visibility.

Example:

```elixir
Synaptic.Tools.chat(messages,
  audit: [
    enabled: true,
    return_metadata: true
  ]
)
```

Read audit records:

```elixir
Synaptic.audit_records(run_id)
Synaptic.verify_audit_records(run_id)
```

Delete run artifacts:

```elixir
Synaptic.delete_run_artifacts(run_id)
```

Ideal when:
- support, forensics, and compliance matter

### Runtime Security

Use this when workflow state itself should be minimized or redacted.

Example:

```elixir
Synaptic.start(MyWorkflow, input,
  runtime_security: [
    enabled: true,
    history: [redact: true, max_entries: 10],
    events: [redact: true],
    snapshot: [redact: true],
    retention: [purge_context_on_terminal: true]
  ]
)
```

Ideal when:
- workflow history and snapshots can contain secrets or PII

### Outbound Egress and Connector Gateway

Use these together when remote network access should be intentional and auditable.

Strict OpenAI-only egress:

```elixir
config :synaptic, Synaptic.EgressPolicy,
  enabled: true,
  openai: [allow_hosts: ["api.openai.com"]],
  mcp: [allow_hosts: []],
  voice: [
    allow_hosts: [
      "api.openai.com",
      "api.elevenlabs.io",
      "generativelanguage.googleapis.com"
    ]
  ]
```

Controlled local MCP development example:

```elixir
Synaptic.Tools.chat(messages,
  mcp: [
    %{
      name: "docs",
      transport: :http,
      adapter: Synaptic.MCP.Adapters.HTTP,
      base_url: "http://localhost:4001/mcp"
    }
  ],
  egress: [
    enabled: true,
    mcp: [
      allow_hosts: ["localhost"],
      allow_localhost: true,
      allow_schemes: ["http"]
    ]
  ],
  connector_gateway: [
    enabled: true,
    managed_only: false,
    auth: [forbid_passthrough_headers: true],
    session_binding: [enabled: true, require_run_id: true]
  ],
  run_id: "dev-mcp-session"
)
```

Practical effect:
- blocked by default unless the host is trusted
- localhost/private-network access must be explicit
- allowlisted DNS names fail closed when resolution fails or yields a
  non-public address
- raw credential passthrough headers can be refused
- caller-supplied session-binding headers are refused when managed binding is
  enabled
- remote traffic can be tied back to a run through session-binding headers

Ideal when:
- MCP or remote connectors are part of the threat model

### Troubleshooting

Use this whenever a call fails and the reason is not obvious.

Examples:

```elixir
Synaptic.explain_error({:egress_blocked, detail})
Synaptic.explain_error({:connector_gateway_blocked, detail})
Synaptic.explain_error({:validation_failed, details})
```

Practical workflow:

1. capture the returned error
2. run `Synaptic.explain_error/1`
3. run `Synaptic.explain_security/2` with the same opts
4. only then decide whether to relax policy or fix input

## Common Recipes

### Protect PII but still allow tool execution

```elixir
Synaptic.Tools.chat(messages,
  security_profile: :high_assurance,
  privacy: [
    enabled: true,
    prompt: [default_action: :tokenize, derived_facts: true],
    output: [default_action: :mask, rehydrate: false]
  ]
)
```

Use when:
- the model should not see raw customer identifiers
- tools still need real values outside the model boundary

### Run tools safely

```elixir
Synaptic.Tools.chat(messages,
  security_profile: :high_assurance,
  validation: [tools: true],
  policy: [
    enabled: true,
    require_approval: [destructive: true, risk_at_or_above: :high]
  ],
  action_controls: [
    enabled: true,
    idempotency: [enabled: true, require_for: [destructive: true]]
  ]
)
```

Use when:
- tools can mutate external systems

### Enable MCP securely

```elixir
Synaptic.Tools.chat(messages,
  mcp: [:docs],
  egress: [
    enabled: true,
    mcp: [allow_hosts: ["docs.example.com"]]
  ],
  connector_gateway: [
    enabled: true,
    managed_only: true,
    tls: [require_https: true],
    session_binding: [enabled: true]
  ],
  mcp_governance: [
    enabled: true,
    managed_only: true
  ]
)
```

Use when:
- remote MCP should be centrally managed and network-constrained

### Lock down network access

```elixir
Synaptic.Tools.chat(messages,
  security_profile: :high_assurance,
  egress: [
    openai: [allow_hosts: ["api.openai.com"]],
    mcp: [allow_hosts: []]
  ],
  connector_gateway: [
    enabled: true,
    tls: [require_https: true],
    auth: [forbid_passthrough_headers: true]
  ]
)
```

Use when:
- only known outbound hosts should ever be reachable

### Triage a denied action

```elixir
case Synaptic.Tools.chat(messages, security_profile: :regulated) do
  {:error, reason} ->
    %{
      explanation: Synaptic.explain_error(reason),
      posture: Synaptic.explain_security(:chat, security_profile: :regulated)
    }

  ok ->
    ok
end
```

Use when:
- something is blocked and you need the fastest path to a correct fix

## Defaults and Practical Notes

- most boundaries are off by default
- posture profiles can turn on coherent bundles
- explicit per-call options override global defaults
- explicit workflow step validation still overrides posture-provided validation
  defaults
- `high_assurance` and `regulated` now also turn on outbound egress and
  connector gateway controls

## Security Boundaries and Known Limits

- Security audit records, spilled tool results, action-control history,
  connector counters, workflow state, and agent-directory state are in-memory.
  Supervision prevents accidental loss when a short-lived caller exits, but an
  application or node restart clears them. Export records to a durable,
  access-controlled sink when retention or compliance evidence is required.
- DNS resolution is checked before a connection, but the transport does not pin
  the resolved address. Use controlled DNS and network-level egress enforcement
  for environments where DNS rebinding is in scope.
- Redaction recognizes configured patterns; it cannot prove that arbitrary
  secrets or every jurisdiction-specific identifier were removed. Add custom
  policy hooks and tests for your data classes.
- Prompt-security checks detect common override, jailbreak, exfiltration, and
  escalation patterns. They do not make model output trustworthy or replace
  tool authorization and approval.
- Explicit per-call settings can relax most defaults. Treat configuration and
  service-owned `workflow_opts` as privileged deployment inputs.

If you want the shortest practical path:

1. start with `security_profile: :production`
2. move to `:high_assurance` when tools or MCP become important
3. use `:regulated` when tenant-aware controls and answer verification matter
4. keep `Synaptic.explain_security/2` and `Synaptic.explain_error/1` in your
   normal debugging workflow
