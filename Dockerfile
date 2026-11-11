# The baked runner image of the briq route (RUNNER_IMAGE in packages/runner, D3). Public on purpose:
# briq pulls public images only, so nothing secret goes in here; the boot secret arrives as env.
# Published from the public repo ci-router/runner, which holds a rendered copy of this file:
# infra/scripts/publish-runner-image.sh.
FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/ci-router/runner"
# A briq's process runs as root, and the VM is destroyed after one job.
ENV RUNNER_ALLOW_RUNASROOT=1
RUN apt-get update -qq \
  && apt-get install -y -qq --no-install-recommends \
       build-essential ca-certificates curl git gzip jq openssh-client python3 sudo tar unzip xz-utils zip \
       >/dev/null
# The shared bake (renderBakeScript in packages/runner, docs/prebaked-images.md): the pinned runner with
# its dependencies, docker, Node 22 and Rust, a warm apt cache and the /opt/ci-router/baked marker.
# The same script bakes the VM images of the other providers. The pinned version and sha256 are in it.
COPY --chmod=0755 bake.sh /tmp/bake.sh
RUN /tmp/bake.sh && rm -f /tmp/bake.sh
COPY --chmod=0755 wrapper.sh /opt/actions-runner/wrapper.sh
COPY --chmod=0755 entrypoint.sh /opt/ci-router/entrypoint.sh
