# Loop Engineering

agent-duo is a loop engineering framework for visible coding agents. It keeps the supervisor, workers, verifier gates, judge verdicts, human decisions, and approval broker in one tmux session where the user can inspect every tab.

## Five Phases

| Phase | agent-duo surface |
|---|---|
| DISCOVER | `peer peek`, `peer checkpoint`, `peer task show` |
| PLAN | `peer task init`, `peer loop init` |
| EXECUTE | `peer ask`, `peer tell`, `peer reframe` |
| VERIFY | `peer verify ls`, `peer verify show`, runtime verify gates |
| ITERATE | `peer judge`, `peer loop reset`, `peer gate resolve` |

## Three Command Layers

- Transport: `peer peek`, `peer tell`, `peer wait`, `peer esc`, `peer status`.
- Loop building blocks: `peer agent`, `peer loop`, `peer verify`, `peer judge`, `peer task`, `peer report`, `peer gate`, `peer approval`, `peer budget`.
- Steering: `peer ask`, `peer checkpoint`, `peer reframe`.

## Building Blocks

| Block | Status |
|---|---|
| auto-trigger | Reserved; `loopd` provides local runtime ticks, no scheduler yet. |
| skill | Use project prompts and injected `AGENTS.md` instructions today. |
| sub-agent | Implemented as visible peer tabs via `peer agent add`. |
| connectors | Reserved; GitHub/Slack style connectors are not built in. |
| verifier | Implemented as frozen loop verify gates and `peer verify` read views. |

## Setup Order

1. Run the workflow manually with `peer tell`, `peer wait`, `peer peek`, and `peer report` until the handoff is understandable.
2. Capture the repeated work as a skill or project instruction, then use `peer task init` to make the worker's steps resumable.
3. Wrap the work in `peer loop init` with a round budget, `--verify` gates, and `--judge` veto rules so `done` is gated by evidence rather than confidence.
4. Use `peer ask`, `peer checkpoint`, and `peer reframe` for supervised iteration.
5. Add scheduling or external triggers only after the manual loop is boring and the verify/judge gates are stable.

## Risks And Guardrails

Loop engineering compounds both useful work and waste. The expensive failures are token compounding, low-signal reports, and changes that pass through review but are not accepted by the user.

`peer budget status` is a reserved guardrail surface for future budget and cost controls. Today the practical guardrails are explicit round budgets in `peer loop init`, mechanical `verify` gates, independent `judge` verdicts, and Human Decision Gates for business, deployment, cost, network, or scope decisions.

Track cost per accepted change, not just whether the loop eventually finishes. A loop that needs many rounds, repeated reframes, or large discarded deltas should be narrowed, given better verify gates, or moved back to manual operation.

## Migration Table

| Old | New |
|---|---|
| `peer ls` | `peer agent ls` |
| `peer add ...` | `peer agent add ...` |
| `peer rm ...` | `peer agent rm ...` |
| `peer loop <id>` | `peer loop show <id>` |
| `peer task <id>` | `peer task show <id>` |
| `--validation*` | `--verify*` |
| `--review` | `--judge` |
| `peer report --verdict ... --target-ref ...` | `peer judge <target-ref> --verdict ...` |
| `peer gate` | `peer gate ls` |
| `peer approvals` | `peer approval ls` |
| `peer approve <id>` | `peer approval approve <id>` |
| `peer deny <id>` | `peer approval deny <id>` |
| `peer broker-status <id>` | `peer approval status <id>` |
| `peer broker-check <id>` | `peer approval check <id>` |

Historical specs keep their original wording. Current docs and CLI use the terms in [glossary.md](glossary.md).

## Source

This page condenses the design discussion in [agent-loop-三agent循环-提炼.md](agent-loop-三agent循环-提炼.md) and keeps the operational vocabulary aligned with [glossary.md](glossary.md).
