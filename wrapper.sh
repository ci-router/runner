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
PROBE_HOST=${CIROUTER_PROBE_HOST:-}
HOST_PROBES=${CIROUTER_HOST_PROBES:-}
unset JIT_CONFIG CIROUTER_TELEMETRY_TOKEN CIROUTER_ADMISSION CIROUTER_MAX_JOB_SEC CIROUTER_PROBE_HOST
unset CIROUTER_HOST_PROBES
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
MARKS="$TMPD/ci-router-marks"
: > "$MARKS"

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
: > "$PROFILE_DIR/phase-prev"
# What the job is doing (D23): the awk classifier and its table, written once. Only a class id from a
# fixed list ever leaves the VM; the table says which executable and which argument words (read in
# memory, at most three, only while a name is ambiguous) map to which class.
cat > "$PROFILE_DIR/phase.awk" <<'CI_ROUTER_PHASE_AWK_EOF'
# Classifies what the job is doing right now (D23). Reads: the previous per-process tick state, a "@@"
# line, then every /proc/<pid>/stat. Prints one class id, or "-" when no job worker exists, and writes
# the new tick state to OUT. Processes are the descendants of Runner.Worker; the class is the one that
# holds at least half of the CPU ticks they used since the last sample, "idle" when they used almost
# none, "other" otherwise. The table (TABLE) is the one in packages/core; this file is its awk twin and
# the tests assert both give the same class.
#
# Privacy: an argument word is read only through tok_next(), only for an executable that has rules, one
# word at a time, at most three words (eight raw tokens with their flags; 32 for java, whose main class
# follows its JVM flags, and an @argfile is never opened), and only into memory. No
# word is printed, written or passed to anything but the table lookup. Only the class id leaves. A
# retitled argv[0] is read the same way, once, for an executable that has rules.
function parse(line,   a, n, i, bar, path, rest, f, fv, cls, ws, kv) {
  n = split(line, a, " ")
  if (n < 2) return
  if (a[1] == "E") {
    for (i = 3; i <= n; i++) { EXE[a[i]] = a[2]; KNOWN[a[i]] = 1 }
    return
  }
  if (a[1] == "X") { split(a[2], f, "|"); ALIAS[f[1]] = f[2]; return }
  rest = substr(line, 3)
  bar = index(rest, "|")
  if (bar == 0) return
  path = substr(rest, 1, bar - 1)
  rest = substr(rest, bar + 1)
  if (a[1] == "N") {
    split(rest, f, "|")
    DEF[path] = f[1]; SKIP[path] = f[2]
    n = split(f[3], fv, ",")
    for (i = 1; i <= n; i++) FV[path SUBSEP fv[i]] = 1
  } else if (a[1] == "L") {
    bar = index(rest, "|")
    cls = substr(rest, 1, bar - 1)
    n = split(substr(rest, bar + 1), ws, " ")
    for (i = 1; i <= n; i++) LEAF[path SUBSEP ws[i]] = cls
  } else if (a[1] == "A") {
    n = split(rest, ws, " ")
    for (i = 1; i <= n; i++) { split(ws[i], kv, "="); AL[path SUBSEP kv[1]] = kv[2] }
  }
}
function normalise(p,   n, root) {
  sub(/ \(deleted\)$/, "", p)
  sub(/^.*\//, "", p)
  n = p
  if (n == "nodejs") return "node"
  if (n ~ /^python([0-9]+(\.[0-9]+)*)?$/) return "python3"
  if (n ~ /^(ruby|php|perl)[0-9]+(\.[0-9]+)*$/) { sub(/[0-9.]+$/, "", n); return n }
  if (match(n, /-[0-9]+(\.[0-9]+)*$/)) {
    root = substr(n, 1, RSTART - 1)
    if (root != "" && (root in KNOWN)) return root
  }
  return n
}
# The next argument word after argv[0], or 0 at the end or at the raw-token cap. A process that retitled
# itself ("npm install x", "node (vitest 1)") has a space in argv[0]: its words come first, as if they
# were the arguments, minus a leading word that is the executable itself (TS twin: titleWords).
function tok_next(   t, n, i, w, k) {
  if (ARGDONE || ARGIDX >= ARGMAX) return 0
  if (!ARGOPEN) {
    ARGCMD = "tr '\\0' '\\n' 2>/dev/null < '" P "/" ARGPID "/cmdline'"
    ARGOPEN = 1
    if ((ARGCMD | getline t) <= 0) { ARGDONE = 1; return 0 }
    TWN = 0; TWI = 0
    sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    if (t ~ /[ \t]/) {
      n = split(t, w, /[ \t]+/)
      i = (normalise(w[1]) == ARGNAME) ? 2 : 1
      for (; i <= n && TWN < ARGMAX; i++) TW[++TWN] = w[i]
    }
  }
  if (TWI < TWN) { TWI++; ARGIDX++; TOK = TW[TWI]; return 1 }
  if ((ARGCMD | getline t) <= 0) { ARGDONE = 1; return 0 }
  ARGIDX++
  TOK = t
  return 1
}
# The next word of the command line at this node. A token the node's table knows is the word, even
# with a leading dash (make --version, node yarn.js --immutable); only a dash token with no entry is a
# flag, skipped (with its value) where the node says so. Sets KEY (the lookup key) and returns 1, or 0
# at the end of the arguments.
function next_word(node, depth,   t, key) {
  for (;;) {
    if (!tok_next()) return 0
    t = TOK
    key = t
    if (depth == 0 && substr(t, 1, 1) != "-") sub(/^.*\//, "", key)
    if ((node SUBSEP key) in AL) key = AL[node SUBSEP key]
    if (SKIP[node] == 1 && ((node SUBSEP t) in FV)) { if (!tok_next()) return 0; continue }
    if (((node SUBSEP key) in LEAF) || ((node " " key) in DEF) || ((node SUBSEP t) in AL)) { KEY = key; return 1 }
    if (SKIP[node] == 1 && substr(t, 1, 1) == "-") continue
    KEY = key
    return 1
  }
}
function classify(exe, pid,   name, rn, node, depth, w, key, r, child, k) {
  name = normalise(exe)
  rn = (name in ALIAS) ? ALIAS[name] : name
  if (!(rn in DEF)) return (name in EXE) ? EXE[name] : "other"
  node = rn; depth = 0; r = ""
  ARGPID = pid; ARGIDX = 0; ARGOPEN = 0; ARGDONE = 0; ARGNAME = name; ARGMAX = (rn == "java") ? 32 : 8; TWN = 0; TWI = 0
  for (w = 0; w < 3 && r == ""; w++) {
    if (!next_word(node, depth)) { r = DEF[node]; break }
    key = KEY
    if ((node SUBSEP key) in LEAF) { r = LEAF[node SUBSEP key]; break }
    child = node " " key
    if (child in DEF) { node = child; depth++; continue }
    r = DEF[node]
  }
  if (r == "") r = DEF[node]
  if (ARGOPEN) close(ARGCMD)
  KEY = ""; TOK = ""
  for (k in TW) delete TW[k]
  TWN = 0; TWI = 0
  return r
}
# The default class of an executable that has rules (no argument is read): where the rest of the
# ambiguous processes land when there are more than the ones read one by one.
function default_class(exe,   name, rn) {
  name = normalise(exe)
  rn = (name in ALIAS) ? ALIAS[name] : name
  return (rn in DEF) ? DEF[rn] : ((name in EXE) ? EXE[name] : "other")
}
function ambiguous(exe,   name, rn) {
  name = normalise(exe)
  rn = (name in ALIAS) ? ALIAS[name] : name
  return rn in DEF
}
BEGIN {
  while ((getline line < TABLE) > 0) parse(line)
  close(TABLE)
  if (CLKTCK + 0 <= 0) CLKTCK = 100
  minbusy = INTERVAL * CLKTCK / 20
}
$0 == "@@" { mode = 1; next }
mode == 0 { PREV[$1] = $2; next }
{
  pid = $1
  if (pid !~ /^[0-9]+$/) next
  c = $0; sub(/^[0-9]+ \(/, "", c); sub(/\) [^)]*$/, "", c)
  rest = $0; sub(/^.*\) /, "", rest)
  if (split(rest, f, " ") < 20) next
  PPID[pid] = f[2]; COMM[pid] = c; TK[pid] = f[12] + f[13]; ST[pid] = f[20]
}
END {
  for (pid in COMM) if (COMM[pid] == "Runner.Worker") worker = 1
  if (!worker) { print "-"; exit }
  total = 0; nc = 0
  for (pid in COMM) {
    p = PPID[pid]; steps = 0; under = 0
    while ((p in COMM) && steps < 64) {
      if (COMM[p] == "Runner.Worker") { under = 1; break }
      p = PPID[p]; steps++
    }
    if (!under) continue
    key = pid "." ST[pid]
    d = TK[pid] - ((key in PREV) ? PREV[key] : 0)
    if (d < 0) d = 0
    print key, TK[pid] > OUT
    total += d
    if (d > 0) CD[pid] = d
  }
  close(OUT)
  # The executables of the busiest processes, read with ONE ls (a missing or unreadable link prints
  # nothing: that process is "other", never its writable comm). Bounded, so a fork storm costs one spawn.
  np = 0; lscmd = ""
  for (k = 0; k < 256; k++) {
    best = 0; bd = 0
    for (pid in CD) if (CD[pid] > bd) { bd = CD[pid]; best = pid }
    if (best == 0) break
    delete CD[best]
    BUSY[best] = bd; np++
    lscmd = lscmd " '" P "/" best "/exe'"
  }
  if (np > 0) {
    cmd = "ls -l" lscmd " 2>/dev/null"
    while ((cmd | getline line) > 0) {
      arrow = index(line, " -> ")
      if (arrow == 0) continue
      left = substr(line, 1, arrow - 1); sub(/^.* /, "", left)
      if (substr(left, 1, length(P) + 1) != P "/") continue
      id = substr(left, length(P) + 2); sub(/\/exe$/, "", id)
      if (id in BUSY) EXEOF[id] = substr(line, arrow + 4)
    }
    close(cmd)
  }
  # Every busy process counts, by the class of its executable. Only those whose executable has rules
  # need their arguments, and only the busiest 24 of them are read; the rest take the default class.
  nr = 0
  for (pid in BUSY) {
    if (!(pid in EXEOF)) { CT["other"] += BUSY[pid]; continue }
    if (!ambiguous(EXEOF[pid])) { CT[classify(EXEOF[pid], pid)] += BUSY[pid]; continue }
    AMB[pid] = BUSY[pid]; nr++
  }
  for (k = 0; k < 24 && nr > 0; k++) {
    best = 0; bd = 0
    for (pid in AMB) if (AMB[pid] > bd) { bd = AMB[pid]; best = pid }
    if (best == 0) break
    delete AMB[best]; nr--
    CT[classify(EXEOF[best], best)] += bd
  }
  for (pid in AMB) CT[default_class(EXEOF[pid])] += AMB[pid]
  if (total < minbusy) { print "idle"; exit }
  top = "other"; tv = 0
  for (cls in CT) if (CT[cls] > tv) { tv = CT[cls]; top = cls }
  if (tv * 2 < total) top = "other"
  print top
}
CI_ROUTER_PHASE_AWK_EOF
cat > "$PROFILE_DIR/phase-table" <<'CI_ROUTER_PHASE_TABLE_EOF'
E git git git-lfs git-annex git-upload-pack git-receive-pack git-remote-http git-remote-https svn
E install-system apt-get apt apk dpkg dpkg-query rpm pacman zypper tdnf choco winget pkg pkg_add pkgin pkgman nix nix-env snap flatpak systemctl launchctl useradd groupadd locale ldconfig fc-cache udevadm sysctl hdiutil diskutil installer tzutil
E install-toolchain rustup-init fnm mise volta proto aqua xcode-select
E install-deps mamba micromamba vcpkg
E compile-native gcc g++ cc c++ clang clang++ clang-cl cc1 cc1plus ld ld.bfd ld.gold ld.lld lld as ar ranlib collect2 llvm-ar llvm-objcopy objcopy cmake cmake3 ninja jom nmake m4 bison flex pkg-config ccache x86_64-linux-gnu-gcc aarch64-linux-gnu-gcc arm-none-eabi-gcc compile asm pack link cgo ghc stack swiftc swift-frontend swift-driver dart2js gen_snapshot frontend_server dartaotruntime impellerc
E compile-rust rustc rust-lld
E compile-js esbuild swc lightningcss sass
E compile-jvm javac jar jlink
E test-native ctest FileCheck valgrind qemu-system-x86_64 qemu-aarch64 abidiff
E test-other xctest xcbeautify xcresulttool launchd_sim miniruby phpdbg
E lint ruff pyrefly ty clippy-driver rustfmt rust-analyzer gofmt gofumpt goimports golangci-lint staticcheck govulncheck gosec revive errcheck ineffassign nilaway shellcheck trivy hadolint clang-format clang-tidy cppcheck actionlint typos vale astyle uncrustify indent iwyu include-what-you-use infer zizmor prek reviewdog misspell editorconfig-checker kube-linter conftest opa tfsec grype syft cov-build aspell hunspell biome oxlint dprint
E archive tar zip unzip 7z 7za 7zr gzip gunzip zstd zstdcat xz unxz bzip2 lz4 lzma lzop cpio pigz brotli rar unrar bsdtar zopfli
E transfer curl wget aws azcopy rclone rsync scp sftp ssh ssh-agent ssh-add ssh-keyscan skopeo crane oras aria2c nc ping dig nslookup xh docker-credential-ecr-login
E docker-build buildkitd buildctl buildah kaniko img
E container-ops runc crun ctr kind k3d k3s minikube kubelet docker-proxy containerd-shim containerd-shim-runc-v2 containerd dockerd docker-compose
E publish goreleaser rpmbuild rpmsign pkgbuild productbuild reprepro changie maturin nfpm dpkg-deb altool notarytool
E db psql mysql mysqldump sqlite3 redis-cli redis-server mongo pg_isready pg_dump pg_restore createdb dropdb
X sh|bash
X dash|bash
N node|other|1|--eval,--import,--loader,--print,--require,-e,-p,-r
N node npm|other|1|--prefix,--registry,--workspace,-w
N node npm run|other|0|
L node npm run|compile-js|build compile bundle dist
L node npm run|test-js|test tests
L node npm run|lint|lint typecheck format
L node npm run|publish|publish
N node npm exec|other|0|
L node npm exec|test-js|jest vitest playwright cypress
L node npm exec|lint|tsc eslint prettier
L node npm exec|compile-js|esbuild vite webpack rollup
L node npm|install-deps|ci install i add uninstall update dedupe prune
L node npm|test-js|test
L node npm|publish|publish pack
N node npx|other|1|--package,-p
L node npx|test-js|jest vitest playwright cypress
L node npx|lint|tsc eslint prettier
L node npx|compile-js|esbuild vite webpack rollup
N node pnpm|other|1|--dir,--filter,--workspace-root,-C,-F,-w
N node pnpm run|other|0|
L node pnpm run|compile-js|build compile bundle dist
L node pnpm run|test-js|test tests test-node test-browser-no-install smoketest-no-compile
L node pnpm run|lint|lint typecheck format
L node pnpm run|publish|publish
L node pnpm run|install-deps|preinstall install
N node pnpm exec|other|0|
L node pnpm exec|test-js|jest vitest playwright cypress
L node pnpm exec|lint|tsc eslint prettier
L node pnpm exec|compile-js|esbuild vite webpack rollup
N node pnpm dlx|other|0|
L node pnpm dlx|test-js|jest vitest
L node pnpm dlx|lint|tsc eslint prettier
L node pnpm dlx|compile-js|esbuild vite
L node pnpm|install-deps|install i add remove update up dedupe prune fetch import
L node pnpm|test-js|test
L node pnpm|publish|publish deploy
L node pnpm|compile-js|build compile
L node pnpm|lint|lint typecheck format
N node yarn|other|1|--cache-folder,--cwd
N node yarn run|other|0|
L node yarn run|compile-js|build compile
L node yarn run|test-js|test
L node yarn run|lint|lint typecheck format
L node yarn run|publish|publish
L node yarn|install-deps|install add remove up link --immutable --immutable-cache
L node yarn|publish|publish pack
L node yarn|test-js|test
L node yarn|compile-js|build build:js compile
L node yarn|lint|lint check:ts
N node corepack|other|1|
L node corepack|install-toolchain|enable prepare
N node vp|other|1|
N node vp run|other|0|
L node vp run|compile-js|build compile
L node vp run|test-js|test
L node vp run|lint|lint
N node vp exec|other|0|
L node vp exec|test-js|jest vitest
L node vp exec|lint|tsc eslint prettier
L node|test-js|jest vitest (vitest (vitest) processChild.js mocha playwright cypress karma ava tap
L node|lint|tsc tsgo eslint prettier biome oxlint stylelint dprint markdownlint snyk fossa pyright basedpyright commitlint
L node|compile-js|esbuild swc rspack rolldown vite webpack rollup next nuxt parcel turbo nx terser babel
L node|publish|semantic-release wrangler electron-builder app-builder
L node|db|mongosh
A node|npm-cli.js=npm npx-cli.js=npx pnpm.cjs=pnpm yarn.js=yarn corepack.cjs=corepack
N python3|other|0|
N python3 -m|other|0|
N python3 -m spin|other|0|
L python3 -m spin|compile-native|build
L python3 -m spin|test-python|test
L python3 -m spin|lint|lint
L python3 -m|install-deps|pip pip3 ensurepip
L python3 -m|install-toolchain|pipx
L python3 -m|test-python|pytest unittest tox nox coverage
L python3 -m|lint|mypy ruff flake8 pylint black isort pyright basedpyright yamllint pre_commit semgrep checkov scancode reuse lintrunner pyspelling doc8 linkchecker
L python3 -m|publish|build twine flit cloudsmith
L python3 -m|db|alembic
L python3 -m|compile-native|meson
L python3 -m|install-system|dnf yum yum-builddep add-apt-repository apt-add-repository
L python3 -m|transfer|az gcloud gsutil
N python3 spin|other|0|
L python3 spin|compile-native|build
L python3 spin|test-python|test
L python3 spin|lint|lint
N python3 meson|other|0|
L python3 meson|compile-native|compile setup install
L python3 meson|test-native|test
N python3 poetry|other|1|
N python3 poetry run|other|0|
L python3 poetry run|test-python|pytest
L python3 poetry run|lint|mypy ruff
L python3 poetry|install-deps|install add update lock
L python3 poetry|publish|publish build
L python3 poetry|lint|check
N python3 conda|other|1|
N python3 conda env|other|0|
L python3 conda env|install-deps|create update
L python3 conda|install-deps|install create update
L python3|other|-c -
L python3|install-deps|pip pip3
L python3|test-python|pytest tox nox unittest coverage
L python3|lint|mypy flake8 pylint black isort cpplint yamllint pre-commit semgrep checkov scancode reuse lintrunner pyspelling doc8 linkchecker
L python3|test-native|lit lnt
L python3|publish|twine flit cloudsmith
L python3|db|alembic
L python3|install-system|dnf yum yum-builddep add-apt-repository apt-add-repository
L python3|transfer|az gcloud gsutil
N ruby|other|0|
N ruby bundle|other|0|
N ruby bundle exec|other|0|
L ruby bundle exec|test-other|rspec rake
L ruby bundle exec|publish|fastlane
L ruby bundle exec|lint|rubocop
L ruby bundle|install-deps|install update config add
N ruby bundler|other|0|
L ruby bundler|install-deps|install
L ruby|test-other|rspec xcpretty
L ruby|install-deps|gem pod
L ruby|lint|rubocop licensee
L ruby|publish|fastlane fpm
L ruby|install-system|brew brew.rb
L ruby|other|-e -v -ne -r
N php|other|0|
N php composer|other|0|
L php composer|install-deps|install update require remove config
L php composer|lint|validate
N php composer.phar|other|0|
L php composer.phar|install-deps|install update require
L php|test-other|phpunit pest paratest simple-phpunit
L php|lint|phpstan psalm php-cs-fixer
L php|install-deps|pear pecl
L php|other|-r -d -f -i -v
N bash|other|1|
N bash gradlew|other|1|--build-file,--project-dir,-b,-p
L bash gradlew|test-jvm|test check
L bash gradlew|compile-jvm|build assemble compileJava compileKotlin jar
L bash gradlew|publish|publish
L bash gradlew|lint|lint detekt ktlint
N bash gradlew.bat|other|1|
L bash gradlew.bat|test-jvm|test
L bash gradlew.bat|compile-jvm|build assemble
L bash gradlew.bat|publish|publish
N bash gradle|other|1|--project-dir,-p
L bash gradle|test-jvm|test check
L bash gradle|compile-jvm|build assemble compileJava jar
L bash gradle|publish|publish
L bash gradle|lint|lint
N bash mvnw|other|1|--file,-D,-P,-f,-gs,-pl,-s
L bash mvnw|test-jvm|test verify
L bash mvnw|compile-jvm|compile package install
L bash mvnw|publish|deploy
N bash mvnw.cmd|other|1|--file,-D,-P,-f,-pl
L bash mvnw.cmd|test-jvm|test verify
L bash mvnw.cmd|compile-jvm|compile package install
L bash mvnw.cmd|publish|deploy
N bash mvn|other|1|--file,-D,-P,-f,-gs,-pl,-s
L bash mvn|test-jvm|test verify
L bash mvn|compile-jvm|compile package install
L bash mvn|publish|deploy
N bash sbt|other|1|-D,-J,-java-home
L bash sbt|test-jvm|test testOnly
L bash sbt|compile-jvm|compile package
L bash sbt|publish|publish
N bash ant|other|1|
L bash ant|test-jvm|test
L bash ant|compile-jvm|jar
N bash mix|other|1|
L bash mix|test-other|test
L bash mix|compile-native|compile
L bash mix|install-deps|deps.get deps.compile
L bash mix|publish|hex.publish
N bash flutter|other|1|
L bash flutter|test-other|test
L bash flutter|compile-native|build
L bash flutter|install-deps|pub
L bash flutter|lint|analyze
N bash pyenv|other|0|
L bash pyenv|install-toolchain|install local
N bash rbenv|other|0|
L bash rbenv|install-toolchain|install
N bash asdf|other|0|
L bash asdf|install-toolchain|install plugin
N bash nvm|other|0|
L bash nvm|install-toolchain|install use
L bash|compile-native|configure otp_build erlc elixirc libtool
L bash|compile-jvm|kotlinc scalac proguard
L bash|lint|codeql sonar-scanner scan-build
L bash|install-toolchain|sdkmanager cs coursier
L bash|install-system|apt-key locale-gen service rpmdev-setuptree tzsetup brew
N perl|other|0|
L perl|compile-native|Configure configdata.pm autoreconf autoconf automake hipcc
L perl|lint|scan-build
L perl|install-deps|cpanm
L perl|test-native|abi-compliance-checker
L perl|install-system|update-alternatives dpkg-reconfigure update-rc.d
N java|other|1|--class-path,-D,-Xms,-Xmx,-classpath,-cp,-jar
N java org.gradle.wrapper.GradleWrapperMain|other|0|
L java org.gradle.wrapper.GradleWrapperMain|test-jvm|test check
L java org.gradle.wrapper.GradleWrapperMain|compile-jvm|build assemble
L java org.gradle.wrapper.GradleWrapperMain|publish|publish
N java org.gradle.launcher.GradleMain|other|0|
L java org.gradle.launcher.GradleMain|test-jvm|test check
L java org.gradle.launcher.GradleMain|compile-jvm|build assemble
L java org.gradle.launcher.GradleMain|publish|publish
N java org.apache.maven.wrapper.MavenWrapperMain|other|0|
L java org.apache.maven.wrapper.MavenWrapperMain|test-jvm|test verify
L java org.apache.maven.wrapper.MavenWrapperMain|compile-jvm|compile package install
L java org.apache.maven.wrapper.MavenWrapperMain|publish|deploy
N java org.codehaus.plexus.classworlds.launcher.Launcher|other|0|
L java org.codehaus.plexus.classworlds.launcher.Launcher|test-jvm|test verify
L java org.codehaus.plexus.classworlds.launcher.Launcher|compile-jvm|compile package install
L java org.codehaus.plexus.classworlds.launcher.Launcher|publish|deploy
L java|other|-version --version -jar
L java|compile-jvm|org.gradle.launcher.daemon.bootstrap.GradleDaemon org.jetbrains.kotlin.cli.jvm.K2JVMCompiler
L java|test-jvm|org.scalatest.tools.Runner org.junit.platform.console.ConsoleLauncher com.google.testing.junit.runner.BazelTestRunner
N dotnet|other|1|--configuration,--framework,--output,--property,--runtime,-c,-f,-o,-p,-r
N dotnet tool|other|0|
L dotnet tool|install-toolchain|install restore update
N dotnet workload|other|0|
L dotnet workload|install-toolchain|install
N dotnet nuget|other|0|
L dotnet nuget|publish|push
L dotnet nuget|install-deps|restore install
N dotnet paket|other|0|
L dotnet paket|install-deps|restore install
L dotnet|install-deps|restore
L dotnet|test-other|test vstest vstest.console testhost nunit3-console xunit.console coverlet
L dotnet|lint|dotnet-format format
L dotnet|other|--info --version
N cargo|other|1|--features,--manifest-path,--package,--target,-F,-Z,-p
L cargo|compile-rust|build check rustc
L cargo|test-native|test nextest fuzz llvm-cov tarpaulin
L cargo|lint|clippy fmt audit deny
L cargo|publish|publish
L cargo|install-toolchain|install uninstall
L cargo|install-deps|update add remove generate-lockfile vendor
N go|other|1|-C
L go|compile-native|build install
L go|test-native|test
L go|lint|vet fmt
L go|install-deps|mod work
N docker|other|1|--config,--context,--host,--log-level,-H,-c
L docker|docker-build|build buildx
L docker|container-ops|run exec compose ps images image tag save load rm stop start create cp inspect commit import export login logout
L docker|transfer|pull push
N podman|other|1|--config,--context,--host,-H,-c
L podman|docker-build|build
L podman|container-ops|run exec compose image images
L podman|transfer|pull push
N make|compile-native|1|-C,-I,-W,-f,-o
L make|test-native|test tests check
L make|lint|lint fmt format
L make|other|docs doc clean --version --help
N gmake|compile-native|1|-C,-I,-f
L gmake|test-native|test check
L gmake|lint|lint
L gmake|other|clean --version
N gh|other|1|
L gh|publish|release
N uv|other|1|--directory,--project,--python,-p
N uv pip|other|0|
L uv pip|install-deps|install sync uninstall
N uv run|other|0|
L uv run|test-python|pytest
L uv run|lint|mypy ruff
N uv tool|other|0|
L uv tool|install-toolchain|install
L uv|install-deps|sync add remove lock export
L uv|publish|build publish
N rustup|other|1|
L rustup|install-toolchain|default update component target toolchain profile override
N conda|other|1|
N conda env|other|0|
L conda env|install-deps|create update
L conda|install-deps|install create update
N poetry|other|1|
N poetry run|other|0|
L poetry run|test-python|pytest
L poetry run|lint|mypy ruff
L poetry|install-deps|install add update lock
L poetry|publish|publish build
L poetry|lint|check
N pixi|other|1|
N pixi run|other|0|
L pixi run|test-python|pytest test
L pixi|install-deps|install add update
L pixi|publish|publish
N swift|other|1|
L swift|compile-native|build
L swift|test-native|test
N xcodebuild|other|1|-arch,-configuration,-derivedDataPath,-destination,-destination-timeout,-only-testing,-project,-resultBundlePath,-scheme,-sdk,-skip-testing,-testPlan,-toolchain,-workspace,-xcconfig
L xcodebuild|test-other|test
L xcodebuild|compile-native|build archive
N xcrun|other|1|--sdk,--toolchain
L xcrun|test-other|simctl
L xcrun|compile-native|clang swiftc
L xcrun|publish|notarytool altool
L xcrun|other|--sdk --show-sdk-path
N dart|other|1|
L dart|install-deps|pub
L dart|test-other|test
L dart|lint|analyze format
L dart|compile-native|compile
N cabal|other|1|
L cabal|compile-native|build
L cabal|test-native|test
L cabal|publish|sdist
L cabal|install-toolchain|install
L cabal|install-deps|v2-update update
L cabal|other|--version --numeric-version
N spin|other|1|
L spin|compile-native|build
L spin|test-python|test
L spin|lint|lint
N vp|other|1|
N vp run|other|0|
L vp run|compile-js|build compile
L vp run|test-js|test
L vp run|lint|lint
N vp exec|other|0|
L vp exec|test-js|jest vitest
L vp exec|lint|tsc eslint prettier
N corepack|other|1|
L corepack|install-toolchain|enable prepare
N pnpm|other|1|--dir,--filter,--workspace-root,-C,-F,-w
N pnpm run|other|0|
L pnpm run|compile-js|build compile bundle dist
L pnpm run|test-js|test tests test-node test-browser-no-install smoketest-no-compile
L pnpm run|lint|lint typecheck format
L pnpm run|publish|publish
L pnpm run|install-deps|preinstall install
N pnpm exec|other|0|
L pnpm exec|test-js|jest vitest playwright cypress
L pnpm exec|lint|tsc eslint prettier
L pnpm exec|compile-js|esbuild vite webpack rollup
N pnpm dlx|other|0|
L pnpm dlx|test-js|jest vitest
L pnpm dlx|lint|tsc eslint prettier
L pnpm dlx|compile-js|esbuild vite
L pnpm|install-deps|install i add remove update up dedupe prune fetch import
L pnpm|test-js|test
L pnpm|publish|publish deploy
L pnpm|compile-js|build compile
L pnpm|lint|lint typecheck format
CI_ROUTER_PHASE_TABLE_EOF
CLKTCK=$(getconf CLK_TCK 2>/dev/null)
case "$CLKTCK" in ''|*[!0-9]*|0) CLKTCK=100 ;; esac
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
  [ -n "$current" ] || { echo "null null"; return; }
  previous=$(cat "$PROFILE_DIR/previous-cpu" 2>/dev/null)
  # "BUSY IOWAIT" in percent of the interval's CPU time (#508): iowait is the share the CPUs sat idle
  # with a request outstanding. Both null when the interval cannot be measured, never 0.
  awk -v c="$current" -v p="$previous" 'BEGIN {
    nc = split(c, cv, " "); np = split(p, pv, " ")
    if (nc != 8 || np != 8) { print "null null"; exit }
    total = 0
    for (i = 1; i <= 8; i++) {
      if (cv[i] !~ /^[0-9]+$/ || pv[i] !~ /^[0-9]+$/ || cv[i] + 0 < pv[i] + 0) { print "null null"; exit }
      d[i] = cv[i] - pv[i]; total += d[i]
    }
    if (total <= 0) { print "null null"; exit }
    v = 100 * (total - d[4] - d[5]) / total
    if (v < 0) v = 0; if (v > 100) v = 100
    w = 100 * d[5] / total
    if (w < 0) w = 0; if (w > 100) w = 100
    printf "%.1f %.1f", v, w
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
# Disk (#508): cumulative reads/writes completed, sectors read/written and milliseconds spent doing
# I/O, "RO WO RS WS MS", summed over whole-disk block devices only: sd*, vd*, xvd*, hd*, nvme*n* and
# mmcblk* (a partition would count its bytes twice; loop, ram, zram, dm, md and optical devices are not
# the VM's disk). Fields 4, 6, 8, 10 and 13 of /proc/diskstats. A row that is short or not numeric is
# skipped, so a partial file still yields what it can; "null" x5 where nothing is readable.
# Cumulative, like the network counters, so a lost or replayed sample cannot skew a delta.
disk_counters() {
  value=$(awk '
    $3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ {
      if ($4 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ && $8 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/ && $13 ~ /^[0-9]+$/) {
        ro += $4; rs += $6; wo += $8; ws += $10; ms += $13; seen = 1
      }
    }
    END { if (seen) printf "%.0f %.0f %.0f %.0f %.0f", ro, wo, rs, ws, ms }' "$PROCFS/diskstats" 2>/dev/null)
  [ -n "$value" ] || value="null null null null null"
  printf '%s' "$value"
}
# The class of what the job's processes are doing since the last sample, or "-" (none known). Always a
# word of lowercase letters and hyphens; the server keeps it only for a team that has run phases on.
profile_phase() {
  [ "$1" = true ] && [ -s "$PROFILE_DIR/phase-table" ] || { printf -- '-'; return; }
  value=$({ cat "$PROFILE_DIR/phase-prev" 2>/dev/null; echo '@@'; cat "$PROCFS"/[0-9]*/stat 2>/dev/null; } |
    awk -v TABLE="$PROFILE_DIR/phase-table" -v OUT="$PROFILE_DIR/phase-prev.new" -v P="$PROCFS" -v INTERVAL="$INTERVAL" -v CLKTCK="$CLKTCK" -f "$PROFILE_DIR/phase.awk" 2>/dev/null)
  if [ -f "$PROFILE_DIR/phase-prev.new" ]; then mv "$PROFILE_DIR/phase-prev.new" "$PROFILE_DIR/phase-prev"; fi
  case "$value" in ''|*[!a-z-]*) value=- ;; esac
  case "$value" in ??????????????????????????????????*) value=- ;; esac
  printf '%s' "$value"
}
sample_profile() {
  sequence=$(cat "$PROFILE_DIR/sequence" 2>/dev/null)
  case "$sequence" in ''|*[!0-9]*) sequence=0 ;; esac
  sequence=$((sequence + 1))
  offset=$(profile_offset_ms)
  printf '%s
