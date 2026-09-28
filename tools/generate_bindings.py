#!/usr/bin/env python3
"""Generate dynamic BindBC bindings from the Box3D public C headers."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = Path("include") / "box3d" / "box3d.h"
OUTPUT = Path("source") / "bindbc" / "box3d" / "package.d"
HEADERS = (
    "base.h",
    "collision.h",
    "constants.h",
    "id.h",
    "math_functions.h",
    "types.h",
    "box3d.h",
)
UNIMPLEMENTED_API = {"b3World_DumpShapeBounds"}


def strip_comments(source: str) -> str:
    def preserve_lines(match: re.Match[str]) -> str:
        return "".join("\n" if char == "\n" else " " for char in match.group())

    return re.sub(r"/\*.*?\*/|//[^\n]*", preserve_lines, source, flags=re.DOTALL)


def split_parameters(parameters: str) -> list[str]:
    if not parameters.strip() or parameters.strip() == "void":
        return []

    result: list[str] = []
    start = 0
    nesting = 0
    for index, char in enumerate(parameters):
        if char in "([<{":
            nesting += 1
        elif char in ")]}>" and nesting:
            nesting -= 1
        elif char == "," and nesting == 0:
            result.append(parameters[start:index].strip())
            start = index + 1
    result.append(parameters[start:].strip())
    return result


def parameter_type(parameter: str) -> str:
    parameter = parameter.strip()
    named_parameter = re.match(r"^(.*\S)\s+([A-Za-z_]\w*)$", parameter)
    if named_parameter:
        return named_parameter.group(1).strip()
    return parameter


def parameter_name(parameter: str) -> str | None:
    match = re.search(r"([A-Za-z_]\w*)\s*$", parameter)
    return match.group(1) if match else None


def parse_api_declaration(
    statement: str,
    start: int,
    end: int,
    callback_parameters: dict[tuple[str, str], str],
):
    statement = re.sub(
        r"^\s*extern\s*\(\s*C\s*\)\s*:?[ \t\r\n]*", "", statement
    ).strip()
    name_match = re.search(r"\b(b3\w*)\s*\(", statement)
    if not name_match:
        return None

    name = name_match.group(1)
    open_paren = statement.find("(", name_match.start())
    depth = 0
    close_paren = -1
    for index in range(open_paren, len(statement)):
        if statement[index] == "(":
            depth += 1
        elif statement[index] == ")":
            depth -= 1
            if depth == 0:
                close_paren = index
                break
    if close_paren < 0 or statement[close_paren + 1 :].strip() != ";":
        return None

    return_type = statement[: name_match.start()].strip()
    return_type = re.sub(r"^extern\s*\(\s*C\s*\)\s*", "", return_type)
    if not return_type or "=" in return_type or "{" in return_type or "}" in return_type:
        return None

    parameters = []
    for parameter in split_parameters(statement[open_paren + 1 : close_paren]):
        argument_name = parameter_name(parameter)
        callback_alias = callback_parameters.get((name_match.group(1), argument_name or ""))
        parameters.append(callback_alias or parameter_type(parameter))
    return {
        "name": name,
        "start": start,
        "end": end,
        "function_type": f"extern(C) {return_type} function({', '.join(parameters)})",
    }


def callback_parameter_aliases(headers: list[Path]) -> dict[tuple[str, str], str]:
    aliases: dict[tuple[str, str], str] = {}
    callback_type = re.compile(r"\b(b3\w*(?:Fcn|Callback))\s*\*\s*(\w+)\s*$")
    for header in headers:
        source = strip_comments(header.read_text(encoding="utf-8"))
        for match in re.finditer(r"\bB3_API\s+([^;]+);", source, flags=re.DOTALL):
            declaration = match.group(1)
            function_match = re.search(r"\b(b3\w*)\s*\(", declaration)
            if not function_match:
                continue
            open_paren = declaration.find("(", function_match.start())
            depth = 0
            close_paren = -1
            for index in range(open_paren, len(declaration)):
                if declaration[index] == "(":
                    depth += 1
                elif declaration[index] == ")":
                    depth -= 1
                    if depth == 0:
                        close_paren = index
                        break
            if close_paren < 0:
                continue
            for parameter in split_parameters(declaration[open_paren + 1 : close_paren]):
                callback = callback_type.search(parameter)
                if callback:
                    aliases[(function_match.group(1), callback.group(2))] = callback.group(1)
    return aliases


def api_names_in_header(header: Path, double_precision: bool) -> set[str]:
    source = strip_comments(header.read_text(encoding="utf-8"))
    names = set()
    for match in re.finditer(r"\bB3_API\s+([^;]+);", source, flags=re.DOTALL):
        function = re.search(r"\b(b3\w*)\s*\(", match.group(1))
        if function:
            name = function.group(1)
            if double_precision and name == "b3CreateWorld":
                name = "b3CreateWorldDoublePrecision"
            names.add(name)
    return names


def callback_typedef_parameters(headers: list[Path]) -> dict[str, dict[str, str]]:
    typedefs: dict[str, dict[str, str]] = {}
    callback_type = re.compile(r"\b(b3\w*(?:Fcn|Callback))\s*\*\s*(\w+)\s*$")
    for header in headers:
        source = strip_comments(header.read_text(encoding="utf-8"))
        for match in re.finditer(r"\btypedef\s+([^;]+);", source, flags=re.DOTALL):
            declaration = match.group(1)
            function_match = re.search(r"\b(b3\w+)\s*\(", declaration)
            if not function_match:
                continue
            open_paren = declaration.find("(", function_match.start())
            depth = 0
            close_paren = -1
            for index in range(open_paren, len(declaration)):
                if declaration[index] == "(":
                    depth += 1
                elif declaration[index] == ")":
                    depth -= 1
                    if depth == 0:
                        close_paren = index
                        break
            if close_paren < 0:
                continue
            nested_aliases = {}
            for parameter in split_parameters(declaration[open_paren + 1 : close_paren]):
                callback = callback_type.search(parameter)
                if callback:
                    nested_aliases[callback.group(2)] = callback.group(1)
            if nested_aliases:
                typedefs[function_match.group(1)] = nested_aliases
    return typedefs


def fix_nested_callbacks(source: str, typedef_parameters: dict[str, dict[str, str]]) -> str:
    for typedef_name, parameters in typedef_parameters.items():
        pattern = re.compile(rf"(\balias\s+{re.escape(typedef_name)}\s*=)(.*?;)", re.DOTALL)
        match = pattern.search(source)
        if not match:
            continue
        declaration = match.group(2)
        for parameter_name, callback_alias in parameters.items():
            declaration = re.sub(
                rf"\b[\w.]+\s*\*?\s+function\s*\(\s*\)\s+{re.escape(parameter_name)}\b",
                f"{callback_alias} {parameter_name}",
                declaration,
            )
        source = source[: match.start(2)] + declaration + source[match.end(2) :]
    return source


def normalize_dstep_output(source: str) -> str:
    source = re.sub(r"(?m)^eimport\b", "import", source)
    source = re.sub(r"(?m)^xtern\b", "extern", source)
    source = re.sub(
        r"\b(0x[0-9a-f]+|[0-9]+)ull\b", r"\1UL", source, flags=re.IGNORECASE
    )
    source = re.sub(
        r"\b(struct|union)\s+(?:\1\s+)?\(unnamed at [^)]*\)", r"\1", source
    )
    return source


def remove_duplicate_aliases(source: str) -> str:
    seen: dict[str, str] = {}
    output = []
    for line in source.splitlines(keepends=True):
        match = re.match(r"\s*alias\s+(\w+)\s*=\s*(.*?);\s*$", line)
        if match:
            name, value = match.groups()
            previous = seen.get(name)
            if previous is not None and previous == value:
                continue
            seen[name] = value
        output.append(line)
    return "".join(output)


def find_api_declarations(
    source: str, callback_parameters: dict[tuple[str, str], str]
) -> list[dict[str, object]]:
    code = strip_comments(source)
    declarations: list[dict[str, object]] = []
    block_stack: list[bool] = []
    segment_start = 0

    for index, char in enumerate(code):
        if char == "{":
            prefix = code[segment_start:index].strip()
            block_stack.append(bool(re.search(r"\bextern\s*\(\s*C\s*\)\s*$", prefix)))
            segment_start = index + 1
        elif char == "}":
            if block_stack:
                block_stack.pop()
            segment_start = index + 1
        elif char == ";":
            if not block_stack or all(block_stack):
                declaration = parse_api_declaration(
                    code[segment_start : index + 1],
                    segment_start,
                    index + 1,
                    callback_parameters,
                )
                if declaration:
                    declarations.append(declaration)
            segment_start = index + 1

    return declarations


def generated_loader(symbols: list[str]) -> str:
    binds = "\n".join(
        f'    bindbc.loader.sharedlib.bindSymbol(lib, cast(void**)&{name}, "{name}");'
        for name in symbols
    )
    clears = "\n".join(f"    {name} = null;" for name in symbols)
    return f"""

