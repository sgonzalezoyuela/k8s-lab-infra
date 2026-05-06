# Companion: bootstrap.split-tools-and-clusters

## Why
The repo currently mixes reusable tooling (scripts, OpenTofu module, Justfile,
Makefile, schematic, patches, docs) with cluster-specific data (`.env`,
`_out/`, `secrets/`, `.ai/`, tfvars, tfstate, kubeconfig). Adding a second
cluster today requires copying the whole repo and editing dozens of paths and
the flake. The fix is to split into a monorepo: one shared `tools/` library
and per-cluster `clusters/<name>/` workspaces.

## Final layout

```
a3c-lab-4/
├── flake.nix                           # exports lib.<system>.mkClusterShell
├── flake.lock
├── README.md
├── .gitignore                          # ignores clusters/*/_out, etc.
│
├── tools/
│   ├── Justfile                        # set working-directory := invocation_directory()
│   ├── Makefile                        # TOOLS_DIR ?= $(CURDIR); paths via $(TOOLS_DIR)/...
│   ├── package.json                    # npm test → make test
│   ├── .env.example                    # NO TALOS_VERSION (lives in flake)
│   ├── infra/                          # OpenTofu MODULE only (no state, no provider block)
│   │   ├── main.tf
│   │   ├── variables.tf                # provider auth vars stay here as MODULE inputs
│   │   ├── outputs.tf
│   │   └── cluster.tfvars.tpl
│   ├── talos/
│   │   ├── schematic.yaml
│   │   ├── patches/{cp,wk0}.yaml.tpl
│   │   └── scripts/                    # build-image.sh, gen-config.sh, render-tfvars.sh,
│   │                                   # print-snippet-upload-cmd.sh, wait-*.sh,
│   │                                   # bootstrap-once.sh, new-cluster.sh
│   ├── docs/INIT-CLUSTER.md
│   └── .ai/                            # tools backlog (separate from any cluster's)
│
└── clusters/
    ├── _scaffold/                      # copied by `just new-cluster <name>`
    │   ├── flake.nix                   # __CLUSTER_NAME__, __TALOS_VERSION__, __NIXPKGS_REV__
    │   ├── .env.example
    │   ├── Makefile                    # cluster smoke test
    │   └── infra/{main.tf,variables.tf,outputs.tf}
    │
    └── k8s4/                           # the existing cluster, migrated in place
        ├── flake.nix                   # nixpkgs pinned to a rev with talosctl-1.13.0
        ├── flake.lock
        ├── .env                        # gitignored
        ├── _out/                       # gitignored
        ├── secrets/                    # gitignored
        ├── .ai/                        # patagon backlog for THIS cluster
        ├── Makefile                    # cluster smoke test
        └── infra/
            ├── main.tf                 # provider {} + module "cluster" { source = "../../../tools/infra" }
            ├── variables.tf            # mirrors tools/infra/variables.tf
            ├── outputs.tf              # re-exposes module.cluster outputs
            ├── cluster.tfvars          # rendered (gitignored)
            ├── terraform.tfstate       # MIGRATED: addresses under module.cluster.*
            └── .terraform.lock.hcl
```

## Root flake.nix sketch

