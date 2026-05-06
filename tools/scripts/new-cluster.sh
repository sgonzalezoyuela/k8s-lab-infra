#!/usr/bin/env bash
# Scaffold a new cluster directory at <repo>/clusters/<name>/ from the
# template at <repo>/clusters/_scaffold/. Substitutes __CLUSTER_NAME__ in the
# generated files; the operator is expected to follow up by editing the
# cluster's flake.nix (talosVersion + nixpkgs input) and .env.

set -euo pipefail

name="${1:?usage: new-cluster <name>}"
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell or export TOOLS_DIR}"

src="$(realpath "$TOOLS_DIR/../clusters/_scaffold")"
dst="$(realpath -m "$TOOLS_DIR/../clusters/$name")"

if [ ! -d "$src" ]; then
  echo "ERROR: scaffold template not found at $src" >&2
  exit 1
fi
if [ -e "$dst" ]; then
  echo "ERROR: $dst already exists" >&2
  exit 1
fi

cp -r "$src" "$dst"

# Substitute placeholders. Use `|| true` so missing files don't fail the run
# (a future scaffold may grow more files).
for f in "$dst/flake.nix" "$dst/.env.example" "$dst/Makefile"; do
  if [ -f "$f" ]; then
    sed -i "s|__CLUSTER_NAME__|$name|g" "$f"
  fi
done

cat <<EOF
Scaffolded $dst.

Next steps:
  1. Edit $dst/flake.nix:
       - bump 'talosVersion' if you want a different Talos release
       - bump nixpkgs input rev to one that ships the matching talosctl
  2. cp $dst/.env.example $dst/.env  &&  edit values for this cluster
  3. cd $dst && nix develop
EOF
