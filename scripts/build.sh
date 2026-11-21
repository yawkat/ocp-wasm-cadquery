#!/usr/bin/env bash
# Build the CadQuery-only wheel from a prepared upstream checkout (see
# prepare.sh and setup_toolchain.sh) and give it the version
# <OCP version>+cadquery<CadQuery version>.
#
# Usage: scripts/build.sh [upstream dir, default ./upstream]
#
# Leaves the wheel, its .sha256 and keep_modules.txt in <upstream>/cadquery-ocp-novtk/dist.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=SCRIPTDIR/../versions.env
source "$root/versions.env"
upstream=$(realpath -m "${1:-$root/upstream}")
cd "$upstream/cadquery-ocp-novtk"

keep_list="$PWD/keep_modules.txt"
if [ ! -s "$keep_list" ]; then
  echo "error: $keep_list is missing, run scripts/prepare.sh first" >&2
  exit 1
fi

# Upstream resets the mtimes of the patched OCP sources, so ninja does not
# notice a changed keep list and silently reuses the old registration code.
# Throw away the patched sources and OCP.cpp's object when the list changed.
keep_hash=$(sha256sum "$keep_list" | cut -d' ' -f1)
for dir in build/*-Release; do
  [ -d "$dir/_deps" ] || continue
  if [ "$(cat "$dir/.keep_modules.sha256" 2>/dev/null)" != "$keep_hash" ]; then
    echo "Keep list changed, resetting OCP sources in $dir"
    rm -rf "$dir/_deps/OCP-src" "$dir/_deps/OCP.stamp" "$dir/_deps/OCP-build/CMakeFiles/OCP.dir/OCP.cpp.o"
  fi
done

# shellcheck disable=SC1091
source emsdk/emsdk_env.sh
# Upstream does this to keep emscripten from rebuilding a restored cache
mkdir -p emsdk/upstream/emscripten/cache
find emsdk/upstream/emscripten/cache -type f -exec touch {} +

export SKBUILD_CMAKE_BUILD_TYPE=Release CFLAGS=-O3 CXXFLAGS=-O3 LDFLAGS=-O1
export CI=1 _FORCE_OLD_SOURCES=TRUE OCP_KEEP_MODULES="$keep_list"
# The compiler is downloaded again on every CI run, so don't compare mtimes
export CCACHE_COMPILERCHECK=content

if command -v ccache >/dev/null; then ccache --show-stats --zero-stats || true; fi
rm -rf dist
start=$(date +%s)
pyodide build --exports=pyinit
echo "Build finished in $(( $(date +%s) - start ))s"
if command -v ccache >/dev/null; then ccache --show-stats || true; fi
for dir in build/*-Release; do
  [ -d "$dir/_deps" ] && echo "$keep_hash" > "$dir/.keep_modules.sha256"
done

whl=(dist/*.whl)
if [ ${#whl[@]} -ne 1 ]; then
  echo "error: expected exactly one wheel in dist/, found ${#whl[@]}" >&2
  exit 1
fi
change_wheel_version "${whl[0]}" --version "$OCP_VERSION+cadquery$CADQUERY_VERSION" --delete-old-wheel
whl=(dist/*.whl)
cp "$keep_list" dist/keep_modules.txt
(cd dist && sha256sum "$(basename "${whl[0]}")" > "$(basename "${whl[0]}").sha256")

echo "Wheel: $(du -b "${whl[0]}" | cut -f1) bytes"
python -I -c 'import sys, zipfile
for i in zipfile.ZipFile(sys.argv[1]).infolist():
    if i.filename.endswith(".so"):
        print(f"{i.filename}: {i.file_size} bytes")' "${whl[0]}"
cat dist/*.sha256
