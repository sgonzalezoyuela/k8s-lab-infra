# cluster.sealed-secrets — Implementation Guide

## Why

A working "secrets in Git" story is a hard prerequisite for any IaC /
GitOps flow. Plain Kubernetes Secrets can't be committed (base64 isn't
encryption); sealing them under a controller-held private key turns Git
back into the source of truth, while keeping the decrypt key in-cluster
where only the API server can read it.

Bitnami's sealed-secrets is the de-facto standard for this in plain
Kubernetes (vs Vault / External Secrets Operator, which solve a strict
superset of problems but pull in much more operational weight). Pair
it with the `kubeseal` CLI (already in our devShell), and the operator
workflow is:

```
echo -n "supersecret" \
  | kubectl create secret generic foo --dry-run=client \
      --from-file=password=/dev/stdin -o yaml \
  | kubeseal --controller-namespace=sealed-secrets --format yaml \
  > foo.sealed.yaml          # commit this
kubectl apply -f foo.sealed.yaml   # controller unseals → real Secret
```

## Source-of-truth decisions (locked in)

| Decision | Value | Rationale |
|---|---|---|
| Helm chart | `sealed-secrets/sealed-secrets` | Upstream `bitnami-labs/sealed-secrets` (the maintainers' org). The bitnami-charts mirror exists but lags. |
| Repo URL | `https://bitnami-labs.github.io/sealed-secrets` | Same as the chart's release artifacts. |
| Chart version | `2.18.5` (pins controller app `0.36.6`) | The chart and the controller are versioned independently; chart 2.18.5 is the published release that ships controller 0.36.6. Bumping requires editing both `tools/cluster/sealed-secrets/chart-version.txt` and the per-cluster `.env`. **Note**: appVersion 0.36.6 is bare semver (no `v` prefix) — the docker.io/bitnami/sealed-secrets-controller registry stopped using v-prefixed tags around appVersion 0.25.0 / chart 2.14.2. |
| Namespace | `sealed-secrets` (dedicated) | Restricted-PSA-labelled. Chart default is `kube-system`; we deviate because: (a) PSA labels on `kube-system` race with Talos's system-namespaces controller (same rationale as metallb's `metallb-system`), (b) a dedicated ns lets us reason about RBAC + future NetworkPolicy without touching `kube-system`. |
| PSA enforcement | `restricted` | Controller is fully restricted-compliant (the chart's defaults already are — we pin them in helm-values to make a future chart-default flip observable). |
| Key management | Auto-generate per cluster | Q4 default. Controller generates an RSA-4096 keypair on first start, stores it as `Secret/sealed-secrets-keyXXXXX` (active key labelled). Operator backs up that Secret out-of-band if they care about cross-cluster decrypt. |
| Smoke approach | Helm release deployed + Deployment rolled out | Minimal. No actual seal→unseal cycle (would need a live `kubeseal --fetch-cert` against the controller and a SealedSecret apply; that's a richer e2e test best left to a future `ops.smoke-test` feature). |
| Metrics / ServiceMonitor | `false` | Observability stack not yet provisioned; pinning `false` prevents the chart from creating a ServiceMonitor that points nowhere. |
| Image tag pin | `image.tag: 0.36.6` (BARE semver, no `v`) | Pinned in `helm-values.yaml` explicitly so a chart bump that updates its default tag is observable in our test diff. The chart honours this override. **CRITICAL**: a v-prefix here (`v0.36.6`) yields ErrImagePull because docker.io/bitnami/sealed-secrets-controller uses bare-semver tags. The structural test now rejects any `image.tag:` value matching `v[0-9]`. |

## Files added

```
tools/cluster/sealed-secrets/
├── install.sh             helm repo add/update + namespace + helm upgrade --install + rollout wait
├── uninstall.sh           helm uninstall + ns delete (idempotent)
├── smoke.sh               helm status + rollout status (no seal/unseal cycle)
├── helm-values.yaml       security context, image.tag pin, metrics off
└── chart-version.txt      bundled-default chart version (2.18.5)
```

Edits:

- `tools/.env.example` — declares `SEALED_SECRETS_CHART_VERSION=2.18.5`.
- `tools/Justfile` — three `[no-cd]` recipes: `sealed-secrets-install`,
  `sealed-secrets-smoke`, `sealed-secrets-uninstall`. Install/smoke
  depend on `env-check`.
- `tools/Makefile` — adds `SEALED_SECRETS_CHART_VERSION` to
  `bootstrap.config-scheme`'s required-vars list; adds
  `test-cluster.sealed-secrets`; wires into `test:`.
- `tools/docs/INIT-CLUSTER.md` — full Phase 2 subsection (prereqs,
  install, verify, smoke, uninstall, kubeseal workflow, key-rotation
  guidance). Configuration table extended.
- `README.md` — Phase 2 step in the per-cluster workflow snippet.
- `clusters/k8s4/.env` — per-cluster pin `SEALED_SECRETS_CHART_VERSION=2.18.5`.

## helm-values.yaml outline

```yaml
# Pinned image tag — chart 2.18.5 ships appVersion 0.36.6 by default,
# but we pin explicitly so a future chart bump can't silently change the
# controller version without us noticing.
#
# Bare semver — NO v-prefix. The docker.io/bitnami/sealed-secrets-controller
# registry uses bare-semver tags (e.g. 0.36.6, not v0.36.6). Using a
# v-prefix yields ErrImagePull.
image:
  tag: 0.36.6

# Restricted-PSA-compatible securityContext.
# The controller runs as uid 1001 (the upstream image's non-root user),
# no capabilities, no priv-esc, read-only root FS. The chart already
# defaults these to safe values; pinning makes a chart-default flip
# observable in CI.
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  runAsNonRoot: true
  runAsUser: 1001
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault

# Observability surface — disabled. Phase-2 observability lands later;
# emitting a ServiceMonitor against a non-existent Prometheus is just
# noise.
metrics:
  serviceMonitor:
    enabled: false
```

## Talos-specific notes

There are none. Unlike metrics-server (which needs `--kubelet-insecure-tls`
because of Talos's kubelet cert handling) and local-path-provisioner
(which needs the kubelet extraMount), sealed-secrets is a normal
Kubernetes Deployment that talks to the API server and listens on
internal HTTPS. Talos is irrelevant.

## Key management

The controller generates an RSA-4096 keypair on first start and stores
it as a Secret in the `sealed-secrets` namespace, labelled
`sealedsecrets.bitnami.com/sealed-secrets-key: active`. The public
half is what `kubeseal --fetch-cert` returns to the operator; the
private half is what the controller uses to unseal SealedSecrets.

### Auto-rotation

The controller rotates the key every 30 days by default (configurable
via `--key-renew-period`). Old keys remain in the cluster as inactive
Secrets so previously sealed payloads keep decrypting. A SealedSecret
sealed under key N continues to unseal correctly for the lifetime of
key N's Secret (which is forever, unless the operator deletes it).

### Backup before uninstall

Critical: `just sealed-secrets-uninstall` deletes the `sealed-secrets`
namespace, which includes the controller's private keys. ALL existing
SealedSecrets in the cluster become un-decryptable.

If you have SealedSecrets you want to keep:

```
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml
```

Re-applying that file before re-installing restores the decrypt
ability. The companion does NOT manage this automatically — it's
operator policy.

### Lab-rebuild rotation

Per Q4 (auto-generate per cluster), each fresh cluster gets fresh
keys. SealedSecrets sealed against the old cluster won't decrypt on
the new one. For the testing-the-cluster use case, operator re-seals
manifests with the new public key. For a Phase-3 multi-cluster story,
the right answer is operator-supplied keys (which we explicitly
deferred — see Out of scope).

## Smoke approach

```
helm -n sealed-secrets status sealed-secrets
kubectl -n sealed-secrets rollout status deployment/sealed-secrets --timeout=60s
```

Minimal on purpose. Two checks that are observable and fast:

1. The Helm release is deployed in `sealed-secrets`.
2. The controller Deployment is fully rolled out.

We deliberately do NOT seal/unseal a probe Secret here. That requires
either:

- Running `kubeseal --fetch-cert` against the in-cluster controller
  (a port-forward or LB), or
- Mounting the public cert into the smoke step manually.

Both are doable but neither adds signal beyond "the controller pod
came up healthy". The `kubeseal` CLI is in the devShell; operators
test seal/unseal manually after install (`kubeseal --version`,
`echo foo | kubeseal --raw --name x --namespace x`).

A richer e2e probe belongs in a future `ops.smoke-test` feature that
spans the whole stack.

## Idempotence claims

- `helm upgrade --install` against an already-installed release with
  unchanged chart version + values produces a no-op revision and the
  Deployment's spec does not change → no pod restart.
- `kubectl rollout status` is read-only.
- The drift warning (`.env` vs `chart-version.txt`) is stderr-only;
  the `.env` value always wins so install.sh remains deterministic.

Re-running `just sealed-secrets-install` with the same `.env` → exit 0,
no state change.

## Uninstall behavior

```
helm uninstall sealed-secrets -n sealed-secrets 2>/dev/null || true
kubectl delete namespace sealed-secrets --ignore-not-found
```

The Helm release owns: Deployment, Service, ServiceAccount, ClusterRoles
+ ClusterRoleBindings, the CustomResourceDefinition for SealedSecret.
The namespace owns: the keypair Secrets, the controller's Pods.

Deleting the namespace also deletes the controller's keys. Existing
SealedSecrets resources in other namespaces become un-decryptable
(see "Backup before uninstall" above).

We DO delete the namespace (unlike metrics-server which lives in
`kube-system`), because `sealed-secrets` is dedicated to this feature
and a clean uninstall should leave no trace.

## How to use

### Create a SealedSecret from scratch

```
echo -n "supersecret" \
  | kubectl create secret generic my-app-db --dry-run=client \
      --from-file=password=/dev/stdin -o yaml \
  | kubeseal --controller-namespace=sealed-secrets --format yaml \
  > my-app-db.sealed.yaml

git add my-app-db.sealed.yaml && git commit -m "feat: db creds"
kubectl apply -f my-app-db.sealed.yaml
# In ~5s, kubectl get secret my-app-db -n default shows the unsealed Secret.
```

### Re-seal across cluster rebuilds

If you destroy `k8s4` and rebuild, the new controller has fresh keys.
The committed `*.sealed.yaml` files no longer decrypt. Either:

- Re-encrypt from the original plaintext (most common in lab; you have
  the plaintext in your password manager / `.env.local` / wherever).
- Restore the old `sealed-secrets-keys-backup.yaml` before applying
  the SealedSecrets (only works if you backed up before tearing down).

### Verify in-cluster

```
kubectl -n sealed-secrets get pods
# sealed-secrets-XXXX-XXXX   1/1   Running

kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
# sealed-secrets-keyXXXX   kubernetes.io/tls   2 ...
```

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Uninstall destroys keys; operator forgets to back up. | Documented loudly in INIT-CLUSTER and in this companion. `uninstall.sh` does NOT print a warning at runtime (it would slow down clean reinstalls); the documentation is the safety net. |
| Chart version drift between `tools/cluster/sealed-secrets/chart-version.txt` and per-cluster `.env`. | install.sh emits `warn:` to stderr when they differ; `.env` always wins. Drift warning is structural-tested. |
| Chart 2.x → 3.x bump (if it ever happens) flips controller defaults. | helm-values.yaml pins `image.tag: 0.36.6` explicitly (bare semver). A chart that ignores `image.tag` is itself broken; a chart that uses it but bumps default elsewhere is caught by the structural assertions on the security context. |
| v-prefix accidentally re-introduced on `image.tag` (the bug we just fixed). | The structural test now rejects any `image.tag: v[0-9]` shape. The docker.io/bitnami/sealed-secrets-controller registry uses bare-semver tags exclusively since appVersion 0.25.0 (chart 2.14.2). |
| `kubeseal` CLI version drift vs controller version. | The devShell pins kubeseal via nixpkgs (the cluster flake's nixpkgs rev). Major drift is rare; minor drift between kubeseal 0.2x and controller 0.34 is harmless (the seal format is stable). |
| 30-day auto-rotation surprises an operator who deletes "old" Secrets thinking they're stale. | Documented in Key Management above. Old key Secrets MUST be kept for old SealedSecrets to keep decrypting. |
| Restricted PSA on the namespace might block a future feature that wants to deploy a sidecar to the controller. | The controller is a single Deployment with no sidecar requirements. If a future feature wants something more, it gets its own namespace. |

## Out of scope

- Operator-supplied keypair (Q4 (b)) — deferred. Trivial to add later:
  drop a key into `clusters/<name>/secrets/sealed-secrets.key`,
  install.sh server-side-applies it before helm install. Same shape as
  cert-manager's CA.
- HA replica count (`replicas: 2` + PDB) — 1+1 cluster doesn't justify
  the overhead; one-line bump in helm-values when we add workers.
- Ingress / external `kubeseal --fetch-cert` exposure — operators
  fetch the cert via `kubectl exec` or port-forward when needed.
- ServiceMonitor / Prometheus integration — observability is a later
  Phase-2 feature; pinned `false` here.
- Full e2e seal→apply→unseal cycle in the smoke. Better suited to a
  cross-cutting `ops.smoke-test` feature.
- Multi-cluster shared decrypt keys — only useful if we deploy across
  multiple clusters. Q4 (b) is the lever for this when needed.
- Per-namespace key scoping (`--namespace-scope`) — defaults are fine
  for our threat model.