private bindbc.loader.sharedlib.SharedLib box3dLibrary;
private enum string[] box3dLibraryNames = mixin(makeLibPaths(["box3d"]));

private void bindModuleSymbols(bindbc.loader.sharedlib.SharedLib lib) @nogc nothrow
{{
{binds}
}}

private void unbindModuleSymbols() @nogc nothrow
{{
{clears}
}}

bool isBox3DLoaded() @nogc nothrow
{{
    return box3dLibrary != bindbc.loader.sharedlib.invalidHandle;
}}

bindbc.loader.sharedlib.LoadMsg loadBox3D() @nogc nothrow
{{
    if (isBox3DLoaded()) return bindbc.loader.sharedlib.LoadMsg.success;

    foreach (libraryName; box3dLibraryNames)
    {{
        auto result = loadBox3D(libraryName.ptr);
        if (result != bindbc.loader.sharedlib.LoadMsg.noLibrary) return result;
    }}
    return bindbc.loader.sharedlib.LoadMsg.noLibrary;
}}

bindbc.loader.sharedlib.LoadMsg loadBox3D(const(char)* libraryName) @nogc nothrow
{{
    if (isBox3DLoaded()) return bindbc.loader.sharedlib.LoadMsg.success;

    auto candidate = bindbc.loader.sharedlib.load(libraryName);
    if (candidate == bindbc.loader.sharedlib.invalidHandle)
        return bindbc.loader.sharedlib.LoadMsg.noLibrary;

    auto errorCountBeforeBinding = bindbc.loader.sharedlib.errorCount();
    bindModuleSymbols(candidate);
    if (bindbc.loader.sharedlib.errorCount() != errorCountBeforeBinding)
    {{
        unbindModuleSymbols();
        bindbc.loader.sharedlib.unload(candidate);
        return bindbc.loader.sharedlib.LoadMsg.badLibrary;
    }}

    box3dLibrary = candidate;
    return bindbc.loader.sharedlib.LoadMsg.success;
}}

