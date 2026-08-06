module cydo.runtime.launch.sandbox_renderer;

import std.algorithm : canFind, splitter, startsWith;
import std.file : exists, isFile, isSymlink, readLink;
import std.logger : tracef;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;
import std.string : toStringz;

import core.sys.posix.unistd : X_OK, access;

import cydo.runtime.config : PathMode;
import cydo.runtime.launch.sandbox_materialization : createGitConfigTempFile, createGroupTempFile,
	createPasswdTempFile, emptyDirPath, emptyFilePath;
import cydo.runtime.launch.sandbox_paths : SandboxPathOrigin, SandboxPathOriginKind;
import cydo.runtime.launch.sandbox_resolver : planMounts;
import cydo.runtime.launch.types : ProcessLaunch, ResolvedSandbox;

/// Absolute path to the currently running cydo binary, resolved at
/// module init to avoid /proc/self/exe returning a "(deleted)" suffix
/// after the binary is replaced by a rebuild.
immutable string cydoBinaryPath;
shared static this()
{
	import std.file : thisExePath;
	cydoBinaryPath = thisExePath();
}

/// Get the directory containing the cydo binary.
string cydoBinaryDir()
{
	auto path = cydoBinaryPath;
	return path.length > 0 ? dirName(path) : "";
}

/// Look up an env value from the prepared launch environment, falling back to
/// the backend process environment when the sandbox did not override it.
string effectiveEnvValue(const string[string] env, string key, string fallback = "")
{
	if (auto value = key in env)
		return *value;
	return environment.get(key, fallback);
}

/// Resolve an executable using the effective launch PATH.
/// Returns an absolute path, or "" when it cannot be found/executed.
string resolveExecutablePath(string executable, const string[string] env)
{
	if (executable.length == 0)
		return "";

	auto requested = expandTilde(executable);
	if (requested.startsWith("/"))
		return isExecutableFile(requested) ? requested : "";

	auto pathVar = effectiveEnvValue(env, "PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		if (dir.length == 0)
			continue;
		auto candidate = buildPath(expandTilde(dir), requested);
		if (isExecutableFile(candidate))
			return candidate;
	}
	return "";
}

/// Return directories that must be mounted for an executable path.
/// Includes both the requested path's directory and the final symlink target's
/// directory when they differ.
string[] executableMountPaths(string executablePath)
{
	if (executablePath.length == 0)
		return null;

	string[] mounts;
	bool[string] seen;

	void addMount(string path)
	{
		if (path.length == 0)
			return;
		if (path in seen)
			return;
		seen[path] = true;
		mounts ~= path;
	}

	addMount(dirName(executablePath));
	auto resolved = resolveSymlinkChain(executablePath);
	if (resolved != executablePath)
		addMount(dirName(resolved));
	return mounts;
}

