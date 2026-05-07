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
test: test-cluster.cert-manager
test: test-cluster.metallb
test: test-cluster.newt

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
		          TALOS_IMAGE_PLATFORM METALLB_RANGE METALLB_CHART_VERSION \
		          CA_CERT_PATH CA_KEY_PATH \
		          CLUSTER_ISSUER_NAME CERT_MANAGER_CHART_VERSION \
		          PANGOLIN_ENDPOINT NEWT_ID NEWT_SECRET NEWT_IMAGE_TAG" ; \
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
		sed -i "s|^NEWT_ID=.*|NEWT_ID=fake-id|"                                         "$$tmp/.env" ; \
		sed -i "s|^NEWT_SECRET=.*|NEWT_SECRET=fake-secret|"                             "$$tmp/.env" ; \
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
		sed -i "s|^NEWT_ID=.*|NEWT_ID=fake-id|"                               "$$tmp2/.env" ; \
		sed -i "s|^NEWT_SECRET=.*|NEWT_SECRET=fake-secret|"                   "$$tmp2/.env" ; \
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
		sed -i "s|^NEWT_ID=.*|NEWT_ID=fake-id|"                               "$$tmp/.env" ; \
		sed -i "s|^NEWT_SECRET=.*|NEWT_SECRET=fake-secret|"                   "$$tmp/.env" ; \
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
		sed -i "s|^NEWT_ID=.*|NEWT_ID=fake-id|"                               "$$tmp/.env" ; \
		sed -i "s|^NEWT_SECRET=.*|NEWT_SECRET=fake-secret|"                   "$$tmp/.env" ; \
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