void unloadBox3D() @nogc nothrow
{{
    if (isBox3DLoaded())
    {{
        bindbc.loader.sharedlib.unload(box3dLibrary);
        unbindModuleSymbols();
    }}
}}
"""


def render_header_module(
    module_name: str,
    dstep_output: str,
    imported_modules: list[str],
    owned_symbols: set[str],
    callback_parameters: dict[tuple[str, str], str],
    typedef_parameters: dict[str, dict[str, str]],
) -> tuple[str, list[str]]:
    declarations = [
        declaration
        for declaration in find_api_declarations(dstep_output, callback_parameters)
        if declaration["name"] in owned_symbols
        or declaration["name"] in UNIMPLEMENTED_API
    ]

    symbols = [
        str(declaration["name"])
        for declaration in declarations
        if declaration["name"] not in UNIMPLEMENTED_API
    ]
    if len(symbols) != len(set(symbols)):
        raise RuntimeError("DStep output contains duplicate Box3D API declarations")

    generated = dstep_output
    for declaration in reversed(declarations):
        name = str(declaration["name"])
        if name in UNIMPLEMENTED_API:
            generated = generated[: int(declaration["start"])] + generated[int(declaration["end"]):]
            continue
        function_type = str(declaration["function_type"])
        replacement = f"alias {name}Fn = {function_type};\n__gshared {name}Fn {name};\n"
        generated = generated[: int(declaration["start"])] + replacement + generated[int(declaration["end"]):]
    generated = fix_nested_callbacks(generated, typedef_parameters)

    module_match = re.search(r"(?m)^\s*module\s+[^;]+;", generated)
    imports = "\n" + "\n".join(
        f"import bindbc.box3d.{name};" for name in imported_modules
    )
    if module_match:
        generated = (
            generated[: module_match.start()]
            + f"module bindbc.box3d.{module_name};"
            + imports
            + generated[module_match.end() :]
        )
    else:
        generated = f"module bindbc.box3d.{module_name};{imports}\n\n" + generated

    return "// Generated by tools/generate_bindings.py; do not edit.\n" + generated.rstrip() + "\n", symbols


def render_package(module_names: list[str], symbols: list[str]) -> str:
    imports = "\n".join(f"public import bindbc.box3d.{name};" for name in module_names)
    loader_imports = """
