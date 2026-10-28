#!/usr/bin/env bash
# Worker worktree/branch lifecycle and closed result-reference validation.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aib-worktree.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$ROOT" "$WORK" <<'PY'
import json, os, stat, subprocess, sys
from pathlib import Path

root, work = map(Path, sys.argv[1:])
repo, state, standup = work/"repo", work/"state", work/"standup"
for path in (repo, state, standup, standup/"transcripts"):
    path.mkdir(parents=True, exist_ok=True)
subprocess.run(["git", "-C", str(repo), "init", "-q", "-b", "main"], check=True)
subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "base"], check=True)

registry = work/"registry.json"
registry.write_text(json.dumps({
    "schema_version": 5,
    "providers": {"stub": {"adapter": str(root/"adapters/codex"), "cap_sandbox":"workspace-write", "cap_tier":"t2", "cap_effort":"low", "cap_timeout":"30"}},
    "projects": {"acme": {"home":str(repo), "standup_dir":str(standup), "mux_session":"acme", "data_class":"internal", "provider":"stub", "model":"example", "effort":"low", "base_branch":"main"}},
    "teams": {"acme-engine": {"project":"acme"}},
    "agents": {
        "acme-lead": {"mode":"supervised", "lead":"true", "project":"acme", "team_uid":"acme-engine", "profile":"lead", "clearance":"t2"},
        "acme-dev1": {"mode":"supervised", "project":"acme", "team_uid":"acme-engine", "profile":"worker", "clearance":"t2"},
    },
}), encoding="utf-8")
deployment = work/"deployment.json"
deployment.write_text(json.dumps({"deployment_id":"test", "allow":{"customer_code":True,"comms_secrets":False}, "commit_identity":{"name_template":"{display_name} ({team})", "email":"workers@example.invalid"}}), encoding="utf-8")
deployment.chmod(0o600)
os.environ.update({
    "AIB_TEST_SEAMS":"1", "AIBOBNET_REGISTRY":str(registry), "STATE_DIRECTORY":str(state),
    "AIB_DEPLOYMENT_CONFIG":str(deployment), "AIB_DEPLOYMENT_OWNER_UID":str(os.getuid()),
})
sys.path.insert(0, str(root/"lib"))
from aib_supervisor import Supervisor

passed=failed=0
def check(name, actual, expected=True):
    global passed, failed
    if actual == expected:
        passed += 1; print(f"ok   - {name}")
    else:
        failed += 1; print(f"FAIL - {name} (got {actual!r}, want {expected!r})")

sup=Supervisor(root, "acme-dev1")
check("supervisor config is valid", sup.configure(), None)
check("all supervisor git operations share one role-confined gateway", hasattr(sup, "_git_as_role"), True)
t1={"task_id":"t-111111111111", "team_uid":"acme-engine"}
t2={"task_id":"t-222222222222", "team_uid":"acme-engine"}
wt=sup.activate_task_worktree(t1)
expected=repo/".aib"/"wt"/"acme-dev1"
check("one worktree is created at the project-owned agent path", wt, expected)
check("task activation checks out the closed branch", subprocess.check_output(["git","-C",str(wt),"branch","--show-current"], text=True).strip(), "aib/acme-engine/t-111111111111")
check("missing shared repository provisioning is attention-only", any(r.get("event") == "attention" and r.get("reason") == "shared_repository_unprovisioned" for r in sup.records), True)
check("worktree parent is setgid", bool(expected.parent.stat().st_mode & stat.S_ISGID))

(wt/"dirty.txt").write_text("preserve me\n", encoding="utf-8")
sup.activate_task_worktree(t2)
old_log=subprocess.check_output(["git","-C",str(repo),"log","-1","--format=%s|%an|%ae","aib/acme-engine/t-111111111111"], text=True).strip()
check("dirty prior work is WIP-committed, never discarded", old_log, "WIP before t-222222222222|acme-dev1 (acme-engine)|workers@example.invalid")
check("new task gets its own branch", subprocess.check_output(["git","-C",str(wt),"branch","--show-current"], text=True).strip(), "aib/acme-engine/t-222222222222")

(wt/"result.txt").write_text("result\n", encoding="utf-8")
subprocess.run(["git","-C",str(wt),"add","result.txt"], check=True)
subprocess.run(["git","-C",str(wt),"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","result"], check=True)
sha=subprocess.check_output(["git","-C",str(wt),"rev-parse","HEAD"], text=True).strip()
task={**t2, "worktree":str(wt)}
valid=f"git:aib/acme-engine/t-222222222222@{sha}"
check("task branch SHA is accepted", sup.validate_result_ref(valid, task), True)
check("wrong branch is rejected", sup.validate_result_ref(f"git:aib/acme-engine/t-111111111111@{sha}", task), False)
old_sha=subprocess.check_output(["git","-C",str(repo),"rev-parse","aib/acme-engine/t-111111111111"], text=True).strip()
check("a reachable SHA on another task branch is rejected by branch binding", sup.validate_result_ref(f"git:aib/acme-engine/t-222222222222@{old_sha}", task), False)

