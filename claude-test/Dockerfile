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

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
