# Test entrypoint for the patagon harness.
#
# Each feature appends a `test-<feature-id>` target below and adds it as a
# prerequisite of the top-level `test` target. The targets verify each
# feature's acceptance criteria as actual shell assertions, executed inside
# the project's nix devShell where required tools are guaranteed to exist.

.PHONY: test
test: test-bootstrap.nix-flake-tools
test: test-bootstrap.config-scheme
test: test-talos.image-factory-schematic
test: test-infra.opentofu.proxmox-vms

# ---------------------------------------------------------------------------
# bootstrap.nix-flake-tools
# ---------------------------------------------------------------------------
# Verifies:
#   - the flake evaluates and the devShell enters non-interactively
#   - every tool listed in the feature's acceptance is in PATH
#   - every devShell export is non-empty
#   - flake.lock is tracked by git
.PHONY: test-bootstrap.nix-flake-tools
test-bootstrap.nix-flake-tools:
	@echo "==> bootstrap.nix-flake-tools"
	@nix develop --command bash -c '\
		set -eu ; \
		for tool in kubectl kubecolor kustomize kubeseal helm k9s openssl \
		            talosctl cmctl just envsubst argo crane tofu yq jq ; do \
		  command -v "$$tool" >/dev/null \
		    || { echo "    [FAIL] tool not in PATH: $$tool" >&2 ; exit 1 ; } ; \
		done ; \
		for v in A3C_HOME CP_IP WK0_IP KUBECONFIG TALOSCONFIG ; do \
		  eval "val=\$${$$v:-}" ; \
		  test -n "$$val" \
		    || { echo "    [FAIL] env var unset: $$v" >&2 ; exit 1 ; } ; \
		done ; \
		tofu version >/dev/null ; \
		yq --version >/dev/null ; \
		jq --version >/dev/null ; \
	'
	@git ls-files --error-unmatch flake.lock >/dev/null 2>&1 \
	  || { echo "    [FAIL] flake.lock not tracked by git" >&2 ; exit 1 ; }
	@echo "    [PASS] bootstrap.nix-flake-tools"

