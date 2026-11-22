# ocp-wasm-cadquery

A smaller build of [OCP.wasm]'s `cadquery-ocp-novtk-OCP.wasm` wheel that only
binds the parts of [OCP] that [CadQuery] uses. It runs CadQuery in the browser
with [Pyodide] and loads faster than the full wheel.

The wheel is a drop-in replacement: same package name, same `import OCP`, same
classes. Every OCP class still exists, but classes that CadQuery never reaches
have no methods.

Current build:

| Input | Version |
| --- | --- |
| OCP / OpenCascade | 7.9.3.1 / 7.9.3 |
| CadQuery (for the keep list) | 2.8.0 |
| OCP.wasm commit | [`f292a63`](https://github.com/yeicor/OCP.wasm/commit/f292a6312ec648fd4eca2d8d8734708d9da1576c) |
| Pyodide xbuildenv | 314.0.7 (Python 3.14, ABI `pyemscripten_2026_0`, emscripten 5.0.3) |

All of these are pinned in [`versions.env`](versions.env).

## Size and speed

Measured with CadQuery 2.8.0 in web-openscad-editor on Pyodide 314.0.8,
comparing upstream's 7.9.3.1 wheel with this one (139 of 314 OCP modules):

| | Upstream | This build |
| --- | --- | --- |
| Wheel | 23.7 MB | 17.9 MB |
| `OCP.*.so` | 156 MB | 111.6 MB |
| Chrome: Pyodide + CadQuery load | 12.2 s | 10.0 s |
| Chrome: `import OCP` | 7.2 s | 5.3 s |
| Firefox: Pyodide + CadQuery load | 7.8 s | 6.2–6.5 s |
| Firefox: render of an enclosure model | 9.5 s | 3.8–4.4 s |

Firefox gains the most on rendering: it scans all of a wasm module's
exception-handling try notes for every thrown C++ exception, so a smaller
module makes each OpenCascade exception cheaper.

A smoke test of about 30 CadQuery features, including the exporters, gives
the same results as with the upstream wheel.

## How it works

OCP registers each of its submodules in two phases:

1. `register_X_enums` (from `X_pre.cpp`) creates the submodule and declares its
   classes and enums.
2. `register_X` (from `X.cpp`) binds the classes' methods and functions.

[`patches/drop_modules.py`](patches/drop_modules.py) keeps phase 1 for every
module, so pybind11 still knows every type and nothing fails at import time. For
modules not on the keep list it comments out the phase 2 declaration and call in
`OCP.cpp` and deletes `X.cpp`. The linker then drops their binding code and the
OpenCascade code that only those bindings used.

[`patches/patch_OCP.cmake.patch`](patches/patch_OCP.cmake.patch) hooks this
into upstream's `patch_OCP.cmake`, which already removes the VTK and OpenGL
bindings. It runs only when the `OCP_KEEP_MODULES` environment variable points
to a keep list.

### Iteration without C++ exceptions

OCP binds `__iter__` of the NCollection containers (`TopTools_ListOfShape`,
`TopTools_IndexedMapOfShape`, ...) with pybind11's `py::make_iterator`, which
signals the end of a loop by throwing a C++ `pybind11::stop_iteration`. Every
Python `for` loop over such a collection therefore throws a C++ exception,
which costs about 0.3 s in Firefox. A simple CadQuery render does more than a
dozen of these (in `Shape.Edges()`, `Shape.Faces()`, `Workplane._findType` and
once in `import cadquery`).

[`patches/fix_iterators.py`](patches/fix_iterators.py) rewrites the 8 such
bindings in OCP's `NCollection_tmpl.hxx` to copy the elements into a Python
list and return the list's iterator, which ends without a C++ exception. The
loop yields the same copies as before, but they are made up front, so changes
to the collection during the loop are not seen. The script fails the build if
it does not find exactly these 8 bindings. `patch_OCP.cmake.patch` runs it
from upstream's `patch_OCP.cmake` too, whether or not a keep list is set.

### The keep list

[`patches/gen_keep_modules.py`](patches/gen_keep_modules.py) computes the keep
list from OCP's generated sources and the CadQuery package:

1. Start with every `OCP.X` module that CadQuery's sources import (88 for
   CadQuery 2.8.0).
