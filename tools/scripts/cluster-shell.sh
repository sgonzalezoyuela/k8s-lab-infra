#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "cluster-shell: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
usage: cluster-shell [--shell bash|zsh] <cluster-name>
USAGE
}

choose_shell() {
  local requested="${1:-}"

  if [ -n "$requested" ]; then
    case "$requested" in
      bash|zsh) ;;
      *) die "unsupported shell '$requested' (expected bash or zsh)" ;;
    esac
    command -v "$requested" >/dev/null 2>&1 \
      || die "requested shell '$requested' is not available in PATH"
    command -v "$requested"
    return
  fi

  if [ -n "${SHELL:-}" ]; then
    case "$(basename -- "$SHELL")" in
      bash|zsh)
        if [ -x "$SHELL" ]; then
          printf '%s\n' "$SHELL"
          return
        fi
        if command -v "$(basename -- "$SHELL")" >/dev/null 2>&1; then
          command -v "$(basename -- "$SHELL")"
          return
        fi
        ;;
    esac
  fi

  if command -v zsh >/dev/null 2>&1; then
    command -v zsh
  elif command -v bash >/dev/null 2>&1; then
    command -v bash
  else
    die "no supported interactive shell found (need zsh or bash)"
  fi
}

requested_shell=""
case "$#" in
  1) cluster_name="$1" ;;
  3)
    [ "$1" = "--shell" ] || { usage; exit 2; }
    requested_shell="$2"
    cluster_name="$3"
    ;;
  *) usage; exit 2 ;;
esac

[ -n "$cluster_name" ] || die "cluster name is required"
case "$cluster_name" in
  */*|*..*|-*) die "invalid cluster name '$cluster_name'" ;;
esac
[[ "$cluster_name" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "invalid cluster name '$cluster_name' (allowed: letters, digits, dot, underscore, dash)"

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(realpath "$script_dir/../..")"
clusters_root="$repo_root/clusters"

candidate="$clusters_root/$cluster_name"
[ -d "$candidate" ] || die "cluster '$cluster_name' not found under $clusters_root"
cluster_dir="$(realpath "$candidate")"

case "$cluster_dir" in
  "$clusters_root"/*) ;;
  *) die "resolved cluster path escapes $clusters_root: $cluster_dir" ;;
esac

[ -f "$cluster_dir/flake.nix" ] \
  || die "cluster '$cluster_name' is missing flake.nix"

shell_bin="$(choose_shell "$requested_shell")"
orig_pwd="$(pwd -P)"

export CLUSTER_SHELL_ORIG_PWD="$orig_pwd"
export CLUSTER_SHELL_FINAL_SHELL="$shell_bin"
export NIX_DEVELOP_NO_ZSH=1

cd -- "$cluster_dir"
exec nix develop --command "$shell_bin" -lc '
  cd -- "$CLUSTER_SHELL_ORIG_PWD" || exit 1
  unset JUST_JUSTFILE
  if [ -n "${CLUSTER_SHELL_TEST_COMMAND:-}" ]; then
    exec "$CLUSTER_SHELL_FINAL_SHELL" -lc "$CLUSTER_SHELL_TEST_COMMAND"
  fi
  exec "$CLUSTER_SHELL_FINAL_SHELL" -i
'