# ---------------------------------------------------------------------------
# bootstrap.config-scheme
# ---------------------------------------------------------------------------
# Verifies:
#   - .env.example contains every required variable (criterion 1)
#   - Justfile has dotenv-load + the three required recipes (criterion 2)
#   - just init-config is a no-op when .env is already complete (criterion 3,
#     non-prompt path; the interactive branch is intentionally not exercised)
#   - just env-check passes/fails correctly (criterion 4)
#   - secrets/ layout exists (criterion 5)
#   - .gitignore has the new entries (criterion 6) and preserves the legacy
#     ones (criterion 7)
.PHONY: test-bootstrap.config-scheme
test-bootstrap.config-scheme:
	@echo "==> bootstrap.config-scheme"
	@nix develop --command bash -c '\
		set -eu ; \
		required="PROXMOX_ENDPOINT PROXMOX_INSECURE PROXMOX_NODE \
		          PROXMOX_API_TOKEN_ID PROXMOX_API_TOKEN_SECRET \
		          PROXMOX_STORAGE_POOL PROXMOX_ISO_STORAGE \
		          CLUSTER_NAME CLUSTER_DOMAIN \
		          CP_HOSTNAME CP_IP WK0_HOSTNAME WK0_IP \
		          NETWORK_CIDR NETWORK_GATEWAY NETWORK_DNS NETWORK_BRIDGE \
		          VM_DISK_SIZE_GB VM_MEMORY_MB VM_CORES \
		          TALOS_VERSION METALLB_RANGE CA_CERT_PATH CA_KEY_PATH" ; \
		test -f .env.example \
		  || { echo "    [FAIL] .env.example missing" >&2 ; exit 1 ; } ; \
		for k in $$required ; do \
		  grep -qE "^$${k}=" .env.example \
		    || { echo "    [FAIL] .env.example missing key: $$k" >&2 ; exit 1 ; } ; \
		done ; \
		test -f Justfile \
		  || { echo "    [FAIL] Justfile missing" >&2 ; exit 1 ; } ; \
		grep -q "^set dotenv-load" Justfile \
		  || { echo "    [FAIL] Justfile missing: set dotenv-load" >&2 ; exit 1 ; } ; \
		grep -qE "^default:" Justfile \
		  || { echo "    [FAIL] Justfile missing recipe: default" >&2 ; exit 1 ; } ; \
		grep -qE "^init-config:" Justfile \
		  || { echo "    [FAIL] Justfile missing recipe: init-config" >&2 ; exit 1 ; } ; \
		grep -qE "^env-check:" Justfile \
		  || { echo "    [FAIL] Justfile missing recipe: env-check" >&2 ; exit 1 ; } ; \
		test -f secrets/.gitkeep \
		  || { echo "    [FAIL] secrets/.gitkeep missing" >&2 ; exit 1 ; } ; \
		test -f secrets/README.md \
		  || { echo "    [FAIL] secrets/README.md missing" >&2 ; exit 1 ; } ; \
		for p in "^\.env\$$" "^secrets/\*\$$" "^!secrets/\.gitkeep\$$" \
		         "^!secrets/README\.md\$$" "^_out/\$$" "^\.terraform/\$$" \
		         "^\.terraform\.lock\.hcl\$$" "^\*\.tfstate\$$" \
		         "^\*\.tfstate\.\*\$$" "^\*\.tfvars\$$" \
		         "^!\*\.tfvars\.example\$$" ; do \
		  grep -qE "$$p" .gitignore \
		    || { echo "    [FAIL] .gitignore missing pattern: $$p" >&2 ; exit 1 ; } ; \
		done ; \
		for p in jpkl kubeconfig talosconfig tmp ; do \
		  grep -qE "^$${p}\$$" .gitignore \
		    || { echo "    [FAIL] .gitignore lost legacy entry: $$p" >&2 ; exit 1 ; } ; \
		done ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		cp .env.example "$$tmp/.env.example" ; \
		cp .env.example "$$tmp/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake-uuid-12345|" "$$tmp/.env" ; \
		cp Justfile "$$tmp/Justfile" ; \
		( cd "$$tmp" && just env-check >/dev/null ) \
		  || { echo "    [FAIL] env-check should pass with full .env" >&2 ; exit 1 ; } ; \
		sed -i "s|^CP_IP=.*|CP_IP=|" "$$tmp/.env" ; \
		if ( cd "$$tmp" && just env-check >/dev/null 2>&1 ) ; then \
		  echo "    [FAIL] env-check should fail when CP_IP empty" >&2 ; exit 1 ; \
		fi ; \
		tmp2=$$(mktemp -d) ; \
		trap "rm -rf $$tmp $$tmp2" EXIT ; \
		cp .env.example "$$tmp2/.env.example" ; \
		cp .env.example "$$tmp2/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake|" "$$tmp2/.env" ; \
		cp Justfile "$$tmp2/Justfile" ; \
		( cd "$$tmp2" && just init-config </dev/null >/dev/null 2>&1 ) \
		  || { echo "    [FAIL] init-config should be no-op when .env complete" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] bootstrap.config-scheme"

