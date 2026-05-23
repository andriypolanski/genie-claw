# GenieClaw

[![CI](https://github.com/GeniePod/genie-claw/actions/workflows/ci.yml/badge.svg)](https://github.com/GeniePod/genie-claw/actions/workflows/ci.yml)
[![Jetson cross-compile](https://github.com/GeniePod/genie-claw/actions/workflows/cross.yml/badge.svg)](https://github.com/GeniePod/genie-claw/actions/workflows/cross.yml)
[![Audit](https://github.com/GeniePod/genie-claw/actions/workflows/audit.yml/badge.svg)](https://github.com/GeniePod/genie-claw/actions/workflows/audit.yml)

**Limited-context AI harness for agentic smart homes: portable across SBCs and
native to GeniePod Home.**

GenieClaw is the Rust agent layer for GeniePod Home. It is built for small local
models, tight VRAM budgets, and a 4096-token Jetson baseline. This repo owns
prompt assembly, memory, tool routing, smart-home intent, safety policy, audit,
and channel/session adapters.

GenieClaw is not the voice pipeline, the LLM runtime, the OS, the final
home-control runtime, or the product app layer.

The default agent contract is intentionally small: the Jetson profile uses
`[agent].context_window_tokens = 4096`. Larger adaptive contexts can exist for
stronger models, but provider/runtime paths must pass the 4096-token harness
first.

## Boundary

| Layer | Owner | Notes |
|-------|-------|-------|
| Agent layer | `genie-claw` | Prompt policy, limited-context harness, memory, tools, skills, smart-home intent, safety, audit, channels |
| LLM runtime | [`genie-ai-runtime`](https://github.com/GeniePod/genie-ai-runtime) | Jetson-first local inference runtime; `llama.cpp` remains selectable |
| Voice runtime | [`genie-voice-runtime`](https://github.com/GeniePod/genie-voice-runtime) | Wake, VAD, STT, TTS, audio streaming, voice session protocol |
| Home runtime | `genie-home-runtime` | Planned AI-native device graph and final actuation gate |
| Home Assistant | Transitional provider | Current integration target until `genie-home-runtime` exists |
| OS and apps | External layers | `genie-os`, web, and mobile surfaces stay outside this repo |

Full stack shape:

```text
user channel / voice runtime
          |
          v
   genie-claw agent layer
    |        |        |
 memory   tools   safety/audit
    |        |        |
    v        v        v
genie-ai-runtime   Home Assistant today
                   genie-home-runtime later
```

## What Works Today

- local chat through `genie-core`
- transitional voice-session adapter while voice moves to `genie-voice-runtime`
- LLM backend facade for `genie-ai-runtime` and selectable `llama.cpp`
- SQLite conversation history and household memory
- Home Assistant adapter with confirmations, rate limits, and audit logging
- local HTTP API, dashboard, CLI, health service, and governor service
- optional `web_search` tool with DuckDuckGo or SearXNG
- cache-aware `genie-ai-runtime` requests with `conversation_id` and
  `nvext.agent_hints` for session KV reuse
- Jetson aarch64 cross-compile CI

Current workspace version: `v1.0.0-alpha.9`.

OpenClaw proved that people want AI that feels present, remembers context, and
fits into everyday life. GenieClaw exists to keep what people wanted and fix the
problems: tighter architecture, stronger privacy boundaries, better security,
lower memory footprint, and a more appliance-like deployment model.

Its direction comes from deep analysis of OpenClaw, ZeroClaw, NanoClaw,
NemoClaw, and OpenFang. The ambition is simple: build the best Claw in the
world for the home.

## What It Is

This repo is the Rust agent runtime for a very specific product shape:

- a Jetson-first home AI appliance
- a full local voice pipeline: wake word, STT, LLM orchestration, tools, and TTS
- a local household memory system
- safe handoff to a home-control runtime
- transitional Home Assistant support while `genie-home-runtime` is not yet split out
- pluggable local LLM backend (`genie-ai-runtime` default on Jetson; `llama.cpp` remains selectable via `[services.llm].backend = "llama_cpp"`)
- a privacy-first and security-first system
- a memory-footprint-conscious runtime built for constrained edge hardware
- a household trust model that exposes redacted posture, not raw config files

If you want a short definition:

> GenieClaw is the local agent layer for private physical AI at home.

## Ecosystem Position

The intended Genie stack has five product layers. Layer three has two runtime
components:

- custom Jetson hardware
- `genie-os`: custom L4T image, drivers, OTA, and service supervision
- `genie-home-runtime`: Rust AI-native home automation runtime and final actuation safety layer
- `genie-ai-runtime`: Jetson-only C++ LLM runtime customized from `llama.cpp`
- `genie-claw`: this repo, the Rust agent layer for voice, memory, tools, skills, and channels
- application layer: web and mobile app surfaces

This repo should not become all five layers. It can keep transitional adapters
for today, but the long-term architecture keeps physical control, inference,
OS bring-up, and product apps behind explicit boundaries.

## What It Does

Today, the system can:

- run a local LLM-backed chat and voice loop
- stay flexible around local model choice inside the Jetson deployment
- expose a local HTTP API and web UI
- store conversation history and household memory in SQLite
- integrate with Home Assistant for device control and status as a transitional provider
- search public web information through a no-key provider, with optional SearXNG support
- run companion services for health monitoring, governance, dashboards, and system control
- target Jetson-class hardware with a small-footprint Rust runtime
- provide the foundations for a tightly controlled native skill model

Home control now has an explicit safety model:

- first-pass local action policy
- final runtime actuation gate before Home Assistant service execution
- configurable request-origin allowlist for physical actuation
- configurable per-origin physical-action rate limits
- pending confirmation tokens for high-risk actions
- recent action ledger for "what did you do?" and bounded undo
- dashboard/API visibility for pending, executed, and audited home actions
- append-only actuation audit logging under the data directory

Alpha 4 also adds the runtime control-plane surfaces needed for safer local
agent operation:

- runtime contract fingerprints for prompt, tools, policy, and hydrated state
- optional contract drift detection after a known-good boot
- system-prompt SHA-256 (logged at boot, surfaced in `/api/health` and `genie-ctl status`) to prove deterministic prompt assembly across restarts
- privacy-preserving tool audit logs
- redacted `/api/security` posture for dashboard/support use instead of raw TOML exposure
- origin-aware tool allow/deny policy
- native skill manifest audit metadata and configurable skill-load policy
- local support bundles for field diagnostics

## What It Is Not

`genie-core` is not:

- a hosted cloud assistant
- a thin wrapper around Home Assistant Assist
- a broad skill marketplace where feature count matters more than trust
- a general-purpose agent platform
- a messaging-bot framework
- the custom Jetson OS layer
- the final home automation and actuation runtime
- the Jetson CUDA inference runtime
- the whole product UI or mobile app

Home Assistant is currently a provider behind a boundary. Long term,
`genie-home-runtime` should own the device graph, automations, and final
physical actuation checks. GenieClaw owns the voice behavior, memory, session
logic, response style, channels, and skill routing.

## How It Fits Together

At a high level:

1. The local model server defaults to `genie-ai-runtime` on Jetson; the
   legacy `llama.cpp` server remains selectable per-deployment via
   `[services.llm].backend = "llama_cpp"` in `geniepod.toml`.
   Backend identity flows through `LlmClient::backend_name()` into
   logs, `/api/health`, and `genie-ctl status` for operator visibility.
2. `genie-core` handles prompts, tool calls, memory, chat, and voice orchestration.
3. Today, Home Assistant can provide device state and service execution. Longer term,
   `genie-home-runtime` should provide that boundary and the final actuation safety layer.
4. GeniePod companion services handle health, governance, and dashboards.

That means the user talks to GeniePod, not directly to Home Assistant internals.

## Why Minimal-First On Jetson
## Current Focus

- keep the agent reliable inside a 4096-token Jetson context
- harden prompt, memory, tool, and safety contracts
- split long-term wake/VAD/STT/TTS ownership into `genie-voice-runtime`
- keep Home Assistant behind a provider boundary until `genie-home-runtime`
- allow optional API-key providers only when they pass the same limited-context harness
- keep development usable on SBCs, laptops, and Macs without making Jetson less native

## Agent Contract

The repo now has explicit code-level contract surfaces for the new direction:

- `genie_core::runtime_boundary` declares the AI, voice, and home runtime
  boundaries so GenieClaw remains the agent layer.
- `genie_core::agent_harness` checks prompt, tool manifest, memory hydration,
  response reserve, and optional provider context against the Jetson 4096-token
  baseline.
- `genie_core::llm::LlmRequestHints` carries session id, expected output
  length, priority, and short-lived cache TTL to runtimes that understand the
  `nvext` extension.
- `[agent]` in `geniepod.toml` selects the runtime profile:
  `jetson`, `raspberry_pi`, `portable_sbc`, `laptop`, or `mac`.
- `[optional_ai_provider]` is disabled by default. API-key providers must keep
  their configured context at or below `[agent].context_window_tokens` before
  they are production candidates.

## Quick Start

```bash
make
make test

GENIEPOD_CONFIG=deploy/config/geniepod.dev.toml cargo run --bin genie-core
GENIEPOD_CONFIG=deploy/config/geniepod.dev.toml cargo run --bin genie-api
```

For Jetson setup, deployment, and Home Assistant wiring, use
[`GETTING_STARTED.md`](GETTING_STARTED.md).

## Repo Layout

| Crate | Purpose |
|-------|---------|
| `genie-core` | Main agent runtime: prompt building, tools, memory, HTTP API, and channel/session adapters |
| `genie-common` | Shared config, mode types, and tegrastats parsing |
| `genie-ctl` | Local CLI for chat, status, tools, health, and diagnostics |
| `genie-governor` | Resource governor and service lifecycle controller |
| `genie-health` | Local health polling and alert forwarding |
| `genie-api` | Lightweight local dashboard |
| `genie-skill-sdk` | Rust SDK for native shared-library skills |

## Documentation

- [`GETTING_STARTED.md`](GETTING_STARTED.md) - local dev, Docker, Jetson bring-up, and deploy
- [`ARCHITECTURE.md`](ARCHITECTURE.md) - Genie ecosystem boundaries
- [`doc/README.md`](doc/README.md) - documentation map
- [`doc/implementation-status.md`](doc/implementation-status.md) - implemented, partial, external, and planned work
- [`CHANGELOG.md`](CHANGELOG.md) - alpha release notes
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - PR and proof requirements
- [`SECURITY.md`](SECURITY.md) - vulnerability reporting

## Contributing

Every PR needs a **Real Behavior Proof** section: what you ran, where you ran it,
and what happened. CI/local proof is enough for docs, harness, provider, and
non-hardware work. Hardware-facing changes should include Jetson/device proof or
state the validation gap clearly.

## License

GNU Affero General Public License v3.0. See [`LICENSE`](LICENSE).
