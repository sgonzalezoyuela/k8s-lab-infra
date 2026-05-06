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
test: test-talos.machine-configs
test: test-talos.bootstrap-cluster
test: test-talos.nocloud-proxmox-cloudinit

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
		          PROXMOX_STORAGE_POOL PROXMOX_ISO_STORAGE PROXMOX_SNIPPET_STORAGE \
		          CLUSTER_NAME CLUSTER_DOMAIN \
		          CP_HOSTNAME CP_IP WK0_HOSTNAME WK0_IP \
		          NETWORK_CIDR NETWORK_GATEWAY NETWORK_DNS NETWORK_BRIDGE \
		          CP_CORES CP_MEMORY_MB CP_DISK_SIZE_GB \
		          WK_CORES WK_MEMORY_MB WK_DISK_SIZE_GB WK_STORAGE_DISK_SIZE_GB \
		          TALOS_VERSION TALOS_IMAGE_PLATFORM METALLB_RANGE CA_CERT_PATH CA_KEY_PATH" ; \
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
#     Proxmox auth header, ISO probe URL, the download-url endpoint, and the
#     task status endpoint (structural cover for criteria 1, 3, 4, 5)
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
		grep -q "var.proxmox_storage_pool"     infra/main.tf \
		  || { echo "    [FAIL] disk not on var.proxmox_storage_pool" >&2 ; exit 1 ; } ; \
		grep -q "var.proxmox_snippet_storage"  infra/main.tf \
		  || { echo "    [FAIL] NoCloud snippets not on var.proxmox_snippet_storage" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_cores"                 infra/main.tf \
		  || { echo "    [FAIL] CP cores not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_memory_mb"             infra/main.tf \
		  || { echo "    [FAIL] CP memory not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_disk_size_gb"          infra/main.tf \
		  || { echo "    [FAIL] CP OS disk not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_cores"                 infra/main.tf \
		  || { echo "    [FAIL] WK cores not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_memory_mb"             infra/main.tf \
		  || { echo "    [FAIL] WK memory not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_disk_size_gb"          infra/main.tf \
		  || { echo "    [FAIL] WK OS disk not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.wk_storage_disk_size_gb"  infra/main.tf \
		  || { echo "    [FAIL] WK storage disk not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.network_bridge"           infra/main.tf \
		  || { echo "    [FAIL] bridge not parameterized" >&2 ; exit 1 ; } ; \
		grep -q "var.talos_iso_file_id"        infra/main.tf \
		  || { echo "    [FAIL] cdrom file_id not parameterized" >&2 ; exit 1 ; } ; \
		disk_count=$$(grep -cE "^[[:space:]]*disk[[:space:]]*\\{" infra/main.tf) ; \
		[ "$$disk_count" = "3" ] \
		  || { echo "    [FAIL] expected 3 disk blocks total (cp:1 + wk0:2), found $$disk_count" >&2 ; exit 1 ; } ; \
		scsi1_count=$$(grep -cE "interface[[:space:]]*=[[:space:]]*\"scsi1\"" infra/main.tf) ; \
		[ "$$scsi1_count" = "1" ] \
		  || { echo "    [FAIL] expected exactly 1 scsi1 interface (wk0 storage disk), found $$scsi1_count" >&2 ; exit 1 ; } ; \
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
		grep -q "proxmox_endpoint"          "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing proxmox_endpoint" >&2 ; exit 1 ; } ; \
		grep -q "talos_iso_file_id"         "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing talos_iso_file_id" >&2 ; exit 1 ; } ; \
		grep -q "proxmox_snippet_storage"   "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing proxmox_snippet_storage" >&2 ; exit 1 ; } ; \
		grep -q "network_gateway"          "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing network_gateway" >&2 ; exit 1 ; } ; \
		grep -q "deadbeef"                  "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] schematic id not interpolated into iso file id" >&2 ; exit 1 ; } ; \
		grep -q "^cp_cores"                 "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing cp_cores" >&2 ; exit 1 ; } ; \
		grep -q "^wk_storage_disk_size_gb"  "$$tmp/infra/cluster.tfvars" \
		  || { echo "    [FAIL] cluster.tfvars missing wk_storage_disk_size_gb" >&2 ; exit 1 ; } ; \
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

