# Self-hosted GitHub Actions runner image for .github/workflows/issue-pipeline.yml
# (runs-on: ionosL1). Minimal on purpose -- decided: only what that
# workflow's own steps need (git, gh, claude, plus Node and the Codex CLI
# for the Codex plugin); not a project's build toolchain (Python/Docker).
# If a pipeline stage ever needs those, add them then, not preemptively.
#
# State that must come in as a volume, never baked into this image:
#   - the GitHub App private key (.pem) the entrypoint uses to register
#     this as an organization runner
#   - the Codex login (~/.codex, its own volume; see spec/runner-claude.md)
#
# claude itself authenticates via CLAUDE_CODE_OAUTH_TOKEN, set as a
# workflow-level env var from the CLAUDE_CODE_OAUTH_TOKEN organization
# secret (see issue-pipeline.yml in the repo that uses this runner) --
# a long-lived token from `claude setup-token`, not an interactive
# browser login, so no ~/.claude session needs to survive container
# recreations.

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

# GitHub CLI from its own official apt repo (the Ubuntu-bundled gh
# package lags behind; this workflow relies on current `gh` behavior).
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
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

# The runner refuses to configure/run as root -- deliberately not
# overriding that with RUNNER_ALLOW_RUNASROOT. uid/gid pinned (not left
# to useradd's default) so the host secrets directory can be chowned to
# a stable, known id -- see README's "Estado y secretos" section.
RUN useradd -m -s /bin/bash -u 1001 -U runner
USER runner
WORKDIR /home/runner

RUN curl -fsSL -o actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c - \
    && mkdir actions-runner && tar xzf actions-runner.tar.gz -C actions-runner \
    && rm actions-runner.tar.gz

# Pre-create _work owned by runner: docker-compose.yml mounts the
# runner-work volume here, and an empty named volume is populated from
# whatever's already at that path in the image. Without this, Docker
# creates it as root on first mount and the runner (uid 1001) can't
# write _tool/_temp/etc under it.
RUN mkdir -p actions-runner/_work

# installdependencies.sh needs root (apt-get); everything else in this
# image runs as `runner`.
USER root
RUN /home/runner/actions-runner/bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/*
USER runner

# Native claude CLI -- curl -fsSL https://claude.ai/install.sh | bash
# is the current official install method (confirmed against the real
# install.sh when this Dockerfile was written), lands in ~/.local/bin.
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
