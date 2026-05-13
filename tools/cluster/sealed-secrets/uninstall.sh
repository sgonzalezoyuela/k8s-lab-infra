#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# WARNING: this deletes the namespace, which deletes the controller's
# private keys. ALL existing SealedSecrets in the cluster become
# un-decryptable once those keys are gone. If you need to keep them,
# back up the keys BEFORE running this:
#
#   kubectl get secret -n sealed-secrets \
#     -l sealedsecrets.bitnami.com/sealed-secrets-key \
#     -o yaml > sealed-secrets-keys-backup.yaml
#
# Re-applying the backup before the next install restores decrypt ability.
# (Documented loudly in tools/docs/INIT-CLUSTER.md; the script itself does
# not gate on it because clean teardowns in lab settings are common.)

# 2>/dev/null || true so this is safe to re-run when the release is already
# gone (helm exits non-zero otherwise).
helm uninstall sealed-secrets -n sealed-secrets 2>/dev/null || true

# --ignore-not-found makes the ns delete idempotent. The Helm release owns
# the CRD, Deployment, RBAC, Service; the namespace owns the keypair Secrets
# and the controller Pods.
kubectl delete namespace sealed-secrets --ignore-not-found

echo "==> sealed-secrets uninstalled (namespace sealed-secrets removed)"
