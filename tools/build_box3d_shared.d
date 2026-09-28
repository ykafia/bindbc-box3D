#!/usr/bin/env rdmd
module tools.build_box3d_shared;

import std.file : dirEntries, exists, mkdirRecurse, SpanMode;
import std.path : absolutePath, baseName, buildPath, relativePath;
import std.process : execute;
import std.stdio : stderr, writeln;
import std.string : startsWith;

int main(string[] args)
{
	auto root = absolutePath(".");
	auto submodule = buildPath(root, "box3d");
	auto buildDir = buildPath(root, "build", "box3d-shared");
	string cmake = "cmake";
	string generator;
	string config = "Release";
	string osxArch;

	for (size_t i = 1; i < args.length; ++i)
	{
		switch (args[i])
		{
		case "--root":
			if (++i == args.length) return usageError("--root requires a path");
			root = absolutePath(args[i]);
			submodule = buildPath(root, "box3d");
			buildDir = buildPath(root, "build", "box3d-shared");
			break;
		case "--submodule":
			if (++i == args.length) return usageError("--submodule requires a path");
			submodule = absolutePath(buildPath(root, args[i]));
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
			if (++i == args.length) return usageError("--config requires a name");
			config = args[i];
			break;
		case "--osx-arch":
			if (++i == args.length) return usageError("--osx-arch requires an architecture");
			osxArch = args[i];
			break;
		case "--help":
		case "-h":
			printUsage();
			return 0;
		default:
			return usageError("Unknown option: " ~ args[i]);
		}
	}

	if (!exists(buildPath(submodule, "CMakeLists.txt")))
	{
		stderr.writeln("Box3D CMake project not found: ", submodule,
			"\nInitialize the box3d Git submodule first.");
		return 2;
	}
	if (insideDirectory(buildDir, submodule))
	{
		stderr.writeln("Refusing to create build output inside the box3d submodule: ", buildDir);
		return 2;
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

	mkdirRecurse(buildDir);
	string[] configure = [cmake, "-S", submodule, "-B", buildDir,
		"-DCMAKE_BUILD_TYPE=" ~ config,
		"-DBUILD_SHARED_LIBS=ON",
		"-DBOX3D_SAMPLES=OFF",
		"-DBOX3D_BENCHMARKS=OFF",
		"-DBOX3D_UNIT_TESTS=OFF",
		"-DBOX3D_DOCS=OFF"];
	if (generator.length)
		configure ~= ["-G", generator];
	if (osxArch.length)
		configure ~= "-DCMAKE_OSX_ARCHITECTURES=" ~ osxArch;

	auto result = execute(configure);
	if (result.status != 0)
		return result.status;
	result = execute([cmake, "--build", buildDir, "--config", config, "--target", "box3d"]);
	if (result.status != 0)
		return result.status;

	string[] patterns;
	version (Windows)
		patterns = ["box3d.dll"];
	else version (OSX)
		patterns = ["libbox3d.dylib"];
	else
		patterns = ["libbox3d.so"];

	string[] libraries;
	foreach (entry; dirEntries(buildDir, SpanMode.depth))
	{
		auto fileName = baseName(entry.name);
		foreach (pattern; patterns)
		{
			if (fileName == pattern || (pattern == "libbox3d.so" && startsWith(fileName, pattern ~ ".")))
				libraries ~= entry.name;
		}
	}
	if (!libraries.length)
	{
		stderr.writeln("Build succeeded but no Box3D shared library was found under ", buildDir, ".");
		return 2;
	}

	writeln("Built Box3D shared library:");
	foreach (library; libraries)
		writeln("  ", library);
	return 0;
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
	writeln("Usage: rdmd tools/build_box3d_shared.d [options]");
	writeln("  --root PATH          Repository root");
	writeln("  --submodule PATH     Box3D submodule directory");
	writeln("  --build-dir PATH     Build directory outside the submodule");
	writeln("  --cmake PATH         CMake executable");
	writeln("  --generator NAME     CMake generator");
	writeln("  --config NAME        Build configuration (default Release)");
	writeln("  --osx-arch ARCH      Apple architecture, e.g. arm64");
}