# ---------------------------------------------------------------------------
# cluster.cert-manager
# ---------------------------------------------------------------------------
# Offline structural verification of the Phase-2 cert-manager assets:
#   - all six tools/cluster/cert-manager/* files exist; the *.sh are executable
#     and start with the "$${TOOLS_DIR:?...}" preamble.
#   - install.sh references helm/kubectl/envsubst/cmctl with the right
#     patterns and includes the openssl pre-validate + 60-day expiry warning.
#   - cluster-issuer.yaml.tpl is a ClusterIssuer with the placeholder used
#     for both metadata.name and spec.ca.secretName.
#   - helm-values.yaml enables installCRDs.
#   - chart-version.txt is a single semver-with-v line.
#   - tools/.env.example carries the new keys (with expected defaults).
#   - tools/Justfile has the three [no-cd] recipes.
#   - INIT-CLUSTER.md mentions atricore-ca and no longer mentions own-ca.
#   - top-level README.md references just cert-manager-install.
.PHONY: test-cluster.cert-manager
test-cluster.cert-manager:
	@echo "==> cluster.cert-manager"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		ASSETS="$(TOOLS_DIR)/cluster/cert-manager" ; \
		for f in install.sh uninstall.sh smoke.sh ; do \
		  test -f "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing" >&2 ; exit 1 ; } ; \
		  test -x "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f not executable" >&2 ; exit 1 ; } ; \
		  head -1 "$$ASSETS/$$f" | grep -q "^#!/usr/bin/env bash" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing bash shebang on line 1" >&2 ; exit 1 ; } ; \
		  head -5 "$$ASSETS/$$f" | grep -qE "\\\$$\\{TOOLS_DIR:\\?" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing TOOLS_DIR preamble in first 5 lines" >&2 ; exit 1 ; } ; \
		done ; \
		for f in helm-values.yaml cluster-issuer.yaml.tpl chart-version.txt ; do \
		  test -f "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "helm upgrade --install cert-manager jetstack/cert-manager" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing helm upgrade --install pattern" >&2 ; exit 1 ; } ; \
		grep -q "kubectl create secret tls" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing kubectl create secret tls" >&2 ; exit 1 ; } ; \
		grep -q "envsubst" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing envsubst" >&2 ; exit 1 ; } ; \
		grep -q "kubectl apply --server-side" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing kubectl apply --server-side" >&2 ; exit 1 ; } ; \
		grep -q "cmctl check api" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing cmctl check api" >&2 ; exit 1 ; } ; \
		grep -q "openssl x509" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing openssl x509 pre-validate" >&2 ; exit 1 ; } ; \
		grep -q "openssl md5" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing openssl md5 (cert/key pubkey hash compare)" >&2 ; exit 1 ; } ; \
		grep -qE "days_left|60-day" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing 60-day expiry warning (days_left or 60-day)" >&2 ; exit 1 ; } ; \
		grep -q "kind: ClusterIssuer" "$$ASSETS/cluster-issuer.yaml.tpl" \
		  || { echo "    [FAIL] cluster-issuer.yaml.tpl missing kind: ClusterIssuer" >&2 ; exit 1 ; } ; \
		ph_count=$$(grep -cE "\\\$$\\{CLUSTER_ISSUER_NAME\\}" "$$ASSETS/cluster-issuer.yaml.tpl") ; \
		[ "$$ph_count" -ge 2 ] \
		  || { echo "    [FAIL] cluster-issuer.yaml.tpl needs >=2 \\\$${CLUSTER_ISSUER_NAME} placeholders, found $$ph_count" >&2 ; exit 1 ; } ; \
		grep -qE "secretName: \\\$$\\{CLUSTER_ISSUER_NAME\\}" "$$ASSETS/cluster-issuer.yaml.tpl" \
		  || { echo "    [FAIL] cluster-issuer.yaml.tpl missing secretName: \\\$${CLUSTER_ISSUER_NAME}" >&2 ; exit 1 ; } ; \
		grep -q "installCRDs: true" "$$ASSETS/helm-values.yaml" \
		  || { echo "    [FAIL] helm-values.yaml missing installCRDs: true" >&2 ; exit 1 ; } ; \
		ver=$$(tr -d "[:space:]" < "$$ASSETS/chart-version.txt") ; \
		echo "$$ver" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$$" \
		  || { echo "    [FAIL] chart-version.txt does not match ^v[0-9]+\\.[0-9]+\\.[0-9]+\$$ (got: $$ver)" >&2 ; exit 1 ; } ; \
		grep -qE "^CLUSTER_ISSUER_NAME=atricore-ca" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing CLUSTER_ISSUER_NAME=atricore-ca" >&2 ; exit 1 ; } ; \
		grep -qE "^CERT_MANAGER_CHART_VERSION=v[0-9.]+" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing CERT_MANAGER_CHART_VERSION=v<semver>" >&2 ; exit 1 ; } ; \
		for r in cert-manager-install cert-manager-smoke cert-manager-uninstall ; do \
		  grep -qE "^$${r}:" "$(TOOLS_DIR)/Justfile" \
		    || { echo "    [FAIL] Justfile lacks recipe: $$r" >&2 ; exit 1 ; } ; \
		  prev_line=$$(grep -B1 "^$${r}:" "$(TOOLS_DIR)/Justfile" | head -1) ; \
		  echo "$$prev_line" | grep -qE "^\[no-cd\]" \
		    || { echo "    [FAIL] Justfile recipe $$r missing [no-cd] attribute on the line above" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "atricore-ca" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] INIT-CLUSTER.md missing atricore-ca" >&2 ; exit 1 ; } ; \
		if grep -q "own-ca" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" ; then \
		  echo "    [FAIL] INIT-CLUSTER.md still mentions own-ca (post-rename)" >&2 ; exit 1 ; \
		fi ; \
		grep -q "just cert-manager-install" "$(REPO_ROOT)/README.md" \
		  || { echo "    [FAIL] README.md does not reference just cert-manager-install" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] cluster.cert-manager"

