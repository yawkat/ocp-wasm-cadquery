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
#  * -O3: geometry kernel speed matters. (-Os for the binding sources
#    shrank the code by only about 1% but added 20% more try blocks, which
#    make every C++ exception slower in Firefox.)
#  * Hidden visibility: OpenCascade's Standard_EXPORT is empty outside
#    Windows, so without it every OpenCascade symbol is exported from the
#    module and every address-taken one goes through a GOT import that the
#    JS dynamic linker resolves at load time. Only PyInit_OCP (explicitly
#    marked visible by pybind11) has to be exported. References to undefined
#    symbols, such as libc++ in the main module, are not affected.
export CFLAGS="-O3 -fvisibility=hidden"
export CXXFLAGS="-O3 -fvisibility=hidden -fvisibility-inlines-hidden"
export LDFLAGS=-O1

# Upstream resets the mtimes of the patched OCP sources, so ninja does not
# notice a changed keep list (or patch) and silently reuses the old
# registration code. Throw away the patched sources and their objects when
# any of them changed.
keep_hash=$(cat "$keep_list" drop_modules.py fix_iterators.py lazy_classes.py ocp_lazy.hxx patch_OCP.cmake | sha256sum | cut -d' ' -f1)
# CFLAGS/CXXFLAGS never reach CMake: pyodide's compiler wrapper appends them,
# out of sight of ninja and ccache. Delete all objects when they changed, so
# that ninja recompiles everything.
flags_stamp="CFLAGS=$CFLAGS CXXFLAGS=$CXXFLAGS"
for dir in build/*-Release; do
  [ -d "$dir/_deps" ] || continue
  if [ "$(cat "$dir/.keep_modules.sha256" 2>/dev/null)" != "$keep_hash" ]; then
    echo "Keep list changed, resetting OCP sources in $dir"
    # (lazy_classes.py rewrites every module's source, not just OCP.cpp;
    # ccache still has the objects of unchanged sources)
    rm -rf "$dir/_deps/OCP-src" "$dir/_deps/OCP.stamp"
    find "$dir/_deps/OCP-build/CMakeFiles/OCP.dir" -name '*.o' -delete 2>/dev/null || true
  fi
  if [ "$(cat "$dir/.compile_flags" 2>/dev/null)" != "$flags_stamp" ]; then
    echo "Compiler flags changed, deleting the object files in $dir"
    find "$dir" -name '*.o' -delete
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
