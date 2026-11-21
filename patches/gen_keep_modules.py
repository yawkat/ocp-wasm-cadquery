"""Compute the OCP submodules whose method bindings a CadQuery build needs.

Starts from the OCP modules that CadQuery imports and closes the set over:

* base classes: methods inherited from a base class are registered by the
  base class's module, and
* return types: CadQuery calls methods on objects returned by OCP functions
  without importing their module (e.g. BRep_Tool.Triangulation returns a
  Poly_Triangulation).

Usage: gen_keep_modules.py <OCP generated sources dir> <cadquery package dir> > keep_modules.txt
"""

import glob
import os
import re
import sys

source_dir, cadquery_dir = sys.argv[1], sys.argv[2]

modules = {
    os.path.basename(p)[: -len("_pre.cpp")]
    for p in glob.glob(os.path.join(source_dir, "*_pre.cpp"))
    if not os.path.basename(p).startswith("collections")
}
# The novtk build removes VTK and OpenGL bindings (see patch_OCP.cmake).
modules = {m for m in modules if not re.search(r"vtk|opengl", m, re.I)}

start = set()
for path in glob.glob(os.path.join(cadquery_dir, "**", "*.py"), recursive=True):
    with open(path, encoding="utf-8") as f:
        start |= set(re.findall(r"(?:from|import)\s+OCP\.([A-Za-z0-9_]+)", f.read()))
start &= modules

# Member function pointer casts, e.g. `(Poly_Triangulation (BRep_Tool::*)(...))`
# or static ones `(opencascade::handle<Geom_Surface> (*)(...))`
RETURN_RE = re.compile(
    r"\(\s*(?:const\s+)?(?:opencascade::handle<)?([A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+)>?\s*[&*]?\s*"
    r"\(\s*(?:[A-Za-z0-9_]+::)?\*\s*\)"
)
CLASS_RE = re.compile(r"py::class_<(.*?)>\s*\(\s*m\s*,", re.S)
NAME_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+)\b")


def module_of(cls):
    prefix = cls.split("_")[0]
    return prefix if prefix in modules else None


def read(module, suffix):
    path = os.path.join(source_dir, module + suffix)
    if not os.path.exists(path):
        return ""
    with open(path, errors="ignore") as f:
        return f.read()


def dependencies(module):
    found = set()
    for name in RETURN_RE.findall(read(module, ".cpp")):
        found.add(module_of(name))
    for args in CLASS_RE.findall(read(module, "_pre.cpp")):
        for name in NAME_RE.findall(args):
            found.add(module_of(name))
    found.discard(None)
    return found


keep = set(start)
todo = list(start)
while todo:
    for dependency in dependencies(todo.pop()):
        if dependency not in keep:
            keep.add(dependency)
            todo.append(dependency)

print("\n".join(sorted(keep)))
print(f"{len(start)} imported by CadQuery, {len(keep)} of {len(modules)} kept", file=sys.stderr)
