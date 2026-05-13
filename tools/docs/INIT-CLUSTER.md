# K8s Talos Cluster — Install Guide

This repository provisions and operates a small Kubernetes cluster on
**Talos Linux** running in **Proxmox VE**: one control-plane node, one worker,
fully reproducible from a single `.env` file.

For design rationale and architecture see [`.ai/architecture.md`](.ai/architecture.md).
For per-feature implementation details see `.ai/<feature-id>.md` and `.ai/feature_list.json`.

---

## What you get

- One control-plane VM and one worker VM on a chosen Proxmox node.
- Talos Linux as the OS, with `qemu-guest-agent`, `iscsi-tools`, and
  `util-linux-tools` baked into the Talos NoCloud image via the Talos Image Factory.
- A working Kubernetes cluster with `kubectl` and `talosctl` access.
- *(Phase 2, planned)* MetalLB, cert-manager wired to your own CA, Longhorn storage.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Nix** with flakes enabled | The flake provides every other tool — no need to install anything else on the host. |
| **Proxmox VE node** | Reachable via HTTPS (port 8006). Self-signed certs are fine; set `PROXMOX_INSECURE=true`. |
| **Proxmox API token** | Needs VM lifecycle + ISO upload privileges. See below. |
| **Two static IPs** | Routable on your VM network, in the same broadcast domain as your gateway. |
| **DNS records** | `cp.<your-domain>` and `wk0.<your-domain>` resolving to the static IPs (Phase 1 assumes resolution; no DNS automation). |
| **Proxmox bridge** | An existing bridge attached to the right LAN (e.g. `vmbr0`). |
| **Storage pools** | One that supports raw disks (e.g. `local-lvm`) and one that holds ISOs (e.g. `local`). They can be the same pool if it has both content types. |
| **Proxmox snippets storage** | A storage such as `local` with the `snippets` content type enabled. OpenTofu uploads each rendered Talos machine config there and attaches it as NoCloud `user-data`. |

### Minimum Proxmox API token privileges

A Proxmox API token only carries the privileges that have been **granted on the
ACL path of the token's user**, plus (when *Privilege Separation* is on) any
ACLs granted on the token itself. A `root@pam` token with privilege separation
turned **off** inherits everything from `root` and Just Works for a lab. For
any other user, you must grant ACLs explicitly.

For a lab with a dedicated automation user (e.g. `terraform@pam!tf-01`), the
simplest path is to grant `Administrator` to the user and turn privilege
separation **off** on the token (so it inherits):

```bash
# on the Proxmox host as root:
pveum acl modify / --users 'terraform@pam' --roles Administrator
pveum user token modify terraform@pam tf-01 --privsep 0
```

For a more constrained setup, grant role bundles per ACL path:

```bash
pveum acl modify /storage    --users 'terraform@pam' --roles PVEDatastoreAdmin
pveum acl modify /vms        --users 'terraform@pam' --roles PVEVMAdmin
pveum acl modify /nodes/<node-name> --users 'terraform@pam' --roles PVEAuditor
pveum acl modify /sdn        --users 'terraform@pam' --roles PVESDNUser
pveum acl modify /pool       --users 'terraform@pam' --roles PVEPoolAdmin
```

Concretely the token must have, at minimum, the privileges:

- `VM.Allocate`, `VM.Audit`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Console`
- `Datastore.Allocate`, `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Datastore.Audit` (all four; see note below)
- `Sys.Audit`

> **Common gotcha — `Datastore.Allocate` vs `Datastore.AllocateSpace`.**
> These are *different* privileges that gate different actions:
>
> - **`Datastore.AllocateSpace`** (in `PVEDatastoreUser`) lets the user
>   allocate **space within the datastore for a VM/CT disk** — e.g. when a VM
>   gets a new 30 GB disk on `local-lvm`. It does **not** allow creating files.
> - **`Datastore.Allocate`** (in `PVEDatastoreAdmin`) lets the user
>   **create or remove datastore-level artifacts** — uploaded ISOs, **NoCloud
>   snippets**, backups, templates.
>
> The split is a security boundary: spinning up VMs does not automatically
> grant the right to plant arbitrary files in shared storage that other VMs
> might consume. If `tofu apply` fails on `proxmox_virtual_environment_file`
> with HTTP 403 and `Permission check failed (/storage/local,
> Datastore.Allocate)`, the token's user is missing this specific privilege.

Verify what the token actually has:

```bash
pveum user permissions terraform@pam --path /storage/local
pveum user token permissions terraform@pam tf-01 --path /storage/local
```

Both should list `Datastore.Allocate 1`. If `Datastore.Allocate` is missing,
`tofu apply` will fail with `403 Permission check failed (/storage/local,
Datastore.Allocate)` when uploading the per-node Talos NoCloud `user-data`
snippets.

---

## Quickstart

```bash
# 1. Enter the dev shell — provides kubectl, talosctl, tofu, just, helm, k9s, ...
cd /path/to/this/repo
nix develop

# 2. Create your config
cp .env.example .env
$EDITOR .env                 # adjust at minimum: PROXMOX_*, CP_IP, WK0_IP, *_HOSTNAME
just init-config             # prompts for PROXMOX_API_TOKEN_SECRET (kept gitignored)
just env-check               # asserts every var is set; aborts otherwise

# 3. Build the Talos NoCloud ISO and render the per-node Talos configs.
just talos-image
just talos-config
just infra-render            # also prints the scp commands you need next

# 4. Manually copy the per-node snippets to the Proxmox host. The Proxmox API
#    has no snippet-upload endpoint, so this step is unavoidable. The exact
#    commands are printed by `infra-render` (or rerun `just snippets-cmd`).
scp _out/cp.yaml  root@<proxmox-host>:/var/lib/vz/snippets/talos-<cluster>-cp.yaml
scp _out/wk0.yaml root@<proxmox-host>:/var/lib/vz/snippets/talos-<cluster>-wk0.yaml

# 5. Create the VMs and bootstrap the cluster.
just infra-up
just talos-bootstrap
just kubeconfig

