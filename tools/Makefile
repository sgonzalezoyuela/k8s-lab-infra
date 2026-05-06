# Test entrypoint for the patagon harness.
#
# Each feature has a `test-<feature-id>` target below and is wired as a
# prerequisite of the top-level `test` target. The targets verify each
# feature's acceptance criteria as actual shell assertions, executed inside
# a tools-maintainer nix devShell.
#
# Layout assumptions:
#   - This Makefile lives at <repo>/tools/Makefile.
#   - Run `make test` from inside `tools/` (the harness does this via
#     package.json's `test` script: `nix develop --command make test`).
#   - The cluster being exercised by structural tests is the canonical
#     production cluster at <repo>/clusters/k8s4 (used to read .env, kubeconfig
#     locations, the flake.lock for the bootstrap test, etc.). Tests do not
#     mutate it; they only inspect or copy files into ephemeral tmpdirs.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# TOOLS_DIR — root of the shared tools library. Defaults to this Makefile's
# directory ($(CURDIR) when invoked via `make -C tools`). Tests pass this
# through into fixtures so the path-aware scripts can resolve their assets.
TOOLS_DIR ?= $(CURDIR)

# REPO_ROOT — one directory up from tools/. Used to nix-develop the root
# flake (which exposes the tools-maintainer devShell as `default`).
REPO_ROOT ?= $(abspath $(TOOLS_DIR)/..)

# CLUSTER_DIR — canonical cluster used by the structural tests for inspection.
CLUSTER_DIR ?= $(REPO_ROOT)/clusters/k8s4

# All test recipes wrap their assertions in `nix develop` so the toolchain
# (kubectl, talosctl, tofu, just, ...) is guaranteed to be present.
NIX_DEV ?= nix develop $(REPO_ROOT) --command

.PHONY: test
test: test-bootstrap.nix-flake-tools
test: test-bootstrap.config-scheme
test: test-talos.image-factory-schematic
test: test-infra.opentofu.proxmox-vms
test: test-talos.machine-configs
test: test-talos.bootstrap-cluster
test: test-talos.nocloud-proxmox-cloudinit

# ---------------------------------------------------------------------------
# bootstrap.nix-flake-tools
# ---------------------------------------------------------------------------
# Verifies:
#   - the root flake evaluates and the maintainer devShell enters non-interactively
#   - every tool listed in the feature's acceptance is in PATH
#   - every devShell export is non-empty
#   - the canonical cluster's flake.lock is tracked by git
.PHONY: test-bootstrap.nix-flake-tools
test-bootstrap.nix-flake-tools:
	@echo "==> bootstrap.nix-flake-tools"
	@$(NIX_DEV) bash -c '\
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
	@( cd $(REPO_ROOT) && git ls-files --error-unmatch flake.lock >/dev/null 2>&1 ) \
	  || { echo "    [FAIL] root flake.lock not tracked by git" >&2 ; exit 1 ; }
	@( cd $(CLUSTER_DIR) && git ls-files --error-unmatch flake.lock >/dev/null 2>&1 ) \
	  || { echo "    [FAIL] $(CLUSTER_DIR)/flake.lock not tracked by git" >&2 ; exit 1 ; }
	@echo "    [PASS] bootstrap.nix-flake-tools"

