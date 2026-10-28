#!/usr/bin/env bash
# Bounded, team-scoped worker board projection.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
python3 -I - "$ROOT" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
try:
    from task_ledger import worker_view
except ImportError:
    print("FAIL - worker_view is missing")
    raise SystemExit(1)

now=datetime.now(timezone.utc)
stamp=lambda delta: (now + delta).isoformat().replace("+00:00", "Z")
tasks={}
for n in range(90):
    own=n % 2 == 0
    tasks[f"t-{n:012x}"]={
        "task_id":f"t-{n:012x}", "run_id":f"r-{n%25:012x}", "team_uid":"acme-engine",
        "assignee":"acme-core" if own else "acme-sib", "state":"DONE" if n < 20 else "IN_PROGRESS",
        "title":"x"*500, "last_summary":"y"*500, "deadline_at":None, "turns":n,
        "assignments":1, "created_at":stamp(timedelta(hours=-n)), "last_at":stamp(timedelta(hours=-n)),
    }
runs={f"r-{n:012x}":{"run_id":f"r-{n:012x}","team_uid":"acme-engine","state":"RUNNING","created_at":stamp(timedelta(hours=-n))} for n in range(30)}
rejections=[]
for n in range(60):
    rejections.append({"seq":n,"team_uid":"other-engine" if n%3==0 else "acme-engine","task_id":f"t-{n:012x}","requested_type":"task.reported","reason":"invalid_transition","free_text":"never expose"})
current={"highest_seq":999,"invalid":2,"invalid_events":[{"seq":1}],"stream_status":"ok","tasks":tasks,"runs":runs,"rejections":rejections}
view=worker_view(current, team="acme-engine", agent="acme-core")
encoded=json.dumps(view, separators=(",",":"), ensure_ascii=False).encode()
checks={
    "bounded": len(encoded) <= 32*1024,
    "caps": len(view["tasks"]) <= 50 and len(view["runs"]) <= 20 and len(view["own_rejections"]) <= 20,
    "filtered": all(set(r) == {"task_id","requested_type","reason"} for r in view["own_rejections"]),
    "safe_text": all(len(t.get("title", "")) <= 200 and len(t.get("last_summary", "")) <= 200 for t in view["tasks"]),
    "terminal_scope": all(t["state"] not in {"DONE","FAILED","CANCELLED","REVIEW"} or t["assignee"] == "acme-core" for t in view["tasks"]),
    "invalid_count_only": view.get("invalid") == 2 and "invalid_events" not in view,
}
for name, ok in checks.items(): print(("ok   - " if ok else "FAIL - ") + name)
raise SystemExit(not all(checks.values()))
PY
