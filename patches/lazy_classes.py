"""Bind the methods of OCP's classes on first use instead of at `import OCP`.

OCP registers each submodule in two phases: `register_X_enums` (X_pre.cpp)
declares its classes and enums, `register_X` (X.cpp) binds their methods. In
Chrome, almost all of `import OCP` is spent compiling the code of `register_X`:
V8 compiles WebAssembly functions lazily, on their first call, and each binding
runs exactly once.

This rewrites `register_X` in every X.cpp so that the bindings of each class
(the `// Class` blocks) and of each NCollection typedef (`register_template_*`)
move into a lambda that is passed to `ocp_lazy::add` (see ocp_lazy.hxx) and
runs the first time the class is used. Each lambda is its own function, so its
code is not compiled until then. Everything else stays at import time, in the
same order: the class declarations of phase 1, nested enums and class constants
(other code may return or take them), module-level functions and exception
translators.

It also copies ocp_lazy.hxx into the source directory and makes OCP.cpp call
`ocp_lazy::finish` after the last `register_X`.

The script fails if any X.cpp does not have exactly the expected shape, and
does nothing on already patched sources.

Usage: lazy_classes.py <OCP source dir>
"""

import os
import re
import shutil
import sys

MARKER = "/* ocp-wasm-cadquery: lazy */"
HEADER = "ocp_lazy.hxx"
INCLUDE_ANCHOR = '#include "OCP_specific.inc"\n'
INCLUDE = f'#include "{HEADER}" {MARKER}\n'

source_dir = sys.argv[1]


class ShapeError(Exception):
    pass


def expect(cond, path, lineno, what):
    if not cond:
        raise ShapeError(f"{path}:{lineno + 1}: {what}")


def add_include(text, path):
    expect(text.count(INCLUDE_ANCHOR) == 1, path, 0, f"expected one {INCLUDE_ANCHOR.strip()}")
    return text.replace(INCLUDE_ANCHOR, INCLUDE_ANCHOR + INCLUDE, 1)


CLASS_RE = re.compile(r"^    // Class (.+) from (\S+)$")
KLASS_RE = re.compile(r'^    klass = m\.attr\("(\w+)"\);$')
CHAIN_RE = re.compile(r"^    static_cast<py::class_<")
TYPEDEF_RE = re.compile(r'^(\s*)(register_template_\w+<.*>\(m,"(\w+)"\);)$')


def statements(lines, start, end, path):
    """Split lines[start:end] into (first line index, lines) statements, skipping comments."""
    result = []
    i = start
    while i < end:
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("//"):
            i += 1
            continue
        first = i
        while not lines[i].rstrip().endswith(";"):
            i += 1
            expect(i < end, path, first, "unterminated statement before the class's bindings")
        result.append((first, lines[first : i + 1]))
        i += 1
    return result


