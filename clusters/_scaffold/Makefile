# Per-cluster smoke test. Runs against THIS cluster's working tree.
# Invoke from inside the cluster's nix develop shell:
#
#   cd clusters/__CLUSTER_NAME__ && nix develop --command make smoke
#
# (The `make` alias in the cluster shellHook already points at
#  tools/Makefile for full structural tests; this `make smoke` overrides
#  that alias by passing -f explicitly.)

CLUSTER_DIR ?= $(CURDIR)
TOOLS_DIR   ?= $(abspath $(CLUSTER_DIR)/../../tools)

.PHONY: smoke
smoke:
	@echo "==> cluster smoke ($(notdir $(CLUSTER_DIR)))"
	@set -eu ; \
	test -f "$(CLUSTER_DIR)/.env" \
	  || { echo "    [FAIL] $(CLUSTER_DIR)/.env missing — run 'just init-config' inside this cluster shell" >&2 ; exit 1 ; } ; \
	test -f "$(CLUSTER_DIR)/flake.nix" \
	  || { echo "    [FAIL] $(CLUSTER_DIR)/flake.nix missing" >&2 ; exit 1 ; } ; \
	grep -q 'clusterName *= *"__CLUSTER_NAME__"' "$(CLUSTER_DIR)/flake.nix" \
	  || { echo "    [FAIL] flake.nix does not set clusterName = \"__CLUSTER_NAME__\"" >&2 ; exit 1 ; } ; \
	grep -qE 'talosVersion *= *"v[0-9]+\.[0-9]+\.[0-9]+"' "$(CLUSTER_DIR)/flake.nix" \
	  || { echo "    [FAIL] flake.nix does not pin a concrete talosVersion" >&2 ; exit 1 ; } ; \
	missing="" ; \
	while IFS= read -r line ; do \
	  case "$$line" in \
	    "" | "#"*) continue ;; \
	  esac ; \
	  var="$${line%%=*}" ; \
	  val=$$(grep -E "^$${var}=" "$(CLUSTER_DIR)/.env" 2>/dev/null | cut -d= -f2- || true) ; \
	  [ -z "$$val" ] && missing="$$missing $$var" ; \
	done < "$(TOOLS_DIR)/.env.example" ; \
	if [ -n "$$missing" ] ; then \
	  echo "    [FAIL] .env missing or empty values for:$$missing" >&2 ; exit 1 ; \
	fi ; \
	test -f "$(CLUSTER_DIR)/infra/main.tf" \
	  || { echo "    [FAIL] infra/main.tf missing" >&2 ; exit 1 ; } ; \
	grep -q '../../../tools/infra' "$(CLUSTER_DIR)/infra/main.tf" \
	  || { echo "    [FAIL] infra/main.tf does not source the shared module at ../../../tools/infra" >&2 ; exit 1 ; } ; \
	( cd "$(CLUSTER_DIR)/infra" && tofu init -backend=false -input=false -no-color >/dev/null ) \
	  || { echo "    [FAIL] tofu init failed in infra/" >&2 ; exit 1 ; } ; \
	( cd "$(CLUSTER_DIR)/infra" && tofu validate -no-color >/dev/null ) \
	  || { echo "    [FAIL] tofu validate failed in infra/" >&2 ; exit 1 ; } ; \
	echo "    [PASS] cluster smoke"
