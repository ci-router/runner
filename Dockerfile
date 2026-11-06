# The baked runner image of the briq route (RUNNER_IMAGE in packages/runner, D3). Public on purpose:
# briq pulls public images only, so nothing secret goes in here; the boot secret arrives as env.
# Published from the public repo ci-router/runner, which holds a rendered copy of this file:
# infra/scripts/publish-runner-image.sh.
FROM ubuntu:24.04
ARG RUNNER_VERSION
ARG RUNNER_SHA256
LABEL org.opencontainers.image.source="https://github.com/ci-router/runner"
# A briq's process runs as root, and the VM is destroyed after one job.
ENV RUNNER_ALLOW_RUNASROOT=1
RUN apt-get update -qq \
  && apt-get install -y -qq --no-install-recommends \
       build-essential ca-certificates curl git gzip jq openssh-client python3 sudo tar unzip xz-utils zip \
       >/dev/null \
  && mkdir -p /opt/actions-runner /opt/ci-router \
  && cd /opt/actions-runner \
  && curl -fsSL -o runner.tar.gz \
       "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
  && tar xzf runner.tar.gz --strip-components=1 \
  && rm runner.tar.gz \
  && ./bin/installdependencies.sh >/dev/null \
  && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 wrapper.sh /opt/actions-runner/wrapper.sh
COPY --chmod=0755 entrypoint.sh /opt/ci-router/entrypoint.sh
