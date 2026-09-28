#!/usr/bin/env rdmd
module tools.generate_bindings;

import std.array : Appender, appender, array, join;
import std.file : dirEntries, exists, mkdirRecurse, readText, rmdirRecurse, SpanMode, write;
import std.path : absolutePath, baseName, buildPath, dirName, extension, relativePath, stripExtension;
import std.process : execute;
import std.stdio : stderr, writeln;
import std.string : chomp, endsWith, indexOf, lastIndexOf, replace, split, splitLines, startsWith, strip, toStringz;

struct ApiDeclaration
{
	string name;
	string functionType;
	size_t start;
	size_t end;
}

enum headerNames = ["base.h", "collision.h", "constants.h", "id.h", "math_functions.h", "types.h", "box3d.h"];
enum unimplementedApi = "b3World_DumpShapeBounds";

int main(string[] args)
{
	auto root = absolutePath(".");
	auto submodule = buildPath(root, "box3d");
	auto outputPath = buildPath(root, "source", "bindbc", "box3d", "package.d");
	string clang = "clang";
	string dstep = "dstep";
	string cmake = "cmake";
	string generator;
	string config = "Release";
	string osxArch;
	auto buildDir = buildPath(root, "build", "box3d-shared");
	bool doublePrecision;
	bool check;

	for (size_t i = 1; i < args.length; ++i)
	{
		switch (args[i])
		{
		case "--root":
			if (++i == args.length) return usageError("--root requires a path");
			root = absolutePath(args[i]);
			submodule = buildPath(root, "box3d");
			outputPath = buildPath(root, "source", "bindbc", "box3d", "package.d");
			buildDir = buildPath(root, "build", "box3d-shared");
			break;
		case "--submodule":
			if (++i == args.length) return usageError("--submodule requires a path");
			submodule = absolutePath(buildPath(root, args[i]));
			break;
		case "--output":
			if (++i == args.length) return usageError("--output requires a path");
			outputPath = absolutePath(buildPath(root, args[i]));
			break;
		case "--clang":
			if (++i == args.length) return usageError("--clang requires an executable");
			clang = args[i];
			break;
		case "--dstep":
			if (++i == args.length) return usageError("--dstep requires an executable");
			dstep = args[i];
			break;
		case "--build-dir":
			if (++i == args.length) return usageError("--build-dir requires a path");
			buildDir = absolutePath(buildPath(root, args[i]));
			break;
		case "--cmake":
			if (++i == args.length) return usageError("--cmake requires an executable");
			cmake = args[i];
			break;
		case "--generator":
			if (++i == args.length) return usageError("--generator requires a name");
			generator = args[i];
			break;
		case "--config":
			if (++i == args.length) return usageError("--config requires a configuration");
			config = args[i];
			break;
		case "--osx-arch":
			if (++i == args.length) return usageError("--osx-arch requires an architecture");
			osxArch = args[i];
			break;
		case "--double-precision":
			doublePrecision = true;
			break;
		case "--check":
			check = true;
			break;
		case "--help":
		case "-h":
			printUsage();
			return 0;
		default:
		{
			auto message = appender!string;
			message.put("Unknown option: ");
			message.put(args[i]);
			return usageError(message.data);
		}
		}
	}

	if (!exists(buildPath(submodule, "include", "box3d", "box3d.h")))
	{
		stderr.writeln("Box3D public headers not found under ", submodule, ". Initialize the Git submodule first.");
		return 2;
	}
	if (insideDirectory(outputPath, submodule))
	{
		stderr.writeln("Refusing to generate bindings inside the box3d submodule: ", outputPath);
		return 2;
	}
	if (insideDirectory(buildDir, submodule))
	{
		stderr.writeln("Refusing to create build output inside the box3d submodule: ", buildDir);
		return 2;
	}
	version (Windows)
	{
		if (!generator.length) generator = "NMake Makefiles";
	}
	version (OSX)
	{
	}
	else
	{
		if (osxArch.length)
		{
			stderr.writeln("--osx-arch can only be used on macOS.");
			return 2;
		}
	}
	if (buildBox3dShared(cmake, generator, config, osxArch, submodule, buildDir) != 0)
		return 2;

	string[] headers;
	foreach (header; headerNames)
		headers ~= buildPath(submodule, "include", "box3d", header);

	auto callbackAliases = callbackParameterAliases(headers);
	auto nestedCallbackAliases = callbackTypedefParameters(headers);
	auto tempDir = buildPath(root, "build", "bindbc-box3d-codegen-tmp");
	if (exists(tempDir))
		rmdirRecurse(tempDir);
	import std.file : mkdirRecurse;
	mkdirRecurse(tempDir);

	// A stub math.h shadows the platform's real one so parsing never pulls in unrelated CRT
	// declarations (e.g. MinGW's locale internals); only sqrtf/remainderf are actually used.
	auto stubIncludeDir = buildPath(tempDir, "compat_include");
	mkdirRecurse(stubIncludeDir);
	write(buildPath(stubIncludeDir, "math.h"), "#pragma once\nfloat sqrtf(float);\nfloat remainderf(float, float);\n");
	string[] extraClangArgs = ["-I" ~ stubIncludeDir];

	// DStep's bundled libclang doesn't reliably auto-detect its resource directory, so tell it
	// explicitly where Clang's own freestanding headers (stdint.h, stddef.h, ...) live.
	auto resourceDirResult = execute([clang, "-print-resource-dir"]);
	if (resourceDirResult.status == 0)
		extraClangArgs ~= "-resource-dir=" ~ strip(resourceDirResult.output);

	auto preprocessed = buildPath(tempDir, "box3d.h");
	auto translated = buildPath(tempDir, "box3d.d");
	auto includeArgument = appender!string;
	includeArgument.put("-I");
	includeArgument.put(buildPath(submodule, "include"));
	string[] clangArgs = [clang, "-E", "-P", "-x", "c", "-DNDEBUG", includeArgument.data];
	if (doublePrecision)
		clangArgs ~= "-DBOX3D_DOUBLE_PRECISION";
	clangArgs ~= extraClangArgs;
	clangArgs ~= [headers[$ - 1], "-o", preprocessed];
	auto result = execute(clangArgs);
	if (result.status != 0)
		return reportProcessError("Clang", result);

	result = runDstep(dstep, preprocessed, translated, extraClangArgs);
	if (result.status != 0)
		return reportProcessError("DStep", result);

	string[string] owned;
	foreach (header; headers)
	{
		auto headerText = stripComments(readText(header));
		foreach (declaration; cApiDeclarations(headerText))
		{
			auto symbol = declaration.name;
			if (doublePrecision && symbol == "b3CreateWorld")
				symbol = "b3CreateWorldDoublePrecision";
			owned[symbol] = symbol;
		}
	}
	owned.remove(unimplementedApi);

	auto dstepOutput = removeDuplicateAliases(normalizeDstepOutput(readText(translated)));
	auto declarations = findApiDeclarations(dstepOutput, callbackAliases, owned);
	if (declarations.length == 0)
	{
		stderr.writeln("DStep output did not contain Box3D API declarations.");
		return 2;
	}

	string[] symbols;
	foreach (declaration; declarations)
		if (declaration.name != unimplementedApi)
			symbols ~= declaration.name;
	auto generated = dstepOutput;
	foreach_reverse (declaration; declarations)
	{
		if (declaration.name == unimplementedApi)
		{
			auto output = appender!string;
			output.put(generated[0 .. declaration.start]);
			output.put(generated[declaration.end .. $]);
			generated = output.data;
			continue;
		}
		auto replacement = appender!string;
		replacement.put("alias ");
		replacement.put(declaration.name);
		replacement.put("Fn = ");
		replacement.put(declaration.functionType);
		replacement.put(";\n__gshared ");
		replacement.put(declaration.name);
		replacement.put("Fn ");
		replacement.put(declaration.name);
		replacement.put(";\n");
		auto output = appender!string;
		output.put(generated[0 .. declaration.start]);
		output.put(replacement.data);
		output.put(generated[declaration.end .. $]);
		generated = output.data;
	}
	generated = fixNestedCallbacks(generated, nestedCallbackAliases);
	auto moduleOutput = appender!string;
	moduleOutput.put("// Generated by tools/generate_bindings.d; do not edit.\n");
	moduleOutput.put("module bindbc.box3d;\n\n");
	moduleOutput.put("import bindbc.loader.codegen : makeLibPaths;\n");
	moduleOutput.put("import bindbc.loader.sharedlib;\n\n\n");
	moduleOutput.put(generated);
	generated = moduleOutput.data;

	string[] macroHeaders = [headers[0], headers[4], headers[2], headers[5]];
	string macroText = extractMacroConstants(macroHeaders, dstep, tempDir, extraClangArgs);
	auto externIndex = generated.indexOf("extern (C):");
	if (externIndex < 0)
	{
		stderr.writeln("DStep output is missing its extern (C) declaration block.");
		return 2;
	}
	auto externOutput = appender!string;
	externOutput.put(generated[0 .. externIndex]);
	externOutput.put(macroText);
	externOutput.put("\nextern (C):");
	externOutput.put(generated[externIndex + "extern (C):".length .. $]);
	externOutput.put("\n\nextern(D):\n");
	externOutput.put(generatedLoader(symbols));
	generated = externOutput.data;

	if (check)
	{
		if (!exists(outputPath) || readText(outputPath) != generated)
		{
			stderr.writeln("Generated bindings are out of date: ", outputPath);
			return 1;
		}
		writeln("Bindings are up to date (", symbols.length, " API bindings).");
		return 0;
	}

	import std.file : write;
	import std.path : dirName;
	mkdirRecurse(dirName(outputPath));
	write(outputPath, generated);
	writeln("Generated ", symbols.length, " API bindings: ", outputPath);
	return 0;
}

