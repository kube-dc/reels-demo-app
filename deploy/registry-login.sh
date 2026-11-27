#!/usr/bin/env bash
# Sign in to a kube-dc managed registry with no stored registry secret. The
# machine identity's token (the one CI deploys with) is exchanged for a token
# whose only audience is the registry (kube-dc-registry), so a registry never
# receives a token the Kubernetes API accepts; docker then logs in with it.
# The token lives as long as the identity's tokens (15 minutes): sign in right
# before pushing.
# Inputs (environment): KUBE_DC_REGISTRY (the registry host), KUBE_DC_TOKEN_URL,
# KUBE_DC_CLIENT_ID; keyless with KUBE_DC_AUDIENCE (the workflow needs
# `permissions: id-token: write`), otherwise KUBE_DC_CLIENT_SECRET.
set -euo pipefail
: "${KUBE_DC_REGISTRY:?KUBE_DC_REGISTRY}"

# client_auth fills auth with the client's credentials; a keyless assertion
# is fetched fresh for every request.
client_auth() {
  if [ -n "${KUBE_DC_AUDIENCE:-}" ]; then
    local assertion
    assertion=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$KUBE_DC_AUDIENCE" | jq -r .value)
    auth=(--data-urlencode "client_id=$KUBE_DC_CLIENT_ID"
      -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
      --data-urlencode "client_assertion=$assertion")
  else
    auth=(--data-urlencode "client_id=$KUBE_DC_CLIENT_ID"
      --data-urlencode "client_secret=${KUBE_DC_CLIENT_SECRET:?KUBE_DC_CLIENT_SECRET or KUBE_DC_AUDIENCE}")
  fi
}

client_auth
token=$(curl -fsS "$KUBE_DC_TOKEN_URL" -d grant_type=client_credentials "${auth[@]}" | jq -r .access_token)
[ -n "$token" ] && [ "$token" != null ] || { echo "token request refused" >&2; exit 1; }
[ -n "${GITHUB_ENV:-}" ] && echo "::add-mask::$token"

# Keycloak standard token exchange: aud becomes only kube-dc-registry; the
# kdc_registry claim carries this identity's push:<project> right.
client_auth
registry_token=$(curl -fsS "$KUBE_DC_TOKEN_URL" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  --data-urlencode "subject_token=$token" \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d requested_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d audience=kube-dc-registry -d scope=kube-dc-registry \
  "${auth[@]}" | jq -r .access_token)
[ -n "$registry_token" ] && [ "$registry_token" != null ] || { echo "registry token exchange refused" >&2; exit 1; }
[ -n "${GITHUB_ENV:-}" ] && echo "::add-mask::$registry_token"

printf '%s' "$registry_token" | docker login "$KUBE_DC_REGISTRY" -u kube-dc --password-stdin