import bindbc.loader.codegen : makeLibPaths;
import bindbc.loader.sharedlib;
"""
    return (
        "// Generated by tools/generate_bindings.py; do not edit.\n"
        "module bindbc.box3d;\n"
        + imports
        + "\n"
        + loader_imports
        + generated_loader(symbols)
    )


def run_dstep(executable: str, input_path: Path, output_path: Path, env: dict[str, str]):
    arguments = [str(input_path), "-o", str(output_path)]
    try:
        return subprocess.run(
            [executable, *arguments], text=True, capture_output=True, check=False, env=env
        )
    except FileNotFoundError:
        if executable != "dstep":
            raise
        dub = shutil.which("dub")
        if not dub:
            raise
        return subprocess.run(
            [dub, "run", "dstep", "--", *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )


def extract_macro_constants(
    headers: list[Path],
    dstep: str,
    temporary_path: Path,
    env: dict[str, str],
) -> list[str]:
    constants: dict[str, str] = {}
    for header in headers:
        translated = temporary_path / f"macros_{header.stem}.d"
        process = run_dstep(dstep, header, translated, env)
        if process.returncode:
            message = process.stderr.strip() or process.stdout.strip()
            raise RuntimeError(f"DStep failed to translate macros in {header.name}: {message}")

        source = normalize_dstep_output(translated.read_text(encoding="utf-8"))
        for match in re.finditer(r"(?m)^\s*enum\s+(B3_\w+)\s*=\s*([^;]+);", source):
            name, value = match.groups()
            value = value.strip().replace("UINT64_MAX", "ulong.max")
            if name in {"B3_API", "B3_BREAKPOINT"}:
                continue
            previous = constants.get(name)
            if previous is not None and previous != value:
                raise RuntimeError(f"Conflicting definitions for {name}: {previous} and {value}")
            constants[name] = value

    emitted: set[str] = set()
    result: list[str] = []
    pending = dict(constants)
    while pending:
        ready = [
            (name, value)
            for name, value in pending.items()
            if "(" not in value
            and set(re.findall(r"\bB3_\w+\b", value)) <= emitted
        ]
        if not ready:
            break
        for name, value in ready:
            result.append(f"enum {name} = {value};")
            emitted.add(name)
            del pending[name]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--submodule", type=Path, default=Path("box3d"))
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--clang", default="clang", help="Clang executable")
    parser.add_argument("--dstep", default="dstep", help="DStep executable")
    parser.add_argument(
        "--double-precision",
        action="store_true",
        help="generate the BOX3D_DOUBLE_PRECISION ABI",
    )
    parser.add_argument(
        "--check", action="store_true", help="fail if generated output is out of date"
    )
    args = parser.parse_args()

    root = args.root.resolve()
    submodule = (root / args.submodule).resolve()
    header_paths = [submodule / "include" / "box3d" / name for name in HEADERS]
    missing_headers = [path for path in header_paths if not path.is_file()]
    if missing_headers:
        print(
            f"Box3D public header not found: {missing_headers[0]}\nInitialize the box3d Git submodule first.",
            file=sys.stderr,
        )
        return 2

    callback_parameters = callback_parameter_aliases(header_paths)
    typedef_parameters = callback_typedef_parameters(header_paths)
    output_path = (root / args.output).resolve()
    try:
        output_path.relative_to(submodule)
    except ValueError:
        pass
    else:
        print(
            f"Refusing to generate bindings inside the box3d submodule: {output_path}",
            file=sys.stderr,
        )
        return 2

    process_env = os.environ.copy()
    clang_executable = shutil.which(args.clang)
    if clang_executable:
        clang_directory = str(Path(clang_executable).resolve().parent)
        process_env["PATH"] = clang_directory + os.pathsep + process_env.get("PATH", "")

    with tempfile.TemporaryDirectory(prefix="bindbc-box3d-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        preprocessed = temporary_path / "box3d.h"
        translated = temporary_path / "box3d.d"
        clang_command = [
            args.clang,
            "-E",
            "-P",
            "-x",
            "c",
            "-DNDEBUG",
            f"-I{submodule / 'include'}",
        ]
        if args.double_precision:
            clang_command.append("-DBOX3D_DOUBLE_PRECISION")
        clang_command.extend([str(header_paths[-1]), "-o", str(preprocessed)])
        try:
            process = subprocess.run(
                clang_command,
                text=True,
                capture_output=True,
                check=False,
                env=process_env,
            )
        except FileNotFoundError:
            print("Clang was not found. Install LLVM/Clang or pass --clang PATH.", file=sys.stderr)
            return 2
        if process.returncode:
            if process.stdout:
                print(process.stdout, file=sys.stderr, end="")
            if process.stderr:
                print(process.stderr, file=sys.stderr, end="")
            return process.returncode

        try:
            process = run_dstep(args.dstep, preprocessed, translated, process_env)
        except FileNotFoundError:
            print(
                "DStep was not found. Install it with `dub run dstep` or pass --dstep PATH.",
                file=sys.stderr,
            )
            return 2
        if process.returncode:
            if process.stdout:
                print(process.stdout, file=sys.stderr, end="")
            if process.stderr:
                print(process.stderr, file=sys.stderr, end="")
            return process.returncode
        if not translated.is_file():
            print("DStep completed without creating its requested output file.", file=sys.stderr)
            return 2

        all_symbols = set()
        for header in header_paths:
            all_symbols.update(api_names_in_header(header, args.double_precision))
        all_symbols.difference_update(UNIMPLEMENTED_API)
        try:
            macro_constants = extract_macro_constants(
                [submodule / "include" / "box3d" / name for name in (
                    "base.h",
                    "math_functions.h",
                    "constants.h",
                    "types.h",
                )],
                args.dstep,
                temporary_path,
                process_env,
            )
            translated_source = remove_duplicate_aliases(
                normalize_dstep_output(translated.read_text(encoding="utf-8"))
            )
            module_source, symbols = render_header_module(
                "package",
                translated_source,
                [],
                all_symbols,
                callback_parameters,
                typedef_parameters,
            )
        except RuntimeError as error:
            print(f"Binding generation failed: {error}", file=sys.stderr)
            return 2

        module_source = module_source.replace(
            "module bindbc.box3d.package;",
            "module bindbc.box3d;\n\nimport bindbc.loader.codegen : makeLibPaths;\nimport bindbc.loader.sharedlib;",
            1,
        )
        macro_block = "\n".join(macro_constants)
        module_source = module_source.replace(
            "extern (C):", f"{macro_block}\n\nextern (C):", 1
        )
        output = module_source.rstrip() + "\n\nextern(D):\n" + generated_loader(symbols)

    generated_files = {output_path: output}

    if args.check:
        stale = [
            path
            for path, content in generated_files.items()
            if not path.is_file() or path.read_text(encoding="utf-8") != content
        ]
        if stale:
            print(f"Generated bindings are out of date: {stale[0]}", file=sys.stderr)
            return 1
        print(f"Bindings are up to date ({len(symbols)} API bindings).")
        return 0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(output.encode("utf-8"))
    stale_module_names = {Path(name).stem + ".d" for name in HEADERS}
    for stale_path in output_path.parent.iterdir():
        if stale_path.name in stale_module_names and stale_path.is_file():
            if stale_path.read_text(encoding="utf-8").startswith(
                "// Generated by tools/generate_bindings.py; do not edit."
            ):
                stale_path.unlink()
    print(f"Generated {len(symbols)} API bindings: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())