# 6. Verify
kubectl get nodes            # cp + wk0 should both be Ready
kubectl get pods -A          # all kube-system pods Running
```

The dev shell already exports `KUBECONFIG=_out/kubeconfig` and
`TALOSCONFIG=_out/talosconfig`, so `kubectl` and `talosctl` Just Work after
`just kubeconfig` finishes.

### App-project workflow: `cluster-shell k8s4`

When you are working in an application/project directory and only need the
cluster auth variables and CLI tools, start the cluster shell from there:

```bash
cd /wa/my-app
cluster-shell k8s4
pwd
kubectl get nodes
```

The command enters the `clusters/k8s4` Nix dev environment to compute
`KUBECONFIG=<repo>/clusters/k8s4/_out/kubeconfig`,
`TALOSCONFIG=<repo>/clusters/k8s4/_out/talosconfig`, `TOOLS_DIR`, and
`A3C_HOME`, then returns the interactive shell to your original app directory.
If `tools/scripts/` is not already on `PATH`, add it or call
`<repo>/tools/scripts/cluster-shell k8s4` directly.

Optional short alias:

```bash
alias ka3c4='cluster-shell k8s4'
```

Cluster maintenance recipes still belong in the cluster directory; `just` is
not hijacked in app-project shells:

```bash
cd /wa/infra/k8s/lab/clusters/k8s4
nix develop
just env-check
```

For a one-off maintenance command from elsewhere, use an explicit subshell and
`cd` into the cluster directory deliberately.

> **Why the manual scp step?** The Proxmox API has no snippet-upload
> endpoint. The bpg/proxmox provider works around that with SSH+SCP, which
> would force OpenTofu to need SSH credentials in addition to the API token.
> We deliberately skip that, reference the snippet by its volume id
> (`<storage>:snippets/<file>.yaml`), and ask the operator to do the one
> manual copy. `just snippets-cmd` re-prints the exact commands at any time.

> **One-shot end-to-end:** `just cluster-up` will fail at `tofu apply` until
> the snippets are on the Proxmox host, because `proxmox_virtual_environment_vm`
> validates that `user_data_file_id` exists. Run it twice if needed: the first
> time prints the scp lines, you copy, then re-run.

> **Single source of network truth.** OpenTofu intentionally does NOT pass
> static IP / gateway / DNS to Proxmox cloud-init (no `ip_config` / `dns`
> blocks in `infra/main.tf`). Doing so would generate a NoCloud
> `network-config` file that competes with the network section of the Talos
> machine config (`machine.network` in the snippet). When the gateway is
> off-link (e.g. node `10.4.0.1/24` with gateway `10.0.0.1`) the cloud-init
> network-config can't install the gateway and ends up blocking the Talos
> user-data from configuring it either, with the symptom **"IP and DNS work,
> but no default route"**. By keeping cloud-init carrying only the user-data
> file, Talos owns networking end-to-end.

---

## Configuration (`.env`)

`.env` is the single source of truth. Everything downstream (OpenTofu tfvars,
Talos patches, Helm values) is rendered from it.

| Variable | Purpose |
|---|---|
| `PROXMOX_ENDPOINT` | Full HTTPS API URL, e.g. `https://emcc.lab.atricore.io:8006/api2/json` |
| `PROXMOX_INSECURE` | `true` to skip TLS verification (self-signed certs) |
| `PROXMOX_NODE` | Target node name in the Proxmox cluster |
| `PROXMOX_API_TOKEN_ID` | E.g. `root@pam!terraform` |
| `PROXMOX_API_TOKEN_SECRET` | UUID; **never commit** — `.env` is gitignored |
| `PROXMOX_STORAGE_POOL` | VM disk storage (`local-lvm` typical) |
| `PROXMOX_ISO_STORAGE` | ISO storage (`local` typical) |
| `PROXMOX_SNIPPET_STORAGE` | Proxmox storage with `snippets` enabled for NoCloud user-data (`local` typical, backing path usually `/var/lib/vz/snippets`) |
| `PROXMOX_SSH_USER` / `PROXMOX_SSH_HOST` | Used by `print-snippet-upload-cmd.sh` to print the `scp` line you must run; the Proxmox API has no snippet-upload endpoint |
| `PROXMOX_SNIPPETS_DIR` | Filesystem path on the Proxmox host that backs `PROXMOX_SNIPPET_STORAGE` (default `/var/lib/vz/snippets`) |
| `CLUSTER_NAME` / `CLUSTER_DOMAIN` | Used in resource names and PKI subjects |
| `CP_HOSTNAME` / `CP_IP` | Control plane node identity |
| `WK0_HOSTNAME` / `WK0_IP` | Worker node identity |
| `NETWORK_CIDR` | Subnet mask length used in Talos addresses (e.g. `24` or `8`). The patch templates emit an explicit on-link `${NETWORK_GATEWAY}/32` route ahead of the default route, so the gateway does **not** need to be in the same subnet as the node. |
| `NETWORK_GATEWAY` | Default gateway IP. Reachability is handled via the on-link route described above; no manual subnet alignment required. |
| `NETWORK_DNS` | Upstream DNS server |
| `NETWORK_BRIDGE` | Proxmox bridge (e.g. `vmbr0`) |
| `CP_CORES` / `CP_MEMORY_MB` / `CP_DISK_SIZE_GB` | Control-plane VM sizing (default 4 / 4096 / 30) |
| `WK_CORES` / `WK_MEMORY_MB` / `WK_DISK_SIZE_GB` | Worker VM sizing (default 8 / 8192 / 30) |
| `WK_STORAGE_DISK_SIZE_GB` | Worker's second disk reserved for Longhorn (default 200) |
| `TALOS_VERSION` | Image version, e.g. `v1.13.0` (the `v` prefix is required) |
| `TALOS_IMAGE_PLATFORM` | Must be `nocloud`; Talos only parses Proxmox NoCloud data when booted with the NoCloud Image Factory variant |
| `METALLB_RANGE` | Phase 2: pool of IPs MetalLB hands to LoadBalancer services. Must be a routable IPv4 CIDR that does **not** contain `CP_IP` or `WK0_IP` (`metallb-install` fails fast otherwise). |
| `METALLB_CHART_VERSION` | Phase 2: pinned `metallb/metallb` Helm chart version (e.g. `0.15.3`). **No `v` prefix** — that's how the MetalLB chart numbers itself (different from cert-manager). The bundled default lives at `tools/cluster/metallb/chart-version.txt`; if `.env` differs, the install script warns and uses the `.env` value. |
| `CA_CERT_PATH` / `CA_KEY_PATH` | Phase 2: paths under `secrets/` for cert-manager `ClusterIssuer` |
| `CLUSTER_ISSUER_NAME` | Phase 2: name of the cert-manager `ClusterIssuer` and its backing TLS Secret in the `cert-manager` namespace (default `atricore-ca`) |
| `CERT_MANAGER_CHART_VERSION` | Phase 2: pinned Jetstack cert-manager Helm chart version (e.g. `v1.16.2`). The bundled default lives at `tools/cluster/cert-manager/chart-version.txt`; if `.env` differs, the install script warns and uses the `.env` value. |
| `PANGOLIN_ENDPOINT` | Phase 2: full HTTPS URL of your Pangolin server (e.g. `https://app.pangolin.net`). `newt-install` validates the `http(s)://` prefix and fails fast otherwise. |
| `NEWT_ID` | Phase 2: site identifier issued by Pangolin's "create site" UI. Ships as the literal `REPLACE-ME-FROM-PANGOLIN-UI` so `env-check` passes; `newt-install` refuses to apply that placeholder. |
| `NEWT_SECRET` | Phase 2: site secret issued by Pangolin's "create site" UI. Same placeholder semantics as `NEWT_ID`. **Never commit** — `.env` is gitignored. |
| `NEWT_IMAGE_TAG` | Phase 2: pinned `fosrl/newt` container image tag (e.g. `1.12.3`). **No `v` prefix** — fosrl/newt tags are bare semver. The bundled default lives at `tools/cluster/newt/image-tag.txt`; if `.env` differs, the install script warns and uses the `.env` value. |
| `INGRESS_NGINX_CHART_VERSION` | Phase 2: pinned `kubernetes/ingress-nginx` Helm chart version (e.g. `4.15.1`). **No `v` prefix** (matches MetalLB, differs from cert-manager). The bundled default lives at `tools/cluster/ingress-nginx/chart-version.txt`; if `.env` differs, the install script warns and uses the `.env` value. |
| `INGRESS_LB_IP` | Phase 2: LoadBalancer IP pinned to the ingress-nginx controller Service. **Must be inside `${METALLB_RANGE}`**; `ingress-install` fails fast otherwise. The recommended pattern is to reserve a stable IP near the bottom of the pool (e.g. `10.4.200.10`) and point your wildcard DNS at it. |
| `INGRESS_DEFAULT_TLS_SECRET` | Phase 2: name of both the cert-manager `Certificate` and the resulting `Secret` in the `ingress-nginx` namespace. Default `ingress-default-tls`. Wired into the controller via `controller.extraArgs.default-ssl-certificate=ingress-nginx/$INGRESS_DEFAULT_TLS_SECRET` so unmatched-SNI clients still get a valid handshake against `*.${CLUSTER_DOMAIN}`. |
| `METRICS_SERVER_CHART_VERSION` | Phase 2: pinned `kubernetes-sigs/metrics-server` Helm chart version (e.g. `3.13.0`). **No `v` prefix** (matches MetalLB/ingress-nginx, differs from cert-manager). The bundled default lives at `tools/cluster/metrics-server/chart-version.txt`; if `.env` differs, the install script warns and uses the `.env` value. |