' "$offset" > "$PROFILE_DIR/last-offset"
  name=$(printf 'sample.%010d' "$sequence")
  cpuio=$(profile_cpu_pct)
  # One line per sample: OFFSET CPU MEM ACTIVE RX TX IOWAIT RO WO RS WS MS PHASE
  printf '%s %s %s %s %s %s %s %s
' "$offset" "${cpuio% *}" "$(profile_mem_pct)" "$1" "$(net_bytes)" "${cpuio#* }" "$(disk_counters)" "$(profile_phase "$1")" > "$PROFILE_DIR/$name.tmp.$$"
  mv "$PROFILE_DIR/$name.tmp.$$" "$PROFILE_DIR/$name"
  # Counted only once the sample exists: a sampler killed mid-sample leaves the counter where it was, so
  # "taken" never exceeds what was written (the final sample then reuses that number).
  printf '%s
' "$sequence" > "$PROFILE_DIR/sequence"
}
sample() {
  if worker_running; then active=true; sample_cpu; else active=false; fi
  sample_profile "$active"
  sample_peaks
}

# The JSON member for a sample's class, or nothing: only lowercase letters and hyphens ever pass.
phase_field() {
  case "$1" in
    ''|-|*[!a-z-]*) ;;
    *) printf ',"phase":"%s"' "$1" ;;
  esac
}
guest_startup_field() {
  [ -f "$MARKS" ] || return 0
  marks=$(
    {
      { timeout -k 1 1 dd "if=$MARKS" iflag=nonblock,nofollow bs=257 count=1 status=none 2>/dev/null || printf '?' >&3; } |
        LC_ALL=C tr -c 'a-z0-9. \n\t' '?'
    } 3>&1 && printf .
  ) || return 0
  case "$marks" in *'?'*) return 0 ;; esac
  [ "${#marks}" -le 257 ] || return 0
  snapshot=$(printf '%s' "${marks%.}" | awk -v up0="$UP0" '
    function decimal(n) { return n ~ /^[0-9]+([.][0-9]+)?$/ }
    function milliseconds(n) { return sprintf("%.0f", n * 1000) }
    function offset(n, ms) {
      ms = milliseconds(n - up0)
      return (n + 0 < up0 + 0 || ms + 0 > 86400000) ? "null" : ms
    }
    BEGIN { listener = worker = "null" }
    NF {
      if (NF != 2 || !decimal($2) || ($1 != "up" && $1 != "start" && $1 != "end") || seen[$1]++) bad = 1
      else if ($1 == "up") listener = offset($2)
      else if ($1 == "start") worker = offset($2)
    }
    END {
      if (bad || !decimal(up0) || up0 + 0 > 10000000) exit
      if (listener != "null" && worker != "null" && listener + 0 > worker + 0) exit
      printf "%s %s %s", milliseconds(up0), listener, worker
    }') || return 0
  set -- $snapshot
  [ "$#" -eq 3 ] || return 0
  printf ',"guestStartup":{"v":1,"uptimeAtWrapperStartMs":%s,"listenerFirstSeenOffsetMs":%s,"workerFirstSeenOffsetMs":%s}' "$1" "$2" "$3"
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
      IFS=' ' read -r offset cpu memory active netrx nettx iowait dro dwo drs dws dms phase < "$file"
      printf '%s{"offsetMs":%s,"cpuPct":%s,"memPct":%s,"jobActive":%s,"netRxBytes":%s,"netTxBytes":%s,"ioWaitPct":%s,"diskReadOps":%s,"diskWriteOps":%s,"diskReadSectors":%s,"diskWriteSectors":%s,"diskBusyMs":%s%s}' "$separator" "$offset" "$cpu" "$memory" "$active" "${netrx:-null}" "${nettx:-null}" "${iowait:-null}" "${dro:-null}" "${dwo:-null}" "${drs:-null}" "${dws:-null}" "${dms:-null}" "$(phase_field "$phase")"
      separator=,
    done < "$manifest"
    printf ']'
    if [ "${1:-}" = startup ]; then guest_startup_field; fi
    printf '}'
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
    if [ "$ticks" -ge "$PROFILE_REPORT" ]; then ticks=0; post_profiles startup || true; fi
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
# OOM kills since this wrapper started, as a JSON number or null (never 0 for "unknown").
oom_delta() {
  oom_now=$(awk '/^oom_kill /{print $2}' "$PROCFS/vmstat" 2>/dev/null)
  case "$OOM0$oom_now" in ''|*[!0-9]*) echo null; return ;; esac
  if [ -n "$OOM0" ] && [ -n "$oom_now" ] && [ "$oom_now" -ge "$OOM0" ]; then
    echo $((oom_now - OOM0))
  else
    echo null
  fi
}
# Memory high-water % = 1 - min(MemAvailable)/MemTotal over the samples so far; empty when unknown.
mem_peak_pct() {
  awk '
  FNR == NR { if ($1 == "MemTotal:") t = $2; next }
  $1 ~ /^[0-9]+$/ && (m == "" || $1 + 0 < m + 0) { m = $1 }
  END { if (t + 0 > 0 && m != "") { v = 100 * (t - m) / t; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.1f", v } }
  ' "$PROCFS/meminfo" "$MEM" 2>/dev/null
}
mem_total_mb() { awk '/^MemTotal:/{printf "%d", $2 / 1024}' "$PROCFS/meminfo" 2>/dev/null; }

( while :; do sample; sleep "$INTERVAL"; done ) >/dev/null 2>&1 &
SAMPLER=$!

# Phase marks (#215), for the router's overhead report: seconds since this wrapper started, from the
# VM's own monotonic /proc/uptime (no clock agreement with the router needed). UP0 is the uptime now,
# so it is also how long the kernel has been up (null where /proc/uptime is unreadable or not the
# VM's). A watcher notes when the runner listener appears (the JIT config is applied as it starts),
# when the job's Runner.Worker appears, and when it is gone again. It only reads.
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

# Host-speed probes (#508, #506): a small-file filesystem probe and a fixed single-core CPU loop, run ONCE
# before the runner starts, and ONLY when the boot environment says so (CIROUTER_HOST_PROBES=1, set by the
# router for its internal benchmark and pilot runs, never for a customer job: VM time is billed). The
# runner has not started, so nothing competes with them. They are capped at 5 s of wall time by
# `timeout` (and by their own soft deadlines), never fail or delay the boot beyond that, and always remove
# their directory. A probe that fails, times out or cannot be timed reports null for its fields, never 0.
# The numbers are JOB-REPORTED and shown for comparison only; they feed no billing, placement or authorization.
HOSTPROBES=null
HP_OUT=
if [ "$HOST_PROBES" = 1 ]; then
  HP_DIR="$PWD/.ci-router-fsprobe"
  HP_SEC=${CI_ROUTER_HOSTPROBE_SEC:-5}
  case "$HP_SEC" in [1-5]) ;; *) HP_SEC=5 ;; esac
  HP_SCRIPT='FILES=${HP_FILES:-2000}
