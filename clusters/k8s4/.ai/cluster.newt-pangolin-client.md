# Companion: cluster.newt-pangolin-client

## Why

The lab needs an outbound-only entry point so workloads behind the cluster's
default LAN can be reached from the public internet without poking holes in
the lab firewall, taking out a public IP, or running a kernel-mode VPN on
the nodes. **[Pangolin](https://github.com/fosrl/pangolin)** is a
self-hosted reverse proxy / tunnel server that solves that shape:
**[newt](https://github.com/fosrl/newt)** runs *inside* the cluster, dials
out to the Pangolin server over HTTPS+WSS, and tunnels per-resource traffic
back over a userspace WireGuard datapath. Pangolin terminates inbound
traffic on the public side — nothing inbound ever reaches the cluster from
this stack.

This feature wires that in as a single-Deployment Phase-2 recipe:
`newt-install` / `newt-smoke` / `newt-uninstall`. It is deliberately
**independent** of MetalLB and cert-manager (newt does not need
LoadBalancer IPs or cluster-issued TLS — its TLS is the public Pangolin
endpoint's, not ours), and it is **not** part of `just cluster-up`.

There is **no** official Helm chart for newt, and a chart for a
two-resource (Secret + Deployment) install would be more boilerplate than
content. We render plain manifests via `envsubst` + `kubectl apply
--server-side`, the same shape used by metallb's `IPAddressPool` and
cert-manager's `ClusterIssuer` template.

## Source-of-truth decisions (locked-in)

| Decision | Value | Rationale |
|---|---|---|
| Helm vs raw manifests | Raw manifests via `envsubst` + `kubectl apply --server-side` | No upstream chart; Secret + Deployment is too small to chart by hand. |
| Image source | `fosrl/newt:${NEWT_IMAGE_TAG}` | Upstream's published Docker image. |
| Default image tag | `1.12.3` (in `tools/cluster/newt/image-tag.txt`, also `tools/.env.example` and `clusters/k8s4/.env`) | Current upstream stable at the time of writing. |
| `v` prefix on the tag | **No** (`1.12.3`, not `v1.12.3`) | fosrl/newt's container tags are bare semver. The structural test guards this so we don't drift toward cert-manager's `v` style. |
| Namespace | `newt` (created by `newt-install`) | One-purpose namespace; clean PSA boundary; matches the metallb / cert-manager precedent. |
| PSA profile | `restricted` (enforce + audit + warn) | newt is fully userspace: `wireguard-go` (netstack mode) needs no `NET_ADMIN`, no host network, no `/dev/net/tun`. Restricted is the strictest profile and a perfect fit. |
| Update strategy | `Recreate` (NOT `RollingUpdate`) | A Pangolin site only accepts ONE concurrent newt connection. RollingUpdate would briefly run two pods racing for the WebSocket → flapping. Recreate gives a clean stop-then-start. |
| Replica count | `1` | Per above; running two replicas would partition the WebSocket. |
| Credential transport | `.env` → `kubectl create Secret` (server-side apply from `secret.yaml.tpl`), Pod consumes via `envFrom: secretRef: newt-credentials` | Keeps the operator-facing knob to the same `.env` flow as everything else. No External Secrets, no Vault. |
| Credential placeholder sentinel | `REPLACE-ME-FROM-PANGOLIN-UI` (in `clusters/k8s4/.env`) | Non-empty so `env-check` passes, but `install.sh` detects the literal string and refuses to apply. Catches the "I copied .env.example, ran cluster-up, then ran newt-install" mistake. |
| Service / Ingress | None | Egress-only stack. Nothing inbound, nothing to expose. |
| Metrics | Container port `2112` declared, no Service / ServiceMonitor | The port is the upstream default; declaring it is structural-test-cheap and harmless. Wiring Prometheus is out of scope. |
| Smoke test | `kubectl rollout status` (60s) + log-grep for `Connecting to endpoint:` (≤30s) with diagnostic hints on timeout | The only externally observable, fast signal that the credentials worked AND Pangolin reciprocated. Anything stronger (curl through the tunnel) requires Pangolin-side fixtures we don't have here. |
| Apply mode | `kubectl apply --server-side --field-manager=newt-install` | Crisp idempotence: re-running reports "unchanged" instead of churning ownership. |
| Phase | Opt-in (`just newt-install`); NOT part of `cluster-up`; independent of metallb + cert-manager | `cluster-up` should stay scoped to "I have a working K8s cluster". newt is workload-grade, and unlike metallb / cert-manager it has no other Phase-2 service depending on it. |

## Files added

```
tools/cluster/newt/
  install.sh                  # idempotent install entrypoint, with URL + REPLACE-ME pre-validate
  uninstall.sh                # safe-to-rerun teardown (Deployment, Secret, namespace)
  smoke.sh                    # rollout status + log-grep "Connecting to endpoint:"
  namespace.yaml              # static — kind: Namespace name: newt + restricted PSA labels
  secret.yaml.tpl             # envsubst template — kind: Secret name: newt-credentials, three stringData keys
  deployment.yaml.tpl         # envsubst template — kind: Deployment name: newt, Recreate, hardened securityContext
  image-tag.txt               # bundled-default image tag (1.12.3, no v prefix)
```

Edits:

```
tools/.env.example                        + 4 keys (PANGOLIN_ENDPOINT, NEWT_ID, NEWT_SECRET, NEWT_IMAGE_TAG)
                                            NEWT_ID/NEWT_SECRET ship empty so init-config prompts.
tools/Justfile                            + 3 [no-cd] recipes (newt-install/-smoke/-uninstall)
                                          + init-config prompt list extended (PROXMOX_API_TOKEN_SECRET → +NEWT_ID, +NEWT_SECRET)
tools/Makefile                            + bootstrap.config-scheme required vars (+4 newt keys)
                                          + new test-cluster.newt target wired into top-level test:
                                          + fixtures (env-check / init-config / infra-render / talos-config)
                                            now also fill NEWT_ID and NEWT_SECRET so env-check passes
tools/docs/INIT-CLUSTER.md                + new "Phase 2: newt (Pangolin tunnel client)" subsection
                                            (positioned after cert-manager, before the loadbalancer-route note)
                                          + 4 new env keys in the configuration table
README.md                                 + Phase 2 step in per-cluster workflow with REPLACE-ME caveat
clusters/k8s4/.env                        + 4 keys with REPLACE-ME placeholders for ID/SECRET
clusters/k8s4/.ai/cluster.newt-pangolin-client.md  fully rewritten (this file)
```

## Pre-install validation rationale

`install.sh` has two cheap, high-value gates before it touches the cluster:

1. **`PANGOLIN_ENDPOINT` URL shape.** The variable must start with `http://`
   or `https://`. Catches operators who paste a hostname or accidentally
   drop the scheme — newt's HTTP client would otherwise produce a
   confusing connect error inside the pod, and the operator would chase
   networking instead of `.env`.
2. **REPLACE-ME placeholder detection.** `clusters/k8s4/.env` ships
   `NEWT_ID=REPLACE-ME-FROM-PANGOLIN-UI` and
   `NEWT_SECRET=REPLACE-ME-FROM-PANGOLIN-UI` so that `just env-check` does
   not block adoption (those values are non-empty). But the literal string
   is a sentinel: if `install.sh` sees it in either variable, it fails
   fast with an explicit "go to your Pangolin site UI and paste the real
   values" message. This catches the "I just ran cluster-up, then
   newt-install, what's wrong" sequence cleanly.

We deliberately do **not**:

- Try to validate the credentials against Pangolin (would require curling
  the endpoint with them, which is what newt does anyway; we'd be racing
  newt's own first request).
- Try to validate that `PANGOLIN_ENDPOINT` is reachable from the operator
  workstation (it might not be — the cluster's egress can differ from the
  operator's). The smoke test is the right place for that.

## Smoke approach

`smoke.sh` does two things, in order:

1. **`kubectl rollout status deployment/newt --timeout=60s`.** Confirms
   the pod is past `ImagePullBackOff` / `CrashLoopBackOff` / PSA admission
   denial. If this fails, the reason is structural and the operator should
   look at `kubectl describe pod` first.
2. **Poll logs for `"Connecting to endpoint:"` for ≤30s.** This literal
   line is emitted by newt 1.12.x at INFO level **only** after:
     a. HTTPS auth to `PANGOLIN_ENDPOINT` succeeded
        (`NEWT_ID`/`NEWT_SECRET` accepted),
     b. the WebSocket upgrade completed,
     c. Pangolin pushed back the `wg/connect` control message with the
        peer descriptor for the userspace WireGuard tunnel.
   So observing it is a strong end-to-end signal: the credentials are
   right *and* Pangolin reciprocated. On timeout, smoke prints the last 30
   log lines plus three diagnostic hints (credential typo, egress
   reachability, another newt already attached to the same site) and
   exits 1.

We deliberately do **not** curl through the tunnel: there's no Pangolin
test fixture on the public side that we own. The contract under test is
"newt authenticated and Pangolin replied", which is exactly what the log
line proves.

## Idempotence claims

| Action | Idempotence proof |
|---|---|
| Namespace creation | `kubectl apply --server-side -f namespace.yaml` — emits "unchanged" when the labels match. |
| Credential Secret | `envsubst < secret.yaml.tpl \| kubectl apply --server-side` — emits "unchanged" when none of `PANGOLIN_ENDPOINT`/`NEWT_ID`/`NEWT_SECRET` changed in `.env`. |
| Deployment | `envsubst < deployment.yaml.tpl \| kubectl apply --server-side` — same; only an `NEWT_IMAGE_TAG` bump (or template edit) produces a real diff and a Recreate-style roll. |
| Rollout wait | `kubectl rollout status deployment/newt --timeout=2m` — returns immediately when the Deployment is already at desired/observed parity. |

Re-running `just newt-install` after a clean install therefore produces no
spurious diffs and no rollout churn. The `--field-manager=newt-install`
tag keeps server-side apply ownership clean.

## Uninstall behavior

Order: `Deployment/newt` → `Secret/newt-credentials` → `Namespace/newt`.
Each step uses `--ignore-not-found`, so the recipe is safe to run on an
empty cluster. We delete the Deployment first so the pod terminates
(closing its WebSocket cleanly on the Pangolin side) before its
credentials disappear; deleting the Secret first would leave the pod
running with stale env on its next restart.

There are no CRDs to leave behind. The namespace deletion cascades any
remaining objects.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Operator forgets to replace `REPLACE-ME-FROM-PANGOLIN-UI` | `install.sh` fails fast with an actionable message before touching the cluster. |
| `readOnlyRootFilesystem: true` breaks newt because it writes to `/` at runtime | Newt 1.12.x is verified to work with read-only root in netstack mode; the smoke test will catch a regression in a future image as a rollout failure or a missing log line. If a future tag needs `/tmp`, the fix is to add `volumes: [{ name: tmp, emptyDir: {} }]` + `volumeMounts: [{ name: tmp, mountPath: /tmp }]` to the Deployment template — readOnlyRootFilesystem stays. |
| The literal `Connecting to endpoint:` log line changes in a future newt | Image tag is pinned to 1.12.3; bumps are deliberate. When bumping `NEWT_IMAGE_TAG`, the smoke test acts as a canary — if the line moved, smoke fails fast and the operator updates `smoke.sh` in lockstep. |
| Operator drift between `.env` image tag and bundled default | `install.sh` prints a `warn:` line when they differ (same UX as metallb/cert-manager). |
| Two pods race the same Pangolin site (e.g. `kubectl scale deploy/newt --replicas=2`) | `strategy.type: Recreate` covers the rolling-upgrade case. Manual scaling above 1 is operator error; smoke would notice it as flapping `Connecting to endpoint:` lines but does not actively prevent it. Documented in INIT-CLUSTER.md "Security model". |
| `NEWT_SECRET` rotation needs a clean handover | Documented in INIT-CLUSTER.md "Rotation" subsection: edit `.env` → `just newt-install`. The server-side-apply Secret bumps `resourceVersion`; the Recreate strategy guarantees the old pod terminates before the new one authenticates. |
| Egress firewall blocks HTTPS/WSS to `PANGOLIN_ENDPOINT` | Smoke times out on the log probe. The hints message tells the operator to check DNS + egress firewall. Out-of-scope to autodiagnose. |
| Pangolin server unavailable / wrong endpoint | Same path: smoke timeout, hints message, operator fixes `.env`. |
| `.env` accidentally committed | `.env` is gitignored (covered by `bootstrap.config-scheme`); REPLACE-ME placeholders mean even the example values aren't real credentials. |

## Out of scope

- **Pangolin server itself.** This recipe assumes a working Pangolin server
  exists somewhere reachable. Setting one up (Docker, public IP, ACME
  TLS, site provisioning UI) is out of scope; it's a different deployment
  target entirely.
- **`ServiceMonitor` for the `:2112` metrics port.** The port is declared
  on the container so a future Prometheus install can scrape it, but we
  don't ship a `Service` or `ServiceMonitor`. Wiring Prometheus is its own
  Phase-2 feature.
- **mTLS / mutual auth between newt and Pangolin.** newt 1.12.x uses
  `NEWT_ID` + `NEWT_SECRET` over HTTPS; no client-cert mode. If upstream
  adds one, that's a future tag bump + template edit.
- **Multiple newt instances per cluster.** Pangolin assumes one
  newt-per-site. If a site needs HA on the cluster side, the right answer
  is two sites with two newt Deployments in two namespaces — not two
  replicas of one Deployment. We don't pre-build that ceremony.
- **Provisioning-key flow.** Some Pangolin deployments use a one-time
  provisioning key instead of long-lived `NEWT_ID`/`NEWT_SECRET`. We use
  the long-lived flow (matches the typical site-create UI). If we ever
  need provisioning keys, the right shape is an extra `.env` variable +
  template branch in `secret.yaml.tpl`.
- **Backup of newt state.** Stateless: everything reproduces from `.env`
  + the templates. The pod's read-only root filesystem makes this
  trivially true.
- **`just cluster-up` integration.** Intentional: `cluster-up` stays
  scoped to "bare K8s on Talos". Phase-2 services are operator-driven.
- **MetalLB / cert-manager / Longhorn.** Separate Phase-2 features, none
  of which depend on newt and vice versa.
