#!/bin/bash
# ci-router prebaked runner image (docs/prebaked-images.md). Nothing here varies per run.
set -euo pipefail
export HOME="${HOME:-/root}"
export DEBIAN_FRONTEND=noninteractive
# This bake is for amd64: a bake on another architecture would pin the wrong binaries.
if [ "$(uname -m)" != "x86_64" ]; then echo "bake: built for x86_64, this machine is $(uname -m)" >&2; exit 1; fi
export NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=a
quiet() {
  local out rc=0
  out=$(mktemp)
  "$@" >"$out" </dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    echo "bake: '$*' failed with exit $rc; its output ends:" >&2
    tail -n 60 "$out" >&2 || true
    echo "bake: held packages: $(apt-mark showhold 2>/dev/null | tr '\n' ' ')" >&2
    dpkg --audit >&2 || true
  fi
  rm -f "$out"
  return "$rc"
}
apt_install() { quiet apt-get install -y -qq "$@"; }
apt-get update -qq
apt_install --no-install-recommends curl ca-certificates xz-utils build-essential chrony
# Node 22.23.5 from nodejs.org, pinned with its published sha256.
NODE_DIR=$(mktemp -d)
curl -fsSL -o "$NODE_DIR/node-v22.23.5-linux-x64.tar.xz" https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-x64.tar.xz
echo "cdeb8670a0c81f51b4dc4ac61919f9b1ad917b304bf8221eb939570663d240f8  $NODE_DIR/node-v22.23.5-linux-x64.tar.xz" | sha256sum -c -
tar xJf "$NODE_DIR/node-v22.23.5-linux-x64.tar.xz" -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE
rm -rf "$NODE_DIR"
node --version >/dev/null
if ! (
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 || exit 1
  ci_router_localhost_configure() {
    'node' - /etc/nsswitch.conf "$@" <<'CI_ROUTER_LOCALHOST_CONFIG_EOF' >/dev/null 2>&1

const fs = require('node:fs');
const { randomUUID } = require('node:crypto');
const path = fs.realpathSync(process.argv[2]);
const stat = fs.statSync(path);
const original = fs.readFileSync(path, 'utf8');
let count = 0;
const updated = original.replace(/^([ \t]*hosts[ \t]*:)([^\n]*)$/gm, (_line, prefix, rest) => {
  count++;
  const commentAt = rest.indexOf('#');
  const comment = commentAt < 0 ? '' : rest.slice(commentAt);
  let policy = (commentAt < 0 ? rest : rest.slice(0, commentAt)).trim();
  const groups = [];
  while (policy) {
    const service = /^([a-zA-Z0-9_-]+)(?=\s|$)/.exec(policy);
    if (!service) throw new Error('unsupported hosts policy');
    policy = policy.slice(service[0].length).trimStart();
    const actions = [];
    while (policy.startsWith('[')) {
      const action = /^\[[^\[\]]+\](?=\s|$)/.exec(policy);
      if (!action) throw new Error('unsupported hosts action');
      actions.push(action[0]);
      policy = policy.slice(action[0].length).trimStart();
    }
    if (service[1] === 'myhostname') {
      if (actions.length) throw new Error('custom myhostname actions');
    } else groups.push({ service: service[1], actions });
  }
  const files = groups.findIndex((group) => group.service === 'files');
  if (files > 0 || groups.filter((group) => group.service === 'files').length > 1)
    throw new Error('unsupported files ordering');
  if (files === 0) {
    const outcomes = { SUCCESS: 'return', NOTFOUND: 'continue', UNAVAIL: 'continue', TRYAGAIN: 'continue' };
    for (const block of groups[0].actions) {
      for (const rule of block.slice(1, -1).trim().split(/\s+/)) {
        const match = /^(!?)(SUCCESS|NOTFOUND|UNAVAIL|TRYAGAIN)=(return|continue|merge)$/i.exec(rule);
        if (!match) throw new Error('unsupported files action');
        for (const status of Object.keys(outcomes)) {
          if ((status === match[2].toUpperCase()) !== Boolean(match[1])) outcomes[status] = match[3].toLowerCase();
        }
      }
    }
    if (outcomes.SUCCESS !== 'return' || outcomes.NOTFOUND !== 'continue')
      throw new Error('files prevents localhost precedence');
  }
  groups.splice(files === 0 ? 1 : 0, 0, { service: 'myhostname', actions: [] });
  return prefix + ' ' + groups.map((group) => [group.service, ...group.actions].join(' ')).join(' ') + (comment ? ' ' + comment : '');
});
if (count !== 1) throw new Error('expected one hosts policy');
if (updated !== original && process.argv[3] !== '--check') {
  const temporary = path + '.ci-router-' + randomUUID();
  let fd;
  try {
    fd = fs.openSync(temporary, 'wx', stat.mode & 0o7777);
    fs.fchownSync(fd, stat.uid, stat.gid);
    fs.fchmodSync(fd, stat.mode & 0o7777);
    fs.writeFileSync(fd, updated);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temporary, path);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}
CI_ROUTER_LOCALHOST_CONFIG_EOF
  }
  ci_router_localhost_configure --check || exit 1
  if ! getent -s myhostname hosts app.localhost >/dev/null 2>&1; then
    timeout --kill-after=5 30 apt-get -o DPkg::Lock::Timeout=5 -o Acquire::Retries=0 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 update -qq >/dev/null 2>&1 || exit 1
    timeout --kill-after=5 30 apt-get -o DPkg::Lock::Timeout=5 -o Acquire::Retries=0 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 install -y -qq --no-install-recommends libnss-myhostname >/dev/null 2>&1 || exit 1
  fi
  ci_router_localhost_configure || exit 1
); then
  echo 'ci-router: localhost resolver setup unavailable' >&2
  exit 1