/// Build the command prefix for running a process with sandbox settings.
/// Returns bwrap args when filesystem or process isolation is needed,
/// env args when only environment/workdir management is needed,
/// or null when no prefix is required.
/// Append the inner command after the returned prefix.
string[] buildCommandPrefix(ref ResolvedSandbox sandbox, string workDir)
{
	if (!sandbox.useBwrap)
		return buildEnvPrefix(sandbox, workDir);

	string[] args;

	args ~= findBwrap();

	// Process isolation — gated on sandbox.isolate_processes
	if (sandbox.isolate_processes)
	{
		args ~= [
			"--unshare-ipc",
			"--unshare-pid",
			"--as-pid-1",
			"--unshare-uts",
			"--unshare-cgroup",
		];
	}

	args ~= "--share-net";
	args ~= "--die-with-parent";

	if (sandbox.isolate_filesystem)
	{
		// Restricted mode: selective bind mounts

		// Host-content binds emitted below are symlink-visibility providers for
		// the configured logical mount plan.
		string[] builtinMounts;

		// Pseudo-filesystems
		args ~= ["--dev", "/dev"];
		args ~= ["--proc", "/proc"];
		if (sandbox.sharedTmpPath.length > 0)
			args ~= ["--bind", sandbox.sharedTmpPath, "/tmp"];
		else
			args ~= ["--tmpfs", "/tmp"];

		auto currentSystem = resolveNixCurrentSystem();

		if (currentSystem.length > 0)
		{
			// NixOS: mount nix store, system binaries, and minimal /etc + /run
			// entries needed for DNS, TLS, and bwrap-wrapped binaries.
			static immutable nixPaths = [
				"/nix",
				"/bin",
				"/lib64",
				"/usr/bin",
				"/etc/nix",
				"/etc/static/nix",
				"/etc/resolv.conf",
				"/etc/ssl",
				"/etc/static/ssl",
			];
			foreach (p; nixPaths)
				if (exists(p))
				{
					args ~= ["--ro-bind", p, p];
					builtinMounts ~= p;
				}

			args ~= ["--tmpfs", "/run"];
			args ~= ["--symlink", currentSystem, "/run/current-system"];
			if (exists("/run/wrappers"))
			{
				args ~= ["--ro-bind", "/run/wrappers", "/run/wrappers"];
				builtinMounts ~= "/run/wrappers";
			}
		}
		else
		{
			// non-NixOS: bind-mount system directories so dynamically linked
			// binaries can find shared libraries, the ELF interpreter (ld-linux),
			// DNS resolver (systemd-resolved socket in /run), and CA certificates
			foreach (p; ["/run", "/etc", "/usr"])
				if (exists(p))
				{
					args ~= ["--ro-bind", p, p];
					builtinMounts ~= p;
				}
			if (exists("/lib64") && isSymlink("/lib64"))
				args ~= ["--symlink", readLink("/lib64"), "/lib64"];
			else if (exists("/lib64"))
			{
				args ~= ["--ro-bind", "/lib64", "/lib64"];
				builtinMounts ~= "/lib64";
			}
			if (exists("/lib") && isSymlink("/lib"))
				args ~= ["--symlink", readLink("/lib"), "/lib"];
			else if (exists("/lib") && !exists("/lib64"))
			{
				args ~= ["--ro-bind", "/lib", "/lib"];
				builtinMounts ~= "/lib";
			}
		}

		// Cgroup filesystem
		if (exists("/sys/fs/cgroup"))
		{
			args ~= ["--bind", "/sys/fs/cgroup", "/sys/fs/cgroup"];
			builtinMounts ~= "/sys/fs/cgroup";
		}

		auto plannedMounts = planMounts(sandbox.paths, builtinMounts);

		// A tmpfs directory parent supports later child binds. The current
		// read-only empty_dir lowering cannot create missing child mountpoints,
		// and empty_file is a leaf. This is a representation limitation, not
		// registry policy.
		foreach (entry; plannedMounts)
		{
			final switch (entry.mode)
			{
				case PathMode.ro:
					args ~= ["--ro-bind", entry.source, entry.destination];
					break;
				case PathMode.rw:
				case PathMode.always_rw:
					args ~= ["--bind", entry.source, entry.destination];
					break;
				case PathMode.tmpfs:
					args ~= ["--tmpfs", entry.destination];
					break;
				case PathMode.empty_dir:
					args ~= ["--ro-bind", emptyDirPath(), entry.destination];
					break;
				case PathMode.empty_file:
					args ~= ["--ro-bind", emptyFilePath(), entry.destination];
					break;
			}
		}

		// /etc/passwd injection
		auto passwdTmp = createPasswdTempFile();
		if (passwdTmp.length > 0)
		{
			args ~= ["--ro-bind", passwdTmp, "/etc/passwd"];
			sandbox.tempFiles ~= passwdTmp;
		}

		// /etc/group injection
		auto groupTmp = createGroupTempFile();
		if (groupTmp.length > 0)
		{
			args ~= ["--ro-bind", groupTmp, "/etc/group"];
			sandbox.tempFiles ~= groupTmp;
		}

		// Git config injection
		auto gitTmp = createGitConfigTempFile(sandbox.gitName, sandbox.gitEmail);
		if (gitTmp.length > 0)
		{
			auto home = environment.get("HOME", "");
			args ~= ["--ro-bind", gitTmp, buildPath(home, ".config/git/config")];
			sandbox.tempFiles ~= gitTmp;
		}
	}
	else
	{
		// Unrestricted filesystem: --dev-bind / / gives the child full host
		// filesystem access including device nodes, /proc, etc.
		// bwrap always creates a mount namespace, so this is required.
		args ~= ["--dev-bind", "/", "/"];
	}

	// Environment
	if (sandbox.isolate_environment)
	{
		args ~= "--clearenv";
		args ~= ["--setenv", "HOME", environment.get("HOME", "/tmp")];

		auto nixPath = environment.get("NIX_PATH", "");
		if (nixPath.length > 0)
			args ~= ["--setenv", "NIX_PATH", nixPath];
	}

	foreach (k, v; sandbox.env)
		args ~= ["--setenv", k, v];

	// Working directory
	if (workDir.length > 0)
		args ~= ["--chdir", workDir];

	// Separator
	args ~= "--";

	return args;
}

