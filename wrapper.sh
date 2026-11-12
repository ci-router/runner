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
MAX_JOB=${CIROUTER_MAX_JOB_SEC:-}
unset JIT_CONFIG CIROUTER_TELEMETRY_TOKEN CIROUTER_ADMISSION CIROUTER_MAX_JOB_SEC
export LC_ALL=C
PROCFS=${CI_ROUTER_PROC:-/proc}
TMPD=${CI_ROUTER_TMP:-/tmp}
INTERVAL=${CI_ROUTER_SAMPLE_SEC:-5}
cd "${CI_ROUTER_DIR:-/opt/actions-runner}"
# A monotonic clock for every limit below: /proc/uptime does not jump when NTP or the hypervisor steps the
# wall clock (a forward step would cut a healthy job at the "cap", a backward one would extend it).
# Chosen once, so the readings are never mixed; without /proc/uptime it is the wall clock.
CLOCK=date
case "$(awk '{print int($1); exit}' "$PROCFS/uptime" 2>/dev/null)" in ''|*[!0-9]*) ;; *) CLOCK=uptime ;; esac
now_s() {
  if [ "$CLOCK" = uptime ]; then awk '{print int($1); exit}' "$PROCFS/uptime"; else date +%s; fi
}
uptime_now() { awk '{print $1; exit}' "$PROCFS/uptime" 2>/dev/null; }
now_ms() {
  if [ "$CLOCK" = uptime ]; then
    awk '{printf "%.0f", $1 * 1000; exit}' "$PROCFS/uptime"
  else
    printf '%s000' "$(date +%s)"
  fi
}
START=$(now_s)
START_MS=$(now_ms)
UP0=$(uptime_now)

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

# Live resource profiles cover the whole wrapper lifetime, independently of the job-only CPU stream
# above. Each sample is its own atomically renamed file: the sampler can append while a heartbeat is
# in flight, and a successful post deletes exactly the files it acknowledged. Failed posts therefore
# leave every sample pending. The number of files is bounded by the wrapper's bounded lifetime.
PROFILE_DIR="$TMPD/ci-router-profile"
rm -rf "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR"
: > "$PROFILE_DIR/previous-cpu"
: > "$PROFILE_DIR/sequence"
: > "$PROFILE_DIR/last-offset"
PROFILE_REPORT=${CI_ROUTER_PROFILE_REPORT_SEC:-15}
case "$PROFILE_REPORT" in ''|*[!0-9]*|0) PROFILE_REPORT=15 ;; esac

profile_cpu_pct() {
  current=$(awk '/^cpu / {
    if (NF >= 9) {
      bad = 0; line = ""
      for (i = 2; i <= 9; i++) { if ($i !~ /^[0-9]+$/) bad = 1; line = line (i > 2 ? " " : "") $i }
      if (!bad) print line
    }
    exit
  }' "$PROCFS/stat" 2>/dev/null)
  [ -n "$current" ] || { echo null; return; }
  previous=$(cat "$PROFILE_DIR/previous-cpu" 2>/dev/null)
  awk -v c="$current" -v p="$previous" 'BEGIN {
    nc = split(c, cv, " "); np = split(p, pv, " ")
    if (nc != 8 || np != 8) { print "null"; exit }
    total = 0
    for (i = 1; i <= 8; i++) {
      if (cv[i] !~ /^[0-9]+$/ || pv[i] !~ /^[0-9]+$/ || cv[i] + 0 < pv[i] + 0) { print "null"; exit }
      d[i] = cv[i] - pv[i]; total += d[i]
    }
    if (total <= 0) { print "null"; exit }
    v = 100 * (total - d[4] - d[5]) / total
    if (v < 0) v = 0; if (v > 100) v = 100
    printf "%.1f", v
  }'
  # Even a counter reset advances the baseline: the next point is a delta from this whole-lifetime
  # observation, never from the job-only file used for the final telemetry.
  printf '%s