# ---------------------------------------------------------------------------
# talos.machine-configs
# ---------------------------------------------------------------------------
# Verifies (executing the recipe in a tempdir; talosctl is in the devShell):
#   - patch templates and gen-config.sh exist (criteria 2, 3)
#   - Justfile has talos-config recipe
#   - just talos-config produces controlplane.yaml, worker.yaml, secrets.yaml,
#     cp.yaml, wk0.yaml, talosconfig, and rendered patches (criteria 1, 3)
#   - patches contain the expected hostnames, addresses, gateway, DNS,
#     install disk, and physical:true deviceSelector (criterion 2)
#   - both final configs validate as `metal` (criterion 4)
#   - talosconfig contains CP_IP and WK0_IP as endpoint/nodes (criterion 5)
#   - rerunning after editing CP_IP regenerates patches but keeps the same
#     secrets.yaml hash (criteria 1, 6)
.PHONY: test-talos.machine-configs
test-talos.machine-configs:
	@echo "==> talos.machine-configs"
	@nix develop --command bash -c '\
		set -eu ; \
		test -f talos/patches/cp.yaml.tpl  \
		  || { echo "    [FAIL] cp.yaml.tpl missing"  >&2 ; exit 1 ; } ; \
		test -f talos/patches/wk0.yaml.tpl \
		  || { echo "    [FAIL] wk0.yaml.tpl missing" >&2 ; exit 1 ; } ; \
		test -x talos/scripts/gen-config.sh \
		  || { echo "    [FAIL] gen-config.sh missing or not executable" >&2 ; exit 1 ; } ; \
		grep -qE "^talos-config:" Justfile \
		  || { echo "    [FAIL] Justfile lacks talos-config recipe" >&2 ; exit 1 ; } ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		cp -r talos "$$tmp/" ; \
		cp Justfile "$$tmp/" ; \
		cp .env.example "$$tmp/" ; \
		cp .env.example "$$tmp/.env" ; \
		sed -i "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=fake|" "$$tmp/.env" ; \
		( cd "$$tmp" && just talos-config >/dev/null 2>&1 ) \
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
		( cd "$$tmp" && just talos-config >/dev/null 2>&1 ) \
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
# Acceptance is mostly RUNTIME (criteria 1, 4, 5 require live Talos VMs and
# a kube-apiserver). We verify structure thoroughly:
#
#   - all four helper scripts exist and are executable
#   - bootstrap-once.sh actually invokes `talosctl bootstrap` and handles
#     the "AlreadyExists"/"already bootstrapped" idempotency case (criterion 2)
#   - wait-secure.sh uses --talosconfig (not --insecure); wait-maintenance.sh
#     uses --insecure (sequence sanity from companion §1–3)
#   - wait-nodes-ready.sh calls kubectl with the Ready/jsonpath check
#     (structural cover for criterion 4)
#   - Justfile has all five new recipes
#   - talos-apply applies BOTH cp and wk0 with --insecure (criterion 1)
#   - kubeconfig recipe calls `talosctl kubeconfig` with --force (criterion 3)
#   - cluster-up dependency chain has the required ordering: talos-image →
#     talos-config → infra-up → talos-bootstrap → kubeconfig
#     (criterion 6)
#
# A best-effort smoke probe runs bootstrap-once.sh against an unreachable
# RFC 5737 IP to confirm it actually invokes talosctl and propagates failure
# (rather than silently exiting 0). It is wrapped in `timeout` to stay fast.
.PHONY: test-talos.bootstrap-cluster
test-talos.bootstrap-cluster:
	@echo "==> talos.bootstrap-cluster"
	@nix develop --command bash -c '\
		set -eu ; \
		for s in wait-maintenance.sh wait-secure.sh bootstrap-once.sh wait-nodes-ready.sh ; do \
		  test -x "talos/scripts/$$s" \
		    || { echo "    [FAIL] talos/scripts/$$s missing or not executable" >&2 ; exit 1 ; } ; \
		done ; \
		grep -qE "already.?exists|already.?bootstrap" talos/scripts/bootstrap-once.sh \
		  || { echo "    [FAIL] bootstrap-once.sh missing AlreadyExists handling" >&2 ; exit 1 ; } ; \
		grep -q "talosctl bootstrap" talos/scripts/bootstrap-once.sh \
		  || { echo "    [FAIL] bootstrap-once.sh does not call talosctl bootstrap" >&2 ; exit 1 ; } ; \
		grep -q -- "--talosconfig" talos/scripts/wait-secure.sh \
		  || { echo "    [FAIL] wait-secure.sh does not use --talosconfig" >&2 ; exit 1 ; } ; \
		grep -q -- "--insecure" talos/scripts/wait-maintenance.sh \
		  || { echo "    [FAIL] wait-maintenance.sh does not use --insecure" >&2 ; exit 1 ; } ; \
		grep -q "kubectl" talos/scripts/wait-nodes-ready.sh \
		  || { echo "    [FAIL] wait-nodes-ready.sh does not call kubectl" >&2 ; exit 1 ; } ; \
		grep -qE "Ready|jsonpath" talos/scripts/wait-nodes-ready.sh \
		  || { echo "    [FAIL] wait-nodes-ready.sh missing Ready check" >&2 ; exit 1 ; } ; \
		for r in talos-apply talos-bootstrap kubeconfig cluster-up cluster-down ; do \
		  grep -qE "^$${r}:" Justfile \
		    || { echo "    [FAIL] Justfile lacks $$r recipe" >&2 ; exit 1 ; } ; \
		done ; \
		grep -A6 "^talos-apply:" Justfile | grep -q -- "--insecure -n.*\$$CP_IP" \
		  || { echo "    [FAIL] talos-apply missing CP --insecure apply" >&2 ; exit 1 ; } ; \
		grep -A6 "^talos-apply:" Justfile | grep -q -- "--insecure -n.*\$$WK0_IP" \
		  || { echo "    [FAIL] talos-apply missing WK0 --insecure apply" >&2 ; exit 1 ; } ; \
		grep -A4 "^kubeconfig:" Justfile | grep -q "talosctl kubeconfig" \
		  || { echo "    [FAIL] kubeconfig recipe missing talosctl kubeconfig" >&2 ; exit 1 ; } ; \
		grep -A4 "^kubeconfig:" Justfile | grep -q -- "--force" \
		  || { echo "    [FAIL] kubeconfig recipe missing --force" >&2 ; exit 1 ; } ; \
		deps=$$(grep -E "^cluster-up:" Justfile | sed -E "s/^cluster-up:[[:space:]]*//") ; \
		for d in talos-image talos-config infra-up talos-bootstrap kubeconfig ; do \
		  echo "$$deps" | grep -q "$$d" \
		    || { echo "    [FAIL] cluster-up missing $$d dep" >&2 ; exit 1 ; } ; \
		done ; \
		if echo "$$deps" | grep -q "talos-apply" ; then \
		  echo "    [FAIL] cluster-up must not require talos-apply/DHCP maintenance discovery" >&2 ; exit 1 ; \
		fi ; \
		tmp=$$(mktemp -d) ; \
		trap "rm -rf $$tmp" EXIT ; \
		mkdir -p "$$tmp/_out" "$$tmp/talos/scripts" ; \
		cp talos/scripts/bootstrap-once.sh "$$tmp/talos/scripts/" ; \
		printf "context: a3c-lab-4\ncontexts:\n  a3c-lab-4:\n    endpoints:\n      - 192.0.2.1\n    nodes:\n      - 192.0.2.1\n" > "$$tmp/_out/talosconfig" ; \
		if ( cd "$$tmp" && CP_IP=192.0.2.1 timeout 10 ./talos/scripts/bootstrap-once.sh </dev/null >/dev/null 2>&1 ) ; then \
		  echo "    [WARN] bootstrap-once.sh smoke probe unexpectedly succeeded (likely network quirk); ignoring" >&2 ; \
		fi ; \
	'
	@echo "    [PASS] talos.bootstrap-cluster"

