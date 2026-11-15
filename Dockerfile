# The baked runner image of the briq route (RUNNER_IMAGE in packages/runner, D3). Public on purpose:
# briq pulls public images only, so nothing secret goes in here; the boot secret arrives as env.
# Published from the public repo ci-router/runner, which holds a rendered copy of this file:
# infra/scripts/publish-runner-image.sh.
FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/ci-router/runner"
# A briq's process runs as root, and the VM is destroyed after one job.
ENV RUNNER_ALLOW_RUNASROOT=1
# GitHub-hosted parity (D20, docs/runners.md): actions/setup-* read the tool cache and the image from
# these. Same values as the bootstrap of the other providers (renderBootstrapCommand).
ENV ImageOS=ubuntu24 RUNNER_TOOL_CACHE=/opt/hostedtoolcache AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
# The shared bake (renderBakeScript({ target: 'container' }) in packages/runner, docs/prebaked-images.md)
# is the only install step for what the runner and the jobs need: the pinned runner with its
# dependencies, Node 22, Rust and build-essential, the /opt/ci-router/baked marker. The extra tools
# below go in the same layer and the bake removes the apt lists at its end, so no layer keeps them.
# The same script bakes the VM images of the other providers. The pinned version and sha256 are in it.
# No Docker in the image: a Docker job installs and starts it at boot (BAKED_DOCKER_START, docs/prebaked-images.md).
COPY --chmod=0755 bake.sh /tmp/bake.sh
RUN apt-get update -qq \
  && apt-get install -y -qq --no-install-recommends \
       git gzip jq openssh-client python3 sudo tar unzip zip \
       >/dev/null \
  && /tmp/bake.sh \
  && rm -f /tmp/bake.sh \
  && mkdir -p /opt/hostedtoolcache
COPY --chmod=0755 wrapper.sh /opt/actions-runner/wrapper.sh
COPY --chmod=0755 entrypoint.sh /opt/ci-router/entrypoint.sh