/// Materialize a reusable process launch from a resolved sandbox and cwd.
ProcessLaunch prepareProcessLaunch(ResolvedSandbox sandbox, string workDir,
	string executable = "")
{
	ProcessLaunch launch;
	launch.sandbox = sandbox;
	launch.workDir = workDir;
	launch.executablePath = resolveExecutablePath(executable, launch.sandbox.env);
	launch.cmdPrefix = buildCommandPrefix(launch.sandbox, workDir);
	return launch;
}

/// Return a launch clone with an additional runtime environment variable.
/// The command prefix is recompiled from the sandbox model rather than patched
/// after argv generation. The executable path is intentionally left unchanged;
/// use this only for env vars that do not affect executable resolution.
ProcessLaunch withProcessLaunchEnv(ProcessLaunch launch, string key, string value)
{
	launch.sandbox.tempFiles = null;
	launch.sandbox.env = launch.sandbox.env.dup;
	launch.sandbox.env[key] = value;
	launch.cmdPrefix = buildCommandPrefix(launch.sandbox, launch.workDir);
	return launch;
}

private:

bool isExecutableFile(string path)
{
	return exists(path) && isFile(path) && access(toStringz(path), X_OK) == 0;
}

string resolveSymlinkChain(string path)
{
	auto current = path;
	for (int i = 0; i < 32 && exists(current) && isSymlink(current); i++)
	{
		auto target = readLink(current);
		if (!target.startsWith("/"))
			target = buildPath(dirName(current), target);
		current = target;
	}
	return current;
}

/// Build an env-based command prefix for non-bwrap mode.
string[] buildEnvPrefix(ref ResolvedSandbox sandbox, string workDir)
{
	bool hasEnv = (sandbox.env !is null && sandbox.env.length > 0) || sandbox.isolate_environment;
	bool hasWorkDir = workDir.length > 0;

	if (!hasEnv && !hasWorkDir)
		return null;

	string[] args = ["env"];

	// Options (-i, -C) must come before KEY=VALUE assignments;
	// GNU env stops option parsing at the first NAME=VALUE argument.
	if (sandbox.isolate_environment)
		args ~= "-i";

	if (hasWorkDir)
		args ~= ["-C", workDir];

	if (sandbox.isolate_environment)
	{
		args ~= "HOME=" ~ environment.get("HOME", "/tmp");
		auto nixPath = environment.get("NIX_PATH", "");
		if (nixPath.length > 0)
			args ~= "NIX_PATH=" ~ nixPath;
	}

	foreach (k, v; sandbox.env)
		args ~= k ~ "=" ~ v;

	return args;
}

