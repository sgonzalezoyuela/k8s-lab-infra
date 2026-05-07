# Companion: cluster.metallb-l2

## Why

Phase 2 of the lab cluster needs a working `Service` type=`LoadBalancer`
plane before anything user-facing makes sense (TLS endpoints, Longhorn UI,
future demo workloads). The lab runs on a single L2 broadcast domain on
Proxmox; there is no upstream BGP speaker to peer with. The natural fit is
**MetalLB in L2 mode** (ARP/NDP), driven from a single named `IPAddressPool`
seeded from `${METALLB_RANGE}` and surfaced by a matching `L2Advertisement`.

This feature wires that in without disturbing Phase 1: `just cluster-up`
remains a bare Talos+Kubernetes bring-up. Installing MetalLB is a separate
opt-in step the operator runs after the cluster is healthy, and is the
*first* opt-in service in Phase 2 (cert-manager and Longhorn build on top of
LB IPs).

The pool name (`default-pool`) and L2Advertisement name (`default-l2-adv`)
are deliberately hardcoded in the manifest templates, in contrast to
cert-manager's parameterized `CLUSTER_ISSUER_NAME`. MetalLB best practice
is a single named pool per cluster (multi-pool advertisements only matter
when you're slicing IPs by tenant/protocol, which the lab never will), so
parameterizing the names would only add ceremony.

## Source-of-truth decisions (locked-in)

| Decision | Value | Rationale |
|---|---|---|
| Mode | L2 (ARP/NDP) | Single broadcast domain on the lab network; no BGP speaker available; FRR is unnecessary complexity. |
| Pool name | `default-pool` (hardcoded in template) | Single-pool best practice; parameter ceremony saves nothing. |
| L2Advertisement name | `default-l2-adv` (hardcoded in template) | Same reason. |
| Pool source | `spec.addresses: ["${METALLB_RANGE}"]` (envsubst) | Single source of truth: `.env` defines the range, the template renders it. |
| Namespace | `metallb-system` | Upstream default; matches the chart's RBAC defaults. |
| Chart version pin | per-cluster via `METALLB_CHART_VERSION` in `.env`, default in `tools/.env.example` and bundled `chart-version.txt` | Same model as cert-manager; different clusters may upgrade independently. |
| Default chart version | `0.15.3` | Current upstream stable at the time of writing. |
| `v` prefix on the version | **No** (`0.15.3`, not `v0.15.3`) | The MetalLB chart numbers itself without the prefix. The structural test guards this explicitly so we don't accidentally re-use cert-manager's `v` style. |
| Phase | Opt-in (`just metallb-install`); NOT part of `cluster-up` | `cluster-up` should stay scoped to "I have a working K8s cluster"; MetalLB is workload-grade. |
| Pre-install validation | parse `METALLB_RANGE` as an IPv4 CIDR + assert neither `CP_IP` nor `WK0_IP` falls inside it | Catches the "I picked a range that overlaps my node IPs" mistake before MetalLB starts answering ARP for one of the node IPs (which would partition the cluster). |
| Speaker readiness gate | `kubectl rollout status daemonset/metallb-speaker --timeout=2m` | Pool config is meaningless until at least one speaker is ready to ARP for it. The `--wait` on `helm upgrade` covers the controller; the DaemonSet rollout covers the speaker. |
| Smoke test | `Service` type=LoadBalancer with **no selector / no backend**, wait ≤30s for `.status.loadBalancer.ingress[0].ip`, assert it's in `${METALLB_RANGE}`, delete | Cheapest possible exerciser; the contract under test is "MetalLB allocates an IP from the pool and surfaces it via Service status". We don't curl anything because there's nothing to curl. |
| Apply mode | `kubectl apply --server-side --field-manager=metallb-install` | Crisp idempotence: rerunning the recipe reports "unchanged" instead of churning ownership labels. |

## Files added

```
tools/cluster/metallb/
  install.sh                  # idempotent install entrypoint, with CIDR pre-validate
  uninstall.sh                # safe-to-rerun teardown
  smoke.sh                    # creates a no-backend LB Service, asserts IP-in-range
  helm-values.yaml            # controller + speaker enabled, CRDs enabled, no FRR
  ip-address-pool.yaml.tpl    # envsubst template — IPAddressPool/default-pool
  l2-advertisement.yaml.tpl   # plain manifest — L2Advertisement/default-l2-adv → default-pool
  chart-version.txt           # bundled-default chart version (0.15.3, no v prefix)
```

Edits:

```
tools/.env.example                        + METALLB_CHART_VERSION (next to METALLB_RANGE)
tools/Justfile                            + 3 [no-cd] recipes (metallb-install/-smoke/-uninstall)
tools/Makefile                            + bootstrap.config-scheme required vars (+METALLB_CHART_VERSION)
                                          + new test-cluster.metallb target wired into top-level test:
tools/docs/INIT-CLUSTER.md                + new "Phase 2: MetalLB (L2 mode)" subsection (positioned
                                            before cert-manager since it's the first opt-in service)
                                          + METALLB_CHART_VERSION row in the configuration table
README.md                                 + Phase 2 step in per-cluster workflow (metallb FIRST)
                                          + sudo ip route add reminder
clusters/k8s4/.env                        + METALLB_CHART_VERSION=0.15.3
```

## Pre-install validation rationale

The MetalLB pool is operator-supplied via `${METALLB_RANGE}`. Two classes of
mistake account for ~all observed L2-mode failures:

1. **CIDR overlaps a node IP.** If `METALLB_RANGE` includes `CP_IP` or
   `WK0_IP`, the speaker on the unlucky node will start answering ARP for
   the node's own IP. The result is a non-deterministic partition: the
   kube-apiserver becomes unreachable from outside, kubelet starts having
   weird heartbeat failures, and the user blames MetalLB. We block this at
   install time with a pure-bash CIDR check (`ip_to_int` + bitmask) that
   computes the network and broadcast for the range and asserts both node
   IPs fall outside `[net, bcast]`.
2. **Bad CIDR shape.** Typos like `10.4.200.0` (no prefix) or
   `10.4.200.0/33` are caught with a regex + range check. We also validate
   each octet is ≤255.

We deliberately do **not** verify L2 reachability between the speaker and
the gateway, or sniff for ARP collisions in the pool — those require live
traffic and are properly the domain of the smoke test. Pre-install
validation is strictly about catching mistakes that would brick the cluster
before any IP is advertised.

## Smoke approach

`smoke.sh` creates a `Service/mlb-smoke-test` in `default` of type
`LoadBalancer` with no selector and a single port (8080→8080). With no
selector, kube-proxy never installs forwarding rules, but MetalLB's
controller still allocates an IP from the pool and writes it to
`.status.loadBalancer.ingress[0].ip`. We poll that field for ≤30s, then
re-run the same `ip_to_int` + bitmask arithmetic from `install.sh` to
assert the assigned IP is inside `${METALLB_RANGE}`. The Service is
deleted on `trap EXIT` so even a failure leaves the cluster clean.

We don't `curl` the IP — there's no backend to curl. The contract under
test is "MetalLB allocates from the pool and surfaces the IP via
`Service.status`". Anything more (ARP from outside the cluster, host route,
end-to-end TCP) is rightly the operator's responsibility and would require
the host route documented in INIT-CLUSTER.md.

