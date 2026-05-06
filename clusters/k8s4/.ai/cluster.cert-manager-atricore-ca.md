# Companion: cluster.cert-manager-atricore-ca

## Why

Phase 2 of the lab cluster needs a working PKI plane. The lab CA already
exists (operator-supplied at `clusters/<name>/secrets/{ca.crt,ca.key}`), so
the natural fit is cert-manager driving a CA-backed `ClusterIssuer`. This
feature wires that in without disturbing Phase 1 (`just cluster-up` stays a
bare Talos+Kubernetes bring-up). Installing cert-manager is a separate
opt-in step the operator runs after the cluster is healthy.

The issuer name is parameterized so the same shared `tools/` library can be
reused by clusters that prefer a different convention. The default,
`atricore-ca`, replaces the older `own-ca` placeholder name that appeared in
docs but never had any code behind it.

## Source-of-truth decisions (locked-in)

| Decision | Value | Rationale |
|---|---|---|
| ClusterIssuer name | env var `CLUSTER_ISSUER_NAME`, default `atricore-ca` | Lets every cluster pick a meaningful name without forking `tools/`. |
| TLS Secret name | same as `CLUSTER_ISSUER_NAME` | One name to remember; Secret and ClusterIssuer track 1:1. |
| Namespace | `cert-manager` | Upstream default; matches the leader-election config we ship in `helm-values.yaml`. |
| Chart version pin | per-cluster via `CERT_MANAGER_CHART_VERSION` in `.env`, default in `tools/.env.example` and bundled `chart-version.txt` | Different clusters may upgrade at different speeds. The bundled `chart-version.txt` is the recommended default; `.env` wins at install time, with a warning on drift. |
| Default chart version | `v1.16.2` | Current upstream stable at the time of writing. |
| Phase | Opt-in (`just cert-manager-install`); NOT part of `cluster-up` | `cluster-up` should stay scoped to "I have a working K8s cluster"; cert-manager is workload-grade. |
| Smoke test | issues a real `Certificate`, waits `Ready=True` ≤60s | Validates issuance end-to-end. We do **not** verify the chain with `openssl` — Ready=True from cert-manager is the contract that matters. |
| Pre-install validation | `openssl x509 -pubkey \| openssl md5` vs `openssl pkey -pubout \| openssl md5`, plus 60-day expiry warning | Catches the most common operator mistakes (wrong key, expired CA) before touching the cluster. Pubkey-hash compare works for RSA, EC, and ed25519. |
| Apply mode | `kubectl apply --server-side --field-manager=cert-manager-install` | Crisp idempotence: rerunning the recipe reports "unchanged" instead of churning ownership labels. |

## Files added

```
tools/cluster/cert-manager/
  install.sh             # idempotent install entrypoint
  uninstall.sh           # safe-to-rerun teardown
  smoke.sh               # issues + waits on a throwaway Certificate
  helm-values.yaml       # installCRDs, no prometheus, namespaced leader election
  cluster-issuer.yaml.tpl  # envsubst template, references CLUSTER_ISSUER_NAME
  chart-version.txt      # bundled-default chart version (v1.16.2)
```

Edits:

```
tools/.env.example                        + CLUSTER_ISSUER_NAME, CERT_MANAGER_CHART_VERSION
tools/Justfile                            + 3 [no-cd] recipes
tools/Makefile                            + bootstrap.config-scheme required vars
                                          + new test-cluster.cert-manager target
                                          + wired into top-level test:
tools/docs/INIT-CLUSTER.md                Phase 2 own-ca → atricore-ca; new subsection
README.md                                 + Phase 2 step in per-cluster workflow
clusters/k8s4/.env                        + CLUSTER_ISSUER_NAME, CERT_MANAGER_CHART_VERSION
```

## Pre-install validation rationale

The CA materials are operator-supplied and live outside source control.
Three classes of mistake account for ~all observed failures:

