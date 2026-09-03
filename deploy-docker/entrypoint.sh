#!/bin/bash
# Registers this container as an organization runner (GitHub App-based
# auth, same reasoning and same App as claude/entrypoint.sh -- a static
# registration token expires in ~1h, unworkable for a container that
# might restart later) and runs it. Deregisters on SIGTERM/SIGINT so
# `docker stop` doesn't leave a stale/offline runner listed in the org.
#
# No `jq` in this image (deliberately -- see spec/runner-deploy-docker.md,
# this runner only installs what it needs beyond the docker CLI), so JSON
# responses are picked apart with grep/sed instead. Every value this
# script needs is a flat top-level string field, so that's enough.
#
# Best-effort: this JWT->installation-token->registration-token chain
# mirrors claude/entrypoint.sh, built from GitHub's documented REST API
# but not run against a real GitHub App/org -- verify end-to-end before
# relying on it, and check GitHub's own docs if anything here has
# drifted.
set -euo pipefail

: "${GITHUB_ORG:?GITHUB_ORG is required}"
: "${GITHUB_APP_ID:?GITHUB_APP_ID is required}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
: "${GITHUB_APP_PRIVATE_KEY_PATH:?GITHUB_APP_PRIVATE_KEY_PATH is required (mount the GitHub App private key here)}"

base64url() {
  base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'
}

# Extracts a flat top-level string field from a single-line JSON
# response, e.g. json_field token <<< '{"token":"abc","expires_at":"..."}'
json_field() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"
}

get_installation_token() {
  local now iat exp header payload unsigned signature jwt
  now=$(date +%s)
  iat=$((now - 60))
  exp=$((now + 300))
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$GITHUB_APP_ID" | base64url)
  unsigned="${header}.${payload}"
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" | base64url)
  jwt="${unsigned}.${signature}"

  curl -sSf -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" \
    | json_field token
}

register() {
  local installation_token reg_token
  installation_token=$(get_installation_token)
  reg_token=$(curl -sSf -X POST \
    -H "Authorization: Bearer $installation_token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token" \
    | json_field token)

  cd /home/runner/actions-runner
  ./config.sh \
    --url "https://github.com/${GITHUB_ORG}" \
    --token "$reg_token" \
    --name "${RUNNER_NAME:-$(hostname)}" \
    --labels "${RUNNER_LABELS:-deployDocker}" \
    --unattended --replace
}

deregister() {
  local installation_token del_token
  installation_token=$(get_installation_token) || return 0
  del_token=$(curl -sSf -X POST \
    -H "Authorization: Bearer $installation_token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/remove-token" \
    | json_field token) || return 0
  cd /home/runner/actions-runner
  ./config.sh remove --token "$del_token" || true
}


# github.com's known host key, added on every start rather than
# assumed present -- this is a fresh image, not a persistent bare-metal
# box. Needed so a `git clone` over SSH during the actual deploy step
# (e.g. private submodules/deps, see spec/runner-deploy-docker.md)
# doesn't hang on an interactive host-key prompt.
mkdir -p ~/.ssh
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true

trap deregister EXIT INT TERM

register
cd /home/runner/actions-runner
./run.sh &
wait $!