case "$FILES" in '\'''\''|*[!0-9]*|0) FILES=2000 ;; esac
[ "$FILES" -le 5000 ] || FILES=5000
B=${HP_DIR:-$PWD/.ci-router-fsprobe}
CHUNK=${HP_CHUNK:-3000000}
case "$CHUNK" in '\'''\''|*[!0-9]*|0) CHUNK=3000000 ;; esac
ns() {
  t=$(date +%s%N 2>/dev/null) || return 1
  case "$t" in '\'''\''|*[!0-9]*) return 1 ;; esac
  [ "${#t}" -ge 16 ] || return 1
  printf '\''%s'\'' "$t"
}
rate() { awk -v k="$1" -v n="$2" -v d="$3" '\''BEGIN { if (d > 0 && n > 0) print k " " sprintf("%.0f", n * 1e9 / d) }'\''; }
T0=$(ns) || exit 0
c=0; S=$T0
while [ "$c" -lt 10 ]; do
  awk -v n="$CHUNK" '\''BEGIN { x = 1; for (i = 0; i < n; i++) x = (x * 69069 + 1) % 4294967296; if (x < 0) exit 1 }'\'' || break
  c=$((c + 1))
  E=$(ns) || break
  [ $((E - S)) -lt 2000000000 ] || break
