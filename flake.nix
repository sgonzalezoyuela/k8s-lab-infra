{
  # a3c-lab monorepo: a reusable `tools/` library plus per-cluster workspaces
  # under `clusters/<name>/`. The root flake exposes `lib.<system>.mkClusterShell`,
  # which each cluster flake imports (via `path:../..`) and instantiates with its
  # own pinned nixpkgs (so `talosctl` version comes from the cluster), its name,
  # its Talos version, and an optional MetalLB range.
  #
  # See tools/docs/INIT-CLUSTER.md and the top-level README.md for the workflow.
  description = "a3c-lab monorepo (tools/ + clusters/)";

  # Root nixpkgs is only used by the tools-maintainer dev shell (cd tools && nix develop)
  # to run the structural test suite. Each cluster pins its OWN nixpkgs.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

    # Shared package list. Cluster shells get this AND the cluster-only env vars.
    # Tools-maintainer shell gets only the packages.
    sharedPackages = pkgs:
      with pkgs; [
        crane
        kubecolor
        kubectl
        kustomize
        kubeseal
        argo-workflows
        kubernetes-helm
        k9s
        openssl
        talosctl
        yarn
        cmctl
        zsh
        envsubst
        just
        opentofu
        yq-go
        jq
      ];
  in {
    # ---------------------------------------------------------------------
    # Reusable cluster shell builder. Each cluster's flake calls this with
    # its OWN pkgs (so talosctl is pinned per-cluster) and identity values.
    # ---------------------------------------------------------------------
    lib = forSystem (system: {
      mkClusterShell = {
        pkgs,
        clusterName,
        talosVersion,
        metalLBRange ? "10.4.200.0/24",
      }:
        pkgs.mkShell {
          packages = sharedPackages pkgs;
          shellHook = ''
            # Cluster identity exported here so scripts/Just/Make all see it.
            export CLUSTER_NAME="${clusterName}"
            export TALOS_VERSION="${talosVersion}"
            export METALLB_RANGE="${metalLBRange}"

            # Locate the shared tools/ library, which lives at <repo>/tools/
            # i.e. two levels up from clusters/<name>/. Resolved at shell
            # entry so cd-ing later doesn't break it.
            export TOOLS_DIR="$(realpath "$PWD/../../tools")"
            export JUST_JUSTFILE="$TOOLS_DIR/Justfile"

            # `make` from inside a cluster directory should drive the shared
            # tools/Makefile (with TOOLS_DIR pointing at it).
            alias make='make -f "$TOOLS_DIR/Makefile" TOOLS_DIR="$TOOLS_DIR"'

            # Talos / kube auth files live in this cluster's _out/.
            mkdir -p _out
            export KUBECONFIG="$PWD/_out/kubeconfig"
            export TALOSCONFIG="$PWD/_out/talosconfig"

            # Source the cluster's .env so CP_IP, WK0_IP, PROXMOX_*, NETWORK_*
            # are available to interactive use without `dotenv` plumbing.
            if [ -f .env ]; then
              set -a; . ./.env; set +a
            fi

            # A3C_HOME stays for backwards compatibility with the legacy
            # bootstrap.nix-flake-tools test (criterion: env var set).
            export A3C_HOME="$PWD"

            test -f "$JUST_JUSTFILE" \
              || echo "warn: $JUST_JUSTFILE not found; are you inside clusters/<name>?"

            echo
            echo -e "\e[1;32mcluster ${clusterName} (talos ${talosVersion})\e[0m"
            echo
            echo " * ${pkgs.kubectl.name} / ${pkgs.kubecolor.name}"
            echo " * ${pkgs.kubernetes-helm.name}"
            echo " * ${pkgs.k9s.name}"
            echo " * ${pkgs.openssl.name}"
            echo " * ${pkgs.talosctl.name}"
            echo
            echo " - CLUSTER_NAME=$CLUSTER_NAME"
            echo " - TALOS_VERSION=$TALOS_VERSION"
            echo " - TOOLS_DIR=$TOOLS_DIR"
            echo " - KUBECONFIG=$KUBECONFIG"
            echo " - TALOSCONFIG=$TALOSCONFIG"
            echo
            echo "Tip: run \`just env-check\`, \`just talos-image\`, \`tofu -chdir=infra plan\`."
            echo "*** Loadbalancer route reminder:"
            echo -e "\e[1;32msudo ip route add $METALLB_RANGE via 10.4.0.1\e[0m"

            # Warn loudly if the pinned nixpkgs talosctl drifts from the
            # declared cluster TALOS_VERSION. talosctl --short prints
            # "Client:\nTalos v1.13.0" — pick the second line's last field.
            actual_talos="$(${pkgs.talosctl}/bin/talosctl version --client --short 2>/dev/null | awk '/^Talos /{print $NF}')"
            if [ -n "$actual_talos" ] && [ "$actual_talos" != "$TALOS_VERSION" ]; then
              echo
              echo "warn: talosctl is $actual_talos but TALOS_VERSION=$TALOS_VERSION; bump nixpkgs in flake.nix" >&2
            fi

            # Set up zsh with kubectl completion (only for interactive sessions).
            export ZDOTDIR=$(mktemp -d)
            cat > "$ZDOTDIR/.zshrc" << 'ZSHRC'
            if [ -f "$HOME/.zshrc" ]; then
              source "$HOME/.zshrc"
            fi
            autoload -Uz compinit && compinit
            source <(kubectl completion zsh)
            alias k=kubecolor
            compdef kubecolor=kubectl
            ZSHRC

            if [ -z "$NIX_DEVELOP_NO_ZSH" ] && [ -t 0 ] && [ -t 1 ]; then
              exec ${pkgs.zsh}/bin/zsh
            fi
          '';
        };
    });

    # ---------------------------------------------------------------------
    # Tools-maintainer dev shell, used by `cd tools && nix develop` to run
    # the structural test suite (`make test`). NO cluster identity here.
    # ---------------------------------------------------------------------
    devShells = forSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      default = pkgs.mkShell {
        packages = sharedPackages pkgs;
        shellHook = ''
          # The tools maintainer shell should never claim a cluster identity,
          # but the test suite expects A3C_HOME / CP_IP / WK0_IP / KUBECONFIG /
          # TALOSCONFIG to be exported (legacy bootstrap.nix-flake-tools test).
          # Use placeholder values that are enough to be non-empty.
          export A3C_HOME="$PWD"
          export CP_IP="cp.example"
          export WK0_IP="wk0.example"
          export KUBECONFIG="$PWD/_out/kubeconfig"
          export TALOSCONFIG="$PWD/_out/talosconfig"
          # Tests reference $TOOLS_DIR for fixtures. Defaults to this dir.
          export TOOLS_DIR="$PWD"
          if [ -z "$NIX_DEVELOP_NO_ZSH" ] && [ -t 0 ] && [ -t 1 ]; then
            exec ${pkgs.zsh}/bin/zsh
          fi
        '';
      };
    });
  };
}