2. Add the modules of base classes (from the `py::class_<...>(m, ...)`
   declarations in `X_pre.cpp`). Inherited methods are bound by the base
   class's module.
3. Add the modules of method return types (from member function pointer casts
   in `X.cpp`). CadQuery calls methods on returned objects without importing
   their module, for example on the `Poly_Triangulation` that
   `BRep_Tool.Triangulation` returns.
4. Repeat 2 and 3 until nothing changes. Skip VTK and OpenGL modules, which the
   novtk build removes anyway.

For CadQuery 2.8.0 this gives 139 modules. The list is generated in CI and
attached to every release as `keep_modules.txt`.

Limits:

* **Only CadQuery is covered.** Code that uses OCP directly (your own
  `from OCP.X import ...`, build123d, other libraries) works only if what it
  calls happens to be on the list. A class outside the list imports fine, but
  calling its methods or constructors raises `TypeError` or `AttributeError`.
* **The analysis is static and approximate.** It follows return types and base
  classes, not argument types, templates, or objects passed back through
  callbacks or `Handle` downcasts. It passes the smoke test above but is not
  proven complete. Earlier, smaller lists (89 and 116 modules) broke AMF/3MF
  and assembly XML export.
* **Module names come from class prefixes.** `module_of` maps `Foo_Bar` to
  module `Foo`, which matches OCP's layout but would miss classes that don't
  follow it.

If something is missing, add its module to the start set (or extend the
script) and rebuild.

### Build flags

On top of dropping modules, the build changes how the module is compiled
(see the comments in [`scripts/build.sh`](scripts/build.sh)):

* **The bindings are compiled with `-Os`, OpenCascade with `-O3`.** At `-O3`
  clang inlines pybind11's templates into a few huge `register_X`
  functions, which run once at import but which the browser still has to
  compile. Binding dispatch speed hardly matters next to the Python
  interpreter, while OpenCascade's geometry code stays fully optimized.
  pyodide's compiler wrapper appends `CFLAGS`/`CXXFLAGS` after all flags
  from CMake, so [`patch_OCP.cmake.patch`](patches/patch_OCP.cmake.patch)
  passes the bindings' level through `EMCC_CFLAGS`, which emcc appends last,
  and compiles a check into the module that fails the build if the flag
  doesn't arrive.
* **Hidden symbol visibility for everything.** OpenCascade's
  `Standard_EXPORT` is empty outside Windows, so by default every
  OpenCascade symbol is exported from the side module and every
  address-taken one is imported again through the GOT, which Emscripten's
  JS dynamic linker resolves when the module loads. The module only needs
  to export `PyInit_OCP`. C++ exceptions and RTTI keep working: OpenCascade
  and OCP are linked into the same module, and references to symbols of the
  main module (libc++, libc++abi) are not affected by `-fvisibility`.

## Using it from web-openscad-editor

Point web-openscad-editor's CadQuery support at a release wheel:

```toml
[cadquery]
ocp-wheel = { url = "https://github.com/yawkat/ocp-wasm-cadquery/releases/download/<tag>/cadquery_ocp_novtk_ocp_wasm-7.9.3.1%2Bcadquery2.8.0-cp314-cp314-pyemscripten_2026_0_wasm32.whl", sha256 = "<sha256 from the release>" }
```

Write the `+` of the local version as `%2B` in the URL. The SHA-256 is in the
release notes and in the `.sha256` asset next to the wheel.

The wheel only works with a Pyodide whose ABI matches the platform tag
(`pyemscripten_2026_0`, Python 3.14) and with the CadQuery version in the
wheel's local version.

## Building