struct CFunction
{
	string name;
	string args;
}

struct DFunction
{
	string name;
	string functionType;
	size_t start;
	size_t end;
}

string stripComments(string source)
{
	auto chars = source.dup;
	bool lineComment;
	bool blockComment;
	for (size_t i = 0; i < chars.length; ++i)
	{
		if (lineComment)
		{
			if (chars[i] == '\n') lineComment = false;
			else chars[i] = ' ';
		}
		else if (blockComment)
		{
			if (chars[i] == '*' && i + 1 < chars.length && chars[i + 1] == '/')
			{
				chars[i++] = ' ';
				chars[i] = ' ';
				blockComment = false;
			}
			else if (chars[i] != '\n') chars[i] = ' ';
		}
		else if (chars[i] == '/' && i + 1 < chars.length && chars[i + 1] == '/')
		{
			chars[i++] = ' ';
			chars[i] = ' ';
			lineComment = true;
		}
		else if (chars[i] == '/' && i + 1 < chars.length && chars[i + 1] == '*')
		{
			chars[i++] = ' ';
			chars[i] = ' ';
			blockComment = true;
		}
	}
	return cast(string) chars;
}

string[] splitParameters(string parameters)
{
	parameters = strip(parameters);
	if (parameters.length == 0 || parameters == "void") return [];
	string[] parts;
	size_t start;
	int depth;
	foreach (i, c; parameters)
	{
		if (c == '(' || c == '[' || c == '<') ++depth;
		else if ((c == ')' || c == ']' || c == '>') && depth > 0) --depth;
		else if (c == ',' && depth == 0)
		{
			parts ~= strip(parameters[start .. i]);
			start = i + 1;
		}
	}
	parts ~= strip(parameters[start .. $]);
	return parts;
}

