#!/bin/sh
# ci-router runner wrapper. JIT_CONFIG arrives via the environment (boot
# secret) and is never logged.
#
# Telemetry contract (docs/auto-routing.md): every metric is a JSON number or
# null. Unknown is null, NEVER 0: without /proc, or with fewer than 2 samples, a
# fake 0 would read as "idle" and trigger a downsize. The CI_ROUTER_* overrides
# below exist for tests only; production leaves them unset.
set -u
# Kept in this shell only, so a step printing its environment does not send them to GitHub's logs.
# This is log hygiene, not a barrier: the job is root here and can read the listener's command line.
JIT=$JIT_CONFIG
TELEMETRY_TOKEN=$CIROUTER_TELEMETRY_TOKEN
ADMISSION=${CIROUTER_ADMISSION:-}
unset JIT_CONFIG CIROUTER_TELEMETRY_TOKEN CIROUTER_ADMISSION
export LC_ALL=C
PROCFS=${CI_ROUTER_PROC:-/proc}
TMPD=${CI_ROUTER_TMP:-/tmp}
INTERVAL=${CI_ROUTER_SAMPLE_SEC:-5}
cd "${CI_ROUTER_DIR:-/opt/actions-runner}"
START=$(date +%s)

CPU="$TMPD/ci-router-cpu"
MEM="$TMPD/ci-router-mem"
DISK="$TMPD/ci-router-disk"
: > "$CPU"; : > "$MEM"; : > "$DISK"

# CPU jiffies (user nice system idle iowait irq softirq steal) are sampled ONLY
# while a job is executing, so boot and the idle wait for a job assignment do not
# dilute cpuAvgPct / cpuSatPct (the oversized trigger would shrink a busy route).
# "Executing" = a process whose comm is exactly Runner.Worker: actions/runner
# starts it per job (Runner.Listener/JobDispatcher.cs: "Runner.Worker" +
# ExeExtension, empty on Linux). The sampling is passive on purpose; the job-started hook
# set below is the one deliberate exception: on a refusal it kills this worker (admission.ts). If the worker
# is ever renamed, CPU metrics become null (CPU triggers go quiet) instead of wrong, and the hook finds
# no worker to stop.
worker_running() {
  # cat, not awk: awk stops at the first file that vanished after the glob, which a busy VM does often.
  cat "$PROCFS"/[0-9]*/comm 2>/dev/null | grep -qxF 'Runner.Worker'
}
sample_cpu() {
  awk '/^cpu /{print $2, $3, $4, $5, $6, $7, $8, $9}' "$PROCFS/stat" >> "$CPU" 2>/dev/null
}
# MemAvailable (kB) and the root filesystem use (%): peaks, whole lifetime.
sample_peaks() {
  awk '/^MemAvailable:/{print $2}' "$PROCFS/meminfo" >> "$MEM" 2>/dev/null
  df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}' >> "$DISK"
}
sample() {
  if worker_running; then sample_cpu; fi
  sample_peaks
}
# A JSON number or null: anything that is not a plain non-negative decimal.
num() {
  case "$1" in
    ''|*[!0-9.]*|*.*.*|.*|*.|0[0-9]*[0-9]) echo null ;;
    *) echo "$1" ;;
  esac
}

OOM0=$(awk '/^oom_kill /{print $2}' "$PROCFS/vmstat" 2>/dev/null)

( while :; do sample; sleep "$INTERVAL"; done ) >/dev/null 2>&1 &
SAMPLER=$!

# Job admission: the runner runs this hook before any step of the job it is actually handed (a JIT
# runner only carries the job's shared labels, so it can receive another queued job). The policy
# snapshot is not a secret; no snapshot means the hook refuses public-repository jobs. A refusal kills the
# job's Runner.Worker (failing the hook step alone would still let "if: always()" steps run), so the listener
# reports the job failed and exits; this wrapper never restarts it (no loop below), posts telemetry and powers off.
cat > ci-router-job-started.cjs <<'CI_ROUTER_HOOK_EOF'
'use strict';
var fs = require('fs');

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (e) {
    return null;
  }
}

function parsePolicy(text) {
  if (!text) return null;
  try {
    var wire = JSON.parse(Buffer.from(text.trim(), 'base64').toString('utf8'));
    if (!wire || wire.v !== 1 || typeof wire.m !== 'string' || !Array.isArray(wire.u)) return null;
    var users = [];
    for (var i = 0; i < wire.u.length; i++) {
      var u = wire.u[i];
      if (!Array.isArray(u) || typeof u[0] !== 'string' || typeof u[1] !== 'string') return null;
      users.push({ id: u[0], login: u[1].toLowerCase() });
    }
    return { mode: wire.m, users: users };
  } catch (e) {
    return null;
  }
}

