# Architecture — a3c-lab-4 (k8s4 cluster)

This repository builds, installs, and operates a small Kubernetes cluster on
Talos Linux running in Proxmox.

## Goal

A reproducible "from clone to working cluster" path: `nix develop`, edit `.env`,
run a few `just` recipes, end with `kubectl get nodes` reporting Ready and a
working LB / TLS / storage stack.

## Layers

The codebase is organized in four layers, each with a clear boundary:

1. **infra** — Proxmox VM provisioning. OpenTofu + `bpg/proxmox` provider.
   Owns: VM definitions (CP, workers), disk, NIC, ISO mount, power state.
   Does NOT own: anything happening inside the VM.

2. **OS** — Talos Linux install + bootstrap. `talosctl` + Image Factory schematics.
   Owns: Talos image (with extensions), per-node machine configs, etcd bootstrap,
   kubeconfig retrieval. PKI is left to Talos itself.

3. **cluster** — In-cluster services. Helm + kustomize.
   Owns: MetalLB (LB IPs), cert-manager + ClusterIssuer (own CA), Longhorn (storage).
   Future: ingress controller, observability, etc.

4. **ops** — Operator-facing orchestration. `Justfile`.
   Owns: top-level recipes (`init-config`, `env-check`, `cluster-up`, `cluster-down`,
   `kubeconfig`, ...). All cross-layer flow lives here.

## Directory layout

```
.
├── flake.nix              # nix devShell — all required tools
├── flake.lock
├── Justfile               # operator entry point (ops layer)
├── .env.example           # config template; copied to .env per checkout
├── .env                   # gitignored, operator-edited
├── infra/                 # OpenTofu (infra layer)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf
│   ├── outputs.tf
│   ├── cluster.tfvars.tpl # rendered via envsubst from .env
│   └── cluster.tfvars.example
├── talos/                 # OS layer
│   ├── schematic.yaml     # Talos Image Factory extensions
│   ├── patches/           # per-node config patch templates
│   │   ├── cp.yaml.tpl
│   │   └── wk0.yaml.tpl
│   └── scripts/           # build-image.sh, gen-config.sh, etc.
├── cluster/               # cluster layer (Helm values, manifests)
│   ├── metallb/
│   ├── cert-manager/
│   └── longhorn/
├── secrets/               # gitignored (except .gitkeep + README)
│   ├── ca.crt             # operator-supplied CA cert (cert-manager)
│   └── ca.key             # operator-supplied CA key (cert-manager)
├── _out/                  # gitignored, all generated artifacts
│   ├── talos-schematic-id
│   ├── talos-<ver>-<id>.iso
│   ├── controlplane.yaml  # talosctl gen
│   ├── worker.yaml
│   ├── secrets.yaml
│   ├── cp.yaml            # patched per-node config
│   ├── wk0.yaml
│   ├── talosconfig
│   └── kubeconfig
└── .ai/                   # patagon harness (architecture, features, companions)
    ├── architecture.md
    ├── feature_list.json
    └── <feature-id>.md    # companion files
```

## Configuration model

Single source of truth: **`.env`**.

Everything else is rendered from it:

```
.env
  ├── envsubst → infra/cluster.tfvars
  ├── envsubst → talos/patches/*.yaml (per-node)
  ├── shell vars in Justfile recipes (`set dotenv-load`)
  └── helm --set values for cluster services
```

Operator workflow:

1. `cp .env.example .env`
2. `just init-config` (interactively prompts for required-empty values, e.g. token secret)
3. `just env-check` (validates completeness)
4. `just cluster-up` (executes the full path)

## Justfile recipes (canonical)

| Recipe              | Purpose                                                                |
|---------------------|------------------------------------------------------------------------|
| `init-config`       | Create `.env` from `.env.example`, prompt for secrets                  |
| `env-check`         | Verify all `.env` vars are set                                         |
| `talos-image`       | Build Talos schematic, download ISO, upload to Proxmox                 |
| `infra-render`      | Render `infra/cluster.tfvars` from `.env`                              |
| `infra-up`          | OpenTofu apply (create VMs)                                            |
| `infra-down`        | OpenTofu destroy                                                       |
| `talos-config`      | Generate Talos machine configs + per-node patches                      |
| `talos-apply`       | `talosctl apply-config` to both nodes (insecure mode)                  |
| `talos-bootstrap`   | `talosctl bootstrap` on CP (idempotent)                                |
| `kubeconfig`        | Fetch kubeconfig from CP                                               |
| `cluster-up`        | Aggregate: image → infra-up → config → apply → bootstrap → kubeconfig  |
| `cluster-down`      | Tear-down inverse of cluster-up                                        |

Phase 2 will add: `metallb-up`, `cert-manager-up`, `longhorn-up`, `smoke-test`.

## Conventions

- **PKI**: Talos manages its own etcd/kubelet PKI from the cluster secrets bundle.
  "Own CA" in this project applies **only** to cert-manager `ClusterIssuer` for
  signing application/ingress certificates (Phase 2).
- **Idempotence**: every recipe must be safe to re-run. Generated artifacts go
  under `_out/`; rebuilding them is cheap. The cluster secrets bundle
  (`_out/secrets.yaml`) is the one exception — never regenerated after first run.
- **No state in repo**: kubeconfig, talosconfig, .env, secrets/, tfstate are all
  gitignored. The repo is reproducible from `.env` + ssh access to Proxmox.
- **Configurability**: VM disk size, MetalLB IP range, and similar lab knobs are
  exposed as `.env` variables, never hard-coded.

## Out of scope (Phase 1)

- DNS automation. We assume `cp.k8s4.lab.atricore.io` and `wk0.k8s4.lab.atricore.io`
  resolve via the network's DNS server (`10.0.1.77`).
- Remote tfstate backend. State stays local under `infra/`.
- High availability. Single CP, single worker; the design accommodates more
  workers via additional `.env` entries later.
- Cluster upgrades. A future feature will model Talos/k8s upgrade flow.

## Patagon-driven workflow

Features land in `failing` state, get implemented, run tests, transition to
`implemented`, then `passing` after operator review. See `.ai/feature_list.json`
for the live feature list and `.ai/<feature-id>.md` for per-feature implementation
companions.
