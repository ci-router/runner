#!/bin/bash
# ci-router prebaked runner image (docs/prebaked-images.md). Nothing here varies per run.
set -euo pipefail
export HOME="${HOME:-/root}"
export DEBIAN_FRONTEND=noninteractive
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
apt_install --no-install-recommends curl ca-certificates xz-utils build-essential
# Node 22.23.5 from nodejs.org, pinned with its published sha256.
NODE_DIR=$(mktemp -d)
curl -fsSL -o "$NODE_DIR/node-v22.23.5-linux-x64.tar.xz" https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-x64.tar.xz
echo "cdeb8670a0c81f51b4dc4ac61919f9b1ad917b304bf8221eb939570663d240f8  $NODE_DIR/node-v22.23.5-linux-x64.tar.xz" | sha256sum -c -
tar xJf "$NODE_DIR/node-v22.23.5-linux-x64.tar.xz" -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE
rm -rf "$NODE_DIR"
node --version >/dev/null
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
# Lean container image: no Alpine node builds (only for Docker `container:` jobs), no package lists.
rm -rf /opt/actions-runner/externals/node*_alpine /var/lib/apt/lists/* /var/cache/apt/*
# Last: the marker says the steps above all finished.
printf '%s\n' "2.338.2" > /opt/ci-router/baked
