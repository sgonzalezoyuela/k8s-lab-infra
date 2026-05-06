{
  description = "A Nix-flake-based talos 1.7.5 env";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  #inputs.nixpkgs.url = "github:NixOS/nixpkgs/ba52980377166b499e46a0d73ccec49ace678c09";

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];

    forEachSupportedSystem = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        });
  in {
    devShells = forEachSupportedSystem ({pkgs}: {
      default = pkgs.mkShell {
        packages = with pkgs; [
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
          yarn  # to build wiki site
          cmctl
          zsh
          envsubst
          just
          opentofu
          yq-go
          jq
        ];
        shellHook = ''
          echo
          echo -e "\e[1;32mAtricore k8s2 #4 - kubernetes (talos)\e[0m"
          echo
          echo " * ${pkgs.kubectl.name} / ${pkgs.kubecolor.name}"
          echo " * ${pkgs.kubernetes-helm.name}"
          echo " * ${pkgs.k9s.name}"
          echo " * ${pkgs.openssl.name}"
          echo " * ${pkgs.talosctl.name}"
          echo

          export A3C_HOME='/wa/infra/k8s/a3c-lab-4'
          export CP_IP="cp.k8s4.lab.atricore.io"
          export WK0_IP="wk0.k8s4.lab.atricore.io"
          export KUBECONFIG="$A3C_HOME/kubeconfig"
          export TALOSCONFIG="$A3C_HOME/_out/talosconfig"

          echo
          echo " - A3C_HOME=$A3C_HOME"
          echo " - CP_IP=$CP_IP"
          echo " - WK0_IP=$WK0_IP"
          echo
          echo " - KUBECONFIG=$KUBECONFIG"
          echo " - TALOSCONFIG=$TALOSCONFIG"
          echo
          kubecolor version
          echo
          echo "NOTE: use k alias to run kubecolor.  Autocomplete is also enabled."
          echo
          echo "*** Remember to add an IP route for the loadbalancer assigned ips via the cluster node ip"
          echo -e "\e[1;32msudo ip route add 10.200.0.0/24 via 10.0.1.40\e[0m"

          # Set up zsh with kubectl completion
          export ZDOTDIR=$(mktemp -d)
          cat > "$ZDOTDIR/.zshrc" << 'ZSHRC'
          # Load user's zsh configuration
          if [ -f "$HOME/.zshrc" ]; then
            source "$HOME/.zshrc"
          fi

          # Add zsh autocomplete for kubernetes
          autoload -Uz compinit && compinit
          source <(kubectl completion zsh)
          alias k=kubecolor
          compdef kubecolor=kubectl
          ZSHRC

          # Only drop into zsh for an interactive session; respect
          # `nix develop --command ...` (used by tests/CI).
          if [ -z "$NIX_DEVELOP_NO_ZSH" ] && [ -t 0 ] && [ -t 1 ]; then
            exec ${pkgs.zsh}/bin/zsh
          fi
        '';
      };
    });
  };
}
