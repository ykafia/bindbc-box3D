#!/usr/bin/env python3
"""Build the Box3D submodule as a shared library with CMake."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--submodule", type=Path, default=Path("box3d"))
    parser.add_argument(
        "--build-dir",
        type=Path,
        default=Path("build") / "box3d-shared",
        help="build directory (must be outside the box3d submodule)",
    )
    parser.add_argument("--cmake", default="cmake", help="CMake executable")
    parser.add_argument("--generator", help="CMake generator, for example Visual Studio 17 2022")
    parser.add_argument("--config", default="Release", help="CMake build configuration")
    parser.add_argument(
        "--osx-arch",
        help="Apple target architecture, for example arm64 or universal",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    submodule = (root / args.submodule).resolve()
    if not (submodule / "CMakeLists.txt").is_file():
        print(
            f"Box3D CMake project not found: {submodule}\nInitialize the box3d Git submodule first.",
            file=sys.stderr,
        )
        return 2

    build_dir = (root / args.build_dir).resolve()
    if is_within(build_dir, submodule):
        print(
            f"Refusing to create build output inside the box3d submodule: {build_dir}",
            file=sys.stderr,
        )
        return 2
    if args.osx_arch and sys.platform != "darwin":
        print("--osx-arch can only be used on macOS.", file=sys.stderr)
        return 2

    configure = [
        args.cmake,
        "-S",
        str(submodule),
        "-B",
        str(build_dir),
        f"-DCMAKE_BUILD_TYPE={args.config}",
        "-DBUILD_SHARED_LIBS=ON",
        "-DBOX3D_SAMPLES=OFF",
        "-DBOX3D_BENCHMARKS=OFF",
        "-DBOX3D_UNIT_TESTS=OFF",
        "-DBOX3D_DOCS=OFF",
    ]
    if args.generator:
        configure.extend(["-G", args.generator])
    if args.osx_arch:
        configure.append(f"-DCMAKE_OSX_ARCHITECTURES={args.osx_arch}")

    try:
        result = subprocess.run(configure, check=False)
        if result.returncode:
            return result.returncode
        result = subprocess.run(
            [args.cmake, "--build", str(build_dir), "--config", args.config, "--target", "box3d"],
            check=False,
        )
    except FileNotFoundError:
        print("CMake was not found. Install CMake or pass --cmake PATH.", file=sys.stderr)
        return 2
    if result.returncode:
        return result.returncode

    if sys.platform == "win32":
        patterns = ["box3d.dll"]
    elif sys.platform == "darwin":
        patterns = ["libbox3d.dylib"]
    else:
        patterns = ["libbox3d.so", "libbox3d.so.*"]
    libraries = [path for pattern in patterns for path in build_dir.rglob(pattern)]
    if not libraries:
        print(f"Build succeeded but no Box3D shared library was found under {build_dir}.", file=sys.stderr)
        return 2

    print("Built Box3D shared library:")
    for library in sorted(set(libraries)):
        print(f"  {library}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())