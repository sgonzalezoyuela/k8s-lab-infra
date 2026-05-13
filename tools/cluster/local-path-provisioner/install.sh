#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${LOCAL_PATH_PROVISIONER_VERSION:?LOCAL_PATH_PROVISIONER_VERSION unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# local-path-storage is the upstream-default namespace; the overlay labels it
# privileged-PSA because helper pods use hostPath. We do NOT pre-create it
# here — the overlay's resources include the Namespace object, and applying
# the overlay server-side both creates the ns and sets its labels in one
# atomic apply.
NS="local-path-storage"
ASSETS="$TOOLS_DIR/cluster/local-path-provisioner"

# Drift warning: if the operator pinned a different upstream tag in .env vs
# the bundled default (version.txt), prefer the .env value but make the drift
# visible. Same model as the other Phase-2 installers.
pinned_default="$(tr -d '[:space:]' < "$ASSETS/version.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$LOCAL_PATH_PROVISIONER_VERSION" ]; then
  echo "warn: .env LOCAL_PATH_PROVISIONER_VERSION=$LOCAL_PATH_PROVISIONER_VERSION differs from $ASSETS/version.txt=$pinned_default; using .env value" >&2
fi

# Apply the kustomize overlay server-side. Server-side apply gives proper
# field-management semantics and reports `unchanged` on idempotent re-runs.
kubectl apply -k "$ASSETS" --server-side --force-conflicts

# Wait for the controller Deployment to roll out (helper pods are short-lived
# and won't exist until a PVC is created; the controller is the steady-state
# component to watch).
kubectl -n "$NS" rollout status deployment/local-path-provisioner --timeout=2m

# Sanity-check: the StorageClass really did get the default-class annotation.
# Without this, PVCs that omit `storageClassName` would sit Pending forever —
# silent failure mode worth catching at install time.
is_default="$(kubectl get storageclass local-path \
  -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"
if [ "$is_default" != "true" ]; then
  echo "ERROR: StorageClass local-path missing storageclass.kubernetes.io/is-default-class: \"true\" annotation (got: '$is_default')" >&2
  exit 1
fi

echo "==> local-path-provisioner installed; StorageClass local-path is the cluster default"
