{
  description = "Talos cluster k8s4";

  # Pin nixpkgs at a revision known to ship talosctl 1.13.0. This is the same
  # revision that the previous top-level flake used, so the cluster keeps the
  # exact `talosctl` binary it was built with. Bump this rev (and TALOS_VERSION
  # below) in lockstep when upgrading Talos.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/ed67bc86e84e51d4a88e73c7fd36006dc876476f";

  # The shared monorepo library lives two levels up. Using `path:` keeps the
  # dependency local without copying lock state. If `tools/` is later split into
  # its own repo, change this to a `github:` URL.
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
      clusterName = "k8s4";
      talosVersion = "v1.13.0";
      metalLBRange = "10.4.200.0/24";
    };
  };
}
