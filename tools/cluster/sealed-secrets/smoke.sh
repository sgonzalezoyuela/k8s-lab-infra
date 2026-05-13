#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="sealed-secrets"

# Two-check minimal smoke:
#   1. The Helm release is actually deployed in $NS (catches the "operator
#      forgot to run install" / "operator targeted a different cluster" cases).
#   2. The controller Deployment is fully rolled out.
#
# We deliberately do NOT seal/unseal a probe Secret here. A real e2e cycle
# requires running `kubeseal --fetch-cert` against the in-cluster controller
# (port-forward or LB) and applying a SealedSecret — that's a richer test
# that belongs in a future cross-cutting ops.smoke-test feature. The two
# checks below confirm the install is healthy, which is all this smoke is for.
helm -n "$NS" status sealed-secrets >/dev/null \
  || { echo "ERROR: helm release sealed-secrets not deployed in $NS" >&2; exit 1; }

kubectl -n "$NS" rollout status deployment/sealed-secrets --timeout=60s

echo "==> sealed-secrets smoke OK (helm release deployed; controller Deployment rolled out)"
