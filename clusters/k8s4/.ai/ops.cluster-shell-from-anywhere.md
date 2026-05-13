# ops.cluster-shell-from-anywhere

## Goal

Provide an operator command:

```sh
cluster-shell k8s4
```

The operator may run it from any application/project directory. The command must enter the selected cluster's Nix dev environment with the cluster directory as the working directory for `shellHook` evaluation, then return the final interactive shell to the operator's original directory.

This fixes the bug where `nix develop /path/to/clusters/k8s4` is launched from another directory and the current root flake computes:

```sh
KUBECONFIG=$PWD/_out/kubeconfig
TALOSCONFIG=$PWD/_out/talosconfig
TOOLS_DIR=$(realpath "$PWD/../../tools")
```

using the application directory instead of the cluster directory.

## Non-goals

- Do not generate aliases/functions in `new-cluster`.
- Do not add `cluster-just`.
- Do not make cluster `just` recipes available from app directories.
- Do not rewrite the existing per-cluster `nix develop` workflow.

## Recommended implementation shape

Add an executable script at:

```text
tools/scripts/cluster-shell.sh
```

It should also be exposed as the user-facing command `cluster-shell`. Acceptable exposure options:
- a small wrapper/symlink named `cluster-shell` in a documented PATH location under `tools/scripts/`, or
- a root flake app/package plus docs showing a shell alias that expands `cluster-shell` to the repo-provided command.

Keep the direct script testable as:

```sh
tools/scripts/cluster-shell.sh k8s4
```

## Safety rules

The script must derive paths from its own location:

```sh
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(realpath "$script_dir/../..")"
clusters_root="$repo_root/clusters"
```

Validate the cluster argument before building a path:

- exactly one required cluster name, plus optional shell selector if implemented
- no `/`
- no `..`
- no leading `-`
- recommended character class: `[A-Za-z0-9._-]+`
- resolved cluster path must remain under `$clusters_root`
- `$cluster_dir/flake.nix` must exist

Do not evaluate or source user-controlled cluster names.

## Shell behavior

The script must remember the caller's original directory:

```sh
orig_pwd="$(pwd -P)"
```

Then it must enter the cluster directory before invoking Nix:

```sh
cd -- "$cluster_dir"
```

This is the critical step. Passing the flake path to `nix develop` while remaining in the app directory reproduces the bug.

The script should suppress the shellHook's automatic zsh exec and run the chosen final shell explicitly. Pseudocode:

```sh
export CLUSTER_SHELL_ORIG_PWD="$orig_pwd"
export CLUSTER_SHELL_FINAL_SHELL="$shell_bin"
export NIX_DEVELOP_NO_ZSH=1

nix develop --command "$shell_bin" -lc '
  cd -- "$CLUSTER_SHELL_ORIG_PWD" || exit 1
  unset JUST_JUSTFILE
  exec "$CLUSTER_SHELL_FINAL_SHELL" -i
'
```

The exact quoting can differ, but must preserve spaces safely and must not use eval.

## Shell selection

Support both bash and zsh.

Recommended interface:

```sh
cluster-shell k8s4
cluster-shell --shell bash k8s4
cluster-shell --shell zsh k8s4
```

Default behavior:
1. If `$SHELL` basename is `zsh` or `bash`, use it.
2. Otherwise use `zsh` if present.
3. Otherwise use `bash` if present.
4. Otherwise fail clearly.

## Justfile behavior

The existing cluster shellHook exports:

```sh
JUST_JUSTFILE="$TOOLS_DIR/Justfile"
```

That is useful when the operator is inside `clusters/<name>`, but wrong when the final shell is returned to an application directory. Before starting the final interactive shell, unset:

```sh
unset JUST_JUSTFILE
```

Do not add `cluster-just`.

## Test guidance

Add a structural test target to `tools/Makefile`, for example:

```make
test: test-ops.cluster-shell-from-anywhere
```

The test should be offline and avoid requiring a live cluster.

Suggested test strategy:
- Assert `tools/scripts/cluster-shell.sh` exists and is executable.
- Assert the script contains defensive validation for slash, dot-dot, leading dash, realpath, and `clusters/` prefix checks.
- Assert the script changes directory to the cluster before invoking `nix develop`.
- Assert the script exports/preserves an original directory variable and cds back to it inside the final shell.
- Assert the script unsets `JUST_JUSTFILE`.
- In a temp directory outside `clusters/k8s4`, run a non-interactive probe if the implementation supports a test mode, e.g. `CLUSTER_SHELL_TEST_COMMAND='printf ...' tools/scripts/cluster-shell.sh --shell bash k8s4`.
- Cover zsh similarly when available in the Nix dev shell.
- Verify expected paths include:
  - `<repo>/clusters/k8s4/_out/kubeconfig`
  - `<repo>/clusters/k8s4/_out/talosconfig`
  - `<repo>/tools`

If adding a test-only command hook, keep it explicit and internal, such as `CLUSTER_SHELL_TEST_COMMAND`, and document that normal operation remains interactive.

## Docs guidance

Update `README.md` and `tools/docs/INIT-CLUSTER.md` with:

```sh
cluster-shell k8s4
```

Example app workflow:

```sh
cd /wa/my-app
cluster-shell k8s4
pwd
kubectl get nodes
```

Optional short alias:

```sh
alias ka3c4='cluster-shell k8s4'
```

Include the caveat that cluster maintenance recipes still belong in the cluster directory:

```sh
cd /wa/infra/k8s/lab/clusters/k8s4
nix develop
just env-check
```

or an explicit subshell if the operator chooses to run one-off maintenance from elsewhere.
