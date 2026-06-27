# Glossary

| Term | Meaning |
|---|---|
| loop | A bounded supervisor-worker iteration contract stored in `loop.json`. |
| mission | The loop's intended outcome. |
| round budget | Maximum report rounds before the loop stops or requires reset/force. |
| verify | Mechanical gates declared on `peer loop init --verify`; results are read with `peer verify`. |
| judge | Independent reviewer/evaluator verdicts recorded with `peer judge`. |
| gate | Human Decision Gate for decisions that need user input. |
| checkpoint | Read-only direction summary from `peer checkpoint`. |
| reframe | Supervisor direction correction sent with `peer reframe`. |
| report | Worker progress/status channel; verdicts are not reports anymore. |
| approval | Approval Broker state and tool-permission decisions under `peer approval`. |
| budget | Reserved guardrail surface; currently `peer budget status` is a stub. |

Structured JSON field names such as `validation` and `acceptance` remain unchanged for compatibility; user-facing CLI and prose use `verify` and `judge`.