---

## What `just cluster-up` does, step by step

Each step has its own `just` recipe and is idempotent — re-run them
individually if anything goes sideways.

### 1. `just talos-image`
- Renders `talos/schematic.yaml` (extension list) to JSON.
- POSTs to `https://factory.talos.dev/schematics`; persists returned id under `_out/talos-schematic-id`.
- Downloads the matching NoCloud ISO to `_out/talos-<version>-<id>-nocloud.iso`.
- Uploads it to `${PROXMOX_ISO_STORAGE}` on `${PROXMOX_NODE}`.
- Idempotent: skips POST when schematic content is unchanged; skips download/upload when artifacts already exist.

### 2. `just talos-config`
- Generates the cluster secrets bundle (`_out/secrets.yaml`) **once** and reuses it on every rerun. **This is your cluster PKI — back it up. Losing it means re-bootstrapping a new cluster.**
- Re-renders base `_out/controlplane.yaml` and `_out/worker.yaml` from those secrets.
- Renders per-node patches from templates → `_out/patches/{cp,wk0}.yaml` (hostname, static IP/CIDR, default route, DNS, install disk).
- Produces final `_out/cp.yaml` and `_out/wk0.yaml` via `talosctl machineconfig patch`.
- Validates both with `talosctl validate --mode metal`.
- Sets `_out/talosconfig` endpoint and node lists to the configured static IPs.

### 3. `just infra-up`
- Renders `infra/cluster.tfvars` from `.env` (and the schematic id) via envsubst.
- Uploads `_out/cp.yaml` and `_out/wk0.yaml` to `${PROXMOX_SNIPPET_STORAGE}` as Proxmox snippets. This is equivalent to the documented Proxmox pattern `qm set <vmid> --cicustom user=local:snippets/<node>.yml`, but managed provider-natively by OpenTofu.
- Runs `tofu init` (downloads the `bpg/proxmox` provider; cached in gitignored `infra/.terraform/`).
- Runs `tofu apply` to create two VMs: `cp-${CLUSTER_NAME}` and `wk0-${CLUSTER_NAME}`.
- The CP VM gets a single OS disk (`scsi0`); the worker VM gets an OS disk (`scsi0` → `/dev/sda`, sized by `WK_DISK_SIZE_GB`) plus a **second blank disk** (`scsi1` → `/dev/sdb`, sized by `WK_STORAGE_DISK_SIZE_GB`) reserved for Longhorn. Talos installs to `/dev/sda` and never touches `/dev/sdb`.
- VMs boot from the ISO first, then from the OS disk after Talos installs.
- Each VM has a Proxmox `initialization`/NoCloud datasource attached before first boot. The NoCloud `user-data` is the rendered Talos machine config, and Proxmox network data carries the static IP/CIDR, gateway, and DNS from `.env`.
- Talos does not run generic Linux cloud-init. Proxmox cloud-init is useful here only because it presents NoCloud seed data, which Talos parses when booted from the NoCloud Talos image.

