# Self-hosted GitHub Actions runner image for .github/workflows/issue-pipeline.yml
# (runs-on: ionosL1). Minimal on purpose -- decided: only what that
# workflow's own steps need (git, gh, ssh, claude); not this repo's own
# toolchain (Python/Node/Docker). If a pipeline stage ever needs those
# to actually build/test weather-ingest, add them then, not preemptively.
#
# State that must come in as a volume, never baked into this image:
#   - the SSH private key setup-ssh-and-git unlocks and pushes with
#   - the GitHub App private key (.pem) the entrypoint uses to register
#     this as an organization runner
#   - claude's own auth/session data (~/.claude, ~/.local/share/claude)
#     -- log in once interactively after the container is up; there's
#     no way to script the OAuth browser flow from a Dockerfile

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
      openssh-client \
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

# The runner refuses to configure/run as root -- deliberately not
# overriding that with RUNNER_ALLOW_RUNASROOT.
RUN useradd -m -s /bin/bash runner
USER runner
WORKDIR /home/runner

RUN curl -fsSL -o actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  actions-runner.tar.gz" | sha256sum -c - \
    && mkdir actions-runner && tar xzf actions-runner.tar.gz -C actions-runner \
    && rm actions-runner.tar.gz

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

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
