"""Keep only the method bindings of selected OCP submodules.

OCP registers each submodule in two phases: `register_X_enums` (from X_pre.cpp)
declares the module and its classes, and `register_X` (from X.cpp) binds their
methods. This keeps phase 1 for every module, so all types stay known to
pybind11, and drops phase 2 (and X.cpp itself) for modules that are not in the
keep list. The linker then discards their binding code and any OpenCascade
code that only they used.

Usage: drop_modules.py <OCP source dir> <keep list file>
"""

import os
import re
import sys

source_dir, keep_file = sys.argv[1], sys.argv[2]
keep = {line.strip() for line in open(keep_file) if line.strip() and not line.startswith("#")}

ocp_cpp = os.path.join(source_dir, "OCP.cpp")
text = open(ocp_cpp).read()
# Every module has an X_pre.cpp (kept), which makes this safe to run again on
# already patched sources.
modules = {
    name[: -len("_pre.cpp")]
    for name in os.listdir(source_dir)
    if name.endswith("_pre.cpp") and not name.startswith("collections")
}
unknown = keep - modules
if unknown:
    print(f"OCP: ignoring unknown modules in keep list: {sorted(unknown)}")
    keep &= modules
drop = sorted(modules - keep)


def comment_out(match):
    return "// dropped: " + match.group(0)


for module in drop:
    # Forward declaration and call of the (non-enum) register function
    text = re.sub(rf"^void register_{module}\(py::module&\);$", comment_out, text, flags=re.M)
    text = re.sub(rf"^[ \t]*register_{module}\(m\);$", comment_out, text, flags=re.M)
    path = os.path.join(source_dir, module + ".cpp")
    if os.path.exists(path):
        os.remove(path)
open(ocp_cpp, "w").write(text)
print(f"OCP: keeping {len(keep)} of {len(modules)} submodules, dropped {len(drop)}")