/// Find the bwrap binary.
string findBwrap()
{
	foreach (candidate; ["/run/wrappers/bin/bwrap", "/usr/bin/bwrap"])
		if (exists(candidate))
			return candidate;

	auto pathVar = environment.get("PATH", "");
	foreach (dir; pathVar.splitter(':'))
	{
		auto candidate = buildPath(dir, "bwrap");
		if (exists(candidate))
			return candidate;
	}

	assert(false, "bwrap binary not found");
}

/// Resolve /run/current-system symlink target (NixOS).
string resolveNixCurrentSystem()
{
	enum path = "/run/current-system";
	if (exists(path) && isSymlink(path))
	{
		try
			return readLink(path);
		catch (Exception e)
		{
			tracef("nixCurrentSystem: readLink failed: %s", e.msg);
			return "";
		}
	}
	return "";
}

unittest
{
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = false;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["CYDO_TEST_TOKEN"] = "value";

	auto launch = prepareProcessLaunch(sandbox, "/tmp/cydo-launch");
	assert(launch.workDir == "/tmp/cydo-launch");
	assert(launch.cmdPrefix == [
		"env",
		"-C", "/tmp/cydo-launch",
		"CYDO_TEST_TOKEN=value",
	]);

	// Preparing a launch should not mutate the caller's sandbox state.
	assert(sandbox.tempFiles.length == 0);
}