string trailingIdentifier(string text)
{
	auto end = text.length;
	while (end && isSpace(text[end - 1])) --end;
	auto start = end;
	while (start && isIdentifierPart(text[start - 1])) --start;
	if (start == end || !isIdentifierStart(text[start])) return "";
	return text[start .. end];
}

string parameterType(string parameter)
{
	auto name = trailingIdentifier(parameter);
	if (!name.length) return strip(parameter);
	auto start = parameter.length - name.length;
	if (!start || !isSpace(parameter[start - 1])) return strip(parameter);
	return strip(parameter[0 .. start]);
}

bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
bool isIdentifierStart(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
bool isIdentifierPart(char c) { return isIdentifierStart(c) || (c >= '0' && c <= '9'); }

size_t findMatchingParen(string text, size_t open)
{
	int depth;
	for (size_t i = open; i < text.length; ++i)
	{
		if (text[i] == '(') ++depth;
		else if (text[i] == ')' && --depth == 0) return i;
	}
	return size_t.max;
}

CFunction parseCFunction(string statement)
{
	for (size_t i = 0; i + 2 < statement.length; ++i)
	{
		if (statement[i .. i + 2] != "b3" || (i && isIdentifierPart(statement[i - 1]))) continue;
		size_t end = i + 2;
		while (end < statement.length && isIdentifierPart(statement[end])) ++end;
		size_t open = end;
		while (open < statement.length && isSpace(statement[open])) ++open;
		if (open == statement.length || statement[open] != '(') continue;
		auto close = findMatchingParen(statement, open);
		if (close == size_t.max) continue;
		return CFunction(statement[i .. end], statement[open + 1 .. close]);
	}
	return CFunction.init;
}

CFunction[] cApiDeclarations(string source)
{
	source = stripComments(source);
	CFunction[] declarations;
	size_t start;
	foreach (i, c; source)
	{
		if (c != ';') continue;
		auto statement = source[start .. i];
		start = i + 1;
		auto api = statement.indexOf("B3_API");
		if (api < 0) continue;
		auto parsedFunction = parseCFunction(statement[api + 6 .. $]);
		if (parsedFunction.name.length) declarations ~= parsedFunction;
	}
	return declarations;
}

string[string] callbackParameterAliases(string[] headers)
{
	string[string] aliases;
	foreach (header; headers)
	{
		auto source = readText(header);
		foreach (apiFunction; cApiDeclarations(source))
		{
			foreach (parameter; splitParameters(apiFunction.args))
			{
				auto name = trailingIdentifier(parameter);
				if (name.length && parameter.indexOf('*') >= 0 && parameter.indexOf("b3") >= 0)
				{
					auto typeName = parseCFunctionTypeName(parameter);
					if (typeName.length)
					{
						auto key = appender!string;
						key.put(apiFunction.name);
						key.put('\0');
						key.put(name);
						aliases[key.data] = typeName;
					}
				}
			}
		}
	}
	return aliases;
}

string parseCFunctionTypeName(string parameter)
{
	for (size_t i = 0; i + 2 < parameter.length; ++i)
	{
		if (parameter[i .. i + 2] != "b3" || (i && isIdentifierPart(parameter[i - 1]))) continue;
		size_t end = i + 2;
		while (end < parameter.length && isIdentifierPart(parameter[end])) ++end;
		auto name = parameter[i .. end];
		if (name.endsWith("Fcn") || name.endsWith("Callback")) return name;
	}
	return "";
}

string[string][string] callbackTypedefParameters(string[] headers)
{
	string[string][string] aliases;
	foreach (header; headers)
	{
		auto source = stripComments(readText(header));
		size_t start;
		foreach (i, c; source)
		{
			if (c != ';') continue;
			auto statement = strip(source[start .. i]);
			start = i + 1;
			if (!statement.startsWith("typedef")) continue;
			auto typedefFunction = parseCFunction(statement[7 .. $]);
			if (!typedefFunction.name.length) continue;
			foreach (parameter; splitParameters(typedefFunction.args))
			{
				auto name = trailingIdentifier(parameter);
				auto typeName = parseCFunctionTypeName(parameter);
				if (name.length && typeName.length && parameter.indexOf('*') >= 0)
					aliases[typedefFunction.name][name] = typeName;
			}
		}
	}
	return aliases;
}

DFunction[] findApiDeclarations(string source, string[string] callbackAliases, string[string] owned)
{
	auto code = stripComments(source);
	DFunction[] declarations;
	size_t segmentStart;
	bool[] blocks;
	foreach (i, c; code)
	{
		if (c == '{')
		{
			auto prefix = strip(code[segmentStart .. i]);
			blocks ~= prefix.endsWith("extern (C)") || prefix.endsWith("extern(C)");
			segmentStart = i + 1;
		}
		else if (c == '}')
		{
			if (blocks.length) blocks = blocks[0 .. $ - 1];
			segmentStart = i + 1;
		}
		else if (c == ';')
		{
			if (!blocks.length || allTrue(blocks))
			{
				auto statement = strip(code[segmentStart .. i + 1]);
				auto parsedFunction = parseCFunction(statement);
				if (parsedFunction.name.length && (parsedFunction.name in owned || parsedFunction.name == unimplementedApi))
				{
					auto functionStart = findFunctionNameStart(statement, parsedFunction.name);
					if (functionStart != size_t.max)
					{
						auto open = statement.indexOf('(', functionStart);
						auto close = findMatchingParen(statement, open);
						if (close != size_t.max)
						{
							auto returnType = strip(statement[0 .. functionStart]);
							if (returnType.startsWith("extern"))
							{
								auto colon = returnType.lastIndexOf(':');
								if (colon >= 0) returnType = strip(returnType[colon + 1 .. $]);
							}
							if (returnType.length && returnType.indexOf('=') < 0 && returnType.indexOf('{') < 0)
							{
								string[] parameters;
								foreach (parameter; splitParameters(statement[open + 1 .. close]))
								{
									auto argumentName = trailingIdentifier(parameter);
									auto keyBuilder = appender!string;
									keyBuilder.put(parsedFunction.name);
									keyBuilder.put('\0');
									keyBuilder.put(argumentName);
									auto key = keyBuilder.data;
									if (auto callbackType = key in callbackAliases)
										parameters ~= *callbackType;
									else parameters ~= parameterType(parameter);
								}
								auto functionType = appender!string;
								functionType.put("extern(C) ");
								functionType.put(returnType);
								functionType.put(" function(");
								functionType.put(join(parameters, ", "));
								functionType.put(')');
								declarations ~= DFunction(parsedFunction.name, functionType.data, segmentStart, i + 1);
							}
						}
					}
				}
			}
			segmentStart = i + 1;
		}
	}
	return declarations;
}

size_t findFunctionNameStart(string statement, string name)
{
	foreach (i; 0 .. statement.length)
	{
		auto end = i + name.length;
		if (end <= statement.length && statement[i .. end] == name &&
			(i == 0 || !isIdentifierPart(statement[i - 1])) &&
			(end == statement.length || !isIdentifierPart(statement[end])))
			return i;
	}
	return size_t.max;
}

bool allTrue(bool[] values)
{
	foreach (value; values) if (!value) return false;
	return true;
}

string fixNestedCallbacks(string source, string[string][string] aliases)
{
	foreach (typedefName, parameters; aliases)
	{
		auto markerBuilder = appender!string;
		markerBuilder.put("alias ");
		markerBuilder.put(typedefName);
		markerBuilder.put(" =");
		auto marker = markerBuilder.data;
		auto aliasStart = source.indexOf(marker);
		if (aliasStart < 0) continue;
		auto end = source.indexOf(';', aliasStart);
		if (end < 0) continue;
		auto declaration = source[aliasStart .. end + 1];
		foreach (parameterName, callbackType; parameters)
		{
			auto searchBuilder = appender!string;
			searchBuilder.put("function () ");
			searchBuilder.put(parameterName);
			auto search = searchBuilder.data;
			auto found = declaration.indexOf(search);
			if (found < 0) continue;
			auto argStart = declaration.lastIndexOf('(', found);
			auto comma = declaration.lastIndexOf(',', found);
			if (comma > argStart) argStart = comma;
			++argStart;
			while (argStart < found && isSpace(declaration[argStart])) ++argStart;
			auto replacement = appender!string;
			replacement.put(declaration[0 .. argStart]);
			replacement.put(callbackType);
			replacement.put(' ');
			replacement.put(parameterName);
			replacement.put(declaration[found + search.length .. $]);
			declaration = replacement.data;
		}
		auto replacement = appender!string;
		replacement.put(source[0 .. aliasStart]);
		replacement.put(declaration);
		replacement.put(source[end + 1 .. $]);
		source = replacement.data;
	}
	return source;
}

string normalizeDstepOutput(string source)
{
	source = replaceAll(source, "(?m)^eimport\\b", "import");
	source = replaceAll(source, "(?m)^xtern\\b", "extern");
	source = replaceAll(source, "(?i)\\b(0x[0-9a-f]+|[0-9]+)ull\\b", "$1UL");
	source = replaceAll(source, "\\b(struct|union)\\s+(?:\\1\\s+)?\\(unnamed at [^)]*\\)", "$1");
	return source;
}

string replaceAll(string source, string pattern, string replacement)
{
	import std.regex : regex, regexReplaceAll = replaceAll;
	return regexReplaceAll(source, regex(pattern), replacement);
}

string removeDuplicateAliases(string source)
{
	string[string] previous;
	auto output = appender!string;
	foreach (line; source.splitLines())
	{
		auto text = strip(line);
		if (text.startsWith("alias "))
		{
			auto equal = text.indexOf('=');
			auto semi = text.lastIndexOf(';');
			if (equal > 6 && semi > equal)
			{
				auto name = strip(text[6 .. equal]);
				auto value = strip(text[equal + 1 .. semi]);
				if (auto found = name in previous)
				{
					if (*found == value) continue;
				}
				previous[name] = value;
			}
		}
		output.put(line);
		output.put('\n');
	}
	return output.data;
}

string extractMacroConstants(string[] headers, string dstep, string tempDir, string[] extraClangArgs = [])
{
	string[string] constants;
	string[] constantOrder;
	foreach (header; headers)
	{
		auto fileName = appender!string;
		fileName.put("macro_");
		fileName.put(stripExtension(baseName(header)));
		fileName.put(".d");
		auto translated = buildPath(tempDir, fileName.data);
		auto result = runDstep(dstep, header, translated, extraClangArgs);
		if (result.status != 0)
		{
			auto message = appender!string;
			message.put("DStep failed for ");
			message.put(header);
			message.put(": ");
			message.put(result.output);
			throw new Exception(message.data);
		}
		foreach (line; normalizeDstepOutput(readText(translated)).splitLines())
		{
			auto text = strip(line);
			if (!text.startsWith("enum B3_")) continue;
			auto equal = text.indexOf('=');
			auto semi = text.lastIndexOf(';');
			if (equal < 0 || semi < equal) continue;
			auto name = strip(text[5 .. equal]);
			auto value = strip(text[equal + 1 .. semi]);
			value = value.replace("UINT64_MAX", "ulong.max");
			if (name == "B3_API" || name == "B3_BREAKPOINT") continue;
			if (name !in constants)
				constantOrder ~= name;
			constants[name] = value;
		}
	}
	auto result = appender!string;
	string[string] emitted;
	while (constants.length)
	{
		string[] ready;
		foreach (name; constantOrder)
		{
			if (name !in constants) continue;
			auto value = constants[name];
			if (value.indexOf('(') >= 0) continue;
			auto dependenciesReady = macroDependenciesReady(value, emitted);
			if (dependenciesReady) ready ~= name;
		}
		if (!ready.length) break;
		foreach (name; ready)
		{
			result.put("enum ");
			result.put(name);
			result.put(" = ");
			result.put(constants[name]);
			result.put(";\n");
			emitted[name] = name;
			constants.remove(name);
		}
	}
	return result.data;
}

bool macroDependenciesReady(string value, string[string] emitted)
{
	size_t searchStart;
	while (searchStart < value.length)
	{
		auto marker = value.indexOf("B3_", searchStart);
		if (marker < 0) break;
		auto start = marker + 3;
		auto end = start;
		while (end < value.length && isIdentifierPart(value[end])) ++end;
		if (end == start) return false;
		auto dependency = appender!string;
		dependency.put("B3_");
		dependency.put(value[start .. end]);
		if (dependency.data !in emitted) return false;
		searchStart = end;
	}
	return true;
}

string generatedLoader(string[] symbols)
{
	auto binds = appender!string;
	auto clears = appender!string;
	foreach (symbol; symbols)
	{
		binds.put("    bindbc.loader.sharedlib.bindSymbol(lib, cast(void**)&");
		binds.put(symbol);
		binds.put(", \"");
		binds.put(symbol);
		binds.put("\");\n");
		clears.put("    ");
		clears.put(symbol);
		clears.put(" = null;\n");
	}
	return `

private bindbc.loader.sharedlib.SharedLib box3dLibrary;
private enum string[] box3dLibraryNames = mixin(makeLibPaths(["box3d"]));

private void bindModuleSymbols(bindbc.loader.sharedlib.SharedLib lib) @nogc nothrow
{
{binds}}

private void unbindModuleSymbols() @nogc nothrow
{
{clears}}

bool isBox3DLoaded() @nogc nothrow
{
	return box3dLibrary != bindbc.loader.sharedlib.invalidHandle;
}

bindbc.loader.sharedlib.LoadMsg loadBox3D() @nogc nothrow
{
	if (isBox3DLoaded()) return bindbc.loader.sharedlib.LoadMsg.success;

	foreach (libraryName; box3dLibraryNames)
	{
		auto result = loadBox3D(libraryName.ptr);
		if (result != bindbc.loader.sharedlib.LoadMsg.noLibrary) return result;
	}
	return bindbc.loader.sharedlib.LoadMsg.noLibrary;
}

bindbc.loader.sharedlib.LoadMsg loadBox3D(const(char)* libraryName) @nogc nothrow
{
	if (isBox3DLoaded()) return bindbc.loader.sharedlib.LoadMsg.success;

	auto candidate = bindbc.loader.sharedlib.load(libraryName);
	if (candidate == bindbc.loader.sharedlib.invalidHandle)
		return bindbc.loader.sharedlib.LoadMsg.noLibrary;

	auto errorCountBeforeBinding = bindbc.loader.sharedlib.errorCount();
	bindModuleSymbols(candidate);
	if (bindbc.loader.sharedlib.errorCount() != errorCountBeforeBinding)
	{
		unbindModuleSymbols();
		bindbc.loader.sharedlib.unload(candidate);
		return bindbc.loader.sharedlib.LoadMsg.badLibrary;
	}

	box3dLibrary = candidate;
	return bindbc.loader.sharedlib.LoadMsg.success;
}

void unloadBox3D() @nogc nothrow
{
	if (isBox3DLoaded())
	{
		bindbc.loader.sharedlib.unload(box3dLibrary);
		unbindModuleSymbols();
	}
}
`.replace("{binds}", binds.data).replace("{clears}", clears.data);
}

auto runDstep(string executable, string input, string output, string[] extraClangArgs = [])
{
	auto args = [executable, input, "-o", output];
	if (extraClangArgs.length)
		args ~= "--" ~ extraClangArgs;
	try return execute(args);
	catch (Exception error)
	{
		if (executable != "dstep") throw error;
		auto dubArgs = ["dub", "run", "dstep", "--", input, "-o", output];
		if (extraClangArgs.length)
			dubArgs ~= "--" ~ extraClangArgs;
		return execute(dubArgs);
	}
}

int reportProcessError(Result)(string tool, Result result)
{
	stderr.writeln(tool, " failed (", result.status, ").");
	if (result.output.length) stderr.write(result.output);
	return result.status;
}

bool insideDirectory(string path, string parent)
{
	auto relative = relativePath(path, parent);
	return relative == "." || (!relative.startsWith("..") && relative != path);
}

int usageError(string message)
{
	stderr.writeln(message);
	printUsage();
	return 2;
}

void printUsage()
{
	writeln("Usage: rdmd tools/generate_bindings.d [options]");
	writeln("  Builds box3d as a shared library, then generates/checks BindBC bindings.");
	writeln("  --root PATH              Repository root");
	writeln("  --submodule PATH         Box3D submodule directory");
	writeln("  --build-dir PATH         CMake build directory (outside submodule)");
	writeln("  --output PATH            Generated BindBC module path");
	writeln("  --generator NAME         CMake generator (Windows defaults to NMake/MSVC)");
	writeln("  --config NAME            CMake configuration (default Release)");
	writeln("  --osx-arch ARCH          Apple architecture, e.g. arm64 or universal");
	writeln("  --cmake PATH             CMake executable");
	writeln("  --clang PATH             Clang executable for header preprocessing");
	writeln("  --dstep PATH             DStep executable");
	writeln("  --double-precision       Generate the double-precision ABI");
	writeln("  --check                  Compare generated bindings without writing them");
}

int buildBox3dShared(string cmake, string generator, string config, string osxArch, string submodule,
	string buildDir)
{
	string[] configure = [cmake, "-S", submodule, "-B", buildDir,
		buildSetting("CMAKE_BUILD_TYPE", config),
		"-DBUILD_SHARED_LIBS=ON",
		"-DBOX3D_SAMPLES=OFF",
		"-DBOX3D_BENCHMARKS=OFF",
		"-DBOX3D_UNIT_TESTS=OFF",
		"-DBOX3D_DOCS=OFF"];
	if (generator.length) configure ~= ["-G", generator];
	if (osxArch.length) configure ~= buildSetting("CMAKE_OSX_ARCHITECTURES", osxArch);

	auto result = execute(configure);
	if (result.status != 0) return reportProcessError("CMake configure", result);
	result = execute([cmake, "--build", buildDir, "--config", config, "--target", "box3d"]);
	if (result.status != 0) return reportProcessError("CMake build", result);

	string[] libraryNames;
	// MinGW toolchains (used as a fallback when MSVC is unavailable) keep the "lib" prefix.
	version (Windows) libraryNames = ["box3d.dll", "libbox3d.dll"];
	else version (OSX) libraryNames = ["libbox3d.dylib"];
	else libraryNames = ["libbox3d.so"];
	string[] libraries;
	foreach (entry; dirEntries(buildDir, SpanMode.depth))
	{
		auto fileName = baseName(entry.name);
		foreach (libraryName; libraryNames)
		{
			if (fileName == libraryName)
				libraries ~= entry.name;
			else if (libraryName == "libbox3d.so")
			{
				auto versionedNamePrefix = appender!string;
				versionedNamePrefix.put(libraryName);
				versionedNamePrefix.put('.');
				if (startsWith(fileName, versionedNamePrefix.data)) libraries ~= entry.name;
			}
		}
	}
	if (!libraries.length)
	{
		stderr.writeln("CMake succeeded but no Box3D shared library was found under ", buildDir, ".");
		return 2;
	}
	writeln("Built Box3D shared library:");
	foreach (library; libraries) writeln("  ", library);
	return 0;
}

string buildSetting(string name, string value)
{
	auto setting = appender!string;
	setting.put("-D");
	setting.put(name);
	setting.put('=');
	setting.put(value);
	return setting.data;
}

unittest
{
	auto declarations = cApiDeclarations(
		"B3_API b3SegmentDistanceResult b3SegmentDistance( b3Vec3 p1, b3Vec3 q1, b3Vec3 p2, b3Vec3 q2 );");
	assert(declarations.length == 1);
	assert(declarations[0].name == "b3SegmentDistance");
	bool foundSegmentDistance;
	foreach (declaration; cApiDeclarations(readText("box3d/include/box3d/math_functions.h")))
		if (declaration.name == "b3SegmentDistance") foundSegmentDistance = true;
	assert(foundSegmentDistance);
	string[string] owned;
	owned["b3SegmentDistance"] = "b3SegmentDistance";
	auto translated = findApiDeclarations(
		"extern (C):\n\nb3SegmentDistanceResult b3SegmentDistance (b3Vec3 p1, b3Vec3 q1, b3Vec3 p2, b3Vec3 q2);",
		null,
		owned);
	assert(translated.length == 1);
	assert(translated[0].name == "b3SegmentDistance");
	assert(macroDependenciesReady("ulong.max", null));
	string[string] emitted;
	assert(!macroDependenciesReady("B3_LINEAR_SLOP", emitted));
	emitted["B3_LINEAR_SLOP"] = "B3_LINEAR_SLOP";
	assert(macroDependenciesReady("0.1f * B3_LINEAR_SLOP", emitted));
}