```nix
{
  description = "a3c-lab monorepo";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forSystem = f: nixpkgs.lib.genAttrs systems (system: f system);
  in {
    lib = forSystem (system: {
      mkClusterShell = {
        pkgs,                          # injected by cluster from cluster's nixpkgs
        clusterName,
        talosVersion,
        metalLBRange ? "10.4.200.0/24",
      }: pkgs.mkShell {
        packages = with pkgs; [
          kubectl kubecolor kustomize kubernetes-helm k9s openssl
          talosctl                       # version comes from CLUSTER's pkgs
          cmctl envsubst just opentofu yq-go jq
        ];
        shellHook = ''
          export CLUSTER_NAME="${clusterName}"
          export TALOS_VERSION="${talosVersion}"
          export TOOLS_DIR="$(realpath "$PWD/../../tools")"
          export JUST_JUSTFILE="$TOOLS_DIR/Justfile"
          alias make='make -f "$TOOLS_DIR/Makefile"'
          export KUBECONFIG="$PWD/_out/kubeconfig"
          export TALOSCONFIG="$PWD/_out/talosconfig"

          test -f "$JUST_JUSTFILE" \
            || echo "warn: $JUST_JUSTFILE not found; are you inside clusters/<name>?"
          # banner + zsh hook
        '';
      };
    });

    # tools-maintainer dev shell, used by `cd tools && nix develop` to run tests
    devShells = forSystem (system: let
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
    in {
      tools = pkgs.mkShell { /* same packages, no cluster vars */ };
    });
  };
}
```

## Cluster flake.nix sketch

```nix
{
  description = "Talos cluster k8s4";
  inputs.nixpkgs.url  = "github:NixOS/nixpkgs/<sha-with-talosctl-1.13.0>";
  inputs.monorepo.url = "path:../..";
  outputs = { self, nixpkgs, monorepo, ... }: let
    system = "x86_64-linux";
    pkgs   = import nixpkgs { inherit system; config.allowUnfree = true; };
  in {
    devShells.${system}.default = monorepo.lib.${system}.mkClusterShell {
      inherit pkgs;
      clusterName  = "k8s4";
      talosVersion = "v1.13.0";
      metalLBRange = "10.4.200.0/24";
    };
  };
}
```

## Cluster wrapper infra/main.tf sketch

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = { source = "bpg/proxmox", version = "~> 0.66" }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_insecure
}