### 4. NoCloud first boot (replaces `talos-apply`)
- On first boot, Talos reads the NoCloud user-data and network data from the Proxmox cloud-init drive.
- The old workflow of discovering a random DHCP maintenance IP and then running `talosctl apply-config --insecure` is not part of `cluster-up`.
- The `talos-apply` recipe remains only as a troubleshooting fallback if an operator intentionally bypasses NoCloud; the normal path targets the configured static IPs after first boot.

### 5. `just talos-bootstrap`
- Waits for the CP secure API.
- `talosctl bootstrap -n $CP_IP` to initialize etcd. Re-running after a successful bootstrap returns "AlreadyExists" — the script treats that as success.

### 6. `just kubeconfig`
- Fetches the kubeconfig to `$KUBECONFIG` (`_out/kubeconfig`).

### 7. wait for nodes Ready
- Loops `kubectl get nodes` until both report `Ready` (timeout 5 min).

---

## Verification

```bash
kubectl get nodes
# NAME                          STATUS   ROLES           AGE   VERSION
# cp.k8s4.lab.atricore.io       Ready    control-plane   2m    v1.31.x
# wk0.k8s4.lab.atricore.io      Ready    <none>          90s   v1.31.x

kubectl get pods -A
# All kube-system pods (kube-apiserver, etcd, controller-manager, scheduler, kube-proxy, kube-flannel)
# should be Running or Completed.

talosctl -n $CP_IP version       # talks to the secure API on CP
```

Run the project test suite anytime:

```bash
make test
# or, equivalently:
npm test                          # what the patagon harness uses
```

---

## Phase 2: MetalLB (L2 mode)

Phase 2 is **opt-in** and **not part of `just cluster-up`**. MetalLB is the
first service installed in Phase 2 because everything else that wants a
routable IP (cert-manager-issued TLS endpoints, Longhorn UI, future workloads)
needs `Service` type=LoadBalancer working first.

This recipe installs MetalLB in **L2 mode** (ARP/NDP, single broadcast
domain — not BGP), sets up a single `IPAddressPool` named `default-pool` from
`${METALLB_RANGE}`, and a matching `L2Advertisement` named `default-l2-adv`.

### Prerequisites

- A working cluster (`just cluster-up` finished and `kubectl get nodes` is
  green).
- `KUBECONFIG` exported (the cluster `nix develop` shell does this; if you
  bypassed it, run `just kubeconfig`).
- `.env` contains `METALLB_RANGE` and `METALLB_CHART_VERSION`.
- `${METALLB_RANGE}` is a valid IPv4 CIDR that does **not** contain
  `${CP_IP}` or `${WK0_IP}`. The install script fails fast otherwise to
  prevent ARP wars on the node IPs.

### Install

```bash
just metallb-install
```

The recipe:

1. Validates that `METALLB_RANGE` parses as an IPv4 CIDR and that neither
   `CP_IP` nor `WK0_IP` falls inside it.
2. `helm upgrade --install metallb metallb/metallb` in namespace
   `metallb-system`, with `--create-namespace` and the pinned chart version.
3. Waits for the `metallb-speaker` DaemonSet to roll out (≤2 min).
4. Server-side-applies the `IPAddressPool/default-pool` rendered from
   `${METALLB_RANGE}` and the `L2Advertisement/default-l2-adv` that pins it.

The recipe is idempotent: re-running it leaves the Helm release at the
same revision and reports "unchanged" for both the IPAddressPool and the
L2Advertisement.

### Verify

```bash
kubectl -n metallb-system get pods            # controller + speaker Ready
kubectl get ipaddresspool -A                  # default-pool present
kubectl get l2advertisement -A                # default-l2-adv present
```

### Smoke

```bash
just metallb-smoke
```

This creates a `Service` named `mlb-smoke-test` of type `LoadBalancer` in
the `default` namespace (no selector, no backend pods), waits up to 30s for
`.status.loadBalancer.ingress[0].ip` to be populated, asserts the IP is
inside `${METALLB_RANGE}`, and deletes the Service. No curl, no backend —
the only contract being smoke-tested is "MetalLB allocates an IP from the
pool and surfaces it via the Service status".

### Uninstall

```bash
just metallb-uninstall
```

Removes the L2Advertisement, the IPAddressPool, the Helm release, and the
`metallb-system` namespace. Safe to re-run when nothing is installed.

### Reaching the LoadBalancer IPs from your workstation

Even after MetalLB is installed, your workstation still needs a route to
`${METALLB_RANGE}`. The pool is intentionally a separate subnet from the
node IPs (so MetalLB has free ARP space), so the lab gateway does not
naturally know how to reach it. Add a one-time host route via the control
plane node:

```bash
sudo ip route add ${METALLB_RANGE} via ${CP_IP}
```