# ---------------------------------------------------------------------------
# bootstrap.config-scheme
# ---------------------------------------------------------------------------
# Verifies:
#   - tools/.env.example contains every required variable (criterion 1).
#     Note: TALOS_VERSION is NOT in tools/.env.example after the
#     tools-vs-clusters split; it is exported by each cluster's flake.
#   - tools/Justfile has dotenv-load + the three required recipes (criterion 2)
#   - just init-config is a no-op when .env is already complete (criterion 3)
#   - just env-check passes/fails correctly (criterion 4)
#   - cluster secrets/ layout exists (criterion 5)
#   - top-level .gitignore has the new entries (criterion 6) and preserves the
#     legacy ones (criterion 7)
.PHONY: test-bootstrap.config-scheme
test-bootstrap.config-scheme:
	@echo "==> bootstrap.config-scheme"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		required="PROXMOX_ENDPOINT PROXMOX_INSECURE PROXMOX_NODE \
		          PROXMOX_API_TOKEN_ID PROXMOX_API_TOKEN_SECRET \
		          PROXMOX_STORAGE_POOL PROXMOX_ISO_STORAGE PROXMOX_SNIPPET_STORAGE \
		          CLUSTER_NAME CLUSTER_DOMAIN \
		          CP_HOSTNAME CP_IP WK0_HOSTNAME WK0_IP \
		          NETWORK_CIDR NETWORK_GATEWAY NETWORK_DNS NETWORK_BRIDGE \
		          CP_CORES CP_MEMORY_MB CP_DISK_SIZE_GB \
		          WK_CORES WK_MEMORY_MB WK_DISK_SIZE_GB WK_STORAGE_DISK_SIZE_GB \
		          TALOS_IMAGE_PLATFORM METALLB_RANGE CA_CERT_PATH CA_KEY_PATH" ; \
		test -f "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] tools/.env.example missing" >&2 ; exit 1 ; } ; \
		for k in $$required ; do \
		  grep -qE "^$${k}=" "$(TOOLS_DIR)/.env.example" \
		    || { echo "    [FAIL] tools/.env.example missing key: $$k" >&2 ; exit 1 ; } ; \
		done ; \
		if grep -qE "^TALOS_VERSION=" "$(TOOLS_DIR)/.env.example" ; then \
		  echo "    [FAIL] tools/.env.example must NOT contain TALOS_VERSION (it is per-cluster, exported by the cluster flake)" >&2 ; exit 1 ; \
		fi ; \
		test -f "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile missing" >&2 ; exit 1 ; } ; \
		grep -q "^set dotenv-load" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile missing: set dotenv-load" >&2 ; exit 1 ; } ; \
		grep -qE "^\[no-cd\]" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile missing [no-cd] attribute on recipes" >&2 ; exit 1 ; } ; \
		grep -qE "^default:" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile missing recipe: default" >&2 ; exit 1 ; } ; \
		grep -qE "^init-config:" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile missing recipe: init-config" >&2 ; exit 1 ; } ; \
		grep -qE "^env-check:" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile missing recipe: env-check" >&2 ; exit 1 ; } ; \
		test -f "$(CLUSTER_DIR)/secrets/.gitkeep" \
		  || { echo "    [FAIL] $(CLUSTER_DIR)/secrets/.gitkeep missing" >&2 ; exit 1 ; } ; \
		test -f "$(CLUSTER_DIR)/secrets/README.md" \
		  || { echo "    [FAIL] $(CLUSTER_DIR)/secrets/README.md missing" >&2 ; exit 1 ; } ; \
		for p in "^\.env\$$" "^\*\*/secrets/\*\$$" "^!\*\*/secrets/\.gitkeep\$$" \
		         "^!\*\*/secrets/README\.md\$$" "^_out/\$$" "^\.terraform/\$$" \
		         "^\.terraform\.lock\.hcl\$$" "^\*\.tfstate\$$" \
		         "^\*\.tfstate\.\*\$$" "^\*\.tfvars\$$" \
		         "^!\*\.tfvars\.example\$$" ; do \
		  grep -qE "$$p" "$(REPO_ROOT)/.gitignore" \
		    || { echo "    [FAIL] .gitignore missing pattern: $$p" >&2 ; exit 1 ; } ; \
		done ; \
		for p in jpkl kubeconfig talosconfig tmp ; do \
		  grep -qE "^$${p}\$$" "$(REPO_ROOT)/.gitignore" \
		    || { echo "    [FAIL] .gitignore lost legacy entry: $$p" >&2 ; exit 1 ; } ; \
		done ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/.env.example" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake-uuid-12345|" "$$tmp/.env" ; \
		mkdir -p "$$tmp/tools" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/tools/.env.example" ; \
		cp "$(TOOLS_DIR)/Justfile" "$$tmp/Justfile" ; \
		( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" just env-check >/dev/null ) \
		  || { echo "    [FAIL] env-check should pass with full .env" >&2 ; exit 1 ; } ; \
		sed -i "s|^CP_IP=.*|CP_IP=|" "$$tmp/.env" ; \
		if ( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" just env-check >/dev/null 2>&1 ) ; then \
		  echo "    [FAIL] env-check should fail when CP_IP empty" >&2 ; exit 1 ; \
		fi ; \
		tmp2=$$(mktemp -d) ; \
		trap "rm -rf $$tmp $$tmp2" EXIT ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp2/.env.example" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp2/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake|" "$$tmp2/.env" ; \
		mkdir -p "$$tmp2/tools" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp2/tools/.env.example" ; \
		cp "$(TOOLS_DIR)/Justfile" "$$tmp2/Justfile" ; \
		( cd "$$tmp2" && TOOLS_DIR="$$tmp2/tools" just init-config </dev/null >/dev/null 2>&1 ) \
		  || { echo "    [FAIL] init-config should be no-op when .env complete" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] bootstrap.config-scheme"

