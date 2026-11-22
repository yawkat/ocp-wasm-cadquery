#!/usr/bin/env bash
# Prepare an OCP.wasm checkout for a CadQuery-only build:
#
#  1. clone yeicor/OCP.wasm at OCP_WASM_COMMIT (unless the directory exists),
#  2. add drop_modules.py and fix_iterators.py and apply patches/*.patch (the
#     hooks that run them, the OCP_BINDINGS_OPT_FLAG hook and the wasm-opt
#     level) to cadquery-ocp-novtk,
#  3. download CadQuery and OCP's generated sources, and
#  4. write cadquery-ocp-novtk/keep_modules.txt.
#
# Usage: scripts/prepare.sh [upstream dir, default ./upstream]
#
# Needs git, curl, unzip and python3. Downloads go to ./work.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=SCRIPTDIR/../versions.env
source "$root/versions.env"
upstream=$(realpath -m "${1:-$root/upstream}")
work="$root/work"
pkg="$upstream/cadquery-ocp-novtk"

# Upstream files that our patches change
mapfile -t patched_files < <(sed -n 's|^+++ b/||p' "$root"/patches/*.patch | sort -u)

# ----- Upstream checkout -----
if [ ! -d "$upstream/.git" ]; then
  git clone --filter=blob:none https://github.com/yeicor/OCP.wasm "$upstream"
fi
if [ "$(git -C "$upstream" rev-parse HEAD)" != "$OCP_WASM_COMMIT" ]; then
  # Move an existing checkout to the pinned commit. Only drop our own changes;
  # untracked files (emsdk, xbuildenv, build dirs) stay.
  git -C "$upstream" checkout -- "${patched_files[@]}"
  git -C "$upstream" cat-file -e "$OCP_WASM_COMMIT^{commit}" 2>/dev/null ||
    git -C "$upstream" fetch origin "$OCP_WASM_COMMIT"
  git -C "$upstream" checkout --detach "$OCP_WASM_COMMIT"
fi
head=$(git -C "$upstream" rev-parse HEAD)
if [ "$head" != "$OCP_WASM_COMMIT" ]; then
  echo "error: $upstream is at $head, expected OCP_WASM_COMMIT=$OCP_WASM_COMMIT" >&2
  exit 1
fi
ocp_url="https://github.com/CadQuery/OCP/releases/download/$OCP_VERSION/OCP_src_stubs_Linux.zip"
if ! grep -qF "\"$ocp_url\"" "$pkg/CMakeLists.txt"; then
  echo "error: upstream does not build OCP $OCP_VERSION; check OCP_VERSION in versions.env:" >&2
  grep -n "OCP_src_stubs" "$pkg/CMakeLists.txt" >&2
  exit 1
fi

# ----- Apply our files -----
cp "$root/patches/drop_modules.py" "$pkg/drop_modules.py"
cp "$root/patches/fix_iterators.py" "$pkg/fix_iterators.py"
# Start from upstream's version of the patched files, so that changed patches
# apply to an already prepared checkout too
git -C "$upstream" checkout -- "${patched_files[@]}"
for patch_file in "$root"/patches/*.patch; do
  if ! git -C "$upstream" apply "$patch_file"; then
    echo "error: $patch_file does not apply to $upstream" >&2
    exit 1
  fi
  echo "Applied $(basename "$patch_file")"
done

# ----- Inputs for the keep list -----
mkdir -p "$work"
if [ ! -d "$work/OCP-src-$OCP_VERSION" ]; then
  rm -rf "$work/ocp-tmp" && mkdir "$work/ocp-tmp"
  curl -fsSL -o "$work/ocp-tmp/src.zip" "$ocp_url"
  unzip -q "$work/ocp-tmp/src.zip" -d "$work/ocp-tmp"
  mv "$work/ocp-tmp/OCP_src_stubs_Linux" "$work/OCP-src-$OCP_VERSION"
  rm -rf "$work/ocp-tmp"
fi
if [ ! -d "$work/cadquery-$CADQUERY_VERSION" ]; then
  rm -rf "$work/cq-tmp" && mkdir "$work/cq-tmp"
  # Find the wheel and its sha256 through PyPI's JSON API
  # (assigned first so that a failure stops the script)
  wheel_info=$(
    curl -fsSL "https://pypi.org/pypi/cadquery/$CADQUERY_VERSION/json" | python3 -I -c '
import json, sys
for f in json.load(sys.stdin)["urls"]:
    if f["packagetype"] == "bdist_wheel":
        print(f["url"], f["digests"]["sha256"])
        break
else:
    sys.exit("no CadQuery wheel on PyPI")
')
  read -r wheel_url wheel_sha256 <<< "$wheel_info"
  curl -fsSL -o "$work/cq-tmp/cadquery.whl" "$wheel_url"
  echo "$wheel_sha256  $work/cq-tmp/cadquery.whl" | sha256sum -c --quiet
  unzip -q "$work/cq-tmp/cadquery.whl" -d "$work/cq-tmp/wheel"
  mv "$work/cq-tmp/wheel/cadquery" "$work/cadquery-$CADQUERY_VERSION"
  rm -rf "$work/cq-tmp"
fi

# ----- Keep list -----
python3 -I "$root/patches/gen_keep_modules.py" \
  "$work/OCP-src-$OCP_VERSION" "$work/cadquery-$CADQUERY_VERSION" > "$pkg/keep_modules.txt"
echo "Wrote $pkg/keep_modules.txt ($(wc -l < "$pkg/keep_modules.txt") modules)"