unittest
{
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = false;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["A"] = "1";

	auto source = prepareProcessLaunch(sandbox, "/tmp/cydo-launch");
	source.sandbox.tempFiles = ["/tmp/original-temp"];
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourcePrefix = source.cmdPrefix.dup;

	auto first = withProcessLaunchEnv(source, "B", "2");
	auto second = withProcessLaunchEnv(source, "C", "3");
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.sandbox.env == sourceEnv);
	assert(source.cmdPrefix == sourcePrefix);
	assert(("B" in source.sandbox.env) is null);
	assert(("C" in source.sandbox.env) is null);
	assert(first.sandbox.env["A"] == "1");
	assert(first.sandbox.env["B"] == "2");
	assert(second.sandbox.env["A"] == "1");
	assert(second.sandbox.env["C"] == "3");
	assert(first.sandbox.tempFiles.length == 0);
	assert(second.sandbox.tempFiles.length == 0);
	assert(first.cmdPrefix[0 .. 3] == ["env", "-C", "/tmp/cydo-launch"]);
	assert(second.cmdPrefix[0 .. 3] == ["env", "-C", "/tmp/cydo-launch"]);
	assert(first.cmdPrefix.canFind("A=1"));
	assert(first.cmdPrefix.canFind("B=2"));
	assert(second.cmdPrefix.canFind("A=1"));
	assert(second.cmdPrefix.canFind("C=3"));
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;
	import cydo.runtime.launch.sandbox_paths : PathAccess;

	auto root = buildPath("/tmp", "cydo-renderer-derived-launch");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto logicalHostMount = buildPath(root, "logical-host-mount");
	auto logicalSecondHostMount = buildPath(root, "logical-second-host-mount");
	mkdirRecurse(logicalHostMount);
	mkdirRecurse(logicalSecondHostMount);
	string[] plannedMountSubsequence(string[] args, string[] configuredPaths)
	{
		bool isConfiguredPath(string path)
		{
			foreach (configuredPath; configuredPaths)
				if (path == configuredPath)
					return true;
			return false;
		}

		string[] result;
		foreach (i; 0 .. args.length)
		{
			if (args[i] == "--tmpfs" && i + 1 < args.length
				&& isConfiguredPath(args[i + 1]))
				result ~= args[i .. i + 2];
			else if ((args[i] == "--ro-bind" || args[i] == "--bind")
				&& i + 2 < args.length
				&& (isConfiguredPath(args[i + 1])
					|| isConfiguredPath(args[i + 2])))
				result ~= args[i .. i + 3];
		}
		return result;
	}

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.env["A"] = "1";
	sandbox.paths.set(logicalHostMount, PathMode.ro,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
			"derived launch", "logical host mount"));
	sandbox.paths.set(logicalSecondHostMount, PathMode.ro,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault,
			"derived launch", "second logical host mount"));

	auto source = prepareProcessLaunch(sandbox, "");
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto configuredPaths = [logicalHostMount, logicalSecondHostMount];
	auto sourceMounts = plannedMountSubsequence(sourcePrefix, configuredPaths);
	assert(sourceMounts == [
		"--ro-bind", logicalHostMount, logicalHostMount,
		"--ro-bind", logicalSecondHostMount, logicalSecondHostMount,
	]);

	auto first = withProcessLaunchEnv(source, "B", "2");
	auto second = withProcessLaunchEnv(source, "C", "3");
	scope (exit)
	{
		foreach (tempFile; source.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
		foreach (tempFile; first.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
		foreach (tempFile; second.sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
	}

	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.sandbox.env == sourceEnv);
	assert(source.cmdPrefix == sourcePrefix);
	assert(first.sandbox.paths.snapshot == sourcePaths);
	assert(second.sandbox.paths.snapshot == sourcePaths);
	assert(first.sandbox.env["A"] == "1");
	assert(first.sandbox.env["B"] == "2");
	assert(second.sandbox.env["A"] == "1");
	assert(second.sandbox.env["C"] == "3");
	assert(first.cmdPrefix.canFind(["--setenv", "A", "1"]));
	assert(first.cmdPrefix.canFind(["--setenv", "B", "2"]));
	assert(second.cmdPrefix.canFind(["--setenv", "A", "1"]));
	assert(second.cmdPrefix.canFind(["--setenv", "C", "3"]));
	assert(plannedMountSubsequence(first.cmdPrefix, configuredPaths) == sourceMounts);
	assert(plannedMountSubsequence(second.cmdPrefix, configuredPaths) == sourceMounts);
	size_t separator = first.cmdPrefix.length;
	size_t firstMountStart = first.cmdPrefix.length;
	size_t secondMountStart = first.cmdPrefix.length;
	foreach (i; 0 .. first.cmdPrefix.length)
	{
		if (first.cmdPrefix[i] == "--")
		{
			separator = i;
		}
		else if ((first.cmdPrefix[i] == "--ro-bind" || first.cmdPrefix[i] == "--bind")
			&& i + 2 < first.cmdPrefix.length
			&& first.cmdPrefix[i + 1] == logicalHostMount
			&& first.cmdPrefix[i + 2] == logicalHostMount)
			firstMountStart = i;
		else if ((first.cmdPrefix[i] == "--ro-bind" || first.cmdPrefix[i] == "--bind")
			&& i + 2 < first.cmdPrefix.length
			&& first.cmdPrefix[i + 1] == logicalSecondHostMount
			&& first.cmdPrefix[i + 2] == logicalSecondHostMount)
			secondMountStart = i;
	}
	assert(separator < first.cmdPrefix.length);
	assert(firstMountStart < secondMountStart);
	assert(secondMountStart == firstMountStart + 3);
	auto divergentFirstPrefix = first.cmdPrefix[0 .. separator].dup;
	divergentFirstPrefix ~= ["--bind", logicalHostMount, logicalHostMount];
	divergentFirstPrefix ~= first.cmdPrefix[separator .. $];
	assert(plannedMountSubsequence(divergentFirstPrefix,
		configuredPaths) != sourceMounts);
	auto missingFirstPrefix = first.cmdPrefix[0 .. firstMountStart].dup;
	missingFirstPrefix ~= first.cmdPrefix[firstMountStart + 3 .. $];
	assert(plannedMountSubsequence(missingFirstPrefix, configuredPaths) != sourceMounts);
	auto swappedFirstPrefix = first.cmdPrefix[0 .. firstMountStart].dup;
	swappedFirstPrefix ~= first.cmdPrefix[secondMountStart .. secondMountStart + 3];
	swappedFirstPrefix ~= first.cmdPrefix[firstMountStart .. firstMountStart + 3];
	swappedFirstPrefix ~= first.cmdPrefix[secondMountStart + 3 .. $];
	assert(plannedMountSubsequence(swappedFirstPrefix, configuredPaths) != sourceMounts);

	auto repeatedSourcePrefix = buildCommandPrefix(source.sandbox, source.workDir);
	auto repeatedFirstPrefix = buildCommandPrefix(first.sandbox, first.workDir);
	auto repeatedSecondPrefix = buildCommandPrefix(second.sandbox, second.workDir);
	assert(plannedMountSubsequence(repeatedSourcePrefix, configuredPaths) == sourceMounts);
	assert(plannedMountSubsequence(repeatedFirstPrefix, configuredPaths) == sourceMounts);
	assert(plannedMountSubsequence(repeatedSecondPrefix, configuredPaths) == sourceMounts);
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(first.sandbox.paths.snapshot == sourcePaths);
	assert(second.sandbox.paths.snapshot == sourcePaths);

	auto sourceTempFilesBeforeMutation = source.sandbox.tempFiles.dup;
	auto sourceEnvBeforeMutation = source.sandbox.env.dup;
	auto secondTempFilesBeforeMutation = second.sandbox.tempFiles.dup;
	auto secondEnvBeforeMutation = second.sandbox.env.dup;
	auto derivedTempFile = buildPath(root, "derived-temp");
	write(derivedTempFile, "");
	first.sandbox.env["DERIVED_ONLY"] = "present";
	first.sandbox.tempFiles ~= derivedTempFile;
	first.sandbox.paths.require(logicalHostMount, PathAccess.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
			"derived launch", "derived write"));
	assert(("B" in source.sandbox.env) is null);
	assert(("C" in source.sandbox.env) is null);
	assert(("DERIVED_ONLY" in source.sandbox.env) is null);
	assert(source.sandbox.tempFiles == sourceTempFilesBeforeMutation);
	assert(source.sandbox.env == sourceEnvBeforeMutation);
	assert(second.sandbox.tempFiles == secondTempFilesBeforeMutation);
	assert(second.sandbox.env == secondEnvBeforeMutation);
	assert(first.sandbox.tempFiles.canFind(derivedTempFile));
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(second.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.paths.exact(logicalHostMount).get.effectiveMode == PathMode.ro);
	assert(second.sandbox.paths.exact(logicalHostMount).get.effectiveMode == PathMode.ro);
	assert(first.sandbox.paths.exact(logicalHostMount).get.effectiveMode == PathMode.rw);
}