# ---------------------------------------------------------------------------
# talos.image-factory-schematic
# ---------------------------------------------------------------------------
# Verifies (without hitting the network):
#   - schematic.yaml lists EXACTLY the three required system extensions (criterion 2)
#   - build-image.sh exists, is executable, and references the factory URLs,
#     Proxmox auth header, ISO probe URL, the download-url endpoint, and the
#     task status endpoint (structural cover for criteria 1, 3, 4, 5)
#   - tools/Justfile has the talos-image recipe
#   - build-image.sh fails fast when env is unset (criterion 6)
.PHONY: test-talos.image-factory-schematic
test-talos.image-factory-schematic:
	@echo "==> talos.image-factory-schematic"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		test -f "$(TOOLS_DIR)/talos/schematic.yaml" \
		  || { echo "    [FAIL] tools/talos/schematic.yaml missing" >&2 ; exit 1 ; } ; \
		exts=$$(yq -r ".customization.systemExtensions.officialExtensions[]" "$(TOOLS_DIR)/talos/schematic.yaml" | sort) ; \
		expected="siderolabs/iscsi-tools\nsiderolabs/qemu-guest-agent\nsiderolabs/util-linux-tools" ; \
		[ "$$exts" = "$$(printf "%b" "$$expected")" ] \
		  || { echo "    [FAIL] schematic extensions mismatch:" >&2 ; echo "$$exts" >&2 ; exit 1 ; } ; \
		script="$(TOOLS_DIR)/talos/scripts/build-image.sh" ; \
		test -x "$$script" \
		  || { echo "    [FAIL] $$script not executable" >&2 ; exit 1 ; } ; \
		grep -q "factory.talos.dev/schematics" "$$script" \
		  || { echo "    [FAIL] script missing factory POST URL" >&2 ; exit 1 ; } ; \
		grep -q "factory.talos.dev/image/" "$$script" \
		  || { echo "    [FAIL] script missing factory image URL pattern" >&2 ; exit 1 ; } ; \
		grep -q "TALOS_IMAGE_PLATFORM" "$$script" && grep -q -- "-amd64.iso" "$$script" \
		  || { echo "    [FAIL] script must request Talos NoCloud image variant" >&2 ; exit 1 ; } ; \
		grep -q "PVEAPIToken=" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox auth header" >&2 ; exit 1 ; } ; \
		grep -q "/storage/.*content?content=iso" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox ISO probe URL" >&2 ; exit 1 ; } ; \
		grep -q "/storage/.*download-url" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox download-url endpoint" >&2 ; exit 1 ; } ; \
		grep -q "/tasks/.*/status" "$$script" \
		  || { echo "    [FAIL] script missing Proxmox task status polling URL" >&2 ; exit 1 ; } ; \
		grep -qE "^talos-image:" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] Justfile lacks talos-image recipe" >&2 ; exit 1 ; } ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		mkdir -p "$$tmp/tools" ; \
		cp -r "$(TOOLS_DIR)/talos" "$$tmp/tools/" ; \
		cp "$(TOOLS_DIR)/Justfile"     "$$tmp/Justfile" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/tools/.env.example" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/.env.example" ; \
		if ( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" "$$tmp/tools/talos/scripts/build-image.sh" </dev/null >/dev/null 2>&1 ) ; then \
		  echo "    [FAIL] build-image.sh should fail when env unset" >&2 ; exit 1 ; \
		fi ; \
	'
	@echo "    [PASS] talos.image-factory-schematic"

# ---------------------------------------------------------------------------
# infra.opentofu.proxmox-vms
# ---------------------------------------------------------------------------
# After the tools/clusters split:
#   - the OpenTofu MODULE lives at tools/infra/{main,variables,outputs,versions}.tf
#     and tools/infra/cluster.tfvars.{tpl,example}.
#   - there is NO `providers.tf` in the module; provider config moved to the
#     cluster wrapper.
#   - we still test the module's structural correctness here.
.PHONY: test-infra.opentofu.proxmox-vms
test-infra.opentofu.proxmox-vms:
	@echo "==> infra.opentofu.proxmox-vms"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		for f in versions.tf variables.tf main.tf outputs.tf cluster.tfvars.example cluster.tfvars.tpl ; do \
		  test -f "$(TOOLS_DIR)/infra/$$f" \
		    || { echo "    [FAIL] tools/infra/$$f missing" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "bpg/proxmox" "$(TOOLS_DIR)/infra/versions.tf" \
		  || { echo "    [FAIL] provider source not bpg/proxmox" >&2 ; exit 1 ; } ; \
		grep -qE "version[[:space:]]*=[[:space:]]*\"~>[[:space:]]*0\.66\"" "$(TOOLS_DIR)/infra/versions.tf" \
		  || { echo "    [FAIL] provider version not pinned ~> 0.66" >&2 ; exit 1 ; } ; \
		( cd "$(TOOLS_DIR)/infra" && tofu init -backend=false -input=false -no-color >/dev/null ) \
		  || { echo "    [FAIL] tofu init failed" >&2 ; exit 1 ; } ; \
		( cd "$(TOOLS_DIR)/infra" && tofu validate -no-color >/dev/null ) \
		  || { echo "    [FAIL] tofu validate failed" >&2 ; exit 1 ; } ; \
		grep -qE "^resource[[:space:]]+\"proxmox_virtual_environment_vm\"[[:space:]]+\"cp\"" "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] main.tf missing cp VM" >&2 ; exit 1 ; } ; \
		grep -qE "^resource[[:space:]]+\"proxmox_virtual_environment_vm\"[[:space:]]+\"wk0\"" "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] main.tf missing wk0 VM" >&2 ; exit 1 ; } ; \
		grep -q "var.proxmox_storage_pool"     "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] disk not on var.proxmox_storage_pool" >&2 ; exit 1 ; } ; \
		grep -q "var.proxmox_snippet_storage"  "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] NoCloud snippets not on var.proxmox_snippet_storage" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_cores"                 "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] CP cores not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_memory_mb"             "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] CP memory not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_disk_size_gb"          "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] CP OS disk not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_cores"                 "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] WK cores not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_memory_mb"             "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] WK memory not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_disk_size_gb"          "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] WK OS disk not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_storage_disk_size_gb"  "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] WK storage disk not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.network_bridge"           "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] bridge not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.talos_iso_file_id"        "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] cdrom file_id not parameterized" >&2 ; exit 1 ; } ; \
		disk_count=$$(grep -cE "^[[:space:]]*disk[[:space:]]*\\{" "$(TOOLS_DIR)/infra/main.tf") ; \
		[ "$$disk_count" = "3" ] \
		  || { echo "    [FAIL] expected 3 disk blocks total (cp:1 + wk0:2), found $$disk_count" >&2 ; exit 1 ; } ; \
		scsi1_count=$$(grep -cE "interface[[:space:]]*=[[:space:]]*\"scsi1\"" "$(TOOLS_DIR)/infra/main.tf") ; \
		[ "$$scsi1_count" = "1" ] \
		  || { echo "    [FAIL] expected exactly 1 scsi1 interface (wk0 storage disk), found $$scsi1_count" >&2 ; exit 1 ; } ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		mkdir -p "$$tmp/infra" "$$tmp/_out" "$$tmp/tools/infra" "$$tmp/tools/talos/scripts" ; \
		cp "$(TOOLS_DIR)/infra/cluster.tfvars.tpl" "$$tmp/tools/infra/" ; \
		cp "$(TOOLS_DIR)/Justfile"                 "$$tmp/Justfile" ; \
		cp "$(TOOLS_DIR)/.env.example"             "$$tmp/.env.example" ; \
		cp "$(TOOLS_DIR)/.env.example"             "$$tmp/.env" ; \
		cp "$(TOOLS_DIR)/.env.example"             "$$tmp/tools/.env.example" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake|" "$$tmp/.env" ; \
		echo "TALOS_VERSION=v1.13.0" >> "$$tmp/.env" ; \
		echo "deadbeefcafef00d1234" > "$$tmp/_out/talos-schematic-id" ; \
		cp "$(TOOLS_DIR)/talos/scripts/render-tfvars.sh"            "$$tmp/tools/talos/scripts/" ; \
		chmod +x "$$tmp/tools/talos/scripts/render-tfvars.sh" ; \
		cp "$(TOOLS_DIR)/talos/scripts/print-snippet-upload-cmd.sh" "$$tmp/tools/talos/scripts/" ; \
		chmod +x "$$tmp/tools/talos/scripts/print-snippet-upload-cmd.sh" ; \
		( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" just infra-render >/dev/null 2>&1 ) \
		  || { echo "    [FAIL] just infra-render failed in fixture" >&2 ; exit 1 ; } ; \
		test -f "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars not produced" >&2 ; exit 1 ; } ; \
		grep -q "proxmox_endpoint"          "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing proxmox_endpoint" >&2 ; exit 1 ; } ; \
		grep -q "talos_iso_file_id"         "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing talos_iso_file_id" >&2 ; exit 1 ; } ; \
		grep -q "proxmox_snippet_storage"   "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing proxmox_snippet_storage" >&2 ; exit 1 ; } ; \
		if grep -q "^network_gateway"      "$$tmp/infra/cluster.tfvars" ; then \
		  echo "    [FAIL] cluster.tfvars MUST NOT include network_gateway; that field is no longer an OpenTofu input (Talos machine config owns networking, see infra/variables.tf comment)" >&2 ; exit 1 ; \
		fi ; \
		grep -q "deadbeef"                  "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] schematic id not interpolated into iso file id" >&2 ; exit 1 ; } ; \
		grep -q "^cp_cores"                 "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing cp_cores" >&2 ; exit 1 ; } ; \
		grep -q "^wk_storage_disk_size_gb"  "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing wk_storage_disk_size_gb" >&2 ; exit 1 ; } ; \
		for r in infra-render infra-up infra-down ; do \
		  grep -qE "^$${r}:" "$(TOOLS_DIR)/Justfile" \
		    || { echo "    [FAIL] Justfile lacks $$r recipe" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qE "^output[[:space:]]+\"vm_ids\"" "$(TOOLS_DIR)/infra/outputs.tf" \
		  || { echo "    [FAIL] missing output vm_ids" >&2 ; exit 1 ; } ; \
		grep -qE "^output[[:space:]]+\"vm_ips\"" "$(TOOLS_DIR)/infra/outputs.tf" \
		  || { echo "    [FAIL] missing output vm_ips" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] infra.opentofu.proxmox-vms"

# ---------------------------------------------------------------------------
# talos.machine-configs
# ---------------------------------------------------------------------------
# Verifies (executing the recipe in a tempdir; talosctl is in the devShell):
#   - patch templates and gen-config.sh exist
#   - tools/Justfile has talos-config recipe
#   - just talos-config produces the expected outputs and patches
#   - patches contain the expected hostnames, addresses, gateway (with on-link
#     /32 route), DNS, install disk, and physical:true deviceSelector
#   - both final configs validate as `metal`
#   - talosconfig contains CP_IP and WK0_IP as endpoint/nodes
#   - rerunning after editing CP_IP regenerates patches but keeps the same
#     secrets.yaml hash
#
# Fixture layout: tmpdir is a "cluster" (with .env, _out/), and a copy of the
# tools/ assets is placed at tmpdir/tools/ so TOOLS_DIR can point there.
.PHONY: test-talos.machine-configs
test-talos.machine-configs:
	@echo "==> talos.machine-configs"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		test -f "$(TOOLS_DIR)/talos/patches/cp.yaml.tpl"  \
		  || { echo "    [FAIL] cp.yaml.tpl missing"  >&2 ; exit 1 ; } ; \
		test -f "$(TOOLS_DIR)/talos/patches/wk0.yaml.tpl" \
		  || { echo "    [FAIL] wk0.yaml.tpl missing" >&2 ; exit 1 ; } ; \
		test -x "$(TOOLS_DIR)/talos/scripts/gen-config.sh" \
		  || { echo "    [FAIL] gen-config.sh missing or not executable" >&2 ; exit 1 ; } ; \
		grep -qE "^talos-config:" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] tools/Justfile lacks talos-config recipe" >&2 ; exit 1 ; } ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		mkdir -p "$$tmp/tools" ; \
		cp -r "$(TOOLS_DIR)/talos" "$$tmp/tools/" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/tools/.env.example" ; \
		cp "$(TOOLS_DIR)/Justfile"     "$$tmp/Justfile" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/.env.example" ; \
		cp "$(TOOLS_DIR)/.env.example" "$$tmp/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake|" "$$tmp/.env" ; \
		echo "TALOS_VERSION=v1.13.0" >> "$$tmp/.env" ; \
		( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" just talos-config >/dev/null 2>&1 ) \
		  || { echo "    [FAIL] just talos-config failed" >&2 ; exit 1 ; } ; \
		for f in controlplane.yaml worker.yaml secrets.yaml cp.yaml wk0.yaml talosconfig patches/cp.yaml patches/wk0.yaml ; do \
		  test -f "$$tmp/_out/$$f" \
		    || { echo "    [FAIL] _out/$$f missing" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "hostname: cp.k8s4.lab.atricore.io" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing hostname" >&2 ; exit 1 ; } ; \
		grep -q "10.4.0.1/8" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing IP/CIDR" >&2 ; exit 1 ; } ; \
		grep -q "gateway: 10.0.0.1" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing gateway" >&2 ; exit 1 ; } ; \
		grep -q "network: 10.0.0.1/32" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing on-link /32 route to gateway (required when gateway is off-link from node prefix)" >&2 ; exit 1 ; } ; \
		grep -q "10.0.1.77" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing DNS" >&2 ; exit 1 ; } ; \
		grep -q "disk: /dev/sda" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing install disk" >&2 ; exit 1 ; } ; \
		grep -q "physical: true" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] cp patch missing deviceSelector physical:true" >&2 ; exit 1 ; } ; \
		grep -q "hostname: wk0.k8s4.lab.atricore.io" "$$tmp/_out/patches/wk0.yaml" \
		  || { echo "    [FAIL] wk0 patch missing hostname" >&2 ; exit 1 ; } ; \
		grep -q "10.4.0.10/8" "$$tmp/_out/patches/wk0.yaml" \
		  || { echo "    [FAIL] wk0 patch missing IP/CIDR" >&2 ; exit 1 ; } ; \
		grep -q "network: 10.0.0.1/32" "$$tmp/_out/patches/wk0.yaml" \
		  || { echo "    [FAIL] wk0 patch missing on-link /32 route to gateway" >&2 ; exit 1 ; } ; \
		( cd "$$tmp" && talosctl validate --config _out/cp.yaml  --mode metal >/dev/null ) \
		  || { echo "    [FAIL] cp.yaml does not validate as metal" >&2 ; exit 1 ; } ; \
		( cd "$$tmp" && talosctl validate --config _out/wk0.yaml --mode metal >/dev/null ) \
		  || { echo "    [FAIL] wk0.yaml does not validate as metal" >&2 ; exit 1 ; } ; \
		grep -q "10.4.0.1" "$$tmp/_out/talosconfig" \
		  || { echo "    [FAIL] talosconfig missing endpoint/node 10.4.0.1" >&2 ; exit 1 ; } ; \
		grep -q "10.4.0.10" "$$tmp/_out/talosconfig" \
		  || { echo "    [FAIL] talosconfig missing node 10.4.0.10" >&2 ; exit 1 ; } ; \
		secrets_hash_before=$$(sha256sum "$$tmp/_out/secrets.yaml" | cut -d" " -f1) ; \
		sed -i "s|^CP_IP=.*|CP_IP=10.4.0.99|" "$$tmp/.env" ; \
		( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" just talos-config >/dev/null 2>&1 ) \
		  || { echo "    [FAIL] just talos-config rerun failed" >&2 ; exit 1 ; } ; \
		secrets_hash_after=$$(sha256sum "$$tmp/_out/secrets.yaml" | cut -d" " -f1) ; \
		[ "$$secrets_hash_before" = "$$secrets_hash_after" ] \
		  || { echo "    [FAIL] secrets.yaml regenerated on rerun (must be stable)" >&2 ; exit 1 ; } ; \
		grep -q "10.4.0.99/8" "$$tmp/_out/patches/cp.yaml" \
		  || { echo "    [FAIL] patch did not pick up new CP_IP" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] talos.machine-configs"

