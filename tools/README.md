# Box3D BindBC generator

`generate_bindings.py` translates the public Box3D C API with DStep and emits a
dynamic BindBC module at `source/bindbc/box3d/package.d`. It does not modify the
`box3d` Git submodule.

Requirements:

- Initialize the `box3d` submodule.
- Install Clang and make it available on `PATH`, or pass its path with `--clang`.
- Install DStep with DUB (`dub run dstep -- --help`); if `dstep` is not on
  `PATH`, the generator invokes it through DUB.
- Python 3.

Generate or refresh the default single-precision bindings from the repository
root:

```powershell
py tools/generate_bindings.py
```

On macOS or Linux, use `python3` in place of `py`.

For a Box3D library built with `BOX3D_DOUBLE_PRECISION`, generate the matching
binding instead:

```powershell
py tools/generate_bindings.py --double-precision
```

The precision modes have different ABIs. Generate the mode that matches the
Box3D library you load. `--check` regenerates in a temporary directory and
returns an error if the checked-in output differs. Use `--clang PATH` and
`--dstep PATH` to select non-default executables. Runtime-valued C macros are
omitted; only compile-time constants whose dependencies are available are
emitted as D enums.

## Build Box3D Shared

`build_box3d_shared.py` builds the Box3D CMake target with
`BUILD_SHARED_LIBS=ON`. Its build tree is `build/box3d-shared/`, outside the
`box3d` Git submodule.

On Windows, select an installed CMake generator. For Visual Studio 2022:

```powershell
py tools/build_box3d_shared.py --generator "Visual Studio 17 2022"
```

For MinGW, use its makefiles generator instead:

```powershell
py tools/build_box3d_shared.py --generator "MinGW Makefiles"
```

On Linux and macOS, use the native CMake generator:

```sh
python3 tools/build_box3d_shared.py
```

On Apple Silicon, CMake builds for the native arm64 architecture by default.
Pass `--osx-arch arm64` to request it explicitly. The helper builds only the
Box3D library, with samples, benchmarks, tests, and docs disabled. It prints
the platform library path when the build succeeds. Put that library on the OS
loader's search path for `loadBox3D()`, or pass its full path to
`loadBox3D(const(char)*)`.

`source/app.d` is a small D usage example. Pass the shared-library path after
`--` when running it:

```powershell
dub run -- build/box3d-shared/bin/box3d.dll
```

On Linux and macOS, pass the `.so` or `.dylib` path printed by the build helper.