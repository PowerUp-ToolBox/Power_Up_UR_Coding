# 4. Harness abstraction: ACP-first, with harness-native fallbacks

Date: 2026-08-27

## Status

Accepted

## Context

DEVELOPMENT.md M3 requires driving harnesses beyond Claude Code. Options:
one native adapter per harness (N integrations, N protocols to reverse and
maintain), or the Agent Client Protocol (JSON-RPC 2.0 over stdio) as a single
adapter surface.

Live probes on this machine (2026-08-27, logs summarized in DESIGN.md v2.0):

- **opencode 1.1.44** speaks ACP natively (`opencode acp`): protocolVersion 1
  handshake, `session/new` returns a sessionId *and a model list with
  `currentModelId`*, `session/prompt` streams `agent_thought_chunk` /
  `agent_message_chunk` updates and finishes with `stopReason: "end_turn"`.
- **The Claude Code bridge** — renamed from `@zed-industries/claude-code-acp`
  to **`@agentclientprotocol/claude-agent-acp`** (0.16.2) — completes the same
  flow and additionally streams `tool_call` / `tool_call_update` (title, kind,
  locations, rawInput) and `usage_update`, and returns per-turn token usage.
  It must be spawned with the `CLAUDECODE`/`CLAUDE_CODE_*` environment
  variables stripped, or its nested-session guard refuses to run.
- Codex and Gemini CLIs are not installed here; both are reachable through
  ACP per upstream docs (codex-acp bridge; Gemini natively in Zed), so the
  same adapter should cover them when present — verify on first availability.

ACP does not standardize everything: dollar cost reporting (Claude-native
`total_cost_usd` has no ACP equivalent; the bridge reports tokens only),
Claude's effort setting (restart semantics are harness-specific), and hook
taxonomies stay native.

## Decision

PowerUp integrates additional harnesses through **one `ACPAdapter`**
implementing the `HarnessAdapter` contract, spawning a configured agent
command over stdio. The Claude Code **stream-json adapter stays** as the
built-in default (see ADR 0005) and as the reference for capabilities ACP
lacks. Adapters declare **capability flags** (live model switch, effort,
dollar-cost reporting) so the app degrades features honestly instead of
faking them. The bridge dependency is the renamed
`@agentclientprotocol/claude-agent-acp`, version-pinned when invoked.

## Consequences

- Codex/Gemini support becomes "point the ACP adapter at their agent
  command", not new protocol work; native adapters (e.g. `codex exec --json`
  for cost) are additive, not prerequisites.
- ACP's `session/request_permission` gives the permission-prompt flow
  (issue #10) a standard shape across every ACP harness at once.
- Third-party bridges are a version-drift risk: they are spawned by explicit
  command (user-overridable), and protocol violations surface as harness
  errors, never crashes.
- Cost display shows "n/a" for harnesses that don't report dollars (#12).