The dev shell prints this reminder on entry. The
[Loadbalancer route](#loadbalancer-route-one-time-after-phase-2) section
below has the same command spelled out.

---

## Phase 2: cert-manager (atricore-ca)

Phase 2 is **opt-in** and **not part of `just cluster-up`**. It installs
cert-manager via Helm and wires a `ClusterIssuer` (default name
`atricore-ca`) backed by your CA in `secrets/ca.crt` + `secrets/ca.key`.

### Prerequisites

- A working cluster (`just cluster-up` finished and `kubectl get nodes` is
  green).
- `KUBECONFIG` exported (the cluster `nix develop` shell does this; if you
  bypassed it, run `just kubeconfig`).
- `secrets/ca.crt` and `secrets/ca.key` are present in the cluster
  directory. They must be a matching cert/key pair (the install script
  refuses to proceed otherwise).
- `.env` contains `CLUSTER_ISSUER_NAME` and `CERT_MANAGER_CHART_VERSION`.

### Install

```bash
just cert-manager-install
```

The recipe:

1. Validates `CA_CERT_PATH` and `CA_KEY_PATH` exist and that their public
   key hashes match.
2. Warns if the CA cert expires in less than 60 days.
3. `helm upgrade --install cert-manager jetstack/cert-manager` in namespace
   `cert-manager`, with `--create-namespace` and the pinned chart version.
4. Server-side-applies the TLS `Secret` named `${CLUSTER_ISSUER_NAME}` in
   the `cert-manager` namespace.
5. Server-side-applies the rendered `ClusterIssuer`.
6. Runs `cmctl check api --wait=2m`.

The recipe is idempotent: re-running it leaves the Helm release at the
same revision and reports "unchanged" for both Secret and ClusterIssuer.

### Verify

```bash
kubectl get clusterissuer atricore-ca
# NAME           READY   AGE
# atricore-ca    True    1m
```

### Smoke

```bash
just cert-manager-smoke
```

This issues a throwaway `Certificate` (`cm-smoke-test`) signed by the
ClusterIssuer and waits up to 60s for `Ready=True`. The Certificate and
its Secret are deleted on exit.

### Uninstall

```bash
just cert-manager-uninstall
```

Removes the ClusterIssuer, the CA Secret, the Helm release, and the
`cert-manager` namespace. Safe to re-run when nothing is installed.

---

## Phase 2: ingress-nginx

Phase 2 is **opt-in** and **not part of `just cluster-up`**. ingress-nginx is
the L7 router for HTTP(S) traffic into the cluster: it terminates TLS, picks
a backend `Service` based on the request's `Host` header (and path), and
forwards the request. We pair it with cert-manager (for per-Ingress
auto-issued certs) and MetalLB (for a real, pinned LoadBalancer IP), so this
recipe **depends on both** of those Phase-2 features being installed first.

The install pins one **wildcard `*.${CLUSTER_DOMAIN}` Certificate** issued by
the `atricore-ca` ClusterIssuer and wires it into the controller as
`controller.extraArgs.default-ssl-certificate`. Unmatched-SNI clients still
get a valid TLS handshake (instead of the dummy "Kubernetes Ingress
Controller Fake Certificate" served by stock ingress-nginx). Per-Ingress
certs are still auto-issued via the standard `cert-manager.io/cluster-issuer`
annotation flow described below.

### Prerequisites

- A working cluster (`just cluster-up` finished and `kubectl get nodes` is
  green).
- `KUBECONFIG` exported (the cluster `nix develop` shell does this; if you
  bypassed it, run `just kubeconfig`).
- **`just metallb-install`** has run successfully and the speaker is Ready
  (controller needs a real LoadBalancer IP allocated by MetalLB).
- **`just cert-manager-install`** has run successfully and the
  `${CLUSTER_ISSUER_NAME}` ClusterIssuer reports `Ready=True` (controller
  needs the wildcard default-ssl Certificate to come up).
- `.env` contains `INGRESS_NGINX_CHART_VERSION`, `INGRESS_LB_IP` (must be
  inside `METALLB_RANGE`), and `INGRESS_DEFAULT_TLS_SECRET`.

### Install

```bash
just ingress-install
```

The recipe:

1. Validates that `INGRESS_LB_IP` parses as an IPv4 address and falls inside
   `METALLB_RANGE` (same `ip_to_int` + bitmask arithmetic as MetalLB's
   pre-validate). Aborts with a clear error otherwise.
2. Server-side-applies the `ingress-nginx` namespace with
   `pod-security.kubernetes.io/enforce: restricted`. The controller is
   fully restricted-PSA-compliant: runs as uid 101, all caps dropped, only
   `NET_BIND_SERVICE` re-added (the one cap restricted PSA still permits,
   which is exactly what nginx needs to bind 80/443).
3. `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx` in
   that namespace, with the pinned chart version and `helm-values.yaml`,
   plus two `--set` values from `.env`:
   `controller.service.loadBalancerIP=$INGRESS_LB_IP` and
   `controller.extraArgs.default-ssl-certificate=ingress-nginx/$INGRESS_DEFAULT_TLS_SECRET`.
   `--wait` blocks until the controller Deployment is rolled out.
4. Server-side-applies the wildcard `Certificate/${INGRESS_DEFAULT_TLS_SECRET}`
   rendered from `default-ssl-cert.yaml.tpl` (covers both `*.${CLUSTER_DOMAIN}`
   and the apex `${CLUSTER_DOMAIN}`).
5. Waits ≤60s for that Certificate to report `Ready=True`.

The recipe is idempotent: re-running it leaves the Helm release at the same
revision and reports "unchanged" for both the namespace and the Certificate.

### Verify

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
# NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
# ingress-nginx-controller   LoadBalancer   10.x.x.x        10.4.200.10    80:.../TCP,443:.../TCP       1m
kubectl -n ingress-nginx get pods                                  # controller Running
kubectl -n ingress-nginx get certificate ${INGRESS_DEFAULT_TLS_SECRET}   # READY=True
```

### Smoke

```bash
just ingress-smoke
```

This runs `helm -n ingress-nginx status ingress-nginx`, then
`kubectl rollout status deployment/ingress-nginx-controller --timeout=60s`,
then asserts `Service.status.loadBalancer.ingress[0].ip` is **exactly**
`${INGRESS_LB_IP}`. The third assertion catches the silent failure where
MetalLB couldn't allocate the pinned IP (because something else in the pool
is squatting it) and silently fell back to the next free IP — at which
point your wildcard DNS still points at `${INGRESS_LB_IP}` and nothing works.

### Uninstall

```bash
just ingress-uninstall
```

Removes the wildcard Certificate, its Secret, the Helm release, and the
`ingress-nginx` namespace. Safe to re-run when nothing is installed.

### DNS and host-route guidance

For services exposed via Ingress to be reachable, two operator-side hops
are needed (neither is automated by this stack):

1. **DNS.** Point your A/AAAA records at `INGRESS_LB_IP`. The recommended
   shape is a wildcard record so adding new app hostnames doesn't require
   DNS edits:

   ```text
   *.k8s4.lab.atricore.io.   IN  A   10.4.200.10
   ```

   Or per-app:

   ```text
   app1.k8s4.lab.atricore.io. IN A   10.4.200.10
   ```

2. **Host route from your workstation.** Same as for MetalLB — your
   workstation needs to know how to reach `${METALLB_RANGE}`:

   ```bash
   sudo ip route add ${METALLB_RANGE} via ${CP_IP}
   ```

   The cluster `nix develop` shell prints this reminder on entry.

### Adding an app Ingress (cert-manager auto-issued cert)

The wildcard default-ssl Certificate handles the unmatched-SNI case, but
production-quality apps should declare their own `Ingress` with an
auto-issued per-host certificate. Annotate with
`cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER_NAME}` and cert-manager's
ingress-shim watches the resource, creates the matching `Certificate`, and
lands the cert in the named `Secret`. ingress-nginx then loads it for SNI
matching the listed hosts.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    cert-manager.io/cluster-issuer: atricore-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts: [my-app.k8s4.lab.atricore.io]
      secretName: my-app-tls
  rules:
    - host: my-app.k8s4.lab.atricore.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

If you skip the per-host `tls:` block entirely, the controller will fall
back to the wildcard default-ssl Certificate and you still get a valid
handshake — but with the wildcard's `commonName` rather than the host's.
For internal/throwaway services this is often good enough; for anything
user-facing, prefer the per-Ingress flow above.

---

## Phase 2: metrics-server

Phase 2 is **opt-in** and **not part of `just cluster-up`**. metrics-server
is the cluster-wide CPU/memory metrics aggregator that the kube-apiserver
exposes at `/apis/metrics.k8s.io/v1beta1`. It is what `kubectl top nodes`,
`kubectl top pods`, and the **HorizontalPodAutoscaler** controller all
read from. Without it `kubectl top` errors out with
`Metrics API not available` and HPAs sit `<unknown>` forever.

This recipe is **independent of every other Phase 2 service** — it does
not depend on MetalLB, cert-manager, ingress-nginx, or newt, and nothing
else depends on it. Install it whenever you need autoscaling or
operator-side resource visibility.

### Prerequisites

- A working cluster (`just cluster-up` finished and `kubectl get nodes` is
  green).
- `KUBECONFIG` exported (the cluster `nix develop` shell does this; if you
  bypassed it, run `just kubeconfig`).
- `.env` contains `METRICS_SERVER_CHART_VERSION`.

### Install

```bash
just metrics-install
```

The recipe:

1. `helm upgrade --install metrics-server metrics-server/metrics-server`
   in namespace `kube-system` (the canonical home for cluster system
   add-ons; we deliberately do not create or label it), with the pinned
   chart version and `helm-values.yaml`. `--wait` blocks until the
   Deployment is rolled out.
2. Waits ≤60s for `apiservice/v1beta1.metrics.k8s.io` to report
   `Available=True`. That condition is the actual contract `kubectl top`
   and HPA consume; the chart creates the APIService but does not block
   on it becoming Available.

The recipe is idempotent: re-running it leaves the Helm release at the
same revision and reports `unchanged` for the deployment.

### Verify

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
# NAME                     SERVICE                      AVAILABLE   AGE
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True        30s

kubectl top nodes
# NAME                          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# cp.k8s4.lab.atricore.io       142m         3%     1654Mi          41%
# wk0.k8s4.lab.atricore.io      221m         2%     2143Mi          26%

kubectl top pods -A
```

`kubectl top` may take 30–60s to surface metrics on a fresh install
because the kubelet scrape window is `--metric-resolution=15s` and
metrics-server needs at least one full window before it has anything
to serve. This is expected; the smoke does not poll `kubectl top` for
that reason.

### Smoke

```bash
just metrics-smoke
```

This runs `helm -n kube-system status metrics-server`, then
`kubectl wait --for=condition=Available --timeout=60s
apiservice/v1beta1.metrics.k8s.io`. Minimal by design — `kubectl top`
validation is left as an operator-side step (see Verify above).

### Uninstall

```bash
just metrics-uninstall
```

Removes the Helm release (Deployment, Service, APIService, RBAC). The
`kube-system` namespace is **not** touched. Safe to re-run when nothing
is installed.

### Talos-specific gotchas

The two non-default flags in `helm-values.yaml` exist specifically
because of Talos:

1. **`--kubelet-insecure-tls`.** Talos rotates kubelet serving certs and
   signs them with a per-node CA that lives in machined's secret store —
   it is not exposed at `/etc/kubernetes/pki` or via any standard
   ConfigMap, so making metrics-server validate kubelet certs requires
   a custom CA-distribution path that is genuinely awkward to wire up.
   The trust boundary here is the cluster network: kubelet ↔
   metrics-server traffic stays on the pod network and never traverses
   an untrusted segment. This matches what k3s, EKS, GKE, AKS, and
   Talos's own recommended deployment do by default — it is not a "lab
   shortcut".

2. **`--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP`.**
   The chart default order starts with `Hostname` and `InternalDNS`. On
   this cluster there is no DNS for the short hostnames `cp` / `wk0`,
   so metrics-server ends up trying `https://cp:10250` first, timing out
   per node, and only then falling through to the InternalIP. Putting
   InternalIP first makes the very first dial succeed.

### Adding an HPA

A minimal HPA against a Deployment looks like this once metrics-server
is installed:

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

`kubectl get hpa -n my-app` should show the current/target ratio
within 30–60s of creation (one scrape window). This stack does not
ship a custom-metrics adapter; HPAs targeting non-resource metrics
(Prometheus, custom application metrics) are out of scope.

---

## Phase 2: newt (Pangolin tunnel client)

Phase 2 is **opt-in** and **not part of `just cluster-up`**. This step is
also independent of MetalLB and cert-manager — none of those three Phase-2
recipes depend on each other.

[newt](https://github.com/fosrl/newt) is the userspace client side of
[Pangolin](https://github.com/fosrl/pangolin), a self-hosted reverse proxy
/ tunnel server. The cluster runs **one** newt pod that connects **outbound
only** to your Pangolin server over HTTPS+WSS, then carries traffic over a
userspace WireGuard tunnel (`wireguard-go` netstack — no kernel module, no
`NET_ADMIN`, no host network). Pangolin terminates inbound traffic on the
public side; nothing inbound reaches the cluster from this stack.

### Prerequisites

- A working cluster (`just cluster-up` finished and `kubectl get nodes` is
  green).
- `KUBECONFIG` exported (the cluster `nix develop` shell does this; if you
  bypassed it, run `just kubeconfig`).
- A reachable Pangolin server. The cluster pods must be able to resolve
  `${PANGOLIN_ENDPOINT}` and reach it over HTTPS/WSS (egress firewall + DNS).
- A `NEWT_ID` and `NEWT_SECRET` issued by your Pangolin server's site UI
  ("create site" → copy the credentials).
- `.env` contains `PANGOLIN_ENDPOINT`, `NEWT_ID`, `NEWT_SECRET`, and
  `NEWT_IMAGE_TAG`. **Replace the `REPLACE-ME-FROM-PANGOLIN-UI` placeholders
  with the real values before running `newt-install`.** `env-check` passes
  with the placeholders (they're non-empty), but `install.sh` detects them
  and refuses to apply.

### Install

```bash
just newt-install
```

The recipe:

1. Validates that `PANGOLIN_ENDPOINT` starts with `http://` or `https://`.
2. Refuses to proceed if `NEWT_ID` or `NEWT_SECRET` is still the literal
   `REPLACE-ME-FROM-PANGOLIN-UI` placeholder.
3. Server-side-applies the `newt` namespace with `pod-security.kubernetes.io/enforce: restricted`.
4. Renders `secret.yaml.tpl` via `envsubst` and server-side-applies a
   `Secret/newt-credentials` carrying the three credential values.
5. Renders `deployment.yaml.tpl` via `envsubst` and server-side-applies a
   single-replica `Deployment/newt` with `strategy.type: Recreate`,
   `image: fosrl/newt:${NEWT_IMAGE_TAG}`, `envFrom: secretRef: newt-credentials`,
   and a hardened `securityContext` (`runAsNonRoot`, `readOnlyRootFilesystem`,
   `capabilities.drop: [ALL]`, seccomp `RuntimeDefault`).
6. Waits ≤2 min for `kubectl rollout status deployment/newt`.

The recipe is idempotent: re-running it reports "unchanged" for namespace,
Secret, and Deployment when nothing in `.env` changed.

### Verify

```bash
kubectl -n newt get pods                                  # newt pod Ready
kubectl -n newt logs deploy/newt | grep "Connecting to endpoint"
```

### Smoke

```bash
just newt-smoke
```

This re-runs `kubectl rollout status` with a 60s budget, then polls the pod
logs for the literal `Connecting to endpoint:` line for ≤30s. That line is
emitted by newt **only after** HTTPS auth succeeded, the WebSocket
upgraded, and Pangolin pushed back the `wg/connect` message — i.e. the
tunnel is genuinely being brought up, not just the container started. On
timeout the recipe prints the last 30 log lines plus diagnostic hints
(credentials, reachability, single-connection-per-site) and exits 1.

### Uninstall

```bash
just newt-uninstall
```

Removes the Deployment, the Secret, and the `newt` namespace. Safe to
re-run on an empty cluster (`--ignore-not-found` on every step).

### Security model

- **Restricted PSA.** The `newt` namespace has
  `pod-security.kubernetes.io/enforce: restricted`. Possible because newt
  is fully userspace — `wireguard-go` (the netstack tunnel) does not need
  `NET_ADMIN`, host network, or `/dev/net/tun`. The pod runs as non-root
  (uid 65532), with a read-only root filesystem, all capabilities dropped,
  and the `RuntimeDefault` seccomp profile.
- **Egress only.** No `Service`, no `Ingress`, no inbound port. Pangolin
  is reached over HTTPS (auth) + WSS (control plane) + the userspace
  WireGuard data path. Inbound traffic to your services arrives only via
  Pangolin's public side; this stack does not expose anything to the local
  cluster network.
- **One connection per site.** A Pangolin site only accepts a single
  concurrent newt connection. The Deployment uses `strategy.type:
  Recreate` (not `RollingUpdate`) so during a roll the old pod is
  terminated *before* the new one starts. RollingUpdate would briefly run
  two pods racing for the WebSocket and produce flapping.

### Rotation

To rotate `NEWT_SECRET` (e.g. after suspected leak):

1. Issue a new secret from the Pangolin site UI.
2. Edit `.env`, replace `NEWT_SECRET=` with the new value.
3. `just newt-install`. The Secret server-side-apply produces a new
   `resourceVersion`, the Deployment template's `envFrom` re-reads it on
   the next pod start, and the `Recreate` strategy guarantees the old pod
   stops before the new one starts (so the new pod authenticates with the
   new secret without overlap).

A clean rotation with no downtime requires the operator to also rotate on
Pangolin's side in lockstep; `just newt-uninstall && just newt-install` is
the heaviest hammer if anything looks stuck.

---

## Loadbalancer route (one-time, after Phase 2)

When MetalLB is installed it hands out IPs from `${METALLB_RANGE}`. To reach
them from your workstation, add a route via one of the cluster nodes:

```bash
sudo ip route add 10.4.200.0/24 via $CP_IP
```

The dev shell prints this reminder on entry.

---

## Tear down

```bash
just cluster-down            # destroys both VMs and removes generated cluster artifacts
# Or more granular:
just infra-down              # tofu destroy only (keeps _out/)
rm -rf _out/                 # nuke local state (kubeconfig, talosconfig, machine configs)
```

> **Warning:** removing `_out/secrets.yaml` discards your cluster PKI.
> The next `just talos-config` generates a fresh secrets bundle, which means
> a brand-new cluster identity. Back this file up if you care about the cluster.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `tofu apply` 401 Unauthorized | Wrong token id/secret | Regenerate the API token; update `PROXMOX_API_TOKEN_SECRET` |
| `tofu apply` 403 *"Permission check failed (/storage/local, Datastore.Allocate)"* | Token user has `Datastore.AllocateSpace` (allocate VM-disk space) but not `Datastore.Allocate` (create new datastore-level files). They are different privileges; only the latter lets the ISO upload create a file. | Run `pveum acl modify /storage --users '<user>' --roles PVEDatastoreAdmin` on the Proxmox host. Verify with `pveum user permissions <user> --path /storage/local` — you should see both `Datastore.Allocate` and `Datastore.AllocateTemplate`. |
| `tofu apply` SSH error *"unable to authenticate user "" over SSH"* | Earlier code path made OpenTofu upload snippets via SSH. We removed that; if you see this, you are on an old `infra/main.tf`. | Pull the latest tree; `infra/main.tf` should contain `local.cp_user_data_file_id` / `local.wk0_user_data_file_id` and **no** `proxmox_virtual_environment_file` resources. |
| `tofu apply` says *"file does not exist"* on `<storage>:snippets/talos-...yaml` | Snippet not copied to the Proxmox host yet | Run `just snippets-cmd`, copy/paste the printed `scp` lines, verify with `ssh <proxmox> "ls /var/lib/vz/snippets/"`, then re-run `just infra-up` |
| `tofu apply` 403 on `/vms/...` or `/nodes/...` | Same: missing role on `/vms` or `/nodes/<node>` | Grant `PVEVMAdmin` on `/vms` and `PVEAuditor` on `/nodes/<node>` to the token's user |
| `tofu apply` complains *"ISO file not found"* | Image not uploaded yet | Run `just talos-image` first |
| VM created but stuck during boot | ISO not actually mounted, or wrong boot order | Check `qm config <vmid>` on the Proxmox host |
| `talos-apply` waits forever for maintenance mode | VM never booted Talos ISO | Open the Proxmox VM console; Talos shows its dashboard when running |
| VM boots but ignores NoCloud data | The ISO is not the Talos NoCloud variant, or snippets storage is not enabled/attached | Ensure `TALOS_IMAGE_PLATFORM=nocloud`, rerun `just talos-image`, and verify `${PROXMOX_SNIPPET_STORAGE}` supports `snippets` (usually `/var/lib/vz/snippets`) |
| Node stays `NotReady` | CNI not up | `kubectl -n kube-flannel get pods` and `kubectl describe node <name>` |
| `bootstrap-once.sh` says *"AlreadyExists"* | etcd already bootstrapped earlier | Expected; treated as success |
| `kubectl` TLS error right after bootstrap | kube-apiserver still starting | Wait ~1 min and retry |
| Default route missing after first boot (DNS/IP work but no internet) | Two possible causes. (1) Old `infra/main.tf` had `ip_config { }` / `dns { }` in the cloud-init `initialization` block, generating a NoCloud `network-config` that competed with Talos's user-data. The current code does not — verify by `grep -E 'ip_config\|^[[:space:]]*dns' infra/main.tf` returning nothing. (2) The Talos snippet does not contain the on-link `${NETWORK_GATEWAY}/32` route ahead of the default route. | Pull/regen, then `just talos-config`, confirm `_out/cp.yaml` and `_out/wk0.yaml` contain both `network: ${NETWORK_GATEWAY}/32` and `network: 0.0.0.0/0 / gateway: ${NETWORK_GATEWAY}`. Re-`scp` the snippets (`just snippets-cmd`). Then `just infra-down && just infra-up` so the VMs reboot with both the new config drive and the new bpg `initialization` shape. After bootstrap, verify with `talosctl --talosconfig _out/talosconfig -n $CP_IP get routestatus`. |
| Can't reach `${METALLB_RANGE}` IPs from workstation | Missing host route | `sudo ip route add <range> via $CP_IP` |

---

## File map (operator-relevant)

```
.env                       your filled-in config (gitignored)
.env.example               template you copy and edit
secrets/                   CA materials (Phase 2; gitignored except README)
_out/                      generated artifacts (gitignored)
  talos-schematic-id       Talos Image Factory id
  talos-<ver>-<id>-nocloud.iso downloaded Talos NoCloud ISO
  controlplane.yaml        base CP config (talosctl gen)
  worker.yaml              base worker config
  secrets.yaml             cluster PKI — DO NOT LOSE
  patches/{cp,wk0}.yaml    per-node patches (rendered)
  {cp,wk0}.yaml            final per-node configs (patched)
  talosconfig              talosctl auth/endpoints
  kubeconfig               kubectl auth
infra/                     OpenTofu module
  providers.tf, variables.tf, main.tf, outputs.tf
  cluster.tfvars.tpl       envsubst template
  cluster.tfvars.example   checked-in example values
talos/
  schematic.yaml           Image Factory extensions list
  patches/{cp,wk0}.yaml.tpl per-node patch templates
  scripts/
    build-image.sh         schematic + ISO + Proxmox upload
    render-tfvars.sh       .env → infra/cluster.tfvars
    gen-config.sh          Talos machine configs
    wait-maintenance.sh    poll VMs in insecure mode
    wait-secure.sh         poll CP secure API
    bootstrap-once.sh      idempotent etcd bootstrap
    wait-nodes-ready.sh    poll until kubectl reports Ready
Justfile                   operator entry point
flake.nix                  dev shell with every tool
Makefile, package.json     patagon test entrypoint (npm test → make test)
.ai/                       harness state (architecture, features, companions)
```

---

## What's next (Phase 2)

The bare cluster is the foundation. Phase 2 adds, in order:

1. **MetalLB** — L2-mode load balancer, IP pool from `${METALLB_RANGE}`.
2. **cert-manager** with a `ClusterIssuer` named `atricore-ca` (configurable
   via `CLUSTER_ISSUER_NAME`), signing certs from `secrets/ca.crt` +
   `secrets/ca.key`. Install with `just cert-manager-install`; verify with
   `just cert-manager-smoke`; remove with `just cert-manager-uninstall`. See
   the [Phase 2: cert-manager (atricore-ca)](#phase-2-cert-manager-atricore-ca)
   section above for details.
3. **Longhorn** — replicated block storage (single replica today; expandable
   when you add worker nodes later).
4. **`ops.justfile-end-to-end`** — polish: full `just up` / `just down`,
   status checks, and idempotent re-installs of the cluster services.
5. **`ops.smoke-test`** — a deployment that exercises storage + LB + TLS
   end-to-end, confirming the stack is healthy.

Run `patagon_status` (or read `.ai/feature_list.json`) for the live state.

---

## Glossary

- **CP** — control plane node (`cp.<domain>`).
- **WK0** — worker node 0 (`wk0.<domain>`).
- **Talos maintenance mode** — Talos's pre-config state, port 50000, no PKI.
- **Talos secure mode** — post-config state, PKI enforced, port 50000 still but with mutual TLS.
- **Image Factory** — `factory.talos.dev`, builds custom Talos images with extensions.
- **Schematic** — Image Factory input describing extensions; identified by content hash.