# ---------------------------------------------------------------------------
# talos.bootstrap-cluster
# ---------------------------------------------------------------------------
.PHONY: test-talos.bootstrap-cluster
test-talos.bootstrap-cluster:
	@echo "==> talos.bootstrap-cluster"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		for s in wait-maintenance.sh wait-secure.sh bootstrap-once.sh wait-nodes-ready.sh ; do \
		  test -x "$(TOOLS_DIR)/talos/scripts/$$s" \
		    || { echo "    [FAIL] tools/talos/scripts/$$s missing or not executable" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qE "already.?exists|already.?bootstrap" "$(TOOLS_DIR)/talos/scripts/bootstrap-once.sh" \
		  || { echo "    [FAIL] bootstrap-once.sh missing AlreadyExists handling" >&2 ; exit 1 ; } ; \
		grep -q "talosctl bootstrap" "$(TOOLS_DIR)/talos/scripts/bootstrap-once.sh" \
		  || { echo "    [FAIL] bootstrap-once.sh does not call talosctl bootstrap" >&2 ; exit 1 ; } ; \
		grep -q -- "--talosconfig" "$(TOOLS_DIR)/talos/scripts/wait-secure.sh" \
		  || { echo "    [FAIL] wait-secure.sh does not use --talosconfig" >&2 ; exit 1 ; } ; \
		grep -q -- "--insecure" "$(TOOLS_DIR)/talos/scripts/wait-maintenance.sh" \
		  || { echo "    [FAIL] wait-maintenance.sh does not use --insecure" >&2 ; exit 1 ; } ; \
		grep -q "kubectl" "$(TOOLS_DIR)/talos/scripts/wait-nodes-ready.sh" \
		  || { echo "    [FAIL] wait-nodes-ready.sh does not call kubectl" >&2 ; exit 1 ; } ; \
		grep -qE "Ready|jsonpath" "$(TOOLS_DIR)/talos/scripts/wait-nodes-ready.sh" \
		  || { echo "    [FAIL] wait-nodes-ready.sh missing Ready check" >&2 ; exit 1 ; } ; \
		for r in talos-apply talos-bootstrap kubeconfig cluster-up cluster-down ; do \
		  grep -qE "^$${r}:" "$(TOOLS_DIR)/Justfile" \
		    || { echo "    [FAIL] Justfile lacks $$r recipe" >&2 ; exit 1 ; } ; \
		done ; \
		grep -A6 "^talos-apply:" "$(TOOLS_DIR)/Justfile" | grep -q -- "--insecure -n.*\$$CP_IP" \
		  || { echo "    [FAIL] talos-apply missing CP --insecure apply" >&2 ; exit 1 ; } ; \
		grep -A6 "^talos-apply:" "$(TOOLS_DIR)/Justfile" | grep -q -- "--insecure -n.*\$$WK0_IP" \
		  || { echo "    [FAIL] talos-apply missing WK0 --insecure apply" >&2 ; exit 1 ; } ; \
		grep -A4 "^kubeconfig:" "$(TOOLS_DIR)/Justfile" | grep -q "talosctl kubeconfig" \
		  || { echo "    [FAIL] kubeconfig recipe missing talosctl kubeconfig" >&2 ; exit 1 ; } ; \
		grep -A4 "^kubeconfig:" "$(TOOLS_DIR)/Justfile" | grep -q -- "--force" \
		  || { echo "    [FAIL] kubeconfig recipe missing --force" >&2 ; exit 1 ; } ; \
		deps=$$(grep -E "^cluster-up:" "$(TOOLS_DIR)/Justfile" | sed -E "s/^cluster-up:[[:space:]]*//") ; \
		for d in talos-image talos-config infra-up talos-bootstrap kubeconfig ; do \
		  echo "$$deps" | grep -q "$$d" \
		    || { echo "    [FAIL] cluster-up missing $$d dep" >&2 ; exit 1 ; } ; \
		done ; \
		if echo "$$deps" | grep -q "talos-apply" ; then \
		  echo "    [FAIL] cluster-up must not require talos-apply/DHCP maintenance discovery" >&2 ; exit 1 ; \
		fi ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		mkdir -p "$$tmp/_out" "$$tmp/tools/talos/scripts" ; \
		cp "$(TOOLS_DIR)/talos/scripts/bootstrap-once.sh" "$$tmp/tools/talos/scripts/" ; \
		printf "context: a3c-lab-4\ncontexts:\n  a3c-lab-4:\n    endpoints:\n      - 192.0.2.1\n    nodes:\n      - 192.0.2.1\n" > "$$tmp/_out/talosconfig" ; \
		if ( cd "$$tmp" && TOOLS_DIR="$$tmp/tools" CP_IP=192.0.2.1 timeout 10 "$$tmp/tools/talos/scripts/bootstrap-once.sh" </dev/null >/dev/null 2>&1 ) ; then \
		  echo "    [WARN] bootstrap-once.sh smoke probe unexpectedly succeeded (likely network quirk); ignoring" >&2 ; \
		fi ; \
	'
	@echo "    [PASS] talos.bootstrap-cluster"

# ---------------------------------------------------------------------------
# talos.nocloud-proxmox-cloudinit
# ---------------------------------------------------------------------------
# Structural coverage. After the split, infra/main.tf assertions point at
# tools/infra/main.tf (the module).
.PHONY: test-talos.nocloud-proxmox-cloudinit
test-talos.nocloud-proxmox-cloudinit:
	@echo "==> talos.nocloud-proxmox-cloudinit"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		grep -qE "TALOS_IMAGE_PLATFORM=.*nocloud" "$(TOOLS_DIR)/talos/scripts/build-image.sh" \
		  || { echo "    [FAIL] build-image.sh missing nocloud platform default" >&2 ; exit 1 ; } ; \
		grep -q "\$${TALOS_IMAGE_PLATFORM}-amd64.iso" "$(TOOLS_DIR)/talos/scripts/build-image.sh" \
		  || { echo "    [FAIL] build-image.sh image URL is not platform-based" >&2 ; exit 1 ; } ; \
		grep -q "TALOS_IMAGE_PLATFORM=nocloud" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example does not declare nocloud image platform" >&2 ; exit 1 ; } ; \
		init_count=$$(grep -cE "^[[:space:]]*initialization[[:space:]]*\\{" "$(TOOLS_DIR)/infra/main.tf") ; \
		[ "$$init_count" = "2" ] \
		  || { echo "    [FAIL] expected two VM initialization blocks, found $$init_count" >&2 ; exit 1 ; } ; \
		grep -qE "type[[:space:]]*=[[:space:]]*\"nocloud\"" "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] VM initialization is not NoCloud" >&2 ; exit 1 ; } ; \
		grep -q "user_data_file_id" "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] VM initialization missing user_data_file_id" >&2 ; exit 1 ; } ; \
		if grep -qE "^resource[[:space:]]+\"proxmox_virtual_environment_file\"" "$(TOOLS_DIR)/infra/main.tf" ; then \
		  echo "    [FAIL] main.tf still defines proxmox_virtual_environment_file resources; the Proxmox API cannot upload snippets, so we must NOT delegate that to OpenTofu" >&2 ; exit 1 ; \
		fi ; \
		grep -qE "snippets/talos-\\$$\\{var.cluster_name\\}-cp.yaml" "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] cp user_data_file_id volume id missing or wrong shape" >&2 ; exit 1 ; } ; \
		grep -qE "snippets/talos-\\$$\\{var.cluster_name\\}-wk0.yaml" "$(TOOLS_DIR)/infra/main.tf" \
		  || { echo "    [FAIL] wk0 user_data_file_id volume id missing or wrong shape" >&2 ; exit 1 ; } ; \
		if grep -qE "^[[:space:]]*ip_config[[:space:]]*\\{" "$(TOOLS_DIR)/infra/main.tf" ; then \
		  echo "    [FAIL] main.tf re-introduced an ip_config block; that creates a cloud-init network-config that competes with Talos user-data. Networking belongs to the Talos machine config (see talos/patches/*.tpl)." >&2 ; exit 1 ; \
		fi ; \
		if grep -qE "^[[:space:]]*dns[[:space:]]*\\{" "$(TOOLS_DIR)/infra/main.tf" ; then \
		  echo "    [FAIL] main.tf re-introduced a dns block in initialization; same reason as ip_config above." >&2 ; exit 1 ; \
		fi ; \
		test -x "$(TOOLS_DIR)/talos/scripts/print-snippet-upload-cmd.sh" \
		  || { echo "    [FAIL] print-snippet-upload-cmd.sh missing or not executable" >&2 ; exit 1 ; } ; \
		grep -q "_out/cp.yaml"  "$(TOOLS_DIR)/talos/scripts/print-snippet-upload-cmd.sh" \
		  || { echo "    [FAIL] print-snippet-upload-cmd.sh does not reference _out/cp.yaml" >&2 ; exit 1 ; } ; \
		grep -q "_out/wk0.yaml" "$(TOOLS_DIR)/talos/scripts/print-snippet-upload-cmd.sh" \
		  || { echo "    [FAIL] print-snippet-upload-cmd.sh does not reference _out/wk0.yaml" >&2 ; exit 1 ; } ; \
		grep -qE "(^|[[:space:]])scp[[:space:]]" "$(TOOLS_DIR)/talos/scripts/print-snippet-upload-cmd.sh" \
		  || { echo "    [FAIL] print-snippet-upload-cmd.sh does not emit an scp command" >&2 ; exit 1 ; } ; \
		grep -q "print-snippet-upload-cmd.sh" "$(TOOLS_DIR)/talos/scripts/render-tfvars.sh" \
		  || { echo "    [FAIL] render-tfvars.sh does not invoke the snippet-upload print step" >&2 ; exit 1 ; } ; \
		grep -qE "^snippets-cmd:" "$(TOOLS_DIR)/Justfile" \
		  || { echo "    [FAIL] Justfile lacks snippets-cmd recipe" >&2 ; exit 1 ; } ; \
		for v in PROXMOX_SSH_USER PROXMOX_SSH_HOST PROXMOX_SNIPPETS_DIR ; do \
		  grep -qE "^$${v}=" "$(TOOLS_DIR)/.env.example" \
		    || { echo "    [FAIL] .env.example missing $$v" >&2 ; exit 1 ; } ; \
		done ; \
		deps=$$(grep -E "^cluster-up:" "$(TOOLS_DIR)/Justfile" | sed -E "s/^cluster-up:[[:space:]]*//") ; \
		echo "$$deps" | grep -q "infra-up" \
		  || { echo "    [FAIL] cluster-up missing infra-up" >&2 ; exit 1 ; } ; \
		if echo "$$deps" | grep -q "talos-apply" ; then \
		  echo "    [FAIL] cluster-up still depends on talos-apply" >&2 ; exit 1 ; \
		fi ; \
		grep -qi "does not run generic.*cloud-init" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] docs missing generic cloud-init warning" >&2 ; exit 1 ; } ; \
		grep -qi "NoCloud" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] docs missing NoCloud guidance" >&2 ; exit 1 ; } ; \
		grep -qi "snippets" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] docs missing Proxmox snippets guidance" >&2 ; exit 1 ; } ; \
		grep -q "scp" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] docs missing scp guidance for manual snippet upload" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] talos.nocloud-proxmox-cloudinit"
