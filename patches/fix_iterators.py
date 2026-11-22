"""Make Python iteration over OCP's NCollection bindings end without a C++ exception.

OCP binds `__iter__` of the NCollection templates (NCollection_List, _Map,
_IndexedMap, _DataMap, ...) with pybind11's `py::make_iterator`. That iterator
can only signal the end by throwing `pybind11::stop_iteration` from C++, so
every `for` loop over an OCP collection ends with a thrown C++ exception. In
WebAssembly that is very slow in Firefox, which scans all of the module's
exception-handling try notes for every throw (about 0.3 s each for OCP).

This rewrites each of these `__iter__` bindings to copy the elements into a
Python list and return the list's iterator, which ends with a plain Python
StopIteration. The elements are copied with the same return value policy as
before, and the same begin()/end() (or cbegin()/cend()) pair is used, so the
loop yields the same values (map values, not keys, for the DataMaps). The
`keep_alive` goes away: the list holds copies, not references into the
collection, and a list iterator cannot be the nurse of a keep_alive anyway (it
does not support weak references).

The script fails if it does not find exactly the expected number of bindings,
and does nothing on already patched sources.

Usage: fix_iterators.py <OCP source dir>
"""

import os
import re
import sys

EXPECTED = 8
MARKER = "/* ocp-wasm-cadquery: list iterator */"

source_dir = sys.argv[1]
path = os.path.join(source_dir, "NCollection_tmpl.hxx")
text = open(path).read()

pattern = re.compile(
    r"""\.def\("__iter__",\[\]\((?P<self>const\ [^&()]+?\ &self)\)\s*
        \{\ return\ py::make_iterator<py::return_value_policy::copy>
        \(self\.(?P<begin>c?begin)\(\),\ self\.(?P<end>c?end)\(\)\);\ \},\s*
        py::keep_alive<0,\ 1>\(\)\)""",
    re.X,
)


def replace(match):
    begin, end = match["begin"], match["end"]
    return (
        f'.def("__iter__",[]({match["self"]}) {MARKER}\n'
        f"             {{ py::list items;\n"
        f"               for (auto it = self.{begin}(), last = self.{end}(); it != last; ++it)\n"
        f"                 items.append(py::cast(*it, py::return_value_policy::copy));\n"
        f"               return py::iter(items); }})"
    )


text, count = pattern.subn(replace, text)
patched = text.count(MARKER)
leftover = text.count("make_iterator")
if patched != EXPECTED or leftover:
    sys.exit(
        f"fix_iterators.py: expected {EXPECTED} patched __iter__ bindings in {path}, "
        f"found {patched} (replaced {count} now), {leftover} make_iterator uses left"
    )
if count:
    open(path, "w").write(text)
    print(f"OCP: replaced {count} make_iterator __iter__ bindings with list iterators")
else:
    print("OCP: __iter__ bindings are already patched")
