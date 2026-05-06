# a3c-lab

Monorepo for one or more Talos-on-Proxmox Kubernetes clusters.

The repo is split into:

- `tools/` — shared library: scripts, OpenTofu module, Justfile, Makefile,
  patches, schematic, and operator docs. Version-agnostic. Same code drives
  every cluster.
- `clusters/<name>/` — one workspace per cluster. Owns its `.env`, generated
  artifacts (`_out/`), secrets, `.ai/` (patagon backlog), OpenTofu state, and
  a `flake.nix` that **pins this cluster's Talos version** by pinning
  `nixpkgs` to a revision that ships the matching `talosctl`.
- `clusters/_scaffold/` — template copied by `just new-cluster <name>` to
  spin up cluster #N.

## Workflow (existing cluster)

```bash
cd clusters/k8s4
nix develop                  # banner shows: cluster k8s4 (talos v1.13.0)
just env-check
just talos-image             # build/upload Talos NoCloud ISO
just talos-config            # render per-node Talos machine configs
just snippets-cmd            # prints the scp command for the snippets
# (run the printed scp lines once, manually)
just infra-up                # tofu apply, creates VMs against this cluster's state
just talos-bootstrap
just kubeconfig
kubectl get nodes
```

The cluster's `nix develop` shell exports:

- `TOOLS_DIR=<repo>/tools` (every script and recipe finds its assets here)
- `JUST_JUSTFILE=$TOOLS_DIR/Justfile` (`just` works from inside the cluster)
- `TALOS_VERSION` (matches the talosctl in `$PATH`)
- `KUBECONFIG`, `TALOSCONFIG` (point at this cluster's `_out/`)
- `make` aliased to `make -f $TOOLS_DIR/Makefile` for structural tests

## Workflow (new cluster)

```bash
cd clusters/k8s4         # any cluster will do, since `just` is shared
just new-cluster k8s5    # scaffolds clusters/k8s5/
cd ../k8s5
$EDITOR flake.nix        # bump nixpkgs rev + talosVersion if needed
$EDITOR .env             # cluster-specific values
nix develop
just init-config         # prompts for PROXMOX_API_TOKEN_SECRET
just env-check
just cluster-up
```

Each cluster's `nix develop` shell will use the talosctl version that its own
`flake.nix` nixpkgs pin ships. Two clusters can therefore run different Talos
versions in parallel without interfering.

## Bumping Talos for a cluster

1. Edit `clusters/<name>/flake.nix`:
   - Update `inputs.nixpkgs.url` to a revision that ships the desired
     talosctl version.
   - Update `talosVersion` to match (the shell warns on drift).
2. `nix flake update --flake clusters/<name>` (or `nix flake lock`).
3. `nix develop` from inside the cluster — the shell loads with the new
   binary.
4. `just talos-image` rebuilds the ISO for the new Talos version.
5. `just talos-config` regenerates the machine configs.
6. `just snippets-cmd` and re-upload, then `just infra-up`.

## Documentation

- `tools/docs/INIT-CLUSTER.md` — full operator guide (Proxmox prerequisites,
  ACL setup, snippet upload, troubleshooting, file map).
- Per-cluster patagon backlogs live under `clusters/<name>/.ai/`.
- The tooling backlog (refactors of `tools/` itself) lives at the repo root
  in `tools/.ai/`.

## Repo layout

```
a3c-lab/
├── flake.nix                 # exports lib.<system>.mkClusterShell
├── tools/                    # reusable library
│   ├── Justfile
│   ├── Makefile              # structural tests; run from `cd tools && nix develop`
│   ├── package.json
│   ├── .env.example
│   ├── infra/                # OpenTofu MODULE (no state)
│   ├── talos/{schematic.yaml,patches/,scripts/}
│   ├── docs/INIT-CLUSTER.md
│   └── scripts/new-cluster.sh
└── clusters/
    ├── _scaffold/            # template for new clusters
    └── k8s4/
        ├── flake.nix         # pins nixpkgs → talosctl, declares clusterName/talosVersion
        ├── .env              # gitignored
        ├── _out/             # gitignored: PKI, kubeconfig, …
        ├── secrets/          # gitignored except README.md
        ├── .ai/              # patagon backlog for THIS cluster
        ├── Makefile          # `make smoke`
        └── infra/            # local state + thin wrapper module
```