function isPrivate(eventText) {
  try {
    var event = JSON.parse(eventText);
    return !!event && !!event.repository && event.repository.private === true;
  } catch (e) {
    return false;
  }
}

function decide(env, eventText, policy) {
  if (eventText && isPrivate(eventText)) return { ok: true };
  if (!policy) return { ok: false, why: 'this runner was given no public repository policy' };
  if (policy.mode === 'anyone') return { ok: true };
  if (policy.mode !== 'allowlist') {
    return { ok: false, why: 'public repository policy: ' + (policy.mode === 'off' ? 'off' : 'unknown') };
  }
  var actorId = env.GITHUB_ACTOR_ID || '';
  var triggering = (env.GITHUB_TRIGGERING_ACTOR || '').toLowerCase();
  var idOk = !!actorId && policy.users.some(function (u) { return u.id === actorId; });
  var loginOk = !!triggering && policy.users.some(function (u) { return u.login === triggering; });
  if (!idOk) return { ok: false, why: 'public repository policy: the run author is not on the allowed users list' };
  if (!loginOk) return { ok: false, why: 'public repository policy: the user who started the run is not on the allowed users list' };
  return { ok: true };
}

try {
  var env = process.env;
  var eventText = env.GITHUB_EVENT_PATH ? readText(env.GITHUB_EVENT_PATH) : null;
  var verdict = decide(env, eventText, parsePolicy(readText(process.argv[2])));
  if (!verdict.ok) {
    console.error('ci-router: this job was not approved to run on ci-router runners (' + verdict.why + '). If this is unexpected, change the public repositories setting in the ci-router dashboard.');
    process.exit(1);
  }
  console.log('ci-router: job admitted (' + (env.GITHUB_REPOSITORY || 'unknown repository') + ')');
} catch (e) {
  console.error('ci-router: could not check this job, so it was not approved to run on ci-router runners.');
  process.exit(1);
}
CI_ROUTER_HOOK_EOF
cat > ci-router-job-started.sh <<'CI_ROUTER_HOOK_SHIM_EOF'
#!/bin/sh
# ci-router job-started hook (runs before any workflow step; see packages/runner/src/admission.ts).
FLUSH=3
D=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

pid_comm() {
  if [ -r "/proc/$1/comm" ]; then cat "/proc/$1/comm" 2>/dev/null; else ps -o comm= -p "$1" 2>/dev/null; fi
}
pid_ppid() {
  if [ -r "/proc/$1/stat" ]; then
    sed -e 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f2
  else
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
  fi
}
# SIGKILL the Runner.Worker this hook runs under. Returns 1 when none is found among the ancestors.
# CIROUTER_HOOK_WALK_STOP_PID (tests only, see admission.ts): never look at that pid or above it.
stop_worker() {
  p=$PPID
  i=0
  while [ "$i" -lt 12 ] && [ "$p" -gt 1 ] 2>/dev/null; do
    if [ -n "$CIROUTER_HOOK_WALK_STOP_PID" ] && [ "$p" = "$CIROUTER_HOOK_WALK_STOP_PID" ]; then
      return 1
    fi
    c=$(pid_comm "$p")
    c=${c##*/}
    if [ "$c" = "Runner.Worker" ]; then
      kill -KILL "$p" 2>/dev/null
      return 0
    fi
    p=$(pid_ppid "$p")
    i=$((i + 1))
  done
  return 1
}
refuse() {
  echo "ci-router: stopping this job, no step will run." >&2
  sleep "$FLUSH"
  if ! stop_worker; then
    echo "ci-router: could not find the runner's job process to stop; failing the job." >&2
  fi
  exit 1
}

# Runner 2.338.2 bundles native node24 and node24_alpine; Ubuntu needs the native binary.
NODE="$D/externals/node24/bin/node"
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "ci-router: could not check this job (no Node in the runner), so it was not approved to run on ci-router runners." >&2
  refuse
fi
if "$NODE" "$D/ci-router-job-started.cjs" "$D/ci-router-admission"; then
  exit 0
fi
refuse
CI_ROUTER_HOOK_SHIM_EOF
chmod 0755 ci-router-job-started.sh
rm -f ci-router-admission
if [ -n "$ADMISSION" ]; then printf '%s' "$ADMISSION" > ci-router-admission; fi
export ACTIONS_RUNNER_HOOK_JOB_STARTED="$PWD/ci-router-job-started.sh"

# Root-mode boot needs this flag; nonroot Tenki handoff does not depend on it.
export RUNNER_ALLOW_RUNASROOT=1
./run.sh --jitconfig "$JIT" &
RUNNER=$!
wait "$RUNNER"
RC=$?
kill "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true
# Peaks only. A CPU sample here would count the runner's teardown as job time, because
# the worker has already exited. A job too short for two ticks reports null CPU.
sample_peaks

OOM1=$(awk '/^oom_kill /{print $2}' "$PROCFS/vmstat" 2>/dev/null)
OOMKILLS=null
case "$OOM0$OOM1" in
  ''|*[!0-9]*) ;;
  *) [ -n "$OOM0" ] && [ -n "$OOM1" ] && [ "$OOM1" -ge "$OOM0" ] && OOMKILLS=$((OOM1 - OOM0)) ;;
