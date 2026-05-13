# cluster.local-path-provisioner — Implementation Guide

## Why

Out-of-the-box Talos exposes no general-purpose StorageClass. PVCs sit
`Pending` forever, which blocks the whole "PVC-aware workload" story
(stateful apps, helper-driven tools that want a scratch volume, the
sealed-secrets backup we now need to do explicitly, …).

Rancher local-path-provisioner is the classic minimum-viable answer:
a single Deployment watches PVCs and provisions host-local directories
under a configured path. Volume binding mode is `WaitForFirstConsumer`,
so a PVC binds only after a Pod gets scheduled — which lets the
provisioner pick the right node, then mkdir the directory there.

Talos's twist: the kubelet runs in its own container, so a `hostPath`
volume Pod-side does NOT see the actual host filesystem. The
provisioner's helper pods (the short-lived workers that mkdir/rmdir the
backing directories) need their `hostPath` to be a *real* host mount.
Talos solves this with `machine.kubelet.extraMounts`: declare a bind
mount, with `rshared` propagation, between a host path and the same
path inside the kubelet container, and host-rooted hostPath volumes
then traverse it correctly.

We add that single mount, point local-path-provisioner at the same
host path (`/var/local-path-provisioner`), make its StorageClass the
cluster default, and stop. Longhorn (planned) can flip the default
later.

## Source-of-truth decisions (locked in)

| Decision | Value | Rationale |
|---|---|---|
| Upstream | rancher/local-path-provisioner | The canonical lightweight provisioner. |
| Pin | `v0.0.31` | Most recent stable upstream tag (May 2025). Bumps require re-vendoring the manifest and updating `version.txt` + `.env`. |
| Install method | `kubectl apply -k` (kustomize overlay over vendored manifest) | Upstream ships raw YAML, not a Helm chart. Vendoring the YAML keeps the source visible and pinnable; overlay applies our three tweaks. |
| Host path | `/var/local-path-provisioner` | User-specified; under `/var` (the conventional location for runtime variable state) rather than `/opt` (upstream default). Requires the Talos kubelet extraMount with `rshared` propagation. |
| StorageClass | `local-path` | Upstream-default name; matches the public ecosystem (helm charts that document a `storageClassName: local-path` example just work). |
| Default class | `is-default-class: "true"` | Phase-2 lab convenience: a PVC with no explicit `storageClassName` binds against local-path. Longhorn's future install will flip this annotation off. |
| Namespace | `local-path-storage` | Upstream-default. Labelled `pod-security.kubernetes.io/enforce: privileged` because helper pods use `hostPath` — restricted/baseline forbid it. The controller Deployment itself is restricted-grade, but the helper pods are not. We accept the privileged label on the ns boundary, scope to one ns, and rely on RBAC/network-policy (out of scope) for further isolation. |
| Volume binding | `WaitForFirstConsumer` (upstream default) | Required for node-local storage; if it bound immediately, the PVC might be scheduled on a node where the provisioner can't mkdir. |
| Reclaim policy | `Delete` (upstream default) | Matches expectations for ephemeral lab workloads. Operators wanting Retain can clone the StorageClass. |
| Smoke approach | PVC + Pod that writes-then-reads | The only meaningful smoke for storage is "can I actually write?". `WaitForFirstConsumer` makes mere PVC-create + status-Bound insufficient — the binding doesn't happen until a Pod schedules. |

## Files added

```
tools/cluster/local-path-provisioner/
├── install.sh                kubectl apply -k overlay; rollout status; default-class assertion; drift warning
├── uninstall.sh              kubectl delete -k overlay (idempotent)
├── smoke.sh                  PVC + Pod that mounts it; waits for Pod Succeeded
├── kustomization.yaml        overlay: namespace PSA label + ConfigMap path + StorageClass default annotation
├── version.txt               bundled-default upstream tag (v0.0.31)
└── manifests/
    └── local-path-storage.yaml   vendored verbatim from
                                  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
```

Edits:

- `tools/talos/patches/cp.yaml.tpl` and `tools/talos/patches/wk0.yaml.tpl`
  — add `machine.kubelet.extraMounts` block with the single
  `/var/local-path-provisioner` bind/rshared/rw entry.
- `tools/.env.example` — declares `LOCAL_PATH_PROVISIONER_VERSION=v0.0.31`.
- `tools/Justfile` — three `[no-cd]` recipes: `local-path-install`,
  `local-path-smoke`, `local-path-uninstall`. Install/smoke depend on
  `env-check`.