done
E=$(ns) || exit 0
if [ "$c" -gt 0 ] && [ "$E" -gt "$S" ]; then
  rate cpuScore $((c * CHUNK)) $((E - S))
  echo "cpuProbeMs $(( (E - S) / 1000000 ))"
fi
rm -rf "$B" 2>/dev/null
mkdir "$B" 2>/dev/null && mkdir "$B/a" "$B/b" 2>/dev/null || { rm -rf "$B" 2>/dev/null; exit 0; }
F0=$(ns) || { rm -rf "$B" 2>/dev/null; exit 0; }
i=0
while [ "$i" -lt "$FILES" ]; do
  true > "$B/a/f$i" || break
  i=$((i + 1))
  if [ $((i % 500)) -eq 0 ]; then N=$(ns) || break; [ $((N - F0)) -lt 3000000000 ] || break; fi
done
Z=$(ns) || Z=
if [ "$i" -eq "$FILES" ] && [ -n "$Z" ]; then
  echo "fsFiles $FILES"
  rate fsCreateOpsPerSec "$FILES" $((Z - F0))
  set -- "$B"/a/f*
  A=$(ns); miss=0; p=0
  while [ "$p" -lt 5 ]; do for f; do [ -e "$f" ] || miss=1; done; p=$((p + 1)); done
  Z=$(ns) || Z=
  if [ "$miss" -eq 0 ] && [ -n "$Z" ] && [ -n "$A" ]; then rate fsStatOpsPerSec $((FILES * 5)) $((Z - A)); fi
  A=$(ns)
  set -- "$@" "$B/b"
  if ln -- "$@" 2>/dev/null; then
    Z=$(ns) || Z=
    if [ -n "$Z" ] && [ -n "$A" ]; then rate fsLinkOpsPerSec "$FILES" $((Z - A)); fi
  fi
