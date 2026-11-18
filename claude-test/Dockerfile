# Self-hosted GitHub Actions runner image for pipeline stages that run
# Claude *and* need Docker to build and test the branch in containers
# (develop, testPR and module-test of generic-data-collector's
# issue-pipeline.yml, runs-on: ionos-l1-test). Same base as
# claude/Dockerfile plus the docker CLI and compose plugin -- see
# spec/runner-claude-test.md.
#
# No dockerd here and no host socket: the CLI talks to the
# `claude-test-dind` sidecar (Docker-in-Docker) through DOCKER_HOST, set
# in docker-compose.yml. Test stacks live and die in that sidecar's own
# daemon, isolated from the host's dockerd and from whatever the
# deploy-docker runner has deployed there.
#
# State that must come in as a volume, never baked into this image:
#   - the GitHub App private key (.pem) the entrypoint uses to register
#     this as an organization runner (same App as claude-runner)
#   - the Codex login (~/.codex, its own volume; see spec/runner-claude.md)
#
# claude authenticates via CLAUDE_CODE_OAUTH_TOKEN, set by the consuming
# workflow, exactly like claude-runner.

FROM ubuntu:24.04

ARG RUNNER_VERSION=2.336.0
ARG RUNNER_SHA256=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
ARG RUNNER_ARCH=x64

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      openssl \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI from its own official apt repo, same reason as
# claude/Dockerfile.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# docker CLI + compose plugin from Docker's own official apt repo (same
# source as deploy-docker/Dockerfile). The compose plugin must be
# >= 2.24.4: consumer test stacks use `ports: !reset []`. No dockerd:
# the daemon is the claude-test-dind sidecar.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-buildx-plugin \
      docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Node.js (system-wide) + Codex CLI, for the Codex plugin below: its
# hooks and commands run `node .../codex-companion.mjs`, which drives the
# global `codex` CLI. Node from NodeSource's official apt repo (Ubuntu's
# own lags); workflows that call actions/setup-node still get their own
# Node first on PATH. Codex pinned so image rebuilds are reproducible --
# bump CODEX_VERSION on purpose.
ARG NODE_MAJOR=22
ARG CODEX_VERSION=0.170.0
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /etc/apt/keyrings/nodesource.asc \
    && chmod a+r /etc/apt/keyrings/nodesource.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force

# Same non-root user as claude/Dockerfile (uid/gid 1001:1001), so the
# shared GitHub App key on the host keeps a single owner. No `docker`
# group needed: the daemon is reached over TCP, not through a socket.
RUN useradd -m -s /bin/bash -u 1001 -U runner
USER runner
WORKDIR /home/runner

RUN curl -fsSL -o actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c - \
    && mkdir actions-runner && tar xzf actions-runner.tar.gz -C actions-runner \
    && rm actions-runner.tar.gz

# Pre-create _work owned by runner, same reason as claude/Dockerfile.
RUN mkdir -p actions-runner/_work

USER root
RUN /home/runner/actions-runner/bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/*
USER runner

# Native claude CLI, same install method as claude/Dockerfile.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/runner/.local/bin:${PATH}"

# Codex plugin for Claude Code (openai/codex-plugin-cc): the non-interactive
# equivalent of `/plugin marketplace add openai/codex-plugin-cc` +
# `/plugin install codex@openai-codex` (user scope, ~/.claude). No
# /reload-plugins needed: every `claude -p` is a fresh process. The
# `/codex:setup` part (Codex login) can't be baked in -- it's a secret --
# see spec/runner-claude.md, "Codex". The plugin's stop-time review gate
# stays off (its default): it would loop Claude and Codex in CI.
RUN claude plugin marketplace add openai/codex-plugin-cc \
    && claude plugin install codex@openai-codex \
    && mkdir -p /home/runner/.codex

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