# ---------------------------------------------------------------------------
# cluster.metallb
# ---------------------------------------------------------------------------
# Offline structural verification of the Phase-2 MetalLB (L2-mode) assets:
#   - all seven tools/cluster/metallb/* files exist; the *.sh are executable
#     and start with the "$${TOOLS_DIR:?...}" preamble.
#   - install.sh references helm/kubectl/envsubst with the right patterns
#     and includes the CIDR pre-validate (METALLB_RANGE shape + CP_IP/WK0_IP
#     overlap check, via the ip_to_int arithmetic helper).
#   - ip-address-pool.yaml.tpl is an IPAddressPool named default-pool in
#     metallb-system with the ${METALLB_RANGE} placeholder.
#   - l2-advertisement.yaml.tpl is an L2Advertisement named default-l2-adv
#     referencing default-pool.
#   - chart-version.txt matches ^[0-9]+\.[0-9]+\.[0-9]+$ (NO `v` prefix; this
#     is intentional, contrast with cert-manager).
#   - tools/.env.example carries METALLB_CHART_VERSION (with expected default).
#   - tools/Justfile has the three [no-cd] recipes.
#   - INIT-CLUSTER.md mentions metallb-install.
#   - top-level README.md references just metallb-install.
.PHONY: test-cluster.metallb
test-cluster.metallb:
	@echo "==> cluster.metallb"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		ASSETS="$(TOOLS_DIR)/cluster/metallb" ; \
		for f in install.sh uninstall.sh smoke.sh ; do \
		  test -f "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing" >&2 ; exit 1 ; } ; \
		  test -x "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f not executable" >&2 ; exit 1 ; } ; \
		  head -1 "$$ASSETS/$$f" | grep -q "^#!/usr/bin/env bash" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing bash shebang on line 1" >&2 ; exit 1 ; } ; \
		  head -5 "$$ASSETS/$$f" | grep -qE "\\\$$\\{TOOLS_DIR:\\?" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing TOOLS_DIR preamble in first 5 lines" >&2 ; exit 1 ; } ; \
		done ; \
		for f in helm-values.yaml ip-address-pool.yaml.tpl l2-advertisement.yaml.tpl chart-version.txt ; do \
		  test -f "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "helm upgrade --install metallb metallb/metallb" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing helm upgrade --install metallb metallb/metallb" >&2 ; exit 1 ; } ; \
		grep -q "kubectl apply --server-side" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing kubectl apply --server-side" >&2 ; exit 1 ; } ; \
		grep -q "envsubst" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing envsubst" >&2 ; exit 1 ; } ; \
		grep -q "metallb-system" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing metallb-system namespace" >&2 ; exit 1 ; } ; \
		grep -q "METALLB_RANGE" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing METALLB_RANGE handling" >&2 ; exit 1 ; } ; \
		grep -q "CP_IP" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing CP_IP overlap check" >&2 ; exit 1 ; } ; \
		grep -q "WK0_IP" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing WK0_IP overlap check" >&2 ; exit 1 ; } ; \
		grep -q "ip_to_int" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing CIDR ip_to_int arithmetic helper" >&2 ; exit 1 ; } ; \
		grep -q "rollout status daemonset/metallb-speaker" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing speaker DaemonSet rollout wait" >&2 ; exit 1 ; } ; \
		grep -q "pod-security.kubernetes.io/enforce: privileged" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh must label metallb-system namespace with PSA enforce=privileged (required by Talos default baseline PSA)" >&2 ; exit 1 ; } ; \
		grep -qE "kind:[[:space:]]*Namespace" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh must create the namespace explicitly (kubectl apply -f - <<EOF) before helm so PSA labels are applied; helm --create-namespace cannot label" >&2 ; exit 1 ; } ; \
		grep -qE "frr:[[:space:]]*$$" "$$ASSETS/helm-values.yaml" \
		  && grep -A1 -E "frr:[[:space:]]*$$" "$$ASSETS/helm-values.yaml" | grep -qE "enabled:[[:space:]]*false" \
		  || { echo "    [FAIL] helm-values.yaml must explicitly set speaker.frr.enabled=false (chart 0.15.x flipped the default to true; we are L2 not BGP)" >&2 ; exit 1 ; } ; \
		grep -q "kind: IPAddressPool" "$$ASSETS/ip-address-pool.yaml.tpl" \
		  || { echo "    [FAIL] ip-address-pool.yaml.tpl missing kind: IPAddressPool" >&2 ; exit 1 ; } ; \
		grep -qE "name: default-pool" "$$ASSETS/ip-address-pool.yaml.tpl" \
		  || { echo "    [FAIL] ip-address-pool.yaml.tpl missing name: default-pool" >&2 ; exit 1 ; } ; \
		grep -qE "namespace: metallb-system" "$$ASSETS/ip-address-pool.yaml.tpl" \
		  || { echo "    [FAIL] ip-address-pool.yaml.tpl missing namespace: metallb-system" >&2 ; exit 1 ; } ; \
		grep -qE "\\\$$\\{METALLB_RANGE\\}" "$$ASSETS/ip-address-pool.yaml.tpl" \
		  || { echo "    [FAIL] ip-address-pool.yaml.tpl missing \\\$${METALLB_RANGE} placeholder" >&2 ; exit 1 ; } ; \
		grep -q "kind: L2Advertisement" "$$ASSETS/l2-advertisement.yaml.tpl" \
		  || { echo "    [FAIL] l2-advertisement.yaml.tpl missing kind: L2Advertisement" >&2 ; exit 1 ; } ; \
		grep -qE "name: default-l2-adv" "$$ASSETS/l2-advertisement.yaml.tpl" \
		  || { echo "    [FAIL] l2-advertisement.yaml.tpl missing name: default-l2-adv" >&2 ; exit 1 ; } ; \
		grep -qE "namespace: metallb-system" "$$ASSETS/l2-advertisement.yaml.tpl" \
		  || { echo "    [FAIL] l2-advertisement.yaml.tpl missing namespace: metallb-system" >&2 ; exit 1 ; } ; \
		grep -qE "default-pool" "$$ASSETS/l2-advertisement.yaml.tpl" \
		  || { echo "    [FAIL] l2-advertisement.yaml.tpl does not reference default-pool" >&2 ; exit 1 ; } ; \
		grep -q "type: LoadBalancer" "$$ASSETS/smoke.sh" \
		  || { echo "    [FAIL] smoke.sh does not create a LoadBalancer Service" >&2 ; exit 1 ; } ; \
		grep -q "mlb-smoke-test" "$$ASSETS/smoke.sh" \
		  || { echo "    [FAIL] smoke.sh does not name the Service mlb-smoke-test" >&2 ; exit 1 ; } ; \
		grep -q "loadBalancer.ingress" "$$ASSETS/smoke.sh" \
		  || { echo "    [FAIL] smoke.sh does not poll .status.loadBalancer.ingress" >&2 ; exit 1 ; } ; \
		grep -qE "l2advertisement[[:space:]]+default-l2-adv" "$$ASSETS/uninstall.sh" \
		  || { echo "    [FAIL] uninstall.sh does not delete L2Advertisement default-l2-adv" >&2 ; exit 1 ; } ; \
		grep -qE "ipaddresspool[[:space:]]+default-pool" "$$ASSETS/uninstall.sh" \
		  || { echo "    [FAIL] uninstall.sh does not delete IPAddressPool default-pool" >&2 ; exit 1 ; } ; \
		grep -q "helm uninstall metallb" "$$ASSETS/uninstall.sh" \
		  || { echo "    [FAIL] uninstall.sh does not helm uninstall metallb" >&2 ; exit 1 ; } ; \
		ver=$$(tr -d "[:space:]" < "$$ASSETS/chart-version.txt") ; \
		echo "$$ver" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+$$" \
		  || { echo "    [FAIL] chart-version.txt does not match ^[0-9]+\\.[0-9]+\\.[0-9]+\$$ (got: $$ver; note: NO v prefix, unlike cert-manager)" >&2 ; exit 1 ; } ; \
		grep -qE "^METALLB_RANGE=" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing METALLB_RANGE" >&2 ; exit 1 ; } ; \
		grep -qE "^METALLB_CHART_VERSION=[0-9]+\.[0-9]+\.[0-9]+" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing METALLB_CHART_VERSION=<bare semver>" >&2 ; exit 1 ; } ; \
		for r in metallb-install metallb-smoke metallb-uninstall ; do \
		  grep -qE "^$${r}:" "$(TOOLS_DIR)/Justfile" \
		    || { echo "    [FAIL] Justfile lacks recipe: $$r" >&2 ; exit 1 ; } ; \
		  prev_line=$$(grep -B1 "^$${r}:" "$(TOOLS_DIR)/Justfile" | head -1) ; \
		  echo "$$prev_line" | grep -qE "^\[no-cd\]" \
		    || { echo "    [FAIL] Justfile recipe $$r missing [no-cd] attribute on the line above" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qi "metallb" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] INIT-CLUSTER.md missing MetalLB coverage" >&2 ; exit 1 ; } ; \
		grep -q "metallb-install" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] INIT-CLUSTER.md missing metallb-install recipe reference" >&2 ; exit 1 ; } ; \
		grep -q "just metallb-install" "$(REPO_ROOT)/README.md" \
		  || { echo "    [FAIL] README.md does not reference just metallb-install" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] cluster.metallb"

