#!/usr/bin/env bash
# Install the build toolchain into the current Python environment and the
# upstream checkout: pyodide-build, the Pyodide cross-build environment and the
# emscripten version it needs. Mirrors upstream's .github/workflows/main.yml.
#
# Usage: scripts/setup_toolchain.sh [upstream dir, default ./upstream]
#
# Writes emscripten_version=<version> to $GITHUB_OUTPUT when set.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=SCRIPTDIR/../versions.env
source "$root/versions.env"
upstream=$(realpath -m "${1:-$root/upstream}")
cd "$upstream/cadquery-ocp-novtk"

python -m pip install -r ../requirements.txt change-wheel-version
# shellcheck disable=SC2046 # one argument per requirement
python -m pip install $(python -c 'import tomllib; cfg = tomllib.load(open("pyproject.toml", "rb")); print(*cfg["build-system"]["requires"])')
pyodide xbuildenv install "$PYODIDE_XBUILDENV_VERSION"

emscripten_version=$(pyodide config get emscripten_version)
echo "Emscripten version: $emscripten_version"
if [ ! -d emsdk ]; then
  git clone --depth 1 https://github.com/emscripten-core/emsdk emsdk
fi
(cd emsdk && ./emsdk install "$emscripten_version" && ./emsdk activate "$emscripten_version")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "emscripten_version=$emscripten_version" >> "$GITHUB_OUTPUT"
fi
