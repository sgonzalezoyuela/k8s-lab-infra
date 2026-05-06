# Test entrypoint for the patagon harness.
#
# Each feature appends a `test-<feature-id>` target below and adds it as a
# prerequisite of the top-level `test` target. The targets verify each
# feature's acceptance criteria as actual shell assertions, executed inside
# the project's nix devShell where required tools are guaranteed to exist.

.PHONY: test
test: test-bootstrap.nix-flake-tools

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