unittest
{
	import std.file : mkdirRecurse, remove, rmdirRecurse, symlink, write;
	import std.path : buildPath;

	import ae.sys.file : realPath;

	// Regression: paths are added to the sandbox after resolveSandbox (task
	// dir, worktree, git dirs) — spelling rewriting must still apply to
	// them, so it happens at render time.
	auto root = buildPath(realPath("/tmp"), "cydo-renderer-symlink");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	// findBwrap only produces argv[0]; satisfy it in environments without a
	// real bwrap (the Nix build sandbox).
	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope(exit)
		environment["PATH"] = oldPath;

	auto wsRoot = buildPath(root, "ws");
	auto wsLink = buildPath(root, "ws-link");
	auto projectDir = buildPath(wsRoot, "project");
	auto taskDir = buildPath(root, "moved", "tasks", "1");
	auto tasksLink = buildPath(wsRoot, ".cydo", "tasks");
	mkdirRecurse(taskDir);
	mkdirRecurse(projectDir);
	mkdirRecurse(buildPath(wsRoot, ".cydo"));
	symlink(wsRoot, wsLink);
	symlink(buildPath(root, "moved", "tasks"), tasksLink);

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	sandbox.paths.set(wsRoot, PathMode.ro,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault, "renderer test",
			"workspace root"));
	// The default task mounts are canonical, but configured paths retain their
	// spelling. Both must survive renderer rewriting.
	sandbox.paths.set(projectDir, PathMode.rw,
		SandboxPathOrigin(SandboxPathOriginKind.builtinDefault, "renderer test",
			"project"));
	sandbox.paths.set(wsLink, PathMode.tmpfs,
		SandboxPathOrigin(SandboxPathOriginKind.workspaceConfig, "renderer test",
			"workspace mask"));
	sandbox.paths.set(buildPath(tasksLink, "1"), PathMode.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement, "renderer test",
			"task directory"));

	auto args = buildCommandPrefix(sandbox, "");
	scope(exit)
		foreach (tempFile; sandbox.tempFiles)
			remove(tempFile);
	assert(args.canFind(["--ro-bind", wsRoot, wsRoot]));
	assert(args.canFind(["--bind", projectDir, projectDir]));
	assert(args.canFind(["--tmpfs", wsLink]));
	assert(args.canFind(["--bind", taskDir, taskDir]));
	assert(!args.canFind(buildPath(tasksLink, "1")));
}