fi
rm -rf "$B" 2>/dev/null
Z=$(ns) && echo "fsProbeMs $(( (Z - F0) / 1000000 ))"
exit 0
'
  if command -v timeout >/dev/null 2>&1; then
    HP_OUT=$(HP_DIR=$HP_DIR HP_FILES=${CI_ROUTER_HOSTPROBE_FILES:-} HP_CHUNK=${CI_ROUTER_HOSTPROBE_CHUNK:-} timeout "$HP_SEC" sh -c "$HP_SCRIPT" </dev/null 2>/dev/null) || true
  else
    HP_OUT=$( (HP_DIR=$HP_DIR; HP_FILES=${CI_ROUTER_HOSTPROBE_FILES:-}; HP_CHUNK=${CI_ROUTER_HOSTPROBE_CHUNK:-}; eval "$HP_SCRIPT") </dev/null 2>/dev/null ) || true
  fi
  rm -rf "$HP_DIR" 2>/dev/null || true
fi
# The boot host probe (#637 step 1): fsync latency and a CPU burst with steal, on EVERY job and every
# provider, started just before the runner. Data collection only: nothing places, replaces or bills on it.
# It never stops or delays a job: the runner starts beside it (waiting for it first delayed every registration
# by about 2 s, SYL-304), so it shares the VM with the listener's start-up and its network-bound session wait.
# It runs DETACHED in the background, writing to a file under $TMPD, and finishes by creating a done marker. After
# the runner has started, the wrapper polls for that marker, at most 5 s from the probe's start, with plain shell (no `timeout`, which may be missing, and no signal the probe could
# ignore) and then goes on. A probe still running at the cap (a `sync` stuck in uninterruptible I/O included) is
# abandoned: never waited on, never reaped, its result dropped even if it arrives later; it gets a best-effort
# KILL and its directory is removed in the background. It runs on the real /proc only: a test that points
# CI_ROUTER_PROC at a fixture gets no probe unless it sets CI_ROUTER_BOOTPROBE=1 (and 0 turns it off). Its lines
# keep to the boot-prefixed, fsync and steal fields: they never fill the benchmark probe's fields.
BP_ON=${CI_ROUTER_BOOTPROBE:-}
if [ -z "$BP_ON" ]; then if [ -z "${CI_ROUTER_PROC:-}" ]; then BP_ON=1; else BP_ON=0; fi; fi
BP_OUT=
if [ "$BP_ON" = 1 ]; then
  BP_DIR="$PWD/.ci-router-bootprobe"
  # A private mode-0700 directory for the result and done marker: never a fixed name in a shared /tmp.
  BP_TMP=$(umask 077; mktemp -d "$TMPD/ci-router-bootprobe.XXXXXX" 2>/dev/null) || BP_TMP=
  [ -n "$BP_TMP" ] && [ -d "$BP_TMP" ] || BP_ON=0