esac

# CPU, first to last job sample (none or one = unknown, never a lifetime fallback),
# over all 8 jiffy columns. busy = everything but idle and iowait (steal counts as
# busy). Saturation = share of consecutive sample pairs with busy >= 90%. Output: avg sat iowait steal samples.
CPUSTATS=$(awk '
  NF == 8 && $0 !~ /[^0-9 ]/ { n++; for (i = 1; i <= 8; i++) c[n, i] = $i }
  function pct(v) { return v < 0 ? 0 : (v > 100 ? 100 : v) }
  END {
    if (n < 1) { print "null null null null null"; exit }
    if (n < 2) { print "null null null null " n; exit }
    dt = 0; neg = 0
    for (i = 1; i <= 8; i++) { d[i] = c[n, i] - c[1, i]; if (d[i] < 0) neg = 1; dt += d[i] }
    if (neg || dt <= 0) { print "null null null null " n; exit }
    avg = pct(100 * (dt - d[4] - d[5]) / dt)
    iow = pct(100 * d[5] / dt)
    stl = pct(100 * d[8] / dt)
    valid = 0; sat = 0
    for (k = 2; k <= n; k++) {
      t = 0; bad = 0
      for (i = 1; i <= 8; i++) { x[i] = c[k, i] - c[k - 1, i]; if (x[i] < 0) bad = 1; t += x[i] }
      if (bad || t <= 0) continue
      valid++
      if (100 * (t - x[4] - x[5]) / t >= 90) sat++
    }
    if (valid > 0) satp = sprintf("%.1f", pct(100 * sat / valid)); else satp = "null"
    printf "%.1f %s %.1f %.1f %d", avg, satp, iow, stl, n
  }' "$CPU" 2>/dev/null)
set -- $CPUSTATS
CPUAVG=$(num "${1:-}"); CPUSAT=$(num "${2:-}"); CPUIOW=$(num "${3:-}"); STEAL=$(num "${4:-}"); SAMPLES=$(num "${5:-}")

# Memory high-water % = 1 - min(MemAvailable)/MemTotal; null when unknown.
MEMP=$(num "$(awk '
  FNR == NR { if ($1 == "MemTotal:") t = $2; next }
  $1 ~ /^[0-9]+$/ && (m == "" || $1 + 0 < m + 0) { m = $1 }
  END { if (t + 0 > 0 && m != "") { v = 100 * (t - m) / t; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.1f", v } }
  ' "$PROCFS/meminfo" "$MEM" 2>/dev/null)")
MEMTOTAL=$(num "$(awk '/^MemTotal:/{printf "%d", $2 / 1024}' "$PROCFS/meminfo" 2>/dev/null)")
# Peak root filesystem use % over the run.
DISKP=$(num "$(awk '$1 ~ /^[0-9]+$/ && $1 + 0 <= 100 && (m == "" || $1 + 0 > m + 0) { m = $1 } END { if (m != "") print m }' "$DISK" 2>/dev/null)")
VCPUS=$(num "$(awk '/^cpu[0-9]+ /{n++} END { if (n > 0) print n }' "$PROCFS/stat" 2>/dev/null)")

DURATION=$(( $(date +%s) - START ))
STATUS=failed; [ "$RC" -eq 0 ] && STATUS=done

BODY=$(printf '{"durationSec": %s, "cpuStealPct": %s, "memPeakPct": %s, "cpuAvgPct": %s, "cpuSatPct": %s, "cpuIowaitPct": %s, "diskPeakPct": %s, "oomKills": %s, "samples": %s, "exitCode": %s, "vcpus": %s, "memTotalMb": %s, "status": "%s"}' \
  "$DURATION" "$STEAL" "$MEMP" "$CPUAVG" "$CPUSAT" "$CPUIOW" "$DISKP" "$OOMKILLS" "$SAMPLES" "$RC" "$VCPUS" "$MEMTOTAL" "$STATUS")

curl -fsS -m 10 -X POST "$CIROUTER_TELEMETRY_URL" \
  -H "Authorization: Bearer $TELEMETRY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$BODY" \
  || true

poweroff -f
