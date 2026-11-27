#!/bin/bash
# run-demo.sh — event-driven multi-agent demo on bin/event-bus.py (mock mode: no LLM, no credits).
#
#   bash examples/event-agents/run-demo.sh
#
# Flow (fan-out → fan-in), all decoupled through topics:
#   test.failed ──► log-analyzer     ──► finding.log     ─┐
#               └─► metrics-analyzer ──► finding.metrics ─┴─► reviewer (waits for 2) ──► verdict.ready
# Nobody calls anybody: adding a third analyzer = one more `worker` line + `--fan-in 3`.
# Real mode: replace `--mock "..."` with `--agent <name> --task "..."` (goes through bin/run-agent.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUS="python3 $ROOT/bin/event-bus.py"
export EVENT_BUS_DB="$(mktemp -d "${TMPDIR:-/tmp}/event-demo.XXXXXX")/events.db"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$(dirname "$EVENT_BUS_DB")"' EXIT

$BUS init >/dev/null
# three long-running workers (separate processes), polling every 0.3 s
$BUS worker --consumer log-analyzer --topic test.failed --emit finding.log --poll 0.3 \
  --mock "job {job_id}: request to the auth service timed out after 30 s (3 retries)" &
$BUS worker --consumer metrics-analyzer --topic test.failed --emit finding.metrics --poll 0.3 \
  --mock "job {job_id}: auth service p99 latency 28 s during the failure window, CPU normal" &
$BUS worker --consumer reviewer --topic finding. --emit verdict.ready --fan-in 2 --poll 0.3 \
  --mock "job {job_id}: both analysts point at the auth service (timeout + latency); environment-side, not a product bug" &

CORR=$($BUS publish test.failed '{"job_id": "demo-42"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["corr_id"])')
echo "published test.failed  corr=$CORR"

for _ in $(seq 1 50); do   # wait up to ~10 s for the verdict
  $BUS trace "$CORR" | grep -q '"verdict.ready"' && break
  sleep 0.2
done

python3 - "$EVENT_BUS_DB" "$CORR" <<'EOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
print("\n=== causal chain (event -> consumers) ===")
verdict = None
for eid, topic, source, payload in con.execute(
        "SELECT id, topic, source, payload FROM events WHERE corr_id=? ORDER BY id", (sys.argv[2],)):
    cons = con.execute("SELECT consumer, status FROM consumed WHERE event_id=? ORDER BY ts", (eid,)).fetchall()
    print(f"#{eid:<3} {topic:<16} from {source:<17} -> " + (", ".join(f"{c}:{s}" for c, s in cons) or "-"))
    if topic == "verdict.ready":
        verdict = json.loads(payload)["result"]
print("\n=== verdict ===")
print(verdict or "no verdict (timeout)")
sys.exit(0 if verdict else 1)
EOF