' "$current" > "$PROFILE_DIR/previous-cpu.tmp.$$"
  mv "$PROFILE_DIR/previous-cpu.tmp.$$" "$PROFILE_DIR/previous-cpu"
}
profile_mem_pct() {
  value=$(awk '
    /^MemTotal:/ { t = $2 }
    /^MemAvailable:/ { a = $2 }
    END {
      if (t !~ /^[0-9]+$/ || a !~ /^[0-9]+$/ || t + 0 <= 0) { print "null"; exit }
      v = 100 * (t - a) / t
      if (v < 0) v = 0; if (v > 100) v = 100
      printf "%.1f", v
    }' "$PROCFS/meminfo" 2>/dev/null)
  # Some awk implementations skip END when opening the input fails.
  [ -n "$value" ] || value=null
  printf '%s' "$value"
}
profile_offset_ms() {
  awk -v start="$START_MS" -v now="$(now_ms)" -v last="$(cat "$PROFILE_DIR/last-offset" 2>/dev/null)" 'BEGIN {
    if (start !~ /^[0-9]+$/ || now !~ /^[0-9]+$/) {
      # A mid-run clock read failure must not reuse an idempotency key and drop later observations.
      if (last ~ /^[0-9]+$/) printf "%d", last + 1; else print 0
      exit
    }
    offset = now - start
    if (offset < 0) offset = 0
    # Strictly increasing offsets double as server-side idempotency keys, even on a coarse clock.
    if (last ~ /^[0-9]+$/ && offset <= last) offset = last + 1
    printf "%d", offset
  }'
}
# Network (#345): cumulative bytes received and transmitted since boot, "RX TX", over the interfaces
# that can leave the host (fields 2 and 10 of /proc/net/dev; loopback and container-internal bridges
# are left out, they would count the same bytes twice). Cumulative on purpose: a lost or replayed
# sample cannot skew a counter. "null null" where /proc/net/dev is unreadable or has no interface.
net_bytes() {
  value=$(awk '
    NR > 2 {
      sub(":", " ")
      if ($1 == "lo" || $1 ~ /^(docker|br-|veth|virbr|cni|flannel)/) next
      if ($2 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/) { rx += $2; tx += $10; seen = 1 }
    }
    END { if (seen) printf "%.0f %.0f", rx, tx }' "$PROCFS/net/dev" 2>/dev/null)
  [ -n "$value" ] || value="null null"
  printf '%s' "$value"
}
sample_profile() {
  sequence=$(cat "$PROFILE_DIR/sequence" 2>/dev/null)
  case "$sequence" in ''|*[!0-9]*) sequence=0 ;; esac
  sequence=$((sequence + 1))
  printf '%s
' "$sequence" > "$PROFILE_DIR/sequence"
  offset=$(profile_offset_ms)
  printf '%s
' "$offset" > "$PROFILE_DIR/last-offset"
  name=$(printf 'sample.%010d' "$sequence")
  printf '%s %s %s %s %s
' "$offset" "$(profile_cpu_pct)" "$(profile_mem_pct)" "$1" "$(net_bytes)" > "$PROFILE_DIR/$name.tmp.$$"
  mv "$PROFILE_DIR/$name.tmp.$$" "$PROFILE_DIR/$name"
}
sample() {
  if worker_running; then active=true; sample_cpu; else active=false; fi
  sample_profile "$active"
  sample_peaks
}

# A single writer avoids overlapping heartbeat requests. One tick per second also makes teardown
# responsive without signalling a shell that could leave its curl child running beside the final flush.
post_profiles() (
  manifest="$PROFILE_DIR/batch"
  : > "$manifest" || exit 1
  count=0
  for file in "$PROFILE_DIR"/sample.*; do
    [ -f "$file" ] || continue
    # sample.*.tmp.$$ is still being written/renamed by the sampler, never a completed observation.
    case "$file" in *.tmp.*) continue ;; esac
    printf '%s
' "$file" >> "$manifest"
    count=$((count + 1))
    [ "$count" -lt 120 ] || break
  done
  if [ "$count" -eq 0 ]; then rm -f "$manifest"; exit 0; fi
  BODY=$(
    printf '{"kind":"samples","samples":['
    separator=
    while IFS= read -r file; do
      IFS=' ' read -r offset cpu memory active netrx nettx < "$file"
      printf '%s{"offsetMs":%s,"cpuPct":%s,"memPct":%s,"jobActive":%s,"netRxBytes":%s,"netTxBytes":%s}' "$separator" "$offset" "$cpu" "$memory" "$active" "${netrx:-null}" "${nettx:-null}"
      separator=,
    done < "$manifest"
    printf ']}'
  )
  if curl -fsS -m 10 -X POST "$CIROUTER_TELEMETRY_URL" \
    -H "Authorization: Bearer $TELEMETRY_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$BODY"
  then
    while IFS= read -r file; do rm -f "$file"; done < "$manifest"
    result=0
  else
    result=1
  fi
  rm -f "$manifest"
  exit "$result"
)
(
  ticks=0
  while [ ! -f "$PROFILE_DIR/stop" ]; do
    sleep 1
    [ ! -f "$PROFILE_DIR/stop" ] || break
    ticks=$((ticks + 1))
    if [ "$ticks" -ge "$PROFILE_REPORT" ]; then ticks=0; post_profiles || true; fi
  done
) >/dev/null 2>&1 &
HEARTBEAT=$!

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

