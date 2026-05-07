# cluster.metrics-server — Implementation Guide

## Why

`kubectl top nodes`, `kubectl top pods`, and the HorizontalPodAutoscaler
controller all read from the aggregated `metrics.k8s.io/v1beta1` API. That
API is not in core Kubernetes — it is registered by metrics-server, a
small controller that scrapes each kubelet's `/metrics/resource` endpoint
on a tight cadence and exposes the rolled-up CPU/memory numbers via the
APIService aggregation layer.

Without it:

- `kubectl top` errors out with `Metrics API not available`.
- HPA objects sit in `<unknown>` forever and never scale.
- Operator-side capacity questions ("which pod is hot?") have no answer
  short of `kubectl exec ... ps`.

This feature lands the kubernetes-sigs/metrics-server Helm chart with
**Talos-specific kubelet args** and **restricted-grade pod security**, so
it works out of the box on Talos and survives a future PSA enforcement
sweep on `kube-system`.

## Source-of-truth decisions (locked in)

| Decision | Value | Rationale |
|---|---|---|
| Helm chart | `metrics-server/metrics-server` | Upstream kubernetes-sigs chart; the de-facto standard. |
| Repo URL | `https://kubernetes-sigs.github.io/metrics-server/` | Same source as the chart's release artifacts. |
| Chart version | `3.13.0` (pins app `v0.8.0`) | Current stable; supports `--metric-resolution`, restricted-PSA-friendly defaults, drops the legacy `nanny` sidecar. |
| Namespace | `kube-system` | Canonical home for cluster system add-ons (CoreDNS, kube-proxy, every managed cloud's metrics-server). We do **not** create or label the namespace — kube-system is system-managed and labelling it would race with Talos's controllers. Pod is restricted-grade through `containerSecurityContext`, which is the layer that matters in an unlabelled namespace. |
| Kubelet TLS | `--kubelet-insecure-tls` | Talos rotates kubelet serving certs signed by a per-node CA that lives in machined's secret store — non-trivial to surface in the metrics-server pod. Trust boundary is the cluster network. Same default as k3s/EKS/GKE/AKS metrics-server installs. |
| Address types | `--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP` | Cluster has no DNS for short Hostnames `cp` / `wk0`; default order tries Hostname first and times out. InternalIP first → first dial succeeds. |
| Replicas | `1` | 1+1 cluster — no point running 2 replicas with one worker. HA upgrade (`replicas: 2` + `pdb.create=true`) is a one-line bump when we add workers. |
| `apiService.create` | `true` | Whole point of the chart; pinned explicitly so a future chart default flip can't break it silently. |
| Smoke approach | helm status + APIService Available | Minimal. No `kubectl top` polling — the kubelet scrape window is 15s so `top` lags 30–60s after install; that wait belongs to the operator, not the smoke. |
| ServiceMonitor / Prometheus | `false` | Observability lands in a later feature; we don't want a Prometheus scrape pointing at a non-existent target. |

## Files added

```
tools/cluster/metrics-server/
├── install.sh           helm repo add/update + helm upgrade --install + APIService wait
├── uninstall.sh         helm uninstall (kube-system left intact)
├── smoke.sh             helm status + kubectl wait APIService Available
├── helm-values.yaml     args, securityContext, apiService.create, replicas
└── chart-version.txt    bundled-default chart version (3.13.0)
```

Edits:

- `tools/.env.example` — declares `METRICS_SERVER_CHART_VERSION=3.13.0`.
- `tools/Justfile` — three `[no-cd]` recipes: `metrics-install`,
  `metrics-smoke`, `metrics-uninstall`. Install/smoke depend on `env-check`.
- `tools/Makefile` — adds `METRICS_SERVER_CHART_VERSION` to
  `bootstrap.config-scheme`'s required-vars list, adds
  `test-cluster.metrics-server`, wires it into `test:`.
- `tools/docs/INIT-CLUSTER.md` — full Phase 2 subsection (prereqs,
  install, verify, smoke, uninstall, Talos gotchas, HPA example),
  configuration table extended.
- `README.md` — Phase 2 step 5 in the per-cluster workflow snippet.
- `clusters/k8s4/.env` — per-cluster pin `METRICS_SERVER_CHART_VERSION=3.13.0`.

## Talos-specific gotchas

### `--kubelet-insecure-tls`

Talos signs each kubelet's serving cert with a per-node CA generated at
machine-config time. That CA is not at `/etc/kubernetes/pki/` and is not
mounted into pods by default; getting it into metrics-server would
require either:

- a DaemonSet that talks to machined to read the per-node CA, then
  publishes it as a ConfigMap (entire side-feature), or
- enabling `serverTLSBootstrap` on the kubelet and standing up a
  certificate signer that issues by-IP certs (more moving parts than the
  scrape itself).

Neither is justifiable when the trust boundary we care about is **the
cluster network**, not the metrics-server-to-kubelet hop. kubelet
listens on `10250` only on the node's network interface; reaching it
requires being on the pod network already, at which point you're inside
the trust boundary by definition. EKS, GKE, AKS, k3s, and Talos's own
recommended metrics-server deployment all use `--kubelet-insecure-tls`
for the same reason.

### `--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP`

metrics-server resolves "which kubelet do I scrape for node N" by
walking `node.status.addresses` in this preferred order. Chart default is
`Hostname,InternalDNS,InternalIP,ExternalIP`. Our nodes register with:

```
status.addresses:
  - type: Hostname
    address: cp                         # short, no DNS
  - type: InternalIP
    address: 10.4.0.1
```

Trying `https://cp:10250` first means a 5–10s DNS-resolution timeout per
node per scrape window, eventually falling through to InternalIP and
succeeding. Putting InternalIP first cuts every scrape to one
successful dial.

## Smoke approach (minimal)

```
helm -n kube-system status metrics-server
kubectl wait --for=condition=Available --timeout=60s apiservice/v1beta1.metrics.k8s.io
```

Two assertions, both observable, both fast:

1. The Helm release is actually deployed in `kube-system` (catches the
   "operator forgot to run install" / "operator on the wrong cluster"
   class of failure).
2. The APIService is `Available=True`. That condition is what `kubectl
   top` and HPA actually consume; if it's flipping, the Deployment is
   broken even if its rollout finished.

We deliberately do **not** poll `kubectl top nodes` here. The kubelet
scrape window is 15s (`--metric-resolution=15s`), so `top` typically
lags 30–60s behind a fresh install before it surfaces numbers. Folding
that wait into the smoke makes it slow and flaky for no real signal —
the operator is going to run `kubectl top` manually as part of "did
this work?" anyway, and that's fine.

## Idempotence claims

- `helm upgrade --install` against an already-installed release with
  unchanged chart version + values produces a no-op revision and the
  Deployment's `spec` does not change → no pod restart.
- `kubectl wait --for=condition=Available` is read-only and re-runnable.
- The drift warning ("`.env` differs from `chart-version.txt`") is
  emitted to stderr but does not change behaviour; the `.env` value
  always wins so install.sh remains deterministic.

Re-running `just metrics-install` with the same `.env` → exit 0, no
state change.

## Uninstall behavior

`helm uninstall metrics-server -n kube-system 2>/dev/null || true`.

The Helm release owns: Deployment, Service, ServiceAccount, the two
ClusterRoles (`system:metrics-server` and the aggregator one),
ClusterRoleBindings, the RoleBinding into `kube-system`, and the
APIService. Uninstall removes all of them.

We do **not** delete the namespace — `kube-system` is system-managed.
The `|| true` makes the recipe safe to re-run when nothing is installed
(helm exits non-zero if the release is already gone).

## How to use

### `kubectl top` examples

```
$ kubectl top nodes
NAME                          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
cp.k8s4.lab.atricore.io       142m         3%     1654Mi          41%
wk0.k8s4.lab.atricore.io      221m         2%     2143Mi          26%

$ kubectl top pods -A --sort-by=memory
NAMESPACE        NAME                                              CPU(cores)   MEMORY(bytes)
kube-system      kube-apiserver-cp.k8s4.lab.atricore.io            45m          343Mi
ingress-nginx    ingress-nginx-controller-7c5...                   3m           67Mi
```

### Minimal HPA (scale a Deployment by CPU)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app
  namespace: my-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

`kubectl get hpa -n my-app` should populate `TARGETS` (e.g. `12%/70%`)
within 30–60s of creation. This mirrors the cert-manager
`cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER_NAME}` annotation flow
in spirit: declarative add-on, no operator-side wiring, the controller
does the work.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Chart version drift between `tools/cluster/metrics-server/chart-version.txt` and per-cluster `.env`. | install.sh emits a `warn:` to stderr when they differ; `.env` always wins. The drift warning is structural-tested. |
| `--kubelet-insecure-tls` is sometimes flagged by security review. | The trust boundary is documented (in helm-values.yaml comments, in INIT-CLUSTER.md, in this companion). Same posture as every managed cloud's metrics-server. If a future feature lands cluster-wide kubelet serving cert distribution, this flag flips to a one-line removal. |
| `kubectl top` shows nothing for ~30–60s after install. | Documented in the verify step. Smoke deliberately doesn't gate on it; the APIService Available condition is the real success signal. |
| Chart 3.13 → 3.14 bumps may flip a default that breaks our pinned values (e.g. `metrics.enabled` chart-side metrics surface). | Both `metrics.enabled` and `serviceMonitor.enabled` are pinned to `false` explicitly. The structural test asserts the kubelet args, restricted securityContext, and the APIService config, so a chart bump that changes any of those fails CI. |
| metrics-server pod evicted by kubelet if cluster is genuinely starving (its own resource requests are tiny but non-zero). | Out of scope. If we get there, bump to 2 replicas + a PDB; that's a one-line change in helm-values.yaml (and the structural test will need to follow). |

## Out of scope

- HPA examples shipped as YAML in this tree (the doc has one snippet;
  that's enough — apps own their HPAs).
- VPA (vertical-pod-autoscaler) — separate operator, separate feature.
- ServiceMonitor / Prometheus integration — observability is a later
  Phase-2 feature; pinned `false` here.
- Custom metrics adapter (`autoscaling/v2` non-Resource metrics) —
  separate operator, separate feature, not commonly needed in a lab.
- HA replicas (`replicas: 2` + PDB) — flips on naturally when we add a
  second worker; not worth it on a 1+1 cluster.
- Mounting Talos's per-node kubelet CA into the pod to drop
  `--kubelet-insecure-tls` — see the gotchas section; out of scope until
  there is a justifying threat model.
