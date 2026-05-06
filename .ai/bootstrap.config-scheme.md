# Companion: bootstrap.config-scheme

## Purpose
Single source of truth for every downstream feature's configuration. `.env` is the
operator-edited file; everything else (tfvars, Talos patches, Helm values) is rendered
from it via `envsubst` in Justfile recipes.

## `.env.example` — required variables

```
# --- Proxmox ---
PROXMOX_ENDPOINT=https://emcc.lab.atricore.io:8006/api2/json
PROXMOX_INSECURE=false                       # set true if using self-signed cert
PROXMOX_NODE=emcc                            # target node name in cluster
PROXMOX_API_TOKEN_ID=root@pam!terraform      # API token id
PROXMOX_API_TOKEN_SECRET=                    # UUID, REQUIRED, leave blank in example
PROXMOX_STORAGE_POOL=local-lvm               # VM disk storage
PROXMOX_ISO_STORAGE=local                    # ISO storage (must support iso content)

# --- Cluster identity ---
CLUSTER_NAME=k8s4
CLUSTER_DOMAIN=k8s4.lab.atricore.io

# --- Nodes ---
CP_HOSTNAME=cp.k8s4.lab.atricore.io
CP_IP=10.4.0.1
WK0_HOSTNAME=wk0.k8s4.lab.atricore.io
WK0_IP=10.4.0.10

# --- Network ---
NETWORK_CIDR=8                               # flat /8 lab network; gateway must be on-link
NETWORK_GATEWAY=10.0.0.1
NETWORK_DNS=10.0.1.77
NETWORK_BRIDGE=vmbr0

# --- Control-plane VM sizing ---
CP_CORES=4
CP_MEMORY_MB=4096
CP_DISK_SIZE_GB=30                           # OS disk

# --- Worker VM sizing ---
WK_CORES=8
WK_MEMORY_MB=8192
WK_DISK_SIZE_GB=30                           # OS disk
WK_STORAGE_DISK_SIZE_GB=200                  # second disk attached to workers, used by Longhorn

# --- Talos ---
TALOS_VERSION=v1.13.0

# --- Phase 2 (forward-declared, unused in Phase 1) ---
METALLB_RANGE=10.4.200.0/24
CA_CERT_PATH=secrets/ca.crt
CA_KEY_PATH=secrets/ca.key
```

## Justfile skeleton

```just
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
```

## `secrets/README.md` (minimal)

```
# secrets/

Holds CA material and other secrets. Everything in this directory is gitignored
except this README and `.gitkeep`. See `.ai/architecture.md` for the layout.
```

## Notes
- Later features add more recipes to the Justfile; do not collapse this skeleton.
- `set dotenv-load` is critical: it makes `.env` values available as both env vars
  AND Just variables in subsequent recipes.
- `init-config` only prompts for `PROXMOX_API_TOKEN_SECRET` initially; extend the
  loop as future features add other secret-sensitive vars.