# Phase marks (#215), for the router's overhead report: seconds since this wrapper started, from the
# VM's own monotonic /proc/uptime (no clock agreement with the router needed). UP0 is the uptime now,
# so it is also how long the kernel has been up (null where /proc/uptime is unreadable or not the
# VM's). A watcher notes when the runner listener appears (the JIT config is applied as it starts),
# when the job's Runner.Worker appears, and when it is gone again. It only reads.
MARKS="$TMPD/ci-router-marks"
: > "$MARKS"
mark() { printf '%s %s\n' "$1" "$(uptime_now)" >> "$MARKS"; }
(
  up=0; started=0; ended=0
  while :; do
    comms=$(cat "$PROCFS"/[0-9]*/comm 2>/dev/null)
    if [ "$up" = 0 ] && printf '%s\n' "$comms" | grep -qxF 'Runner.Listener'; then mark up; up=1; fi
    if printf '%s\n' "$comms" | grep -qxF 'Runner.Worker'; then
      if [ "$started" = 0 ]; then mark start; started=1; fi
    elif [ "$started" = 1 ] && [ "$ended" = 0 ]; then mark end; ended=1; fi
    sleep "${CI_ROUTER_MARK_SEC:-1}"
  done
) >/dev/null 2>&1 &
MARKER=$!

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

// Tested-commit capture (run identity). JOB-REPORTED evidence for duplicate-run analysis, never
// authoritative: a job step can overwrite the file. It has its own try/catch and runs before the
// verdict, so an admitted and a refused job are both recorded, and nothing here can change the
// verdict, the output or the exit code (a missing or unwritable path is ignored). Two lines: the
// commit GITHUB_SHA and the ref GITHUB_REF; the wrapper validates both before it reports them.
// A value with a line break is dropped whole: it must not split into the file's other line.
function oneLine(value) {
  var v = String(value || '');
  if (v.indexOf(String.fromCharCode(10)) >= 0 || v.indexOf(String.fromCharCode(13)) >= 0) return '';
  return v;
}

function captureTested(env, file) {
  if (!file) return;
  var sha = oneLine(env.GITHUB_SHA).slice(0, 100);
  var ref = oneLine(env.GITHUB_REF).slice(0, 300);
  fs.writeFileSync(file, [sha, ref].join(String.fromCharCode(10)) + String.fromCharCode(10));
}

