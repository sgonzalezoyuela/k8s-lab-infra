#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="default"
PVC="lpp-smoke-test"
POD="lpp-smoke-test"

# Clean up the PVC and Pod on exit regardless of pass/fail. --wait=false so
# a hung delete doesn't mask the underlying test result.
cleanup() {
  kubectl -n "$NS" delete pod  "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pvc  "$PVC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Two-resource smoke: a 1Gi PVC + a one-shot Pod that mounts it, writes a
# file, reads it back, and exits 0. WaitForFirstConsumer means the PVC will
# only bind when the Pod schedules, so a status-only PVC check is NOT enough
# to prove the provisioner works end-to-end.
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NS
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
---
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.36
      command: ["sh","-c","echo ok > /data/ok && cat /data/ok"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC
EOF

# Fail-fast: the PVC must end up on the local-path StorageClass. If a future
# Phase-2 service (Longhorn) flipped the default, this would catch it.
sc="$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.storageClassName}')"
if [ "$sc" != "local-path" ]; then
  echo "ERROR: PVC $PVC bound to StorageClass '$sc', expected 'local-path'" >&2
  exit 1
fi

# Wait for the Pod to reach Succeeded (the write+read finished). Timeout
# tight enough to fail fast if the kubelet extraMount is missing on the node
# the Pod scheduled to.
kubectl -n "$NS" wait pod/"$POD" \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=60s

echo "==> local-path-provisioner smoke OK (PVC bound, Pod wrote+read /data/ok)"