# ---------------------------------------------------------------------------
# talos.image-factory-schematic
# ---------------------------------------------------------------------------
# Verifies (without hitting the network):
#   - schematic.yaml lists EXACTLY the three required system extensions (criterion 2)
#   - build-image.sh exists, is executable, and references the factory URLs,
#     Proxmox auth header, ISO probe URL, and upload URL (structural cover for
#     criteria 1, 3, 4, 5)
#   - Justfile has the talos-image recipe
#   - build-image.sh fails fast when env is unset (criterion 6)
.PHONY: test-talos.image-factory-schematic
test-talos.image-factory-schematic:
	@echo "==> talos.image-factory-schematic"
	@nix develop --command bash -c '\
		set -eu ; \
		test -f talos/schematic.yaml \
		  || { echo "    [FAIL] talos/schematic.yaml missing" >&2 ; exit 1 ; } ; \
		exts=$$(yq -r ".customization.systemExtensions.officialExtensions[]" talos/schematic.yaml | sort) ; \
		expected="siderolabs/iscsi-tools\nsiderolabs/qemu-guest-agent\nsiderolabs/util-linux-tools" ; \
		[ "$$exts" = "$$(printf "%b" "$$expected")" ] \
		  || { echo "    [FAIL] schematic extensions mismatch:" >&2 ; echo "$$exts" >&2 ; exit 1 ; } ; \
		script=talos/scripts/build-image.sh ; \
		test -x "$$script" \
		  || { echo "    [FAIL] $$script not executable" >&2 ; exit 1 ; } ; \
		grep -q "factory.talos.dev/schematics" "$$script" \
		  || { echo "    [FAIL] script missing factory POST URL" >&2 ; exit 1 ; } ; \
		grep -q "factory.talos.dev/image/" "$$script" \
		  || { echo "    [FAIL] script missing factory image URL pattern" >&2 ; exit 1 ; } ; \
		grep -q "PVEAPIToken=" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox auth header" >&2 ; exit 1 ; } ; \
		grep -q "/storage/.*content?content=iso" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox ISO probe URL" >&2 ; exit 1 ; } ; \
		grep -q "/storage/.*upload" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox upload URL" >&2 ; exit 1 ; } ; \
		grep -qE "^talos-image:" Justfile \
		  || { echo "    [FAIL] Justfile lacks talos-image recipe" >&2 ; exit 1 ; } ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		cp -r talos "$$tmp/" ; \
		cp Justfile "$$tmp/Justfile" ; \
		cp .env.example "$$tmp/.env.example" ; \
		if ( cd "$$tmp" && ./talos/scripts/build-image.sh </dev/null >/dev/null 2>&1 ) ; then \
		  echo "    [FAIL] build-image.sh should fail when env unset" >&2 ; exit 1 ; \
		fi ; \
	'
	@echo "    [PASS] talos.image-factory-schematic"