try {
  captureTested(process.env, process.argv[3]);
} catch (e) {
  // ignored on purpose
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
if "$NODE" "$D/ci-router-job-started.cjs" "$D/ci-router-admission" "$D/ci-router-tested"; then
  exit 0
fi
refuse
CI_ROUTER_HOOK_SHIM_EOF
chmod 0755 ci-router-job-started.sh
rm -f ci-router-admission ci-router-tested
TESTED="$PWD/ci-router-tested"
if [ -n "$ADMISSION" ]; then printf '%s' "$ADMISSION" > ci-router-admission; fi
export ACTIONS_RUNNER_HOOK_JOB_STARTED="$PWD/ci-router-job-started.sh"

# Root-mode boot needs this flag; nonroot Tenki handoff does not depend on it.
export RUNNER_ALLOW_RUNASROOT=1
# Its own session and process group (setsid), so a stop reaches the listener, the worker and the job's
# steps together, not just the shell run.sh started.
if command -v setsid >/dev/null 2>&1; then setsid ./run.sh --jitconfig "$JIT" & else ./run.sh --jitconfig "$JIT" & fi
RUNNER=$!

# Runtime limits, independent of the router (it may be down). One watcher, three rules:
#  - idle: no Runner.Worker within IDLE seconds of the start = a registered runner nobody sent a job to
#    (re-checked once after RECHECK seconds, so a job assigned right at the deadline is not killed);
#  - cap: the job (first Runner.Worker seen) has run MAX_JOB seconds;
#  - hard: IDLE + MAX_JOB + 2 x GRACE since the start, whatever else is happening.
# idle and cap stop the runner (its whole process group: TERM, then KILL after TERM_WAIT), so this wrapper
# falls through to the telemetry post and the poweroff below (GitHub then fails the job as lost); if it
# does not get there within GRACE, the watcher powers off itself. The runner is stopped, never the VM
# first, so the telemetry still goes out. The reason is written to a file the wrapper reads after the
# runner exits: a cap stop is reported as exit 124, which the router scores as the job's own
# timeout, not as a runner crash.
case "$MAX_JOB" in ''|*[!0-9]*|0) MAX_JOB=21600 ;; esac
IDLE=${CI_ROUTER_IDLE_SEC:-180}
GRACE=${CI_ROUTER_KILL_GRACE_SEC:-120}
WATCH=${CI_ROUTER_WATCH_SEC:-2}
RECHECK=${CI_ROUTER_IDLE_RECHECK_SEC:-5}
TERM_WAIT=${CI_ROUTER_TERM_WAIT_SEC:-10}
LIMIT_FILE="$TMPD/ci-router-limit"
SEEN_FILE="$TMPD/ci-router-seen"
rm -f "$LIMIT_FILE" "$SEEN_FILE"
poweroff_now() { poweroff -f; }
stop_runner() {
  echo "$1" > "$LIMIT_FILE"
  kill -TERM "-$RUNNER" 2>/dev/null
  kill -TERM "$RUNNER" 2>/dev/null
  sleep "$TERM_WAIT"
  kill -KILL "-$RUNNER" 2>/dev/null
  kill -KILL "$RUNNER" 2>/dev/null
}
(
  seen=0; seen_at=0
  while :; do
    sleep "$WATCH"
    now=$(now_s)
    if [ "$seen" -eq 0 ]; then
      if worker_running; then seen=1; seen_at=$now; echo "$seen_at" > "$SEEN_FILE"
      elif [ $((now - START)) -ge "$IDLE" ]; then
        sleep "$RECHECK"
        if worker_running; then seen=1; seen_at=$(now_s); echo "$seen_at" > "$SEEN_FILE"
        else
          stop_runner idle
          sleep "$GRACE"; poweroff_now
        fi
      fi
    elif [ $((now - seen_at)) -ge "$MAX_JOB" ]; then
      stop_runner cap
      sleep "$GRACE"; poweroff_now
    fi
    if [ $((now - START)) -ge $((IDLE + MAX_JOB + 2 * GRACE)) ]; then poweroff_now; fi
  done
) >/dev/null 2>&1 &
LIMITS=$!
wait "$RUNNER"
RC=$?
# A runner the watcher stopped at the cap reports the cap, not the signal that ended it. The marker
# file lives where the job can write (it runs as this user), so it is not trusted alone: a real cap
# stop only happens once the job has run MAX_JOB seconds, measured from the moment the watcher first
# saw the job's worker (the file it wrote), not from the wrapper's start: a job that starts late
# must not be reported as having hit the cap early. A job that writes "cap" into it earlier, to turn its runner crash into
# its own "timeout" and hide the failure from scoring, is reported as the crash it was.
if [ "$(cat "$LIMIT_FILE" 2>/dev/null)" = cap ]; then
  SEEN_AT=$(cat "$SEEN_FILE" 2>/dev/null)
  case "$SEEN_AT" in ''|*[!0-9]*) SEEN_AT= ;; esac
  if [ -n "$SEEN_AT" ] && [ $(($(now_s) - SEEN_AT)) -ge "$MAX_JOB" ]; then RC=124; fi
fi
: > "$PROFILE_DIR/stop"
kill "$LIMITS" 2>/dev/null || true
kill "$SAMPLER" "$MARKER" 2>/dev/null || true
wait "$SAMPLER" "$MARKER" 2>/dev/null || true
# Let an in-flight heartbeat finish before the final drain, so no two sample posts can overlap.
wait "$HEARTBEAT" 2>/dev/null || true
# A worker still listed when the runner exited ends with it.
if grep -q '^start ' "$MARKS" 2>/dev/null && ! grep -q '^end ' "$MARKS" 2>/dev/null; then mark end; fi
# A final profile point covers teardown, but do not add a CPU sample to the legacy job-only file:
# that would count the runner's teardown as job time. Peaks remain whole-lifetime.
sample_peaks
if worker_running; then active=true; else active=false; fi
sample_profile "$active"
# Drain pending batches, oldest first, before the one final telemetry post. A failed batch stays
# on disk. The TOTAL deadline bounds even a long backlog of slow successful posts: telemetry must
# never postpone the mandatory poweroff indefinitely (one in-flight curl still has its own 10 s cap).
FLUSH_SEC=${CI_ROUTER_PROFILE_FLUSH_SEC:-60}
case "$FLUSH_SEC" in ''|*[!0-9]*) FLUSH_SEC=60 ;; esac
FLUSH_DEADLINE=$(( $(now_s) + FLUSH_SEC ))
while [ "$(now_s)" -lt "$FLUSH_DEADLINE" ]; do
  set -- "$PROFILE_DIR"/sample.*
  [ -f "$1" ] || break
  # A transient failure leaves every file pending: retry within the same total deadline instead of
  # abandoning the rest of the profile. The short sleep also bounds a tight failure loop.
  post_profiles >/dev/null 2>&1 || sleep 1
