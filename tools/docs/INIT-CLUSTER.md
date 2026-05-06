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
| `METALLB_RANGE` | Phase 2: pool of IPs MetalLB hands to LoadBalancer services |
| `CA_CERT_PATH` / `CA_KEY_PATH` | Phase 2: paths under `secrets/` for cert-manager `ClusterIssuer` |

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
2. **cert-manager** with a `ClusterIssuer` named `own-ca`, signing certs from
   `secrets/ca.crt` + `secrets/ca.key`.
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
