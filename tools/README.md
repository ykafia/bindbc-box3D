# Box3D D Build and Binding Generator

`generate_bindings.d` is the single build/code-generation entry point. It builds
Box3D as a shared library with CMake, then generates the dynamic BindBC module
at `source/bindbc/box3d/package.d`. Build and temporary code-generation files
are kept outside the `box3d` Git submodule.

Requirements:

- Initialize the `box3d` submodule.
- Install a D compiler with `rdmd` and DUB.
- Install CMake and Clang; make both available on `PATH` or pass executable
  paths with `--cmake` and `--clang`.
- Install DStep with DUB (`dub run dstep -- --help`); the script falls back to
  `dub run dstep` when `dstep` is not on `PATH`.

Run from the repository root:

```sh
rdmd tools/generate_bindings.d
```

On Windows, first enter the x64 Visual Studio developer shell, then run the
same command. For the Visual Studio instance used during development:

```powershell
Import-Module "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell d88e261c -Arch amd64 -HostArch amd64
rdmd tools/generate_bindings.d
```

Windows defaults to the NMake generator, which uses MSVC from that shell.
macOS and Linux use CMake's native generator. Apple Silicon builds arm64 by
default; pass `--osx-arch arm64` to request it explicitly.

The script also accepts `--generator NAME`, `--config NAME`, `--build-dir PATH`,
`--submodule PATH`, `--output PATH`, `--cmake PATH`, and `--clang PATH`.
`--double-precision` generates the ABI for a Box3D library built with
`BOX3D_DOUBLE_PRECISION`; `--check` checks generated bindings without writing
them. Runtime-valued C macros are omitted, and only compile-time constants with
resolved dependencies are emitted.

To run the D usage example after building, pass the shared library printed by
the script:

```sh
rdmd source/app.d -- build/box3d-shared/bin/libbox3d.so
```

Use the printed `.dll` or `.dylib` path on Windows or macOS, respectively.