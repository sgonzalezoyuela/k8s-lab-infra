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

# Apply OpenTofu — creates the CP and WK0 VMs on Proxmox.
infra-up: infra-render
    cd infra && tofu init -upgrade && tofu apply -auto-approve -var-file=cluster.tfvars

# Destroy the VMs (and any other infra-managed resources).
infra-down:
    cd infra && tofu destroy -auto-approve -var-file=cluster.tfvars
