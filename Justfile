set dotenv-load

default:
    @just --list

# Create or update .env from .env.example, prompting for required-empty values.
init-config:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f .env ]; then
      cp .env.example .env
      echo "Created .env from .env.example"
    fi
    # Prompt for PROXMOX_API_TOKEN_SECRET if empty (extend list as needed).
    for var in PROXMOX_API_TOKEN_SECRET; do
      current=$(grep -E "^${var}=" .env | cut -d= -f2-)
      if [ -z "$current" ]; then
        read -r -s -p "Value for $var: " val; echo
        sed -i "s|^${var}=.*|${var}=${val}|" .env
      fi
    done

# Verify every variable defined in .env.example is set and non-empty in .env.
env-check:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=()
    while IFS= read -r line; do
      [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
      var=$(echo "$line" | cut -d= -f1)
      val=$(grep -E "^${var}=" .env 2>/dev/null | cut -d= -f2- || true)
      [ -z "$val" ] && missing+=("$var")
    done < .env.example
    if [ ${#missing[@]} -gt 0 ]; then
      echo "Missing or empty in .env: ${missing[*]}" >&2
      exit 1
    fi
    echo "env OK"

# Build Talos Image Factory schematic, download ISO, upload to Proxmox.
talos-image: env-check
    ./talos/scripts/build-image.sh

# Render infra/cluster.tfvars from .env + _out/talos-schematic-id.
infra-render: env-check
    ./talos/scripts/render-tfvars.sh

# Apply OpenTofu — uploads Talos NoCloud user-data snippets and creates VMs.
infra-up: talos-image talos-config infra-render
    cd infra && tofu init -upgrade && tofu apply -auto-approve -var-file=cluster.tfvars

# Destroy the VMs (and any other infra-managed resources).
infra-down:
    cd infra && tofu destroy -auto-approve -var-file=cluster.tfvars

# Generate Talos machine configs (controlplane + worker) with per-node patches.
talos-config: env-check
    ./talos/scripts/gen-config.sh

# Fallback only: apply Talos machine configs manually if NoCloud first-boot
# configuration was intentionally bypassed during troubleshooting.
talos-apply: talos-config
    ./talos/scripts/wait-maintenance.sh
    talosctl apply-config --insecure -n $CP_IP  -f _out/cp.yaml
    talosctl apply-config --insecure -n $WK0_IP -f _out/wk0.yaml

# Bootstrap etcd on the control plane (idempotent).
talos-bootstrap: infra-up
    ./talos/scripts/wait-secure.sh
    ./talos/scripts/bootstrap-once.sh

# Fetch the kubeconfig from the control plane.
kubeconfig: talos-bootstrap
    talosctl kubeconfig --talosconfig _out/talosconfig -n $CP_IP $KUBECONFIG --force

# End-to-end: build the NoCloud image, generate configs, create VMs, bootstrap, and fetch kubeconfig.
cluster-up: talos-image talos-config infra-up talos-bootstrap kubeconfig
    ./talos/scripts/wait-nodes-ready.sh

# Tear down the cluster (destroys VMs + cleans local artifacts).
cluster-down: infra-down
    rm -f $KUBECONFIG _out/cp.yaml _out/wk0.yaml _out/patches/cp.yaml _out/patches/wk0.yaml