1. **Mismatched cert/key.** Operator copies a stale `ca.key` next to a fresh
   `ca.crt` (or vice versa). cert-manager will accept the Secret but every
   issued cert fails to validate. We catch this by hashing the public key
   from each side and comparing — pubkey hashes match iff cert and key are
   the same pair, regardless of algo (RSA, EC, ed25519).
2. **Expired or near-expired CA.** Once the CA expires every issued cert is
   immediately invalid. We don't fail the install for `< 60 days`, just
   warn — the operator may legitimately be testing a renewal flow.
3. **Wrong path / unreadable file.** Cheap `[ -r "$path" ]` checks up front
   beat a kubectl secret push that mostly succeeds and then blows up later.

We deliberately do **not** verify the cert chain or hostnames in
pre-validation: that's a one-CA self-signed setup; chain-of-trust is exactly
"this cert".

## Smoke approach

`smoke.sh` issues a `Certificate` named `cm-smoke-test` in `default` with
`dnsNames: smoke.${CLUSTER_DOMAIN}`, `duration: 24h`, `issuerRef:
ClusterIssuer/${CLUSTER_ISSUER_NAME}`. It waits up to 60s for
`Ready=True`. The Certificate and its TLS Secret are deleted on exit (via
`trap cleanup EXIT`, with `--ignore-not-found --wait=false`).

We don't `openssl s_client` against anything — the cert never gets served.
The criterion for "the issuer works" is "cert-manager signed it"; cert-manager
itself is the only thing that can produce a `Ready=True` Certificate from a
CA Issuer.

## Idempotence claims

| Action | Idempotence proof |
|---|---|
| Helm release | `helm upgrade --install` — same chart version, same values, no-op rollout. |
| `cert-manager` namespace | `--create-namespace` — no-op if it already exists. |
| TLS Secret | `kubectl create secret tls ... --dry-run=client -o yaml \| kubectl apply --server-side` — server-side apply emits "unchanged" when the spec is bit-identical. |
| ClusterIssuer | `envsubst < tpl \| kubectl apply --server-side` — same. |
| `cmctl check api --wait=2m` | Read-only health probe. |

Re-running `just cert-manager-install` after a clean install therefore
produces no spurious diffs and no rollout churn.

## Uninstall behavior

Order: ClusterIssuer → Secret → Helm release → namespace. Each step uses
`--ignore-not-found` (or `helm uninstall ... 2>/dev/null || true`) so the
recipe can be re-run on an empty cluster without errors.

The namespace deletion is the long-pole; it cascades all remaining
cert-manager objects.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Operator drift between `.env` chart version and bundled default | `install.sh` prints a `warn:` line when they differ. |
| Bundled chart version no longer exists upstream | `helm upgrade --install` will fail loudly; bumping requires editing both `chart-version.txt` and the relevant `.env`. README + INIT-CLUSTER.md document this. |
| User CA expires silently mid-quarter | 60-day warning at install time; nothing else nudges the operator yet (a periodic check is out of scope). |
| Smoke test hits a 60s timeout on a slow cluster | Increase timeout if it bites; for the lab cluster issuance is sub-second. |
| `cmctl check api --wait=2m` on an unhealthy cluster blocks | Acceptable — that's the symptom we want surfaced. |
| Re-running uninstall while the namespace is mid-terminating | `kubectl delete namespace --ignore-not-found` is a no-op on a missing namespace; on a terminating namespace it just re-issues the same delete, which is harmless. |

## Out of scope

- ACME / Let's Encrypt issuers (this lab uses a private CA only).
- DNS-01 / HTTP-01 solvers (CA Issuer doesn't need them).
- A `Certificate` for the cert-manager webhook itself (the chart handles its own webhook PKI via cainjector).
- Periodic CA-expiry watch (job, alert, etc.). Today we only warn at install time.
- MetalLB / Longhorn — separate Phase-2 features.
- Backup of the CA materials. The operator owns `secrets/`.
