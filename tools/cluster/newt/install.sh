#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${PANGOLIN_ENDPOINT:?PANGOLIN_ENDPOINT unset (see .env)}"
: "${NEWT_ID:?NEWT_ID unset (see .env)}"
: "${NEWT_SECRET:?NEWT_SECRET unset (see .env)}"
: "${NEWT_IMAGE_TAG:?NEWT_IMAGE_TAG unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# Sanity: PANGOLIN_ENDPOINT must look like an http(s) URL. Catches operators
# who paste hostnames or accidentally drop the scheme.
if [[ ! "$PANGOLIN_ENDPOINT" =~ ^https?:// ]]; then
  echo "ERROR: PANGOLIN_ENDPOINT must start with http:// or https:// (got: $PANGOLIN_ENDPOINT)" >&2
  exit 1
fi

# Catch the REPLACE-ME sentinels we ship in clusters/<name>/.env so a bare
# `cp .env.example .env` + `just newt-install` does not push placeholder
# credentials at the Pangolin server.
if [ "$NEWT_ID" = "REPLACE-ME-FROM-PANGOLIN-UI" ] || [ "$NEWT_SECRET" = "REPLACE-ME-FROM-PANGOLIN-UI" ]; then
  echo "ERROR: NEWT_ID or NEWT_SECRET is still the REPLACE-ME-FROM-PANGOLIN-UI placeholder." >&2
  echo "       Get real values from your Pangolin site UI (Sites -> create/edit -> newt credentials)" >&2
  echo "       and edit .env before re-running 'just newt-install'." >&2
  exit 1
fi

NS="newt"
ASSETS="$TOOLS_DIR/cluster/newt"

# If the operator pinned a different image tag in .env vs the bundled default,
# prefer the .env value but make the drift visible.
pinned_default="$(tr -d '[:space:]' < "$ASSETS/image-tag.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$NEWT_IMAGE_TAG" ]; then
  echo "warn: .env NEWT_IMAGE_TAG=$NEWT_IMAGE_TAG differs from $ASSETS/image-tag.txt=$pinned_default; using .env value" >&2
fi

# 1. Namespace with restricted PSA labels. newt is fully userspace
#    (wireguard-go netstack + outbound-only HTTPS/WSS), so no privileged
#    capabilities, no host network, no host paths. Restricted is correct.
kubectl apply --server-side --field-manager=newt-install -f "$ASSETS/namespace.yaml"

# 2. Secret with the three credential values rendered from env. Restrict
#    envsubst's variable list explicitly so $-prefixed strings inside any
#    future template field (annotations etc.) are not accidentally expanded.
export PANGOLIN_ENDPOINT NEWT_ID NEWT_SECRET
envsubst '$PANGOLIN_ENDPOINT $NEWT_ID $NEWT_SECRET' < "$ASSETS/secret.yaml.tpl" \
  | kubectl apply --server-side --field-manager=newt-install -f -

# 3. Deployment, image tag rendered from env.
export NEWT_IMAGE_TAG
envsubst '$NEWT_IMAGE_TAG' < "$ASSETS/deployment.yaml.tpl" \
  | kubectl apply --server-side --field-manager=newt-install -f -

# 4. Wait for the Recreate rollout to finish. With strategy.type=Recreate the
#    old pod terminates fully before the new one starts, which is what
#    Pangolin wants (one WebSocket per site at a time).
kubectl -n "$NS" rollout status deployment/newt --timeout=2m

echo "==> newt installed; tunnel client connecting to $PANGOLIN_ENDPOINT"