### In GitHub Actions

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds the wheel:

* on **pull requests** and **manual runs** (`workflow_dispatch`): the wheel,
  its `.sha256` and `keep_modules.txt` are uploaded as the `wheel` artifact;
* on **tag pushes**: the same files are also attached to a GitHub release for
  the tag (created if it doesn't exist).

Tag releases after the wheel version, e.g. `7.9.3.1-cadquery2.8.0`, with a
`-N` suffix for rebuilds.

The emscripten cache and ccache are kept in GitHub's cache between runs, like
upstream does. A cold build takes well over an hour on GitHub's runners
(upstream allows 310 minutes); a local build with 8 parallel jobs on 24
cores took 25–36 minutes.

### Locally

You need git, curl, unzip, Python 3.14 with pip, ccache (optional) and
`wasm-opt` from [binaryen] on `PATH`. The emscripten toolchain is downloaded
into the upstream checkout.

```bash
python3.14 -m venv .venv && source .venv/bin/activate
scripts/prepare.sh          # clone OCP.wasm into ./upstream, patch, write keep list
scripts/setup_toolchain.sh  # pyodide-build, xbuildenv, emsdk
scripts/build.sh            # wheel lands in upstream/cadquery-ocp-novtk/dist
```

All three take an optional path to the upstream checkout (default
`./upstream`). Set `CMAKE_BUILD_PARALLEL_LEVEL` to limit parallel jobs.

Notes:

* **Changing the keep list on an existing build directory.** Upstream resets
  the patched OCP sources' mtimes, so ninja would silently reuse the old
  registration code. `scripts/build.sh` records a hash of the list and our
  patch files in the build directory and deletes `_deps/OCP-src`,
  `_deps/OCP.stamp` and `OCP.cpp.o` when it changes. CI always starts from a clean build directory.
* **Changing compiler flags on an existing build directory.** `pyodide
  build` doesn't pass `CFLAGS`/`CXXFLAGS` to CMake; its compiler wrapper
  appends them to each compile command without ninja or ccache noticing.
  `scripts/build.sh` deletes all object files when they change, and puts
  them into `CCACHE_NAMESPACE` so that ccache doesn't return objects built
  with other flags.
* **NixOS.** The emsdk and pyodide binaries need an FHS environment, e.g.
  `nix-shell -p steam-run binaryen --run "steam-run scripts/build.sh"` (and
  the same for `setup_toolchain.sh`). Set `TMPDIR` to a directory inside the
  checkout, since nix-shell's `TMPDIR` doesn't exist inside steam-run.

### Updating versions

[Renovate](renovate.json5) proposes updates to `versions.env`: CadQuery and
binaryen directly, a new OCP.wasm commit or Pyodide xbuildenv only after
approval in the dependency dashboard. When bumping by hand:

* **CadQuery**: just bump `CADQUERY_VERSION`; the keep list is regenerated.
  Check that the OCP version CadQuery requires is still the one built.
* **OCP.wasm commit**: the commit decides the OCP version (`OCP_VERSION` must
  match the URL in its `cadquery-ocp-novtk/CMakeLists.txt`; `prepare.sh`
  checks). Upstream master is on OCP 8.0, which CadQuery 2.8 cannot use.
* **xbuildenv**: changes the wheel's ABI. Keep it in step with the Pyodide
  version of the app that loads the wheel, and `PYTHON_VERSION` with it.

## License

This repository is MIT licensed. The wheel contains OpenCascade (LGPL 2.1 with
the Open CASCADE exception), OCP (Apache 2.0) and code built with OCP.wasm's
scripts (MIT), among others; see [NOTICE.md](NOTICE.md).

[OCP.wasm]: https://github.com/yeicor/OCP.wasm
[OCP]: https://github.com/CadQuery/OCP
[CadQuery]: https://github.com/CadQuery/cadquery
[Pyodide]: https://pyodide.org/
[binaryen]: https://github.com/WebAssembly/binaryen
