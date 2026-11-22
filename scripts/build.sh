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

# Compiler flags. pyodide's compiler wrapper appends CFLAGS and CXXFLAGS to
# every compile command, after the flags from CMake, so they win over any
# per-target flags.
#  * -O3 for OpenCascade: geometry kernel speed matters.
#  * Hidden visibility: OpenCascade's Standard_EXPORT is empty outside
#    Windows, so without it every OpenCascade symbol is exported from the
#    module and every address-taken one goes through a GOT import that the
#    JS dynamic linker resolves at load time. Only PyInit_OCP (explicitly
#    marked visible by pybind11) has to be exported. References to undefined
#    symbols, such as libc++ in the main module, are not affected.
#  * OCP_BINDINGS_OPT_FLAG: optimization level of the binding sources only
#    (see patch_OCP.cmake.patch). Binding dispatch speed doesn't matter, and
#    -O3 inlines pybind11's templates into huge register_* functions that the
#    browser compiles on import. -Os is what pybind11 uses for its modules.
export CFLAGS="-O3 -fvisibility=hidden"
export CXXFLAGS="-O3 -fvisibility=hidden -fvisibility-inlines-hidden"
export LDFLAGS=-O1
export OCP_BINDINGS_OPT_FLAG=-Os

# Upstream resets the mtimes of the patched OCP sources, so ninja does not
# notice a changed keep list (or patch) and silently reuses the old
# registration code. Throw away the patched sources and OCP.cpp's object when
# any of them changed.
keep_hash=$({ cat "$keep_list" drop_modules.py fix_iterators.py patch_OCP.cmake; echo "$OCP_BINDINGS_OPT_FLAG"; } | sha256sum | cut -d' ' -f1)
# CMake takes CFLAGS/CXXFLAGS into its cache only on the first configure, and
# the compiler wrapper adds them out of sight of ninja and ccache. Reconfigure
# from scratch when they changed, so that the compile commands change too.
flags_stamp="CFLAGS=$CFLAGS CXXFLAGS=$CXXFLAGS"
for dir in build/*-Release; do
  [ -d "$dir/_deps" ] || continue
  if [ "$(cat "$dir/.keep_modules.sha256" 2>/dev/null)" != "$keep_hash" ]; then
    echo "Keep list changed, resetting OCP sources in $dir"
    rm -rf "$dir/_deps/OCP-src" "$dir/_deps/OCP.stamp" "$dir/_deps/OCP-build/CMakeFiles/OCP.dir/OCP.cpp.o"
  fi
  if [ "$(cat "$dir/.compile_flags" 2>/dev/null)" != "$flags_stamp" ]; then
    echo "Compiler flags changed, deleting the CMake cache in $dir"
    rm -f "$dir/CMakeCache.txt"
  fi
done

# shellcheck disable=SC1091
source emsdk/emsdk_env.sh
# Upstream does this to keep emscripten from rebuilding a restored cache
mkdir -p emsdk/upstream/emscripten/cache
find emsdk/upstream/emscripten/cache -type f -exec touch {} +

export SKBUILD_CMAKE_BUILD_TYPE=Release
export CI=1 _FORCE_OLD_SOURCES=TRUE OCP_KEEP_MODULES="$keep_list"
# The compiler is downloaded again on every CI run, so don't compare mtimes
export CCACHE_COMPILERCHECK=content
# ccache only sees the command line from CMake, not the CFLAGS/CXXFLAGS that
# pyodide's compiler wrapper appends behind it, so add them to the hash
export CCACHE_NAMESPACE="$flags_stamp"

if command -v ccache >/dev/null; then ccache --show-stats --zero-stats || true; fi
rm -rf dist
mkdir -p build
build_marker=build/.build-started
touch "$build_marker"
start=$(date +%s)
pyodide build --exports=pyinit
echo "Build finished in $(( $(date +%s) - start ))s"
if command -v ccache >/dev/null; then ccache --show-stats || true; fi
# Stamp only the build directory this run used: the one it installed from
for dir in build/*-Release; do
  if [ "$dir/install_manifest.txt" -nt "$build_marker" ]; then
    echo "$keep_hash" > "$dir/.keep_modules.sha256"
    echo "$flags_stamp" > "$dir/.compile_flags"
  fi
done
rm -f "$build_marker"

# Show the CMake-side compile commands of one binding and one OpenCascade
# source (pyodide's wrapper appends CFLAGS/CXXFLAGS to them)
for dir in build/*-Release; do
  [ -f "$dir/build.ninja" ] || continue
  awk '/^build [^ ]*(OCP\.dir\/gp\.cpp|\/gp_Pnt\.cxx)\.o:/ { show = 1; print; next }
       show && /^ *(FLAGS|LAUNCHER) =/ { print }
       /^$/ { show = 0 }' "$dir/build.ninja" | cut -c1-2000
done

whl=(dist/*.whl)
if [ ${#whl[@]} -ne 1 ]; then
  echo "error: expected exactly one wheel in dist/, found ${#whl[@]}" >&2
  exit 1
fi
# (--version rejects local versions; the base version is upstream's OCP
# version, which prepare.sh checked against OCP_VERSION)
change_wheel_version "${whl[0]}" --local-version "cadquery$CADQUERY_VERSION" --delete-old-wheel
whl=(dist/*.whl)
cp "$keep_list" dist/keep_modules.txt
(cd dist && sha256sum "$(basename "${whl[0]}")" > "$(basename "${whl[0]}").sha256")

echo "Wheel: $(du -b "${whl[0]}" | cut -f1) bytes"
python -I -c 'import sys, zipfile
for i in zipfile.ZipFile(sys.argv[1]).infolist():
    if i.filename.endswith(".so"):
        print(f"{i.filename}: {i.file_size} bytes")' "${whl[0]}"
cat dist/*.sha256