done

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

# Seconds since wrapper start of a mark (or now, for poweroff), as a JSON number or null.
since_start() {
  num "$(awk -v a="$UP0" -v b="$1" 'BEGIN { if (a ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/ && b + 0 >= a + 0) printf "%.2f", b - a }')"
}
mark_since() { since_start "$(awk -v n="$1" '$1 == n { print $2; exit }' "$MARKS" 2>/dev/null)"; }
RUNNERUP=$(mark_since up); JOBSTART=$(mark_since start); JOBEND=$(mark_since end)
POWEROFFSEC=$(since_start "$(uptime_now)")
UPSTART=$(num "$UP0")
# Bytes received over the VM's whole life so far (#345), same filter and same counters as the samples.
NETRX=$(num "$(net_bytes | awk '{print $1}')")

# Egress (#232): bytes this VM transmitted since boot over every interface that can leave the host
# (field 10 of /proc/net/dev; loopback and container-internal bridges are left out, they would count
# the same bytes twice). Whole VM lifetime, as providers bill it. Null where /proc/net/dev is unreadable.
NETTX=$(num "$(awk '
  NR > 2 {
    sub(":", " ")
    if ($1 == "lo" || $1 ~ /^(docker|br-|veth|virbr|cni|flannel)/) next
    if ($10 ~ /^[0-9]+$/) { s += $10; seen = 1 }
  }
  END { if (seen) printf "%.0f", s }' "$PROCFS/net/dev" 2>/dev/null)")

# The commit and ref the job saw (GITHUB_SHA / GITHUB_REF), as the job-started hook wrote them. JOB-REPORTED,
# never authoritative: a job step can overwrite the file. Only values of the exact expected shape are sent
# (that is also what keeps the printf'd JSON below safe); anything else is null.
TESTED_SHA=null
TESTED_REF=null
if [ -r "$TESTED" ]; then
  t_sha=$(sed -n 1p "$TESTED" 2>/dev/null | cut -c1-100)
  t_ref=$(sed -n 2p "$TESTED" 2>/dev/null | cut -c1-300)
  if printf '%s
' "$t_sha" | LC_ALL=C grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'; then TESTED_SHA=$(printf '"%s"' "$t_sha"); fi
  if printf '%s
' "$t_ref" | LC_ALL=C grep -Eq '^refs/[A-Za-z0-9._/-]{1,255}$'; then TESTED_REF=$(printf '"%s"' "$t_ref"); fi
fi

DURATION=$(( $(now_s) - START ))
STATUS=failed; [ "$RC" -eq 0 ] && STATUS=done

BODY=$(printf '{"durationSec": %s, "cpuStealPct": %s, "memPeakPct": %s, "cpuAvgPct": %s, "cpuSatPct": %s, "cpuIowaitPct": %s, "diskPeakPct": %s, "oomKills": %s, "samples": %s, "exitCode": %s, "vcpus": %s, "memTotalMb": %s, "status": "%s", "vmUptimeAtStartSec": %s, "runnerUpSec": %s, "jobStartSec": %s, "jobEndSec": %s, "poweroffSec": %s, "netTxBytes": %s, "netRxBytes": %s, "testedSha": %s, "testedRef": %s}' \
  "$DURATION" "$STEAL" "$MEMP" "$CPUAVG" "$CPUSAT" "$CPUIOW" "$DISKP" "$OOMKILLS" "$SAMPLES" "$RC" "$VCPUS" "$MEMTOTAL" "$STATUS" "$UPSTART" "$RUNNERUP" "$JOBSTART" "$JOBEND" "$POWEROFFSEC" "$NETTX" "$NETRX" "$TESTED_SHA" "$TESTED_REF")

curl -fsS -m 10 -X POST "$CIROUTER_TELEMETRY_URL" \
  -H "Authorization: Bearer $TELEMETRY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$BODY" \
  || true

poweroff -f
