#!/bin/bash
# Prints a short-lived (~1h) GitHub App installation access token to
# stdout. Extracted out of entrypoint.sh's own registration flow (same
# JWT -> installation-token chain) so consumer workflow steps running on
# this runner can call it directly to clone other private repos of the
# organization over HTTPS during a deploy -- repos the ephemeral
# actions/checkout token doesn't cover:
#
#   git clone "https://x-access-token:$(get-installation-token.sh)@github.com/<org>/<repo>.git"
#
# No new secret: reuses the same GitHub App private key already
# mounted for registration. See spec/runner-deploy-docker.md.
set -euo pipefail

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
