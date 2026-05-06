{
  description = "Talos cluster __CLUSTER_NAME__";

  # Pin nixpkgs to a revision that ships the talosctl version this cluster
  # targets. Bump this rev (and `talosVersion` below) in lockstep when
  # upgrading Talos. Find a suitable rev with:
  #   nix flake metadata github:NixOS/nixpkgs/<channel>
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # Shared monorepo library lives two levels up.
  inputs.monorepo.url = "path:../..";

  outputs = {
    self,
    nixpkgs,
    monorepo,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    devShells.${system}.default = monorepo.lib.${system}.mkClusterShell {
      inherit pkgs;
      clusterName = "__CLUSTER_NAME__";
      talosVersion = "v1.13.0";
      metalLBRange = "10.4.200.0/24";
    };
  };
}
