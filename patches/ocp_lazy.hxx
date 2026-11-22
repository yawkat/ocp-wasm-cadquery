// ocp-wasm-cadquery: bind the methods of OCP's classes on first use.
//
// lazy_classes.py rewrites each register_X function so that the method
// bindings of every class (and of every NCollection typedef) are not run at
// `import OCP`, but passed to ocp_lazy::add. They run the first time Python
// needs the class:
//
//  * an instance of it or of a subclass is created, from Python or by a C++
//    function returning one (the type's tp_alloc),
//  * an attribute of the class or of a subclass is looked up (the metaclass's
//    tp_getattro: static methods, `cls.__dict__`, `cls.__init__`, ...), or
//  * the class or a subclass is called (the metaclass's tp_call, which covers
//    Python subclasses, whose tp_alloc Python sets itself).
//
// Instance attributes and special methods (`__hash__`, `__iter__`, operators)
// need no hook: an instance only exists after its class was bound. Bindings
// always run for the whole MRO, base classes first, because a class only binds
// its own methods.
//
// All classes are still declared at import (register_X_enums), so pybind11
// knows every type for argument conversion and return values, as before.
#pragma once

#include <pybind11/pybind11.h>

#include <exception>
#include <unordered_map>
#include <vector>

namespace ocp_lazy {

namespace py = pybind11;

using register_fn = void (*)(py::module_ &);

struct registration {
    PyObject *module; // borrowed: OCP's submodules are never unloaded
    register_fn fn;
};

struct state {
    std::unordered_map<PyTypeObject *, std::vector<registration>> pending;
    std::size_t added = 0;
    std::size_t run = 0;
    PyTypeObject *metaclass = nullptr;
    getattrofunc meta_getattro = nullptr;
    ternaryfunc meta_call = nullptr;
    allocfunc alloc = nullptr;
};

inline state &get_state() {
    static state *s = new state(); // never destroyed, like the bindings
    return *s;
}

/// Run the pending bindings of `type` and its bases. Returns false with a
/// Python error set if one of them failed.
inline bool ensure(PyTypeObject *type) {
    state &s = get_state();
    if (s.pending.empty() || type->tp_mro == nullptr) {
        return true;
    }
    py::tuple mro = py::reinterpret_borrow<py::tuple>(type->tp_mro);
    for (Py_ssize_t i = PyTuple_GET_SIZE(mro.ptr()) - 1; i >= 0; --i) {
        auto *base = reinterpret_cast<PyTypeObject *>(PyTuple_GET_ITEM(mro.ptr(), i));
        auto it = s.pending.find(base);
        if (it == s.pending.end()) {
            continue;
        }
        // Remove first: the bindings look up attributes of the class and may
        // create instances of it (default arguments).
        std::vector<registration> regs = std::move(it->second);
        s.pending.erase(it);
        try {
            for (const registration &r : regs) {
                auto m = py::reinterpret_borrow<py::module_>(r.module);
                r.fn(m);
                s.run++;
            }
        } catch (py::error_already_set &e) {
            e.restore();
            return false;
        } catch (py::builtin_exception &e) {
            e.set_error();
            return false;
        } catch (const std::exception &e) {
            PyErr_SetString(PyExc_RuntimeError, e.what());
            return false;
        } catch (...) {
            PyErr_SetString(PyExc_RuntimeError, "ocp_lazy: unknown C++ exception while binding a class");
            return false;
        }
    }
    return true;
}

inline PyObject *lazy_alloc(PyTypeObject *type, Py_ssize_t nitems) {
    state &s = get_state();
    // Afterwards nothing in this type's MRO is pending any more
    type->tp_alloc = s.alloc;
    if (!ensure(type)) {
        // pybind11 does not expect tp_alloc to fail
        PyErr_WriteUnraisable(reinterpret_cast<PyObject *>(type));
    }
    return s.alloc(type, nitems);
}

inline PyObject *lazy_getattro(PyObject *type, PyObject *name) {
    state &s = get_state();
    if (!ensure(reinterpret_cast<PyTypeObject *>(type))) {
        return nullptr;
    }
    return s.meta_getattro(type, name);
}

inline PyObject *lazy_call(PyObject *type, PyObject *args, PyObject *kwargs) {
    state &s = get_state();
    if (!ensure(reinterpret_cast<PyTypeObject *>(type))) {
        return nullptr;
    }
    return s.meta_call(type, args, kwargs);
}

inline void hook_alloc(PyTypeObject *type) {
    state &s = get_state();
    if (type->tp_alloc == lazy_alloc) {
        return;
    }
    if (s.alloc == nullptr) {
        s.alloc = type->tp_alloc;
    }
    if (type->tp_alloc != s.alloc) {
        pybind11::pybind11_fail(std::string("ocp_lazy: unexpected tp_alloc of ") + type->tp_name);
    }
    type->tp_alloc = lazy_alloc;
}

/// Defer the bindings `fn` of class `name` in submodule `m` until first use.
inline void add(py::module_ &m, const char *name, register_fn fn) {
    state &s = get_state();
    py::object cls = m.attr(name);
    if (!PyType_Check(cls.ptr())) {
        pybind11::pybind11_fail(std::string("ocp_lazy: ") + name + " is not a class");
    }
    auto *type = reinterpret_cast<PyTypeObject *>(cls.ptr());
    PyTypeObject *metaclass = Py_TYPE(cls.ptr());
    if (s.metaclass == nullptr) {
        if (metaclass != py::detail::get_internals().default_metaclass) {
            pybind11::pybind11_fail(std::string("ocp_lazy: unexpected metaclass of ") + name);
        }
        s.metaclass = metaclass;
        s.meta_getattro = metaclass->tp_getattro;
        s.meta_call = metaclass->tp_call;
        metaclass->tp_getattro = lazy_getattro;
        metaclass->tp_call = lazy_call;
    } else if (metaclass != s.metaclass) {
        pybind11::pybind11_fail(std::string("ocp_lazy: unexpected metaclass of ") + name);
    }
    s.pending[type].push_back({m.ptr(), fn});
    s.added++;
    hook_alloc(type);
}

/// Called after all register_X: also hook the allocation of classes that have
/// no deferred bindings of their own but a base class with some (classes of
/// dropped modules, for example).
inline void finish(py::module_ &m) {
    state &s = get_state();
    std::vector<PyTypeObject *> types;
    py::detail::with_internals([&](py::detail::internals &internals) {
        for (const auto &entry : internals.registered_types_py) {
            types.push_back(entry.first);
        }
    });
    for (PyTypeObject *type : types) {
        PyObject *mro = type->tp_mro;
        if (mro == nullptr || type->tp_alloc == lazy_alloc) {
            continue;
        }
        for (Py_ssize_t i = 0; i < PyTuple_GET_SIZE(mro); ++i) {
            if (s.pending.count(reinterpret_cast<PyTypeObject *>(PyTuple_GET_ITEM(mro, i)))) {
                hook_alloc(type);
                break;
            }
        }
    }
    // For measurements and tests: (bindings deferred, bindings run so far,
    // classes still pending), and a way to run all of them.
    m.def("_lazy_stats", []() {
        state &s = get_state();
        return py::make_tuple(s.added, s.run, s.pending.size());
    });
    m.def("_lazy_bind_all", []() {
        state &s = get_state();
        while (!s.pending.empty()) {
            if (!ensure(s.pending.begin()->first)) {
                throw py::error_already_set();
            }
        }
    });
}

} // namespace ocp_lazy
