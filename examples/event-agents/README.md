# event-agents demo

Event-driven multi-agent flow on `bin/event-bus.py`, in mock mode (no LLM, no credits, ~2 s):

```bash
bash examples/event-agents/run-demo.sh
```

```
test.failed ──► log-analyzer     ──► finding.log     ─┐
            └─► metrics-analyzer ──► finding.metrics ─┴─► reviewer (--fan-in 2) ──► verdict.ready
```

Agents never call each other; they subscribe to topics. The demo prints the causal chain
(`trace`) — every event and what each consumer did with it — and the final verdict.

To try it for real, swap `--mock "<template>"` for `--agent <name> --task "<template>"`;
the call then goes through `bin/run-agent.sh` (budget + depth guard). Usage and red lines:
`contexts/rules/orchestration.md` → *Event mode*.
