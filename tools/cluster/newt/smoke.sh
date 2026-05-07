#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="newt"

# 1. Rollout must already be steady. We use a short 60s budget here on top
#    of install.sh's 2-minute wait — if the pod is not Ready by the time the
#    operator runs smoke, something downstream is wrong (CrashLoopBackOff,
#    ImagePullBackOff, etc.) and we want to surface that before grepping
#    logs.
kubectl -n "$NS" rollout status deployment/newt --timeout=60s

# 2. Poll the pod logs for the literal "Connecting to endpoint:" string
#    (newt 1.12.x logs this line at INFO level). The line is only emitted
#    AFTER:
#      a. HTTPS auth to PANGOLIN_ENDPOINT succeeded (NEWT_ID/NEWT_SECRET
#         accepted by Pangolin),
#      b. the WebSocket upgrade completed,
#      c. Pangolin pushed back the wg/connect message with the tunnel
#         peer descriptor.
#    So observing it is a strong signal that the tunnel is genuinely being
#    brought up — not just that the container started.
deadline=$(( $(date +%s) + 30 ))
found=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl -n "$NS" logs deployment/newt --tail=200 2>/dev/null \
       | grep -q "Connecting to endpoint:"; then
    found=1
    break
  fi
  sleep 2
done

if [ "$found" != 1 ]; then
  echo "ERROR: newt did not log 'Connecting to endpoint:' within 30s of rollout being Ready" >&2
  echo "Last 30 log lines:" >&2
  kubectl -n "$NS" logs deployment/newt --tail=30 >&2 || true
  echo >&2
  echo "Hints:" >&2
  echo "  - Verify NEWT_ID and NEWT_SECRET in .env match what Pangolin issued for this site" >&2
  echo "    (a typo gives a 401 from Pangolin, not a crash)." >&2
  echo "  - Verify PANGOLIN_ENDPOINT is reachable from inside the cluster" >&2
  echo "    (DNS resolves, egress firewall lets HTTPS/WSS out)." >&2
  echo "  - A Pangolin site only accepts ONE concurrent newt connection;" >&2
  echo "    if another newt is already attached, this one will idle. Stop the other or rotate the secret." >&2
  exit 1
fi

echo "==> newt smoke OK (tunnel up; reached Pangolin and accepted credentials)"