subprocess.run(["git","-C",str(repo),"checkout","-q","-b","foreign","main"], check=True)
(repo/"foreign.txt").write_text("foreign\n", encoding="utf-8")
subprocess.run(["git","-C",str(repo),"add","foreign.txt"], check=True)
subprocess.run(["git","-C",str(repo),"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","foreign"], check=True)
foreign=subprocess.check_output(["git","-C",str(repo),"rev-parse","HEAD"], text=True).strip()
check("existing foreign SHA is rejected", sup.validate_result_ref(f"git:aib/acme-engine/t-222222222222@{foreign}", task), False)
base=subprocess.check_output(["git","-C",str(repo),"rev-parse","main"], text=True).strip()
check("a base-branch SHA is not accepted as task work", sup.validate_result_ref(f"git:aib/acme-engine/t-222222222222@{base}", task), False)
check("contained result file is accepted", sup.validate_result_ref("file:result.txt", task), True)
(repo/".aib"/"wt"/"outside.txt").write_text("outside\n", encoding="utf-8")
check("file traversal to a regular file is rejected", sup.validate_result_ref("file:../outside.txt", task), False)
(wt/"escape.txt").symlink_to(repo/".aib"/"wt"/"outside.txt")
check("a result symlink escaping the worktree is rejected", sup.validate_result_ref("file:escape.txt", task), False)
large=wt/"large.bin"; large.write_bytes(b"x"*(1024*1024+1))
check("result files over one MiB are rejected", sup.validate_result_ref("file:large.bin", task), False)
check("message refs use the closed token grammar", sup.validate_result_ref("msg:result-1", task), True)
check("option-like message refs are rejected", sup.validate_result_ref("msg:-bad", task), False)

confine=work/"landlock-stub"
confine.write_text(f'''#!/usr/bin/env bash
printf 'LL_RO=%s\\nLL_RW=%s\\nARGV=%s\\n' "$LL_RO" "$LL_RW" "$*" >> "{work/'git-helper.log'}"
shift 6
exec "$@"
''', encoding="utf-8")
confine.chmod(0o755)
os.environ["AIB_CONFINE_BIN"]=str(confine)
sup.role_uid=os.getuid(); sup.role_gid=os.getgid(); sup.role_groups={repo.stat().st_gid}
probe=sup._git_as_role(repo, "rev-parse", "HEAD")
helper_log=(work/"git-helper.log").read_text(encoding="utf-8")
check("role-confined git helper executes an arbitrary git command", probe.returncode, 0)
for needle in (
    f"--uid {os.getuid()} --gid {os.getgid()} --groups {repo.stat().st_gid}",
    f"LL_RW=/tmp:/var/tmp:/dev:{repo}", "LL_RO=/", "/usr/bin/env -i", "HOME=/nonexistent",
    "GIT_CONFIG_NOSYSTEM=1", "GIT_ATTR_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_GLOBAL=",
    "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.untrackedCache=false",
    "credential.helper=", "protocol.allow=never", "--no-replace-objects",
):
    check(f"git helper composition includes {needle}", needle in helper_log, True)

marker=work/"repo-code-ran"
hooks=repo/"poison-hooks"; hooks.mkdir()
(hooks/"post-checkout").write_text(f"#!/bin/sh\ntouch '{marker}'\n", encoding="utf-8"); (hooks/"post-checkout").chmod(0o755)
subprocess.run(["git","-C",str(repo),"config","core.hooksPath",str(hooks)], check=True)
subprocess.run(["git","-C",str(repo),"config","core.fsmonitor",f"touch {marker}"], check=True)
sup._git_as_role(wt, "status", "--porcelain")
sup._git_as_role(wt, "switch", "--detach", "HEAD")
sup._git_as_role(wt, "switch", "aib/acme-engine/t-222222222222")
check("repo fsmonitor and post-checkout code never executes in the supervisor git process", marker.exists(), False)

source=(root/"lib"/"aib_supervisor.py").read_text(encoding="utf-8")
tree=__import__("ast").parse(source)
git_argv=[]
for node in __import__("ast").walk(tree):
    if isinstance(node, (__import__("ast").List, __import__("ast").Tuple)):
        for item in node.elts:
            if isinstance(item, __import__("ast").Constant) and item.value == "git":
                owner=next((parent for parent in __import__("ast").walk(tree) if isinstance(parent, (__import__("ast").FunctionDef, __import__("ast").AsyncFunctionDef)) and node in list(__import__("ast").walk(parent))), None)
                git_argv.append(owner.name if owner else "<module>")
check("literal git argv is confined to _git_as_role", set(git_argv), {"_git_as_role"})
check(
    "root project-home metadata access uses a verified directory-fd chain",
    "def _open_project_home" in source
    and "Path(self.project_home).resolve" not in source
    and "repo.stat().st_gid" not in source,
    True,
)
check(
    "result files are checked by the confined role rather than root path traversal",
    "def _validate_file_ref_as_role" in source
    and "target = (root / relative).resolve" not in source,
    True,
)

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(failed != 0)
PY