fi
'node' <<'CI_ROUTER_LOCALHOST_SMOKE_EOF'

const dns = require('node:dns').promises;
let step = 'start';
const timer = setTimeout(() => {
  console.error('ci-router: localhost resolver smoke timed out at ' + step);
  process.exit(1);
}, 10000);
(async () => {
  for (const name of ['localhost', 'app.localhost', 'nested.app.localhost']) {
    for (const family of [4, 6]) {
      step = 'lookup ' + name + ' IPv' + family;
      const result = await dns.lookup(name, { family });
      if (result.address !== (family === 4 ? '127.0.0.1' : '::1')) throw new Error('got ' + result.address);
    }
  }
  if (process.argv.includes('--connect')) {
    const net = require('node:net');
    step = 'hosts override';
    if ((await dns.lookup('ci-router-override.localhost', { family: 4 })).address !== '127.0.0.2')
      throw new Error('hosts override lost');
    for (const family of [4, 6, 0]) {
      step = 'connect ' + (family ? 'IPv' + family : 'default');
      const server = net.createServer((socket) => socket.end('loopback'));
      try {
        const host = family === 4 ? '127.0.0.1' : family === 6 ? '::1' : undefined;
        await new Promise((resolve, reject) => server.once('error', reject).listen({ port: 0, ...(host ? { host } : {}) }, resolve));
      } catch (error) {
        if (family === 6 && ['EAFNOSUPPORT', 'EADDRNOTAVAIL'].includes(error.code)) {
          console.log('ci-router: IPv6 socket unavailable; IPv6 lookup passed');
          continue;
        }
        throw error;
      }
      try {
        await new Promise((resolve, reject) => {
          const socket = net.connect({ host: 'app.localhost', port: server.address().port, ...(family ? { family } : {}) });
          socket.setTimeout(2000, () => socket.destroy(new Error('connection timeout')));
          let body = '';
          socket.on('data', (chunk) => body += chunk);
          socket.on('error', reject);
          socket.on('end', () => { if (body === 'loopback') resolve(); else reject(new Error('invalid response')); });
        });
      } finally {
        await new Promise((resolve) => server.close(resolve));
      }
      console.log(family ? 'ci-router: IPv' + family + ' explicit connection passed' : 'ci-router: default connection passed');
    }
  }
})().then(() => {
  clearTimeout(timer);
  console.log('ci-router: localhost resolver smoke passed');
}, (error) => {
  clearTimeout(timer);
  const reason = String((error && (error.code || error.message)) || 'error').slice(0, 120);
  let ipv6 = 'no';
  try {
    if (require('node:fs').readFileSync('/proc/net/if_inet6', 'utf8').trim()) ipv6 = 'yes';
  } catch {}
  console.error('ci-router: localhost resolver smoke failed at ' + step + ': ' + reason + ' (kernel IPv6: ' + ipv6 + ')');
  process.exitCode = 1;
});
CI_ROUTER_LOCALHOST_SMOKE_EOF

