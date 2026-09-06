# Self-hosted GitHub Actions runner image for infrastructure deploys.
# Generic capability, consumed by the pipelines of several *other* apps
# in the org (runs-on: deploy-docker), not by any workflow in this repo
# -- see spec/runner-deploy-docker.md. Minimal on purpose, same
# philosophy as claude/Dockerfile: only what this function needs (a
# docker client to talk to the host daemon), not any consumer app's own
# toolchain.
#
# State that must come in as a volume, never baked into this image:
#   - the GitHub App private key (.pem) the entrypoint uses to register
#     this as an organization runner (same App as claude-runner), and
#     that get-installation-token.sh (below) reuses on demand to clone
#     other private repos during a deploy, see spec/runner-deploy-docker.md
#   - /var/run/docker.sock (host) -- Docker-outside-of-Docker, see
#     spec/runner-deploy-docker.md
#   - DEPLOY_DIR, bind-mounted 1:1 (same path inside and outside the
#     container) -- see spec/runner-deploy-docker.md

FROM ubuntu:24.04

ARG RUNNER_VERSION=2.336.0
ARG RUNNER_SHA256=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
ARG RUNNER_ARCH=x64

# GID of the `docker` group on the host, so `runner` (uid 1001 below)
# can use the socket bind-mounted at /var/run/docker.sock. Varies per
# host -- override at build time, not hardcoded:
#   docker build --build-arg DOCKER_GID=$(getent group docker | cut -d: -f3) ...
ARG DOCKER_GID=999

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssl \
    && rm -rf /var/lib/apt/lists/*

# docker CLI + compose plugin from Docker's own official apt repo.
# Deliberately no dockerd here -- this runner talks to the *host's*
# daemon through the mounted socket (Docker-outside-of-Docker, not
# Docker-in-Docker), so containers it starts outlive its own lifecycle.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# The runner refuses to configure/run as root -- deliberately not
# overriding that with RUNNER_ALLOW_RUNASROOT. uid/gid pinned to
# 1001:1001 (not left to useradd's default), same reasoning as
# claude/Dockerfile: the host secrets directory is chowned to this
# stable, known id. Also joined to a `docker` group matching the host's,
# so it can use the mounted socket.
RUN groupadd -g "${DOCKER_GID}" docker \
    && useradd -m -s /bin/bash -u 1001 -U -G docker runner
USER runner
WORKDIR /home/runner

# Workflows consumidores hacen git clone/pull dentro de DEPLOY_DIR/<proyecto>
# (bind mount 1:1 desde el host), cuyo propietario en el host no siempre
# coincide con el uid 1001 de `runner` -- sin esto, git rechaza operar ahí
# ("dubious ownership", detectado desde Git 2.35.2). Comodín en vez de rutas
# concretas porque DEPLOY_DIR/<proyecto> es dinámico, un subdirectorio por
# app desplegada; ver spec/runner-deploy-docker.md (issue #3).
RUN git config --global --add safe.directory '*'

RUN curl -fsSL -o actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c - \
    && mkdir actions-runner && tar xzf actions-runner.tar.gz -C actions-runner \
    && rm actions-runner.tar.gz

# Pre-create _work owned by runner -- same reasoning as claude/Dockerfile:
# docker-compose.yml mounts a named volume here, and an empty volume is
# populated from whatever's already at that path in the image. Without
# this, Docker creates it as root on first mount and runner (uid 1001)
# can't write _tool/_temp/etc under it.
RUN mkdir -p actions-runner/_work

# installdependencies.sh needs root (apt-get); everything else in this
# image runs as `runner`.
USER root
RUN /home/runner/actions-runner/bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/*
USER runner

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

# Standalone helper, reused by entrypoint.sh's own registration flow and
# also directly callable from consumer workflow steps running on this
# runner, to clone other private repos over HTTPS during a deploy --
# see spec/runner-deploy-docker.md.
COPY --chown=runner:runner get-installation-token.sh /home/runner/bin/get-installation-token.sh
RUN chmod +x /home/runner/bin/get-installation-token.sh
ENV PATH="/home/runner/bin:${PATH}"

ENTRYPOINT ["/home/runner/entrypoint.sh"]