def patch_module(path, text):
    lines = text.split("\n")
    module = os.path.basename(path)[: -len(".cpp")]
    head = f"void register_{module}(py::module &main_module) {{"
    starts = [i for i, line in enumerate(lines) if line == head]
    expect(len(starts) == 1, path, 0, f"expected one '{head}'")
    i = starts[0] + 1

    def find(marker, start):
        found = [j for j in range(start, len(lines)) if lines[j] == marker]
        expect(len(found) == 1, path, start, f"expected one '{marker}' after line {start + 1}")
        return found[0]

    klass_decl = find("py::object klass;", i)
    classes = find("// classes", klass_decl)
    functions = find("// functions", classes)
    typedefs = find("// register typdefs", functions)
    exceptions = find("// exceptions", typedefs)
    for j in range(functions, len(lines)):
        expect("klass" not in lines[j], path, j, "klass used after the classes")

    out = lines[: classes + 1]
    chunks = 0
    j = classes + 1
    while j < functions:
        line = lines[j]
        if not line.strip():
            out.append(line)
            j += 1
            continue
        m = CLASS_RE.match(line)
        expect(m, path, j, "expected '// Class ... from ...'")
        header = j
        j += 1
        while not lines[j].strip():
            j += 1
        k = KLASS_RE.match(lines[j])
        expect(k, path, j, "expected 'klass = m.attr(\"...\");'")
        name = k.group(1)
        prefix_start = j + 1
        chain = next(
            (c for c in range(prefix_start, functions) if CHAIN_RE.match(lines[c]) or CLASS_RE.match(lines[c])),
            None,
        )
        expect(chain is not None and CHAIN_RE.match(lines[chain]), path, j, "expected 'static_cast<py::class_<...>>(klass)'")
        end = next((c for c in range(chain, functions) if lines[c] == ";" or CLASS_RE.match(lines[c])), None)
        expect(end is not None and lines[end] == ";", path, chain, "expected ';' ending the class's bindings")

        eager, lazy = [], []
        for first, stmt in statements(lines, prefix_start, chain, path):
            s = stmt[0].lstrip()
            if s.startswith("register_default_constructor<"):
                lazy += stmt
            elif s.startswith("py::enum_<") or s.startswith("klass.attr("):
                eager += stmt
            else:
                expect(False, path, first, "unexpected statement before the class's bindings")

        out.append(lines[header])
        if eager:
            out.append(lines[j])
            out += eager
        out.append(f'    ocp_lazy::add(m, "{name}", [](py::module &m) {{ {MARKER}')
        out.append(f'    py::object klass = m.attr("{name}");')
        out += lazy
        out += lines[chain : end + 1]
        out.append("    });")
        chunks += 1
        j = end + 1

    out += lines[functions : typedefs + 1]
    templates = 0
    for j in range(typedefs + 1, exceptions):
        line = lines[j]
        if not line.strip():
            out.append(line)
            continue
        t = TYPEDEF_RE.match(line)
        expect(t, path, j, "expected 'register_template_...(m,\"...\");'")
        indent, call, name = t.groups()
        out.append(f'{indent}ocp_lazy::add(m, "{name}", [](py::module &m) {{ {MARKER} {call} }});')
        templates += 1
    out += lines[exceptions:]
    return add_include("\n".join(out), path), chunks, templates


def patch_ocp_cpp(path, text):
    anchor = "// Add attributes if present\n"
    expect(text.count(anchor) == 1, path, 0, f"expected one '{anchor.strip()}'")
    text = text.replace(anchor, f"    ocp_lazy::finish(m); {MARKER}\n\n{anchor}", 1)
    return add_include(text, path)


def main():
    names = sorted(
        name
        for name in os.listdir(source_dir)
        if name.endswith(".cpp") and not name.endswith("_pre.cpp") and name != "OCP.cpp"
    )
    if not names:
        sys.exit(f"lazy_classes.py: no module sources in {source_dir}")
    # Check every file before writing any
    changes = {}
    already = chunks = templates = 0
    try:
        for name in names + ["OCP.cpp"]:
            path = os.path.join(source_dir, name)
            text = open(path).read()
            if INCLUDE in text:
                already += 1
            elif name == "OCP.cpp":
                changes[path] = patch_ocp_cpp(path, text)
            else:
                changes[path], c, t = patch_module(path, text)
                chunks += c
                templates += t
    except ShapeError as e:
        sys.exit(f"lazy_classes.py: unexpected generated code: {e}")
    if changes and already:
        sys.exit(f"lazy_classes.py: {already} files are already patched, {len(changes)} are not")
    shutil.copyfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), HEADER), os.path.join(source_dir, HEADER))
    for path, text in changes.items():
        open(path, "w").write(text)
    if changes:
        print(f"OCP: deferred the bindings of {chunks} classes and {templates} typedefs in {len(names)} modules")
    else:
        print(f"OCP: the bindings of all {len(names)} modules are already deferred")

main()