- `tools/Makefile` — adds `LOCAL_PATH_PROVISIONER_VERSION` to
  `bootstrap.config-scheme`'s required-vars list; adds
  `test-cluster.local-path-provisioner`; wires into `test:`.
- `tools/docs/INIT-CLUSTER.md` — Phase 2 subsection (prereqs, install,
  verify, smoke, uninstall, Talos extraMount rationale, StorageClass
  default note). Configuration table extended.
- `README.md` — Phase 2 step in the per-cluster workflow snippet.
- `clusters/k8s4/.env` — per-cluster pin `LOCAL_PATH_PROVISIONER_VERSION=v0.0.31`.

## Why kustomize, not Helm

Upstream rancher/local-path-provisioner does not ship a maintained Helm
chart. The community charts in the ecosystem are third-party forks that
lag the upstream release cadence. Our needs are also narrow:

1. Pin the upstream image tag (already done by the vendored YAML).
2. Override the ConfigMap's `config.json` to point at our host path.
3. Annotate the StorageClass as default.
4. Slap a privileged PSA label on the namespace.

Each is one strategic-merge or JSON-patch entry. A whole Helm chart for
four tweaks is overkill; kustomize is exactly the right grain. We
commit to re-vendoring `local-path-storage.yaml` on every bump (one
curl + commit).

## Why `/var/local-path-provisioner` and rshared

The user's spec is verbatim:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options:
          - bind
          - rshared
          - rw
```

- `/var/local-path-provisioner`: under `/var` (the FHS-blessed home for
  variable runtime state). `/opt` is the upstream default; `/var`
  matches the operational mental model (logs, libs, runtime state).
- `bind` mount type: Talos's `extraMounts` API supports `bind` (between
  two host paths) and friends; this mirrors the host directory into the
  kubelet container at the same path, so a hostPath `/var/...` Pod-side
  is the same inode as the host's `/var/...`.
- `rshared` propagation: required for sub-mounts (CSI-style) to leak
  between the kubelet container and host. local-path-provisioner
  doesn't strictly need this today (it's mkdir/rmdir, not sub-mounts),
  but `rshared` is the standard "this is a real host mount" idiom and
  costs nothing.
- `rw`: writable (helper pods mkdir directories on demand).

Talos creates `/var/local-path-provisioner` on the host if missing
(Talos's `os.installer` provisions a writable `/var` partition).

## Kustomize overlay shape

```yaml
# tools/cluster/local-path-provisioner/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: local-path-storage
resources:
  - manifests/local-path-storage.yaml
patches:
  # Patch 1: namespace PSA label (helper pods use hostPath).
  - target: { kind: Namespace, name: local-path-storage }
    patch: |
      - op: add
        path: /metadata/labels
        value:
          pod-security.kubernetes.io/enforce: privileged
          pod-security.kubernetes.io/audit: privileged
          pod-security.kubernetes.io/warn: privileged
  # Patch 2: ConfigMap path override.
  - target: { kind: ConfigMap, name: local-path-config }
    patch: |
      - op: replace
        path: /data/config.json
        value: |
          {
            "nodePathMap": [
              {
                "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
                "paths": ["/var/local-path-provisioner"]
              }
            ]
          }
  # Patch 3: StorageClass default annotation.
  - target: { kind: StorageClass, name: local-path }
    patch: |
      - op: add
        path: /metadata/annotations/storageclass.kubernetes.io~1is-default-class
        value: "true"
```

(In RFC-6901 JSON pointer escaping, `/` inside a key becomes `~1`; the
patch above is correct for the `storageclass.kubernetes.io/is-default-class`
annotation key.)

## Smoke approach

```
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lpp-smoke-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: local-path
---
apiVersion: v1
kind: Pod
metadata: { name: lpp-smoke-test, namespace: default }
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.36
      command: ["sh","-c","echo ok > /data/ok && cat /data/ok"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: lpp-smoke-test }
EOF

