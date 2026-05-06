# K8S Talos Cluster

The objective is to install and manage a K8S cluster based on Talos Linux
running in proxmox.

## Environment

Use nix flake to install and setup a shell with kubernetes, talosctl, and other tools.

## Install

Install a Control Plane (CP) and a Worker (WK_01).

The install should request an IP for each machine, and the proxmox node to run the vms.

1. Automate VM creation

Using terraform or other tool to manage proxmox vms.

2. Automate Talos install in VM

3. Automate Cluster configuration

- Install Storage provider: explore options
- Install IPs provider: metallb
- Install Certificate manager: use my own CA.