module "cluster" {
  source = "../../../tools/infra"
  proxmox_endpoint         = var.proxmox_endpoint
  proxmox_api_token_id     = var.proxmox_api_token_id
  proxmox_api_token_secret = var.proxmox_api_token_secret
  proxmox_insecure         = var.proxmox_insecure
  proxmox_node             = var.proxmox_node
  proxmox_storage_pool     = var.proxmox_storage_pool
  proxmox_snippet_storage  = var.proxmox_snippet_storage
  talos_iso_file_id        = var.talos_iso_file_id
  network_bridge           = var.network_bridge
  network_cidr             = var.network_cidr
  network_gateway          = var.network_gateway
  network_dns              = var.network_dns
  cluster_name             = var.cluster_name
  cp_cores                 = var.cp_cores
  cp_memory_mb             = var.cp_memory_mb
  cp_disk_size_gb          = var.cp_disk_size_gb
  wk_cores                 = var.wk_cores
  wk_memory_mb             = var.wk_memory_mb
  wk_disk_size_gb          = var.wk_disk_size_gb
  wk_storage_disk_size_gb  = var.wk_storage_disk_size_gb
  cp_hostname              = var.cp_hostname
  cp_ip                    = var.cp_ip
  wk0_hostname             = var.wk0_hostname
  wk0_ip                   = var.wk0_ip
}
```

`clusters/k8s4/infra/variables.tf` mirrors every variable in
`tools/infra/variables.tf` so tfvars apply at the wrapper layer.
`clusters/k8s4/infra/outputs.tf` re-exposes `module.cluster.vm_ids` etc.

## Path-aware scripts

Standard preamble in every script under `tools/talos/scripts/`:

```bash
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside a cluster's nix develop shell}"
schematic="$TOOLS_DIR/talos/schematic.yaml"
patches_dir="$TOOLS_DIR/talos/patches"
tfvars_tpl="$TOOLS_DIR/infra/cluster.tfvars.tpl"
# outputs go to $PWD/_out, $PWD/infra/cluster.tfvars (cluster dir)
```

Today's scripts to migrate: `build-image.sh`, `gen-config.sh`,
`render-tfvars.sh`, `print-snippet-upload-cmd.sh`, `bootstrap-once.sh`,
`wait-secure.sh`, `wait-maintenance.sh`, `wait-nodes-ready.sh`.

## Migration sequence

1. Create new top-level `flake.nix` and `tools/`, `clusters/k8s4/`,
   `clusters/_scaffold/` skeletons (additive).
2. `git mv` reusable files into `tools/`. The old top-level
   `infra/{main,variables,outputs,cluster.tfvars.tpl}.tf` go to `tools/infra/`.
   The current `infra/providers.tf` is REMOVED (provider lives in cluster
   wrapper) — its content is folded into the wrapper.
3. `git mv` cluster-specific files into `clusters/k8s4/`:
   `.env`, `_out/`, `secrets/`, `.ai/`, `kubeconfig`,
   `infra/cluster.tfvars`, `infra/terraform.tfstate*`,
   `infra/.terraform.lock.hcl`.
4. Add new files: cluster `flake.nix`, cluster wrapper
   `infra/{main,variables,outputs}.tf`, scaffold templates.
5. Edit reusable code: every script gets the `$TOOLS_DIR` preamble; Justfile
   gets `set working-directory := invocation_directory()`; Makefile uses
   `TOOLS_DIR ?= $(CURDIR)` with `$(TOOLS_DIR)/...` paths;
   `tools/.env.example` drops `TALOS_VERSION`.
6. Migrate Tofu state addresses (run from `clusters/k8s4/infra/`):
   ```bash
   tofu init -upgrade
   tofu state mv proxmox_virtual_environment_vm.cp  module.cluster.proxmox_virtual_environment_vm.cp
   tofu state mv proxmox_virtual_environment_vm.wk0 module.cluster.proxmox_virtual_environment_vm.wk0
   tofu plan                              # MUST show: No changes
   ```
   Live VMs unaffected; only logical addresses move.
7. Verify:
   - `cd tools && nix develop --command make test` → 7 structural tests pass.
   - `cd clusters/k8s4 && nix develop` → banner shows
     `cluster k8s4 (talos v1.13.0)`; `talosctl version --client` is 1.13.0.
   - `just env-check`, `just talos-config`, `tofu -chdir=infra plan` clean.
8. Cleanup: remove now-empty top-level `flake.nix`, `Justfile`, `Makefile`,
   `package.json`, `talos/`, `infra/` at the root. Update `.gitignore`.
9. Smoke test scaffolding: `just new-cluster k8s5-test`. Verify the new
   cluster directory has expected files with placeholders substituted.
   (Don't deploy.)

## Tests

- `tools/Makefile` keeps every existing structural test, but runs from inside
  `tools/` (the tools-maintainer shell). Tmpdir fixtures must export
  `TOOLS_DIR=<repo>/tools` so scripts find their assets.
- `clusters/k8s4/Makefile` adds a small `smoke` target asserting:
  - `.env` is complete (every var declared in `tools/.env.example` has a
    value).
  - `flake.nix` declares `clusterName = "k8s4"` and `talosVersion = "v1.13.0"`.
  - `tofu -chdir=infra validate` succeeds.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Tofu state addresses change | `tofu state mv`, then `tofu plan == no-change` gate |
| Scripts run outside a cluster shell silently break | `: "${TOOLS_DIR:?...}"` mandatory preamble |
| Cluster TALOS_VERSION drifts from nixpkgs talosctl | shellHook compares `talosctl version --client --short` to `$TALOS_VERSION`; warn on mismatch |
| Operator runs old top-level `just` after migration | Step 8 deletes the old files; warn if both layouts coexist |
| `path:../..` flake input copies entire monorepo | Acceptable for current size; revisit if `clusters/` ever grows binary artifacts |

## Out of scope

- Phase 2 features (cert-manager, MetalLB, Longhorn).
- Remote OpenTofu backend.
- Splitting `tools/` into a separate git repo (one-line URL change later).
- Patagon "tools" backlog — keep `.ai/` per cluster for now.
