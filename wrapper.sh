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
unset JIT_CONFIG CIROUTER_TELEMETRY_TOKEN
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
# ExeExtension, empty on Linux). Passive on purpose: ACTIONS_RUNNER_HOOK_JOB_STARTED
# shows in customers' job logs and can fail their jobs. If the worker is ever
# renamed, CPU metrics become null (CPU triggers go quiet) instead of wrong.
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

# As root (these single-use VMs boot as root), the runner refuses to start without this, and exits 0.
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
