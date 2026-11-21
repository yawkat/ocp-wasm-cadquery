# Notices

## This repository

The scripts, patches and workflow in this repository are under the MIT license
(see [LICENSE](LICENSE)).

`patches/patch_OCP.cmake.patch` contains context lines from
`cadquery-ocp-novtk/patch_OCP.cmake` in [yeicor/OCP.wasm], and
`patches/drop_modules.py` is written to run from that build. OCP.wasm is
Copyright 2025 Yeicor, under the MIT license.

## The built wheel

The wheel this repository builds is a binary of third-party code. It is not
covered by this repository's MIT license alone. It contains:

| Component | License |
| --- | --- |
| [Open CASCADE Technology][occt] 7.9.3 | GNU LGPL 2.1 with the Open CASCADE exception |
| [OCP] (CadQuery's pybind11 bindings for OCCT) | Apache License 2.0 |
| [OCP.wasm][yeicor/OCP.wasm] build scripts and patches | MIT |
| [pybind11] | BSD 3-Clause |
| [RapidJSON] | MIT |
| [{fmt}][fmt] | MIT |
| [FreeType] (emscripten port) | FreeType License |
| emscripten runtime and libc++/libc++abi | MIT / University of Illinois NCSA, Apache 2.0 with LLVM exception |

Open CASCADE Technology is statically linked into the WebAssembly module. The
complete build (this repository, the pinned OCP.wasm commit and the upstream
sources it downloads) is public, so the wheel can be rebuilt with a modified
OCCT. Redistributors should check the LGPL 2.1 terms and the Open CASCADE
exception themselves.

[occt]: https://github.com/Open-Cascade-SAS/OCCT
[OCP]: https://github.com/CadQuery/OCP
[yeicor/OCP.wasm]: https://github.com/yeicor/OCP.wasm
[pybind11]: https://github.com/pybind/pybind11
[RapidJSON]: https://github.com/Tencent/rapidjson
[fmt]: https://github.com/fmtlib/fmt
[FreeType]: https://freetype.org/