kubectl -n default wait pod/lpp-smoke-test \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
kubectl -n default delete pod/lpp-smoke-test pvc/lpp-smoke-test --wait=false
```

Two things go right when this works:

1. The PVC was bound to a PV provisioned by `rancher.io/local-path`
   under `/var/local-path-provisioner/<pvc-id>` on the node where the
   Pod ran. The kubelet extraMount actually plumbed the path through.
2. The Pod wrote to and read back from the volume — i.e. the helper
   pod's mkdir + chmod completed and the PVC mount succeeded.

If the Pod stalls at `Pending`, the most likely cause is the kubelet
extraMount is missing on the node it scheduled to — see Troubleshooting.

## Idempotence claims

- `kubectl apply -k overlay/` is idempotent by construction; subsequent
  runs report `unchanged` for every resource.
- `kubectl wait` (for jsonpath / condition) is read-only.
- Re-running `just local-path-install` with the same `.env` → exit 0,
  no state change.

## Uninstall behavior

`kubectl delete -k overlay/ --ignore-not-found`. Removes the namespace
(which cascades the Deployment, ConfigMap, helper RBAC, …) plus the
cluster-scoped StorageClass.

We deliberately do NOT delete the host directory `/var/local-path-provisioner`
on uninstall. Pre-existing PV data would orphan; the operator can `rm -rf`
on the host (via `talosctl shell -n <node> rm -rf /var/local-path-provisioner/*`)
if they truly want a clean slate.

## How to use

### Default StorageClass

Once installed, any PVC without an explicit `storageClassName` lands
on `local-path`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: my-pvc, namespace: my-app }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 5Gi } }
  # storageClassName omitted → local-path (default).
```

### Explicit class

```yaml
spec:
  storageClassName: local-path
```

### Lifecycle gotcha: WaitForFirstConsumer

A `kubectl get pvc` right after creation will show `Pending`. That's
not a failure — `WaitForFirstConsumer` binding mode delays the bind
until a Pod schedules and the provisioner can pick the right node.
Operators sometimes interpret this as a stuck PVC; the smoke test
above demonstrates the right pattern (apply PVC + Pod together).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Helper Pod CrashLoops with `mkdir: cannot create directory '/var/local-path-provisioner/...'` | Talos kubelet extraMount missing on that node. | The node's machine config does not have the new `extraMounts` entry. Either the node was bootstrapped before the patch landed (rebuild — that is this repo's plan per Q7) or `_out/{node}.yaml` is stale (`just talos-config`, re-snippet, reboot the node). |
| PVC binds to a different StorageClass | A previous install left a different default class, or another Phase-2 service (Longhorn) flipped the default. | `kubectl get sc` and look for the `(default)` marker. `kubectl annotate sc <other> storageclass.kubernetes.io/is-default-class-`. |
| Helper Pod fails with PSA error | `local-path-storage` namespace not labelled `privileged`. | Re-run `just local-path-install` (the namespace label is in the overlay). |
| `kubectl delete pvc <pvc>` hangs | Reclaim policy is `Delete` and the helper Pod is still cleaning up. | Wait 30–60s, then check `kubectl get pods -n local-path-storage`. |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Upstream YAML drifts (new fields, deprecated apiVersion). | The vendored manifest is pinned by tag. Bumps are deliberate: re-curl, commit, bump `version.txt` + `.env`. The structural test catches `kustomization.yaml` referencing a missing file. |
| local-path-provisioner is single-node-affinity by design — a Pod that re-schedules to a different node loses its data. | Documented in the INIT-CLUSTER subsection. Longhorn (replicated storage) is the planned successor for workloads that need that property; local-path is the right answer only for "scratch-grade" PVCs. |
| Default-class collision with a later Longhorn install. | Longhorn's feature (when it lands) is expected to flip `local-path`'s default annotation off and set itself as default. Until then, local-path is the only class. |
| Helper Pods leak orphaned dirs under `/var/local-path-provisioner/`. | Out of scope for this feature; operator can `rm` on the node. A cleanup CronJob is an obvious follow-up if the lab grows. |
| The privileged PSA label on `local-path-storage` is a real attack surface if an operator deploys something OTHER than the provisioner into that namespace. | Ns is reserved for the provisioner only; documented in INIT-CLUSTER. NetworkPolicy is out of scope. |

## Out of scope

- Replicated/HA storage. That's Longhorn's territory.
- A separate non-default named StorageClass (e.g. `local-path-retain`
  with `reclaimPolicy: Retain`). Trivial to clone the StorageClass
  post-install if anyone needs it.
- Live-cluster migration. The user is rebuilding `k8s4` (Q7 = defer),
  so this feature does NOT include `talosctl apply-config` steps to
  push the new extraMount to live nodes.
- Backup integration (Velero, restic, ...). Lab workloads accept
  ephemeral-grade durability.