fi
if [ "$BP_ON" = 1 ]; then
  BP_RES="$BP_TMP/out"
  BP_DONE="$BP_TMP/done"
  BP_SEC=${CI_ROUTER_BOOTPROBE_SEC:-5}
  case "$BP_SEC" in [1-5]) ;; *) BP_SEC=5 ;; esac
  BP_SCRIPT='FSYNCS=${BP_FSYNCS:-50}
case "$FSYNCS" in '\'''\''|*[!0-9]*|0) FSYNCS=50 ;; esac
[ "$FSYNCS" -le 100 ] || FSYNCS=100
BURST=${BP_BURST_MS:-1500}
case "$BURST" in '\'''\''|*[!0-9]*|0) BURST=1500 ;; esac
[ "$BURST" -le 3000 ] || BURST=3000
CHUNK=${BP_CHUNK:-3000000}
case "$CHUNK" in '\'''\''|*[!0-9]*|0) CHUNK=3000000 ;; esac
PROC=${BP_PROC:-/proc}
B=${BP_DIR:-$PWD/.ci-router-bootprobe}
ns() {
  t=$(date +%s%N 2>/dev/null) || return 1
  case "$t" in '\'''\''|*[!0-9]*) return 1 ;; esac
  [ "${#t}" -ge 16 ] || return 1
  printf '\''%s'\'' "$t"
}
rm -rf "$B" 2>/dev/null
mkdir "$B" 2>/dev/null || exit 0
trap '\''rm -rf "$B" 2>/dev/null'\'' EXIT
# --- fsync latency ---
F0=$(ns) || F0=
if [ -n "$F0" ] && : > "$B/clean" 2>/dev/null && sync "$B/clean" 2>/dev/null; then
  BLK=$(awk '\''BEGIN { s = "x"; for (i = 0; i < 10; i++) s = s s; printf "%s", s }'\'')
  # The timing overhead: the same two clock reads and a sync of a file with nothing dirty.
  : > "$B/base"
  i=0
  while [ "$i" -lt 7 ]; do
    a=$(ns) || break
    sync "$B/clean" 2>/dev/null
    z=$(ns) || break
    echo $((z - a)) >> "$B/base"
    i=$((i + 1))
  done
  OVER=$(sort -n "$B/base" 2>/dev/null | awk '\''{ v[NR] = $1 } END { if (NR > 0) print v[int((NR + 1) / 2)]; else print 0 }'\'')
  case "$OVER" in '\'''\''|*[!0-9]*) OVER=0 ;; esac
  : > "$B/f"
  : > "$B/lat"
  n=0
  while [ "$n" -lt "$FSYNCS" ]; do
    a=$(ns) || break
    printf '\''%s'\'' "$BLK" >> "$B/f" 2>/dev/null || break
    sync "$B/f" 2>/dev/null || break
    z=$(ns) || break
    d=$(( (z - a - OVER) / 1000 ))
    [ "$d" -ge 0 ] || d=0
    echo "$d" >> "$B/lat"
    n=$((n + 1))
    [ $(( (z - F0) / 1000000 )) -lt 1500 ] || break
  done
  Z=$(ns) || Z=
  if [ "$n" -gt 0 ] && [ -n "$Z" ]; then
    sort -n "$B/lat" | awk '\''{ v[NR] = $1; s += $1 }
      END { if (NR == 0) exit
        k = int(NR * 0.95); if (k < NR * 0.95) k++; if (k < 1) k = 1
        printf "fsyncMeanUs %.0f\nfsyncP95Us %d\nfsyncSamples %d\n", s / NR, v[k], NR }'\''
    echo "bootFsProbeMs $(( (Z - F0) / 1000000 ))"
  fi
fi
# --- CPU burst and steal ---
cpu_line() { awk '\''NR == 1 && $1 == "cpu" { print $2, $3, $4, $5, $6, $7, $8, $9; exit }'\'' "$PROC/stat" 2>/dev/null; }
W=$(grep -c '\''^processor'\'' "$PROC/cpuinfo" 2>/dev/null) || W=
case "$W" in '\'''\''|*[!0-9]*|0) W=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || W=1 ;; esac
case "$W" in '\'''\''|*[!0-9]*|0) W=1 ;; esac
[ "$W" -le 16 ] || W=16
S0=$(cpu_line)
T0=$(ns) || T0=
if [ -n "$S0" ] && [ -n "$T0" ]; then
  LIMIT=$((BURST * 1000000))
  w=0
  while [ "$w" -lt "$W" ]; do
    (
      c=0; S=$(ns) || exit 0
      while :; do
        awk -v n="$CHUNK" '\''BEGIN { x = 1; for (i = 0; i < n; i++) x = (x * 69069 + 1) % 4294967296; if (x < 0) exit 1 }'\'' || exit 0
        c=$((c + 1))
        E=$(ns) || exit 0
        [ $((E - S)) -lt "$LIMIT" ] || break
      done
      echo "$c $((E - S))" > "$B/w$w"
    ) >/dev/null 2>&1 &
    w=$((w + 1))
  done
  wait
  T1=$(ns) || T1=
  S1=$(cpu_line)
  if [ -n "$T1" ] && [ -n "$S1" ]; then
    echo "$S0 $S1" | awk '\''{ t0 = 0; t1 = 0; for (i = 1; i <= 8; i++) { t0 += $i; t1 += $(i + 8) }
      dt = t1 - t0; if (dt > 0) printf "cpuStealPct %.2f\n", ($16 - $8) * 100 / dt }'\''
    cat "$B"/w[0-9]* 2>/dev/null | awk -v chunk="$CHUNK" -v want="$W" '\''
      NF == 2 && $1 > 0 && $2 > 0 { r += $1 * chunk * 1e9 / $2; n++ }
      END { if (n == want && n > 0) printf "bootCpuScore %.0f\n", r / n }'\''
    echo "bootCpuProbeMs $(( (T1 - T0) / 1000000 ))"
  fi
fi
exit 0
'
  BP_PROC=$PROCFS; BP_FSYNCS=${CI_ROUTER_BOOTPROBE_FSYNCS:-}
  BP_BURST_MS=${CI_ROUTER_BOOTPROBE_BURST_MS:-}; BP_CHUNK=${CI_ROUTER_BOOTPROBE_CHUNK:-}
  export BP_DIR BP_PROC BP_FSYNCS BP_BURST_MS BP_CHUNK BP_SCRIPT BP_DONE
  # Its own session and process group (setsid, where present), so an abandoned probe is killed with all
  # of its descendants (sync, the CPU workers), not only its top shell.
  BP_RUN='sh -c "$BP_SCRIPT" || true; : > "$BP_DONE"'
  BP_GRP=
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "$BP_RUN" </dev/null >"$BP_RES" 2>/dev/null &
    BP_GRP=1
  else
    sh -c "$BP_RUN" </dev/null >"$BP_RES" 2>/dev/null &
  fi
  BP_PID=$!
  unset BP_SCRIPT BP_RUN
  BP_T0=$(date +%s 2>/dev/null) || BP_T0=
  case "$BP_T0" in ''|*[!0-9]*) BP_T0= ;; esac