unittest
{
	import std.file : mkdirRecurse, remove, write;
	import std.process : execute;

	auto binDir = buildPath("/tmp", "cydo-launch-bin");
	auto binPath = buildPath(binDir, "cydo-test-exec");
	mkdirRecurse(binDir);
	scope(exit)
	{
		if (exists(binPath))
			remove(binPath);
	}

	write(binPath, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", binPath]);

	ResolvedSandbox sandbox;
	sandbox.env["PATH"] = binDir;

	auto launch = prepareProcessLaunch(sandbox, "", "cydo-test-exec");
	assert(launch.executablePath == binPath);
	assert(executableMountPaths(binPath).canFind(binDir));
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-renderer-all-modes");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto roPath = buildPath(root, "ro");
	auto rwPath = buildPath(root, "rw");
	auto alwaysRwPath = buildPath(root, "always-rw");
	auto tmpfsPath = buildPath(root, "tmpfs");
	auto emptyDirPath_ = buildPath(root, "empty-dir");
	auto emptyFilePath_ = buildPath(root, "empty-file");
	foreach (path; [roPath, rwPath, alwaysRwPath, tmpfsPath, emptyDirPath_])
		mkdirRecurse(path);
	write(emptyFilePath_, "");

	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.isolate_processes = false;
	sandbox.isolate_environment = false;
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"renderer modes", "configured mount");
	sandbox.paths.set(roPath, PathMode.ro, origin);
	sandbox.paths.set(rwPath, PathMode.rw, origin);
	sandbox.paths.set(alwaysRwPath, PathMode.always_rw, origin);
	sandbox.paths.set(tmpfsPath, PathMode.tmpfs, origin);
	sandbox.paths.set(emptyDirPath_, PathMode.empty_dir, origin);
	sandbox.paths.set(emptyFilePath_, PathMode.empty_file, origin);
	auto logicalBefore = sandbox.paths.snapshot;

	auto args = buildCommandPrefix(sandbox, "");
	auto repeatedArgs = buildCommandPrefix(sandbox, "");
	scope (exit)
		foreach (tempFile; sandbox.tempFiles)
			if (exists(tempFile))
				remove(tempFile);
	assert(args.canFind(["--ro-bind", roPath, roPath]));
	assert(args.canFind(["--bind", rwPath, rwPath]));
	assert(args.canFind(["--bind", alwaysRwPath, alwaysRwPath]));
	assert(args.canFind(["--tmpfs", tmpfsPath]));
	assert(args.canFind(["--ro-bind", emptyDirPath(), emptyDirPath_]));
	assert(args.canFind(["--ro-bind", emptyFilePath(), emptyFilePath_]));
	assert(repeatedArgs.canFind(["--ro-bind", roPath, roPath]));
	assert(repeatedArgs.canFind(["--bind", rwPath, rwPath]));
	assert(repeatedArgs.canFind(["--bind", alwaysRwPath, alwaysRwPath]));
	assert(repeatedArgs.canFind(["--tmpfs", tmpfsPath]));
	assert(repeatedArgs.canFind(["--ro-bind", emptyDirPath(), emptyDirPath_]));
	assert(repeatedArgs.canFind(["--ro-bind", emptyFilePath(), emptyFilePath_]));

	auto logicalAfter = sandbox.paths.snapshot;
	assert(logicalAfter.length == logicalBefore.length);
	foreach (i, view; logicalBefore)
	{
		assert(logicalAfter[i].path == view.path);
		assert(logicalAfter[i].effectiveMode == view.effectiveMode);
		assert(logicalAfter[i].declaration.get.mode == view.declaration.get.mode);
		assert(logicalAfter[i].declaration.get.origin.kind == view.declaration.get.origin.kind);
		assert(logicalAfter[i].declaration.get.origin.scope_
			== view.declaration.get.origin.scope_);
		assert(logicalAfter[i].declaration.get.origin.detail
			== view.declaration.get.origin.detail);
	}
}