## Idempotence claims

| Action | Idempotence proof |
|---|---|
| Helm release | `helm upgrade --install metallb metallb/metallb` — same chart version, same values, no-op rollout. |
| `metallb-system` namespace | `--create-namespace` — no-op if it already exists. |
| Speaker rollout wait | `kubectl rollout status` returns immediately when the DaemonSet is already at desiredNumberScheduled. |
| `IPAddressPool/default-pool` | `envsubst < tpl \| kubectl apply --server-side` — emits "unchanged" when the spec is bit-identical. |
| `L2Advertisement/default-l2-adv` | Plain `kubectl apply --server-side` — same. |

Re-running `just metallb-install` after a clean install therefore produces
no spurious diffs and no rollout churn.

## Uninstall behavior

Order: L2Advertisement → IPAddressPool → Helm release → namespace. Each
step uses `--ignore-not-found` (or `helm uninstall ... 2>/dev/null || true`)
so the recipe can be re-run on an empty cluster without errors. The
advertisement is removed *before* the pool so we never leave a dangling
advertisement that references a nonexistent pool.

The namespace deletion is the long-pole; it cascades any remaining MetalLB
objects (CRDs survive — they live cluster-scoped and are managed by the
chart, so a fresh `metallb-install` re-uses them).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Operator picks a `METALLB_RANGE` that overlaps `CP_IP`/`WK0_IP` | `install.sh` fails fast with a clear error before touching the cluster. |
| Operator drift between `.env` chart version and bundled default | `install.sh` prints a `warn:` line when they differ. |
| Bundled chart version no longer exists upstream | `helm upgrade --install` will fail loudly; bumping requires editing both `chart-version.txt` and the relevant `.env`. INIT-CLUSTER.md and README.md document this. |
| Workstation can't reach `${METALLB_RANGE}` IPs | Out-of-band: the operator must `sudo ip route add ${METALLB_RANGE} via ${CP_IP}` once. The dev shell banner reminds them; INIT-CLUSTER.md documents it under "Reaching the LoadBalancer IPs". |
| ARP wars from another MetalLB / VRRP / KeepAliveD on the same L2 | Out of scope. The lab network is single-tenant; if a second L2 announcer ever appears we'll detect it via duplicate ARP replies during smoke. |
| Smoke test 30s timeout on a slow cluster | Increase if it bites; allocation is sub-second on the lab. |

## Out of scope

- **BGP mode.** Requires an upstream peer; the lab has none. If we ever
  grow to BGP, the natural shape is a sibling `tools/cluster/metallb-bgp/`
  with its own templates and a different feature id; the L2 assets stay
  untouched.
- **Multi-pool / per-tenant slicing.** A single pool covers everything we
  need. Adding more pools is straightforward (drop in another
  `IPAddressPool` + `L2Advertisement`) but not part of this feature.
- **FRR.** Disabled in `helm-values.yaml`; only relevant in BGP mode.
- **External traffic policy / source IP preservation.** Workload-level
  concerns; left to the per-Service spec.
- **Backup of MetalLB state.** Stateless: everything reproduces from
  `.env` + the templates.
- **cert-manager / Longhorn.** Separate Phase-2 features.
