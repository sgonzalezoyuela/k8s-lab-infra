# Test entrypoint for the patagon harness.
#
# Each feature appends a `test-<feature-id>` target below and adds it as a
# prerequisite of the top-level `test` target. The targets verify each
# feature's acceptance criteria as actual shell assertions, executed inside
# the project's nix devShell where required tools are guaranteed to exist.

.PHONY: test
test: test-bootstrap.nix-flake-tools
test: test-bootstrap.config-scheme

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