fi
# Root-mode boot needs this flag; nonroot Luxor handoff does not depend on it.
export RUNNER_ALLOW_RUNASROOT=1
# Its own session and process group (setsid), so a stop reaches the listener, the worker and the job's
# steps together, not just the shell run.sh started. The runner and the job's steps get GitHub's umask 022
# (the boot runs under 077 to keep its secrets private): a step's files get the modes it asked for, as on a
# GitHub-hosted runner. Only that subshell, which exec's the runner so $! stays its pid: the wrapper's own
# later files keep 077.
# The job's steps also get the default handling of HUP, INT and QUIT, as on a GitHub-hosted runner. A
# background job of this non-interactive shell starts with INT and QUIT ignored, a provider's boot may
# start this wrapper with HUP ignored, and a signal ignored at exec stays ignored in every step, where
# bash cannot even trap it (a step's own cleanup on SIGINT or SIGHUP never ran). env --default-signal
# (coreutils 8.31+) resets them right before run.sh; without it the runner starts as before. Only with
# setsid: without its own session the runner would share the boot's, whose disconnect HUP would then end it.
DEFSIG=
if env --default-signal=HUP,INT,QUIT true 2>/dev/null; then DEFSIG='env --default-signal=HUP,INT,QUIT'; fi
if command -v setsid >/dev/null 2>&1; then (umask 022; exec setsid $DEFSIG ./run.sh --jitconfig "$JIT") & else (umask 022; exec ./run.sh --jitconfig "$JIT") & fi
RUNNER=$!
# The boot probe has run beside the listener since it started; collect it now (it waits at most the cap
# from the probe start, so in practice only for what is left of it) for the telemetry post.
if [ "$BP_ON" = 1 ]; then
  BP_N=0
  BP_MAX=$((BP_SEC * 10))
  while [ ! -e "$BP_DONE" ]; do
    BP_N=$((BP_N + 1))
    [ "$BP_N" -le "$BP_MAX" ] || break
    if [ -n "$BP_T0" ]; then
      BP_T1=$(date +%s 2>/dev/null) || BP_T1=
      case "$BP_T1" in ''|*[!0-9]*) ;; *) [ $((BP_T1 - BP_T0)) -lt "$BP_SEC" ] || break ;; esac
    fi
    sleep 0.1 2>/dev/null || true
  done
  if [ -e "$BP_DONE" ]; then
    BP_OUT=$(head -c 4096 "$BP_RES" 2>/dev/null) || BP_OUT=
    rm -rf "$BP_DIR" "$BP_TMP" 2>/dev/null || true
  else
    # Abandoned: best-effort KILL of its whole process group (a process in D state ignores it), then remove
    # its files without waiting. The done marker is checked again first: a probe that just finished may have
    # been reaped, and its pid reused by something else.
    (
      if [ ! -e "$BP_DONE" ]; then
        if [ -n "$BP_GRP" ]; then kill -KILL "-$BP_PID" 2>/dev/null; fi
        pkill -KILL -P "$BP_PID" 2>/dev/null; kill -KILL "$BP_PID" 2>/dev/null
      fi
      rm -rf "$BP_DIR" "$BP_TMP" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
  fi
fi
if [ -n "$BP_OUT$HP_OUT" ]; then
  # Only the known names with plain non-negative numbers are kept; anything else is dropped.
  HOSTPROBES=$(printf '%s\n%s\n' "$BP_OUT" "$HP_OUT" | awk '
    NF == 2 && $2 ~ /^[0-9]+(\.[0-9]+)?$/ && length($2) <= 15 { m[$1] = $2 }
    function v(k) { return (k in m) ? m[k] : "null" }
    END {
      if (!(("cpuScore" in m) || ("fsCreateOpsPerSec" in m) || ("fsStatOpsPerSec" in m) || ("fsLinkOpsPerSec" in m) || ("bootCpuScore" in m) || ("fsyncMeanUs" in m) || ("cpuStealPct" in m))) { print "null"; exit }
      printf "{\"cpuScore\": %s, \"cpuProbeMs\": %s, \"fsFiles\": %s, \"fsCreateOpsPerSec\": %s, \"fsStatOpsPerSec\": %s, \"fsLinkOpsPerSec\": %s, \"fsProbeMs\": %s, \"fsyncMeanUs\": %s, \"fsyncP95Us\": %s, \"fsyncSamples\": %s, \"cpuStealPct\": %s, \"bootCpuScore\": %s, \"bootCpuProbeMs\": %s, \"bootFsProbeMs\": %s}\n", v("cpuScore"), v("cpuProbeMs"), v("fsFiles"), v("fsCreateOpsPerSec"), v("fsStatOpsPerSec"), v("fsLinkOpsPerSec"), v("fsProbeMs"), v("fsyncMeanUs"), v("fsyncP95Us"), v("fsyncSamples"), v("cpuStealPct"), v("bootCpuScore"), v("bootCpuProbeMs"), v("bootFsProbeMs")
    }' 2>/dev/null)
  case "$HOSTPROBES" in "{"*"}") ;; *) HOSTPROBES=null ;; esac
fi

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

# Shutdown report (#448). When the guest stops under a running job (SIGTERM/SIGINT/SIGHUP to this
# wrapper, or a system shutdown that signals it), send ONE final best-effort message so a provider-side
# VM loss leaves evidence, then die the way the signal would have killed us anyway. It is bounded (at most
# about 4 s: a 1 s systemctl probe and a 3 s curl), every failure is swallowed, and it never starts the normal
# exit path: the cap watcher above stays the poweroff backstop, exactly as without the trap.
# The body is enums and numbers read from /proc only: no env, no command line, no JIT config and no id (the
# run is in the URL). The router treats it as observation, never as completion or a charge.
shutdown_report() {
  sig=$1
  trap '' TERM INT HUP
  src=unknown
  case "$sig" in TERM) src=SIGTERM ;; INT) src=SIGINT ;; HUP) src=SIGHUP ;; esac
  if command -v systemctl >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      sd_jobs=$(timeout 1 systemctl list-jobs --no-legend </dev/null 2>/dev/null) || sd_jobs=
    else
      sd_jobs=$(systemctl list-jobs --no-legend </dev/null 2>/dev/null) || sd_jobs=
    fi
    case "$sd_jobs" in
      *shutdown.target*|*poweroff.target*|*halt.target*|*reboot.target*|*kexec.target*) src=systemd_shutdown ;;
    esac
  fi
  sd_up=$(awk -v a="$UP0" -v b="$(uptime_now)" 'BEGIN { if (a ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/ && b + 0 >= a + 0) printf "%.2f", b - a }' 2>/dev/null)
  sd_body=$(printf '{"kind":"shutdown","reason":"shutdown","source":"%s","uptimeSec":%s,"memPct":%s,"memPeakPct":%s,"memTotalMb":%s,"oomKills":%s}' \
    "$src" "$(num "$sd_up")" "$(profile_mem_pct)" "$(num "$(mem_peak_pct)")" "$(num "$(mem_total_mb)")" "$(oom_delta)")
  curl -fsS -m 3 --connect-timeout 2 -X POST "$CIROUTER_TELEMETRY_URL" \
    -H "Authorization: Bearer $TELEMETRY_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$sd_body" >/dev/null 2>&1 || true
  trap - TERM INT HUP
  kill -s "$sig" "$$"
}
trap 'shutdown_report TERM' TERM
trap 'shutdown_report INT' INT
trap 'shutdown_report HUP' HUP
wait "$RUNNER"
RC=$?
# From here the runner is gone and the normal exit path posts the final telemetry itself.
trap - TERM INT HUP
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
# Why the runner was stopped early, for the profile's coverage note (#509): only the two reasons the
# watcher writes are reported, and "cap" only when the check above confirmed it (RC rewritten).
PROFSTOP=null
case "$(cat "$LIMIT_FILE" 2>/dev/null)" in
  idle) PROFSTOP='"idle"' ;;
  cap) [ "$RC" -eq 124 ] && PROFSTOP='"cap"' ;;
esac
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

OOMKILLS=$(oom_delta)

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

# Memory high-water % and total; null when unknown.
MEMP=$(num "$(mem_peak_pct)")
MEMTOTAL=$(num "$(mem_total_mb)")
# Peak root filesystem use % over the run.
DISKP=$(num "$(awk '$1 ~ /^[0-9]+$/ && $1 + 0 <= 100 && (m == "" || $1 + 0 > m + 0) { m = $1 } END { if (m != "") print m }' "$DISK" 2>/dev/null)")
VCPUS=$(num "$(awk '/^cpu[0-9]+ /{n++} END { if (n > 0) print n }' "$PROCFS/stat" 2>/dev/null)")

# Guest-visible CPU (#506) and normalized machine architecture (#544). These are observations reported
# by the guest, not physical-host identity or workflow intent, and never feed routing or billing. CPU
# details stay null when unreadable; architecture can be reported independently. Only the two uname
# values this bootstrap supports are mapped; unknown or failed commands stay null.
# CPU model, family, model id, stepping and hypervisor flag are job-reported. The missing/unknown model
# can use a CPUID brand or literal vendor/family/model descriptor, never an inferred physical SKU. The
# name is reduced to a safe character set, keeping the printf'd JSON below valid.
HOSTCPU=null
HOST_ARCH=$(uname -m 2>/dev/null) || HOST_ARCH=
case "$HOST_ARCH" in
  x86_64) HOST_ARCH='"x64"' ;;
  aarch64) HOST_ARCH='"arm64"' ;;
  *) HOST_ARCH=null ;;