# ---------------------------------------------------------------------------
# cluster.newt
# ---------------------------------------------------------------------------
# Offline structural verification of the Phase-2 newt (Pangolin tunnel client)
# assets:
#   - all seven tools/cluster/newt/* files exist; the *.sh are executable and
#     start with the "$${TOOLS_DIR:?...}" preamble.
#   - install.sh references kubectl apply --server-side, envsubst, the
#     rollout wait, all four env keys, the http(s) URL regex, and the
#     REPLACE-ME placeholder check.
#   - namespace.yaml declares name: newt + restricted PSA enforce label.
#   - secret.yaml.tpl is kind: Secret named newt-credentials in ns newt with
#     all three placeholders.
#   - deployment.yaml.tpl is kind: Deployment named newt in ns newt with
#     Recreate strategy, the pinned image template, envFrom secretRef
#     newt-credentials, runAsNonRoot/readOnlyRootFilesystem, capabilities
#     drop ALL, and containerPort 2112.
#   - smoke.sh references rollout status and the literal "Connecting to
#     endpoint:" log line.
#   - image-tag.txt matches ^[0-9]+\.[0-9]+\.[0-9]+$ (NO `v` prefix; matches
#     fosrl/newt's container tag style; consistent with metallb).
#   - tools/.env.example carries the four env keys (PANGOLIN_ENDPOINT
#     non-empty, NEWT_ID/NEWT_SECRET empty for init-config to prompt,
#     NEWT_IMAGE_TAG=<bare semver>).
#   - tools/Justfile has the three [no-cd] recipes.
#   - INIT-CLUSTER.md mentions newt-install and Pangolin.
#   - top-level README.md references just newt-install.
.PHONY: test-cluster.newt
test-cluster.newt:
	@echo "==> cluster.newt"
	@$(NIX_DEV) bash -c '\
		set -eu ; \
		export TOOLS_DIR="$(TOOLS_DIR)" ; \
		ASSETS="$(TOOLS_DIR)/cluster/newt" ; \
		for f in install.sh uninstall.sh smoke.sh ; do \
		  test -f "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing" >&2 ; exit 1 ; } ; \
		  test -x "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f not executable" >&2 ; exit 1 ; } ; \
		  head -1 "$$ASSETS/$$f" | grep -q "^#!/usr/bin/env bash" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing bash shebang on line 1" >&2 ; exit 1 ; } ; \
		  head -5 "$$ASSETS/$$f" | grep -qE "\\\$$\\{TOOLS_DIR:\\?" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing TOOLS_DIR preamble in first 5 lines" >&2 ; exit 1 ; } ; \
		done ; \
		for f in namespace.yaml secret.yaml.tpl deployment.yaml.tpl image-tag.txt ; do \
		  test -f "$$ASSETS/$$f" \
		    || { echo "    [FAIL] $$ASSETS/$$f missing" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "kubectl apply --server-side" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing kubectl apply --server-side" >&2 ; exit 1 ; } ; \
		grep -q "envsubst" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing envsubst" >&2 ; exit 1 ; } ; \
		grep -q "rollout status deployment/newt" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing rollout status deployment/newt" >&2 ; exit 1 ; } ; \
		for v in PANGOLIN_ENDPOINT NEWT_ID NEWT_SECRET NEWT_IMAGE_TAG ; do \
		  grep -q "$$v" "$$ASSETS/install.sh" \
		    || { echo "    [FAIL] install.sh does not reference $$v" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qE "https\\?://" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing http(s):// URL regex check on PANGOLIN_ENDPOINT" >&2 ; exit 1 ; } ; \
		grep -q "REPLACE-ME-FROM-PANGOLIN-UI" "$$ASSETS/install.sh" \
		  || { echo "    [FAIL] install.sh missing REPLACE-ME-FROM-PANGOLIN-UI placeholder check" >&2 ; exit 1 ; } ; \
		grep -qE "kind:[[:space:]]*Namespace" "$$ASSETS/namespace.yaml" \
		  || { echo "    [FAIL] namespace.yaml missing kind: Namespace" >&2 ; exit 1 ; } ; \
		grep -qE "name:[[:space:]]*newt" "$$ASSETS/namespace.yaml" \
		  || { echo "    [FAIL] namespace.yaml missing name: newt" >&2 ; exit 1 ; } ; \
		grep -q "pod-security.kubernetes.io/enforce: restricted" "$$ASSETS/namespace.yaml" \
		  || { echo "    [FAIL] namespace.yaml missing pod-security.kubernetes.io/enforce: restricted" >&2 ; exit 1 ; } ; \
		grep -qE "kind:[[:space:]]*Secret" "$$ASSETS/secret.yaml.tpl" \
		  || { echo "    [FAIL] secret.yaml.tpl missing kind: Secret" >&2 ; exit 1 ; } ; \
		grep -qE "name:[[:space:]]*newt-credentials" "$$ASSETS/secret.yaml.tpl" \
		  || { echo "    [FAIL] secret.yaml.tpl missing name: newt-credentials" >&2 ; exit 1 ; } ; \
		grep -qE "namespace:[[:space:]]*newt" "$$ASSETS/secret.yaml.tpl" \
		  || { echo "    [FAIL] secret.yaml.tpl missing namespace: newt" >&2 ; exit 1 ; } ; \
		for ph in PANGOLIN_ENDPOINT NEWT_ID NEWT_SECRET ; do \
		  grep -qE "\\\$$\\{$$ph\\}" "$$ASSETS/secret.yaml.tpl" \
		    || { echo "    [FAIL] secret.yaml.tpl missing \\\$${$$ph} placeholder" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qE "kind:[[:space:]]*Deployment" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing kind: Deployment" >&2 ; exit 1 ; } ; \
		grep -qE "name:[[:space:]]*newt$$" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing name: newt" >&2 ; exit 1 ; } ; \
		grep -qE "namespace:[[:space:]]*newt" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing namespace: newt" >&2 ; exit 1 ; } ; \
		grep -qE "type:[[:space:]]*Recreate" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing strategy.type: Recreate (one Pangolin WS connection per site; RollingUpdate would race)" >&2 ; exit 1 ; } ; \
		grep -qE "image:[[:space:]]*fosrl/newt:\\\$$\\{NEWT_IMAGE_TAG\\}" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing image: fosrl/newt:\\\$${NEWT_IMAGE_TAG}" >&2 ; exit 1 ; } ; \
		grep -q "envFrom:" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing envFrom" >&2 ; exit 1 ; } ; \
		grep -qE "name:[[:space:]]*newt-credentials" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing secretRef name: newt-credentials" >&2 ; exit 1 ; } ; \
		grep -q "runAsNonRoot: true" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing runAsNonRoot: true" >&2 ; exit 1 ; } ; \
		grep -q "readOnlyRootFilesystem: true" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing readOnlyRootFilesystem: true" >&2 ; exit 1 ; } ; \
		grep -A1 -E "drop:[[:space:]]*$$" "$$ASSETS/deployment.yaml.tpl" | grep -qE -- "-[[:space:]]*ALL" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing capabilities.drop: [ALL]" >&2 ; exit 1 ; } ; \
		grep -q "containerPort: 2112" "$$ASSETS/deployment.yaml.tpl" \
		  || { echo "    [FAIL] deployment.yaml.tpl missing containerPort: 2112 (newt metrics)" >&2 ; exit 1 ; } ; \
		grep -q "rollout status deployment/newt" "$$ASSETS/smoke.sh" \
		  || { echo "    [FAIL] smoke.sh missing rollout status deployment/newt" >&2 ; exit 1 ; } ; \
		grep -q "Connecting to endpoint:" "$$ASSETS/smoke.sh" \
		  || { echo "    [FAIL] smoke.sh missing literal \"Connecting to endpoint:\" log probe" >&2 ; exit 1 ; } ; \
		ver=$$(tr -d "[:space:]" < "$$ASSETS/image-tag.txt") ; \
		echo "$$ver" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+$$" \
		  || { echo "    [FAIL] image-tag.txt does not match ^[0-9]+\\.[0-9]+\\.[0-9]+\$$ (got: $$ver; note: NO v prefix, fosrl/newt tags are bare semver)" >&2 ; exit 1 ; } ; \
		grep -qE "^PANGOLIN_ENDPOINT=" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing PANGOLIN_ENDPOINT" >&2 ; exit 1 ; } ; \
		grep -qE "^NEWT_ID=" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing NEWT_ID" >&2 ; exit 1 ; } ; \
		grep -qE "^NEWT_SECRET=" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing NEWT_SECRET" >&2 ; exit 1 ; } ; \
		grep -qE "^NEWT_IMAGE_TAG=[0-9]+\.[0-9]+\.[0-9]+" "$(TOOLS_DIR)/.env.example" \
		  || { echo "    [FAIL] .env.example missing NEWT_IMAGE_TAG=<bare semver>" >&2 ; exit 1 ; } ; \
		for r in newt-install newt-smoke newt-uninstall ; do \
		  grep -qE "^$${r}:" "$(TOOLS_DIR)/Justfile" \
		    || { echo "    [FAIL] Justfile lacks recipe: $$r" >&2 ; exit 1 ; } ; \
		  prev_line=$$(grep -B1 "^$${r}:" "$(TOOLS_DIR)/Justfile" | head -1) ; \
		  echo "$$prev_line" | grep -qE "^\[no-cd\]" \
		    || { echo "    [FAIL] Justfile recipe $$r missing [no-cd] attribute on the line above" >&2 ; exit 1 ; } ; \
		done ; \
		grep -q "newt-install" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] INIT-CLUSTER.md missing newt-install recipe reference" >&2 ; exit 1 ; } ; \
		grep -qi "pangolin" "$(TOOLS_DIR)/docs/INIT-CLUSTER.md" \
		  || { echo "    [FAIL] INIT-CLUSTER.md missing Pangolin coverage" >&2 ; exit 1 ; } ; \
		grep -q "just newt-install" "$(REPO_ROOT)/README.md" \
		  || { echo "    [FAIL] README.md does not reference just newt-install" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] cluster.newt"
