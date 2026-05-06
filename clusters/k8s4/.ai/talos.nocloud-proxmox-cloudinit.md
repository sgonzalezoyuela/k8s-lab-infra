# talos.nocloud-proxmox-cloudinit Implementation Guide

## Overview

Boot Talos with the NoCloud image and use Proxmox cloud-init/NoCloud data to provide Talos machine config and static network config at first boot, avoiding temporary DHCP IP discovery.

## Technical Approach

<!-- Describe the implementation strategy here -->

## Code Examples

```
// Add code examples here
```

## Acceptance Criteria Reference

1. Talos Image Factory build/request flow uses the NoCloud platform/image variant required by Talos NoCloud datasource support, while preserving required system extensions.
2. OpenTofu/Proxmox VM definitions attach or configure a Proxmox cloud-init/NoCloud datasource for each Talos VM instead of relying on normal guest cloud-init inside Talos.
3. Each node receives its Talos machine config as NoCloud `user-data` and static network settings for its configured IP, gateway, and DNS as NoCloud/Proxmox network data before first boot.
4. The workflow no longer requires discovering random DHCP maintenance IPs before applying Talos configs, and Talos apply/bootstrap commands target the configured static IPs after first boot.
5. Operator-facing docs explain that Talos does not run generic cloud-init, but does parse NoCloud when booted with the NoCloud Talos image, and document any Proxmox snippet/storage requirements.
6. Existing structural tests cover the NoCloud image selection, cloud-init datasource wiring, static IP config, and docs guidance without requiring live Proxmox or Talos access.

## Edge Cases

- <!-- Edge case 1 -->
- <!-- Edge case 2 -->

## Dependencies

- <!-- List external dependencies here -->

## Testing Strategy

<!-- Describe how to test this feature beyond acceptance criteria -->

## Notes

User provided Talos v1.13 NoCloud docs. Correct design is not generic cloud-init in Talos, but Talos NoCloud datasource support. Proxmox cloud-init can provide NoCloud user-data/network-config when booting the NoCloud image. Proxmox docs path uses cicustom user=local:snippets/<node>.yml where snippet content is the Talos machine config; snippets may need placement/upload support.