esac
CPUINFO=; CPU_NAME=; CPU_DESCRIPTOR=
CPU_FAM=null; CPU_MOD=null; CPU_STEP=null; CPU_HV=null
if [ -r "$PROCFS/cpuinfo" ]; then
  CPUINFO=$(awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function small(v) { return (v ~ /^[0-9]+$/ && length(v) <= 6 && v + 0 <= 100000) ? v + 0 : "null" }
    /^[[:space:]]*$/ { if (seen) exit; next }
    {
      i = index($0, ":"); if (i == 0) next
      k = trim(substr($0, 1, i - 1)); v = trim(substr($0, i + 1)); seen = 1
      if (k == "model name") name = v
      else if (k == "vendor_id") vendor = v
      else if (k == "cpu family") fam = v
      else if (k == "model") mod = v
      else if (k == "stepping") step = v
      else if (k == "flags") hv = ((" " v " ") ~ / hypervisor /) ? "true" : "false"
    }
    END {
      fam = small(fam); mod = small(mod); step = small(step)
      if (tolower(name) == "unknown") name = ""
      if (name == "" && vendor ~ /^[A-Za-z0-9_-]+$/ && length(vendor) <= 12 && tolower(vendor) != "unknown" && fam != "null" && mod != "null")
        descriptor = "x86 " vendor " family " fam " model " mod
      if (seen) printf "%s %s %s %s\n%s\n%s\n", fam, mod, step, (hv == "" ? "null" : hv), name, descriptor
    }' "$PROCFS/cpuinfo" 2>/dev/null)
  if [ -n "$CPUINFO" ]; then
    set -- $(printf '%s
' "$CPUINFO" | sed -n 1p)
    CPU_FAM=${1:-null}; CPU_MOD=${2:-null}; CPU_STEP=${3:-null}; CPU_HV=${4:-null}
    CPU_NAME=$(printf '%s
' "$CPUINFO" | sed -n 2p | LC_ALL=C tr -cd 'A-Za-z0-9 ().@_/+,:-' | cut -c1-128)
    CPU_DESCRIPTOR=$(printf '%s
' "$CPUINFO" | sed -n 3p | LC_ALL=C tr -cd 'A-Za-z0-9 ().@_/+,:-' | cut -c1-128)
  fi
fi
# Samples this wrapper took (the sequence counter), so the server can tell how many it never received.
PROFTAKEN=$(num "$(cat "$PROFILE_DIR/sequence" 2>/dev/null)")

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

# Guest-visible CPUID brand when /proc hides it. One watchdog budget covers compilation and execution;
# a missing tool, timeout or invalid result leaves the literal descriptor. This runs after duration
# capture, never changes the job's exit status, and adds only reporting/teardown work, not a calibration.
if [ -z "$CPU_NAME" ] && command -v cc >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  CPU_DIR=$(umask 077; mktemp -d "$TMPD/ci-router-cpu.XXXXXX" 2>/dev/null) || CPU_DIR=
  if [ -n "$CPU_DIR" ]; then
    cat > "$CPU_DIR/brand.c" <<'CI_ROUTER_CPU_BRAND_EOF'
#include <stdio.h>
#include <string.h>
#if defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#endif

int main(void) {
  char brand[49] = {0};
#if defined(__x86_64__) || defined(__i386__)
  if (__get_cpuid_max(0x80000000, NULL) >= 0x80000004) {
    for (unsigned int leaf = 0; leaf < 3; leaf++) {
      unsigned int a, b, c, d;
      __cpuid(0x80000002 + leaf, a, b, c, d);
      memcpy(brand + leaf * 16, &a, 4);
      memcpy(brand + leaf * 16 + 4, &b, 4);
      memcpy(brand + leaf * 16 + 8, &c, 4);
      memcpy(brand + leaf * 16 + 12, &d, 4);
    }
  }
#endif
  fputs(brand, stdout);
  return ferror(stdout) ? 1 : 0;
}
CI_ROUTER_CPU_BRAND_EOF
    CPU_BRAND=$(timeout -s KILL 1 sh -c '[ "$(uname -m 2>/dev/null)" = x86_64 ] && cc -std=c11 -O0 "$1/brand.c" -o "$1/brand" >/dev/null 2>&1 && "$1/brand"' sh "$CPU_DIR" 2>/dev/null) || CPU_BRAND=
    rm -rf "$CPU_DIR" 2>/dev/null || true
    CPU_NAME=$(printf '%s' "$CPU_BRAND" | LC_ALL=C tr -cd 'A-Za-z0-9 ().@_/+,:-' | cut -c1-128 | sed 's/^ *//;s/ *$//')
    if [ "$(printf '%s' "$CPU_NAME" | LC_ALL=C tr 'A-Z' 'a-z')" = unknown ]; then CPU_NAME=; fi
  fi
fi
if [ -z "$CPU_NAME" ]; then CPU_NAME=$CPU_DESCRIPTOR; fi
if [ -n "$CPUINFO" ] || [ -n "$CPU_NAME" ] || [ "$HOST_ARCH" != null ]; then
  if [ -n "$CPU_NAME" ]; then CPU_NAME_JSON=$(printf '"%s"' "$CPU_NAME"); else CPU_NAME_JSON=null; fi
  HOSTCPU=$(printf '{"model": %s, "family": %s, "modelId": %s, "stepping": %s, "hypervisor": %s, "arch": %s}' "$CPU_NAME_JSON" "$CPU_FAM" "$CPU_MOD" "$CPU_STEP" "$CPU_HV" "$HOST_ARCH")
fi

# Post-job RTT probe (#489): TLS connect, TLS handshake and first byte to GitHub's results receiver and
# to the route's object-store host. No auth, no cookies, no body. The probe script runs in its own
# process under timeout 5 when the VM has it (a hard 5 s cap whatever a curl does), else in a
# subshell where each curl is capped at 2 s by its own flags (at most two run). Any error leaves
# PROBE_JSON null; nothing here can change the exit path, skip the telemetry POST or the poweroff.
# Timings are curl's, in ms; a failed or timed-out curl reports nothing for its host.
PROBE_JSON=null
PROBE_SCRIPT='  probe_one() {
    # $1 = JSON key, $2 = host. Prints "key": {...} or nothing.
    t=$(curl -sS -o /dev/null -m 2 --connect-timeout 2 -w '\''%{time_connect} %{time_appconnect} %{time_starttransfer}'\'' "https://$2/" 2>/dev/null) || return 0
    printf '\''%s
'\'' "$t" | awk -v k="$1" '\''NF == 3 && $1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ && $2 > 0 && $3 > 0 {
      printf "\"%s\": {\"connectMs\": %.0f, \"tlsMs\": %.0f, \"firstByteMs\": %.0f}", k, $1 * 1000, ($2 - $1) * 1000, ($3 - $2) * 1000 }'\''
  }
  a=$(probe_one github results-receiver.actions.githubusercontent.com)
  b=
  if [ -n "$PROBE_HOST" ]; then b=$(probe_one r2 "$PROBE_HOST"); fi
  j=
  for r in "$a" "$b"; do
    [ -n "$r" ] || continue
    if [ -n "$j" ]; then j="$j, $r"; else j=$r; fi
  done
  [ -n "$j" ] && printf '\''{%s}'\'' "$j"
'
PROBE_OUT=
if command -v timeout >/dev/null 2>&1; then
  PROBE_OUT=$(PROBE_HOST=$PROBE_HOST timeout 5 sh -c "$PROBE_SCRIPT" </dev/null 2>/dev/null) || PROBE_OUT=
else
  PROBE_OUT=$( (PROBE_HOST=$PROBE_HOST; eval "$PROBE_SCRIPT") </dev/null 2>/dev/null ) || PROBE_OUT=
fi
case "$PROBE_OUT" in "{"*"}") PROBE_JSON=$PROBE_OUT ;; esac

BODY=$(printf '{"durationSec": %s, "cpuStealPct": %s, "memPeakPct": %s, "cpuAvgPct": %s, "cpuSatPct": %s, "cpuIowaitPct": %s, "diskPeakPct": %s, "oomKills": %s, "samples": %s, "exitCode": %s, "vcpus": %s, "memTotalMb": %s, "status": "%s", "vmUptimeAtStartSec": %s, "runnerUpSec": %s, "jobStartSec": %s, "jobEndSec": %s, "poweroffSec": %s, "netTxBytes": %s, "netRxBytes": %s, "testedSha": %s, "testedRef": %s, "probe": %s, "hostCpu": %s, "hostProbes": %s, "profileSamplesTaken": %s, "profileStop": %s}' \
  "$DURATION" "$STEAL" "$MEMP" "$CPUAVG" "$CPUSAT" "$CPUIOW" "$DISKP" "$OOMKILLS" "$SAMPLES" "$RC" "$VCPUS" "$MEMTOTAL" "$STATUS" "$UPSTART" "$RUNNERUP" "$JOBSTART" "$JOBEND" "$POWEROFFSEC" "$NETTX" "$NETRX" "$TESTED_SHA" "$TESTED_REF" "$PROBE_JSON" "$HOSTCPU" "$HOSTPROBES" "$PROFTAKEN" "$PROFSTOP")

curl -fsS -m 10 -X POST "$CIROUTER_TELEMETRY_URL" \
  -H "Authorization: Bearer $TELEMETRY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$BODY" \
  || true

poweroff -f