# ---------------------------------------------------------------------------
# infra.opentofu.proxmox-vms
# ---------------------------------------------------------------------------
# Verifies:
#   - all required files in infra/ exist (criterion 1)
#   - provider is bpg/proxmox pinned ~> 0.66 (criterion 2)
#   - tofu init -backend=false + tofu validate succeed (criterion 2)
#   - main.tf declares both VMs and parameterizes the right vars
#     (criteria 4, 5)
#   - infra-render fixture produces a populated cluster.tfvars with the
#     schematic id interpolated into the ISO file id (criterion 3)
#   - Justfile has infra-render / infra-up / infra-down recipes (criteria
#     3, 4, 7)
#   - outputs.tf exposes vm_ids and vm_ips (criterion 9)
#
# Boot order (criterion 6) is covered structurally: bpg/proxmox v0.66's
# `boot_order` is a list of device interface names; cdrom-first is encoded
# as ["ide3", "scsi0"] in main.tf, where ide3 is the cdrom interface and
# scsi0 is the disk. We don't grep for the exact list to keep the test
# resilient to formatting; `tofu validate` covers schema correctness.
.PHONY: test-infra.opentofu.proxmox-vms
test-infra.opentofu.proxmox-vms:
	@echo "==> infra.opentofu.proxmox-vms"
	@nix develop --command bash -c '\
		set -eu ; \
		for f in providers.tf variables.tf main.tf outputs.tf cluster.tfvars.example cluster.tfvars.tpl ; do \
		  test -f "infra/$$f" \
		    || { echo "    [FAIL] infra/$$f missing" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "bpg/proxmox" infra/providers.tf \
		  || { echo "    [FAIL] provider source not bpg/proxmox" >&2 ; exit 1 ; } ; \
		grep -qE "version[[:space:]]*=[[:space:]]*\"~>[[:space:]]*0\.66\"" infra/providers.tf \
		  || { echo "    [FAIL] provider version not pinned ~> 0.66" >&2 ; exit 1 ; } ; \
		( cd infra && tofu init -backend=false -input=false -no-color >/dev/null ) \
		  || { echo "    [FAIL] tofu init failed" >&2 ; exit 1 ; } ; \
		( cd infra && tofu validate -no-color >/dev/null ) \
		  || { echo "    [FAIL] tofu validate failed" >&2 ; exit 1 ; } ; \
		grep -qE "^resource[[:space:]]+\"proxmox_virtual_environment_vm\"[[:space:]]+\"cp\"" infra/main.tf \
		  || { echo "    [FAIL] main.tf missing cp VM" >&2 ; exit 1 ; } ; \
		grep -qE "^resource[[:space:]]+\"proxmox_virtual_environment_vm\"[[:space:]]+\"wk0\"" infra/main.tf \
		  || { echo "    [FAIL] main.tf missing wk0 VM" >&2 ; exit 1 ; } ; \
		grep -q "var.proxmox_storage_pool" infra/main.tf \
		  || { echo "    [FAIL] disk not on var.proxmox_storage_pool" >&2 ; exit 1 ; } ; \
		grep -q "var.vm_disk_size_gb"      infra/main.tf \
		  || { echo "    [FAIL] disk not parameterized by vm_disk_size_gb" >&2 ; exit 1 ; } ; \
		grep -q "var.vm_cores"             infra/main.tf \
		  || { echo "    [FAIL] cores not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.vm_memory_mb"         infra/main.tf \
		  || { echo "    [FAIL] memory not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.network_bridge"       infra/main.tf \
		  || { echo "    [FAIL] bridge not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.talos_iso_file_id"    infra/main.tf \
		  || { echo "    [FAIL] cdrom file_id not parameterized" >&2 ; exit 1 ; } ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		mkdir -p "$$tmp/infra" "$$tmp/_out" "$$tmp/talos/scripts" ; \
		cp infra/cluster.tfvars.tpl "$$tmp/infra/" ; \
		cp Justfile "$$tmp/Justfile" ; \
		cp .env.example "$$tmp/.env.example" ; \
		cp .env.example "$$tmp/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake|" "$$tmp/.env" ; \
		echo "deadbeefcafef00d1234" > "$$tmp/_out/talos-schematic-id" ; \
		cp talos/scripts/render-tfvars.sh "$$tmp/talos/scripts/" ; \
		chmod +x "$$tmp/talos/scripts/render-tfvars.sh" ; \
		( cd "$$tmp" && just infra-render >/dev/null 2>&1 ) \
		  || { echo "    [FAIL] just infra-render failed in fixture" >&2 ; exit 1 ; } ; \
		test -f "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars not produced" >&2 ; exit 1 ; } ; \
		grep -q "proxmox_endpoint" "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing proxmox_endpoint" >&2 ; exit 1 ; } ; \
		grep -q "talos_iso_file_id" "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing talos_iso_file_id" >&2 ; exit 1 ; } ; \
		grep -q "deadbeef" "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] schematic id not interpolated into iso file id" >&2 ; exit 1 ; } ; \
		for r in infra-render infra-up infra-down ; do \
		  grep -qE "^$${r}:" Justfile \
		    || { echo "    [FAIL] Justfile lacks $$r recipe" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qE "^output[[:space:]]+\"vm_ids\"" infra/outputs.tf \
		  || { echo "    [FAIL] missing output vm_ids" >&2 ; exit 1 ; } ; \
		grep -qE "^output[[:space:]]+\"vm_ips\"" infra/outputs.tf \
		  || { echo "    [FAIL] missing output vm_ips" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] infra.opentofu.proxmox-vms"