unittest
{
	import std.file : exists, mkdirRecurse, remove, rmdirRecurse, write;
	import std.path : buildPath;

	size_t sequenceIndex(string[] args, string[] sequence)
	{
		foreach (i; 0 .. args.length - sequence.length + 1)
			if (args[i .. i + sequence.length] == sequence)
				return i;
		assert(false, "missing renderer argument sequence");
	}

	auto root = buildPath("/tmp", "cydo-renderer-tmpfs-children");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto fakeBin = buildPath(root, "bin");
	mkdirRecurse(fakeBin);
	write(buildPath(fakeBin, "bwrap"), "");
	auto oldPath = environment.get("PATH", "");
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	scope (exit) environment["PATH"] = oldPath;

	auto parent = buildPath(root, "masked");
	auto alpha = buildPath(parent, "alpha");
	auto bravo = buildPath(parent, "bravo");
	auto cider = buildPath(parent, "cider");
	foreach (path; [alpha, bravo, cider])
		mkdirRecurse(path);
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"renderer ordering", "configured mount");

	foreach (reverseRegistration; [false, true])
	{
		ResolvedSandbox sandbox;
		sandbox.isolate_filesystem = true;
		sandbox.isolate_processes = false;
		sandbox.isolate_environment = false;
		if (reverseRegistration)
		{
			sandbox.paths.set(cider, PathMode.always_rw, origin);
			sandbox.paths.set(bravo, PathMode.rw, origin);
			sandbox.paths.set(alpha, PathMode.ro, origin);
			sandbox.paths.set(parent, PathMode.tmpfs, origin);
		}
		else
		{
			sandbox.paths.set(parent, PathMode.tmpfs, origin);
			sandbox.paths.set(alpha, PathMode.ro, origin);
			sandbox.paths.set(bravo, PathMode.rw, origin);
			sandbox.paths.set(cider, PathMode.always_rw, origin);
		}

		auto args = buildCommandPrefix(sandbox, "");
		scope (exit)
			foreach (tempFile; sandbox.tempFiles)
				if (exists(tempFile))
					remove(tempFile);
		auto parentIndex = sequenceIndex(args, ["--tmpfs", parent]);
		auto alphaIndex = sequenceIndex(args, ["--ro-bind", alpha, alpha]);
		auto bravoIndex = sequenceIndex(args, ["--bind", bravo, bravo]);
		auto ciderIndex = sequenceIndex(args, ["--bind", cider, cider]);
		assert(parentIndex < alphaIndex);
		assert(parentIndex < bravoIndex);
		assert(parentIndex < ciderIndex);
		assert(alphaIndex < bravoIndex);
		assert(bravoIndex < ciderIndex);
	}
}