# Rust 1.99.1 via a pinned rustup-init (1.29.3), minimal profile. The toolchain binaries go on
# /usr/local/bin straight from the pinned toolchain dir; rustup is linked too, and RUSTUP_HOME / CARGO_HOME
# are exported for login shells (profile.d) and for non-login runner shells (/etc/environment).
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUSTUP_TMP=$(mktemp -d)
curl --proto '=https' --tlsv1.2 -fsSL -o "$RUSTUP_TMP/rustup-init" https://static.rust-lang.org/rustup/archive/1.29.3/x86_64-unknown-linux-gnu/rustup-init
echo "b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55  $RUSTUP_TMP/rustup-init" | sha256sum -c -
chmod +x "$RUSTUP_TMP/rustup-init"
"$RUSTUP_TMP/rustup-init" -y --profile minimal --default-toolchain 1.99.1 --no-modify-path >/dev/null 2>&1
rm -rf "$RUSTUP_TMP"
for tool in cargo rustc rustdoc; do ln -sf /opt/rustup/toolchains/1.99.1-x86_64-unknown-linux-gnu/bin/$tool /usr/local/bin/$tool; done
ln -sf /opt/cargo/bin/rustup /usr/local/bin/rustup
printf 'export RUSTUP_HOME=/opt/rustup\nexport CARGO_HOME=/opt/cargo\n' > /etc/profile.d/ci-router-rust.sh
touch /etc/environment
sed -i '/^RUSTUP_HOME=/d;/^CARGO_HOME=/d' /etc/environment
printf 'RUSTUP_HOME=/opt/rustup\nCARGO_HOME=/opt/cargo\n' >> /etc/environment
rustc --version >/dev/null
cargo --version >/dev/null
rustup --version >/dev/null 2>&1
# The pinned actions/runner, exactly as the bootstrap installs it.
mkdir -p /opt/actions-runner /opt/ci-router && cd /opt/actions-runner
curl -fsSL -o runner.tar.gz https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
echo "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40  runner.tar.gz" | sha256sum -c -
tar xzf runner.tar.gz --strip-components=1
rm -f runner.tar.gz
ICU_PKG=$(apt-cache search --names-only '^libicu[0-9]+$' | awk '{print $1}' | sort -V | tail -n 1)
if [ -n "$ICU_PKG" ]; then apt_install --no-install-recommends "$ICU_PKG"; fi
quiet ./bin/installdependencies.sh
if ! ldconfig -p | grep 'libicuuc\.so\.[0-9]' >/dev/null; then
  echo "bake: no ICU library is installed (the runner needs libicu)" >&2
  exit 1
fi
# ICU is required here even if the environment asks for invariant globalization.
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0 ./bin/Runner.Listener --version >/dev/null
# Keep Alpine Node runtimes for JavaScript actions in Alpine job containers; drop only package lists.
rm -rf /var/lib/apt/lists/* /var/cache/apt/*
# Last: the marker says the steps above all finished.
printf '%s\n' "2.338.2" > /opt/ci-router/baked
