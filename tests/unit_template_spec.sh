#!/usr/bin/env bash
# ai-bobnet — RED spec for the systemd template unit deploy/systemd/aib-agent@.service
# (Supervisor slice S1a-2; design B1/B2 as amended by F5b, F6, F9).
#
# WHAT THIS PINS — the unit's TEXT, not systemd's behaviour. Each assertion names the section a key
# lives in (StartLimit* belongs to [Unit]; everything else to [Service]) because a key in the wrong
# section is silently ignored by systemd. The one place systemd itself is consulted is
# `systemd-analyze verify`, which needs systemd >= 254 (RestartSteps) and is opt-in:
# AIB_UNIT_VERIFY=1 on the VM. Elsewhere that single check is skipped with a stated reason.
#
#   - template: no [Install] (the VM drop-in / provisioning adds WantedBy; it is the dashboard-unit
#     pattern), no User=/Group= (a per-instance drop-in from the clearance->role map writes those;
#     agents never write units), no ConditionPathExists= marker (F5b: nothing that carries authority
#     lives in agent-writable space; abschalten is `systemctl disable`).
#   - lifecycle: Type=notify + NotifyAccess=all, WatchdogSec=90, Restart=on-failure, RestartSec=5,
#     RestartSteps=5, RestartMaxDelaySec=300, StartLimitIntervalSec=900 + StartLimitBurst=5 (outer
#     brake), RestartForceExitStatus=75 (neustart --hard), KillMode=mixed, TimeoutStopSec=60.
#   - state: StateDirectory=aib-sup/%i with StateDirectoryMode=0700 (F1: v2 wins over v1's 0750).
#   - confinement: ProtectSystem=strict, NoNewPrivileges=yes, and ReadWritePaths that include
#     /run/aib (broker socket + ctl dir — F9) and the shared standup tree /srv/aib/standup.
#   - ExecStart runs bin/aib-supervisor with the instance name (%i) as the agent uid, by absolute path.
#   - Environment= names the registry (AIBOBNET_REGISTRY) and nothing secret.
set -uo pipefail
SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
UNIT="$SRC_ROOT/deploy/systemd/aib-agent@.service"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
no(){ fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

[ -f "$UNIT" ] && ok "unit template exists" || no "unit template exists ($UNIT)"

# sec_of <Section> -> the lines of that section (comments and blanks dropped)
sec() { awk -v want="[$1]" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} /^\[/ {cur=$0; next} cur==want {print}' "$UNIT" 2>/dev/null; }
sections() { grep -E '^\[[A-Za-z]+\]' "$UNIT" 2>/dev/null | tr -d '\n'; }
in_sec() { # in_sec <Section> <exact line>
  if sec "$1" | grep -qxF -- "$2"; then ok "[$1] $2"; else no "[$1] $2 (not present as an exact line in that section)"; fi
}
not_anywhere() { # not_anywhere <regex> <why>
  if grep -Eq "$1" "$UNIT" 2>/dev/null && [ -f "$UNIT" ]; then no "$2"; elif [ -f "$UNIT" ]; then ok "$2"; else no "$2 (no unit)"; fi
}

eq "sections are exactly [Unit][Service] (no [Install])" "$(sections)" "[Unit][Service]"
not_anywhere '^\s*User=|^\s*Group=' "no User=/Group= in the template (per-instance drop-in owns the role account)"
not_anywhere '^\s*ConditionPathExists' "no ConditionPathExists marker (disable state is systemd's, not a file an agent can delete)"

in_sec Unit "StartLimitIntervalSec=900"
in_sec Unit "StartLimitBurst=5"
in_sec Service "Type=notify"
in_sec Service "NotifyAccess=all"
in_sec Service "WatchdogSec=90"
in_sec Service "Restart=on-failure"
in_sec Service "RestartSec=5"
in_sec Service "RestartSteps=5"
in_sec Service "RestartMaxDelaySec=300"
in_sec Service "RestartForceExitStatus=75"
in_sec Service "KillMode=mixed"
in_sec Service "TimeoutStopSec=60"
in_sec Service "StateDirectory=aib-sup/%i"
in_sec Service "StateDirectoryMode=0700"
in_sec Service "ProtectSystem=strict"
in_sec Service "NoNewPrivileges=yes"

rw="$(sec Service | grep '^ReadWritePaths=' | head -1)"
case " ${rw#ReadWritePaths=} " in *" /run/aib "*) ok "ReadWritePaths includes /run/aib";; *) no "ReadWritePaths includes /run/aib (got '$rw')";; esac
case " ${rw#ReadWritePaths=} " in *" /srv/aib/standup "*) ok "ReadWritePaths includes /srv/aib/standup";; *) no "ReadWritePaths includes /srv/aib/standup (got '$rw')";; esac
eq "exactly one ReadWritePaths= line" "$(sec Service | grep -c '^ReadWritePaths=')" 1

es="$(sec Service | grep '^ExecStart=' | head -1)"
case "$es" in ExecStart=/*/bin/aib-supervisor\ %i) ok "ExecStart= is an absolute path to bin/aib-supervisor with %i as the agent uid";; *) no "ExecStart= is an absolute path to bin/aib-supervisor with %i (got '$es')";; esac
eq "Environment= sets AIBOBNET_REGISTRY" "$(sec Service | grep -c '^Environment=AIBOBNET_REGISTRY=/')" 1
eq "no credential-looking Environment= (TOKEN/KEY/SECRET/PASSWORD)" "$([ -f "$UNIT" ] && sec Service | grep -ciE '^Environment=.*(TOKEN|KEY|SECRET|PASSWORD)')" 0

# --- systemd itself: opt-in, VM only ---------------------------------------------
ver="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"
if [ "${AIB_UNIT_VERIFY:-}" != 1 ]; then
  printf 'skip - systemd-analyze verify: set AIB_UNIT_VERIFY=1 on the VM (needs systemd >= 254; this host: %s)\n' "${ver:-none}"
elif [ -z "$ver" ] || [ "$ver" -lt 254 ]; then
  printf 'skip - systemd-analyze verify: needs systemd >= 254 for RestartSteps= (this host: %s)\n' "${ver:-none}"
else
  d="$(mktemp -d)"; cp "$UNIT" "$d/aib-agent@acme-core.service"
  if systemd-analyze verify "$d/aib-agent@acme-core.service" 2>"$d/err"; then ok "systemd-analyze verify accepts the unit"; else no "systemd-analyze verify accepts the unit ($(head -c 300 "$d/err"))"; fi
  rm -rf "$d"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