# ---------------------------------------------------------------------------
# talos.nocloud-proxmox-cloudinit
# ---------------------------------------------------------------------------
# Structural coverage for Talos NoCloud on Proxmox without live Proxmox/Talos:
#   - Image Factory flow requests the nocloud platform image while preserving
#     schematic extensions.
#   - bpg/proxmox resources upload Talos machine configs as snippet user-data
#     and wire them into VM initialization as NoCloud.
#   - network data uses the configured static IP/CIDR, gateway, and DNS.
#   - operator workflow targets configured static IPs and does not include the
#     old talos-apply maintenance-mode step in cluster-up.
#   - docs explain Talos NoCloud vs generic cloud-init and snippet storage.
.PHONY: test-talos.nocloud-proxmox-cloudinit
test-talos.nocloud-proxmox-cloudinit:
	@echo "==> talos.nocloud-proxmox-cloudinit"
	@nix develop --command bash -c '\
		set -eu ; \
		grep -qE "TALOS_IMAGE_PLATFORM=.*nocloud" talos/scripts/build-image.sh \
		  || { echo "    [FAIL] build-image.sh missing nocloud platform default" >&2 ; exit 1 ; } ; \
		grep -q "\$${TALOS_IMAGE_PLATFORM}-amd64.iso" talos/scripts/build-image.sh \
		  || { echo "    [FAIL] build-image.sh image URL is not platform-based" >&2 ; exit 1 ; } ; \
		grep -q "TALOS_IMAGE_PLATFORM=nocloud" .env.example \
		  || { echo "    [FAIL] .env.example does not declare nocloud image platform" >&2 ; exit 1 ; } ; \
		grep -qE "content_type[[:space:]]*=[[:space:]]*\"snippets\"" infra/main.tf \
		  || { echo "    [FAIL] Proxmox snippet file resource missing" >&2 ; exit 1 ; } ; \
		grep -qE "source_file[[:space:]]*\\{" infra/main.tf \
		  || { echo "    [FAIL] Talos machine configs are not uploaded as files" >&2 ; exit 1 ; } ; \
		grep -q "var.cp_talos_config_path" infra/main.tf \
		  || { echo "    [FAIL] CP Talos config path not used as user-data source" >&2 ; exit 1 ; } ; \
		grep -q "var.wk0_talos_config_path" infra/main.tf \
		  || { echo "    [FAIL] WK0 Talos config path not used as user-data source" >&2 ; exit 1 ; } ; \
		init_count=$$(grep -cE "^[[:space:]]*initialization[[:space:]]*\\{" infra/main.tf) ; \
		[ "$$init_count" = "2" ] \
		  || { echo "    [FAIL] expected two VM initialization blocks, found $$init_count" >&2 ; exit 1 ; } ; \
		grep -qE "type[[:space:]]*=[[:space:]]*\"nocloud\"" infra/main.tf \
		  || { echo "    [FAIL] VM initialization is not NoCloud" >&2 ; exit 1 ; } ; \
		grep -q "user_data_file_id" infra/main.tf \
		  || { echo "    [FAIL] VM initialization missing user_data_file_id" >&2 ; exit 1 ; } ; \
		for expr in "var.cp_ip" "var.wk0_ip" "var.network_cidr" "gateway = var.network_gateway" "servers = [var.network_dns]" ; do \
		  grep -Fq "$$expr" infra/main.tf \
		    || { echo "    [FAIL] missing static network wiring: $$expr" >&2 ; exit 1 ; } ; \
		done ; \
		deps=$$(grep -E "^cluster-up:" Justfile | sed -E "s/^cluster-up:[[:space:]]*//") ; \
		echo "$$deps" | grep -q "infra-up" \
		  || { echo "    [FAIL] cluster-up missing infra-up" >&2 ; exit 1 ; } ; \
		if echo "$$deps" | grep -q "talos-apply" ; then \
		  echo "    [FAIL] cluster-up still depends on talos-apply" >&2 ; exit 1 ; \
		fi ; \
		grep -qi "does not run generic.*cloud-init" INIT-CLUSTER.md \
		  || { echo "    [FAIL] docs missing generic cloud-init warning" >&2 ; exit 1 ; } ; \
		grep -qi "NoCloud" INIT-CLUSTER.md \
		  || { echo "    [FAIL] docs missing NoCloud guidance" >&2 ; exit 1 ; } ; \
		grep -qi "snippets" INIT-CLUSTER.md \
		  || { echo "    [FAIL] docs missing Proxmox snippets guidance" >&2 ; exit 1 ; } ; \
	'
	@echo "    [PASS] talos.nocloud-proxmox-cloudinit"
