module cydo.runtime.launch.sandbox_resolver;

import std.algorithm : any, canFind, startsWith;
import std.exception : enforce;
import std.file : exists, isSymlink, readLink;
import std.format : format;
import std.logger : warningf;
import std.path : expandTilde, pathSplitter;
import std.process : environment;
import std.string : lastIndexOf;

import ae.sys.file : realPath;

import configy.attributes : SetInfo;

import cydo.runtime.config : GitIdentityConfig, PathMode, SandboxConfig;
import cydo.runtime.launch.types : AgentSandboxConfig, ResolvedSandbox;

/// Merge sandbox config layers: global config → per-agent config → default
/// workspace/project mounts → per-workspace config → agent defaults.
/// When readOnly is true, all config/workspace/project paths are downgraded
/// to ro before the agent layer runs — so agent-declared paths (e.g. ~/.claude)
/// stay rw while the project tree becomes read-only.
ResolvedSandbox resolveSandbox(SandboxConfig global, SandboxConfig agentTypeConfig,
	SandboxConfig workspace, AgentSandboxConfig agent, string projectDir,
	string wsRoot = "",
	bool readOnly = false)
{
	ResolvedSandbox result;

	// Layer 1: global config paths
	mergePaths(result.paths, global.paths);

	// Layer 1.5: per-agent config paths (overrides global)
	mergePaths(result.paths, agentTypeConfig.paths);

	// Default workspace root mount. Workspace config can still override this
	// (e.g. mount the root as tmpfs to mask the host tree).
	if (wsRoot.length > 0)
		result.paths[expandTilde(wsRoot)] = PathMode.ro;

	// Default task workspace/project mount.
	if (projectDir.length > 0)
		result.paths[expandTilde(projectDir)] = PathMode.rw;

	// Layer 2: per-workspace config paths (overrides defaults above)
	mergePaths(result.paths, workspace.paths);

	// Read-only mode: downgrade all rw paths to ro before agent layer
	if (readOnly)
		foreach (ref mode; result.paths)
			if (mode == PathMode.rw)
				mode = PathMode.ro;

	// Merge env: global, then per-agent, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, agentTypeConfig.env);
	mergeEnv(result.env, workspace.env);

	// Layer 3: agent-declared paths/env (last — always rw for agent state)
	// Agent sandbox setup sees the merged config env so binary/path resolution
	// can honor sandbox.env overrides such as PATH.
	agent.configureSandbox(result.paths, result.env);

	renderResolvedEnv(result.env);
	resolveGitIdentity(result, agent.gitName, agent.gitEmail,
		global.git, agentTypeConfig.git, workspace.git);
	resolveIsolationFlags(result, global, agentTypeConfig, workspace);

	return result;
}

/// Resolve sandbox for project discovery (no agent layer).
/// Merges global + workspace sandbox layers; all paths are downgraded to ro.
ResolvedSandbox resolveSandboxForDiscovery(SandboxConfig global, SandboxConfig workspace,
	string wsRoot, string cydoBinDir)
{
	ResolvedSandbox result;

	// Layer 1: global config paths
	mergePaths(result.paths, global.paths);

	// Default workspace root mount. Workspace config can still override this
	// (e.g. mount the root as tmpfs to mask the host tree).
	if (wsRoot.length > 0)
		result.paths[expandTilde(wsRoot)] = PathMode.ro;

	// Layer 2: workspace config paths (overrides defaults above)
	mergePaths(result.paths, workspace.paths);

	// Add cydo binary directory as ro
	if (cydoBinDir.length > 0)
		result.paths[cydoBinDir] = PathMode.ro;

	// Downgrade all rw paths to ro (discovery is read-only)
	foreach (ref mode; result.paths)
		if (mode == PathMode.rw || mode == PathMode.always_rw)
			mode = PathMode.ro;

	// Merge env: global, then workspace overrides
	mergeEnv(result.env, global.env);
	mergeEnv(result.env, workspace.env);
	renderResolvedEnv(result.env);
	resolveIsolationFlags(result, global, workspace);

	return result;
}

private:

/// Expand and rewrite sandbox path spellings so each is mountable as a bwrap
/// destination and reachable inside the sandbox at run time.
///
/// bwrap materializes destination parents as plain directories in its staging
/// root, following any symlinks that already exist there. A symlink component
/// exists in the staging root only when an enclosing host-content mount
/// exposes it — destination creation would then chase it into paths that do
/// not exist yet (and run-time resolution chases it likewise), so such
/// spellings are rewritten to the symlink's target. A symlink no mount
/// exposes simply materializes as a plain directory (or, as a final
/// component, a dereferenced bind), so its spelling is kept as-is.
///
/// Called by the renderer, at the last moment before argv generation: paths
/// are contributed both by config resolution and by later launch stages
/// (task dir, worktree, git dirs), and all of them must pass through here.
/// `builtinMounts` are the renderer's hardcoded host-content binds, which
/// expose symlinks just like configured ones.
public void rewriteSandboxPaths(ref PathMode[string] paths, const(string)[] builtinMounts)
{
	auto providers = builtinMounts.dup;
	foreach (path, mode; paths)
		if (mode == PathMode.ro || mode == PathMode.rw || mode == PathMode.always_rw)
		{
			auto logical = expandTilde(path);
			if (exists(logical))
				providers ~= logical;
		}

	PathMode[string] rewritten;
	string[string] spellings; // rewritten → configured spelling
	foreach (path, mode; paths)
	{
		auto logical = expandTilde(path);
		if (!exists(logical))
		{
			warningf("sandbox: skipping non-existent path: %s", logical);
			continue;
		}
		auto dest = rewriteSandboxPath(logical, providers);
		if (auto existingMode = dest in rewritten)
			enforce(*existingMode == mode, format(
				"sandbox: %s and %s are the same path (%s) with conflicting modes",
				spellings[dest], logical, dest));
		rewritten[dest] = mode;
		spellings[dest] = logical;
	}
	paths = rewritten;
}

/// Walk `logical` the way the sandbox resolves it: a symlink component is
/// followed (spelling rewritten to its target) only when it is strictly
/// inside a host-content mount and therefore present in the sandbox;
/// otherwise the component is kept literally, to materialize as a plain
/// directory or dereferenced bind.
string rewriteSandboxPath(string logical, const(string)[] providers)
{
	// Terminates: mirrors the host resolution of `logical`, whose full
	// resolvability was already proven by exists() above.
	string current; // spelling-so-far; "" is the root
	auto remaining = pathComponents(logical);
	while (remaining.length)
	{
		auto component = remaining[0];
		remaining = remaining[1 .. $];
		if (component == ".")
			continue;
		if (component == "..")
		{
			auto slash = current.lastIndexOf('/');
			current = slash <= 0 ? "" : current[0 .. slash];
			continue;
		}
		auto candidate = current ~ "/" ~ component;
		if (isSymlink(candidate)
			&& providers.any!(p => candidate.startsWith(p ~ "/")))
		{
			auto target = readLink(candidate);
			remaining = pathComponents(target) ~ remaining;
			if (target.startsWith("/"))
				current = "";
		}
		else
			current = candidate;
	}
	return current;
}

string[] pathComponents(string path)
{
	string[] result;
	foreach (component; path.pathSplitter)
		if (component != "/")
			result ~= component;
	return result;
}

void renderResolvedEnv(ref string[string] env)
{
	auto hostEnv = environment.toAA();
	auto home = environment.get("HOME", "");
	string[string] expandedEnv;
	foreach (k, v; env)
		expandedEnv[k] = expandAllTildes(renderSandboxEnvValue(v, hostEnv), home);
	env = expandedEnv;
}

void resolveGitIdentity(ref ResolvedSandbox result, string agentGitName, string agentGitEmail,
	GitIdentityConfig globalGit, GitIdentityConfig agentTypeGit,
	GitIdentityConfig workspaceGit)
{
	result.gitName = agentGitName;
	result.gitEmail = agentGitEmail;
	if (globalGit.name.length > 0)
		result.gitName = globalGit.name;
	if (globalGit.email.length > 0)
		result.gitEmail = globalGit.email;
	if (agentTypeGit.name.length > 0)
		result.gitName = agentTypeGit.name;
	if (agentTypeGit.email.length > 0)
		result.gitEmail = agentTypeGit.email;
	if (workspaceGit.name.length > 0)
		result.gitName = workspaceGit.name;
	if (workspaceGit.email.length > 0)
		result.gitEmail = workspaceGit.email;
}

void resolveIsolationFlags(ref ResolvedSandbox result, SandboxConfig global,
	SandboxConfig agentTypeConfig, SandboxConfig workspace)
{
	result.isolate_filesystem = true;
	result.isolate_processes = true;
	result.isolate_environment = true;
	overrideBool(result.isolate_filesystem, global.isolate_filesystem);
	overrideBool(result.isolate_filesystem, agentTypeConfig.isolate_filesystem);
	overrideBool(result.isolate_filesystem, workspace.isolate_filesystem);
	overrideBool(result.isolate_processes, global.isolate_processes);
	overrideBool(result.isolate_processes, agentTypeConfig.isolate_processes);
	overrideBool(result.isolate_processes, workspace.isolate_processes);
	overrideBool(result.isolate_environment, global.isolate_environment);
	overrideBool(result.isolate_environment, agentTypeConfig.isolate_environment);
	overrideBool(result.isolate_environment, workspace.isolate_environment);
}

void resolveIsolationFlags(ref ResolvedSandbox result, SandboxConfig global,
	SandboxConfig workspace)
{
	result.isolate_filesystem = true;
	result.isolate_processes = true;
	result.isolate_environment = true;
	overrideBool(result.isolate_filesystem, global.isolate_filesystem);
	overrideBool(result.isolate_filesystem, workspace.isolate_filesystem);
	overrideBool(result.isolate_processes, global.isolate_processes);
	overrideBool(result.isolate_processes, workspace.isolate_processes);
	overrideBool(result.isolate_environment, global.isolate_environment);
	overrideBool(result.isolate_environment, workspace.isolate_environment);
}

/// Override dest with source value if source was explicitly set in config.
void overrideBool(ref bool dest, SetInfo!bool source)
{
	if (source.set)
		dest = source.value;
}

/// Replace all occurrences of ~ with the home directory.
/// Handles ~/path at the start, and :~/path in PATH-like variables.
string expandAllTildes(string value, string home)
{
	import std.array : replace;
	if (home.length == 0)
		return value;
	return value.replace("~/", home ~ "/");
}

string renderSandboxEnvValue(string raw, const string[string] hostEnv)
{
	if (raw.length == 0 || !raw.canFind("{{"))
		return raw;

	import djinja.djinja : loadData;
	import djinja.render : Render;
	import uninode.node : UniNode;

	UniNode[string] envMap;
	foreach (k, v; hostEnv)
		envMap[k] = UniNode(v);

	UniNode[string] data;
	data["env"] = UniNode(envMap);

	try
	{
		auto tmpl = loadData(raw);
		return (new Render(tmpl)).render(UniNode(data));
	}
	catch (Exception e)
	{
		warningf("sandbox.env: failed to render template %s: %s", raw, e.msg);
		return "";
	}
}

/// Merge source paths into destination (source wins on conflicts).
void mergePaths(ref PathMode[string] dest, PathMode[string] source)
{
	if (source is null)
		return;
	foreach (path, mode; source)
		dest[path] = mode;
}

/// Merge source env into destination (source wins on conflicts).
void mergeEnv(ref string[string] dest, string[string] source)
{
	if (source is null)
		return;
	foreach (k, v; source)
		dest[k] = v;
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;

	auto wsRoot = buildPath("/tmp", "cydo-sandbox-ws-root");
	auto projectDir = buildPath(wsRoot, "project");
	if (exists(wsRoot))
		rmdirRecurse(wsRoot);
	scope(exit)
		if (exists(wsRoot))
			rmdirRecurse(wsRoot);

	mkdirRecurse(projectDir);

	SandboxConfig workspace;
	workspace.paths = [wsRoot : PathMode.tmpfs];

	AgentSandboxConfig agent;
	agent.configureSandbox = (ref PathMode[string] paths, ref string[string] env) {};
	auto taskSandbox = resolveSandbox(SandboxConfig.init, SandboxConfig.init,
		workspace, agent, projectDir, wsRoot);
	assert(taskSandbox.paths[wsRoot] == PathMode.tmpfs);
	assert(taskSandbox.paths[projectDir] == PathMode.rw);

	auto discoverySandbox = resolveSandboxForDiscovery(SandboxConfig.init,
		workspace, wsRoot, "");
	assert(discoverySandbox.paths[wsRoot] == PathMode.tmpfs);
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;

	auto root = buildPath("/tmp", "cydo-sandbox-agent-config");
	auto wsRoot = buildPath(root, "workspace");
	auto projectDir = buildPath(wsRoot, "project");
	auto globalDir = buildPath(root, "global");
	auto agentTypeDir = buildPath(root, "agent-type");
	auto workspaceDir = buildPath(root, "workspace-layer");
	auto agentStateDir = buildPath(root, "agent-state");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	foreach (path; [projectDir, globalDir, agentTypeDir, workspaceDir, agentStateDir])
		mkdirRecurse(path);

	SandboxConfig global;
	global.paths[globalDir] = PathMode.rw;
	global.env["GLOBAL_ONLY"] = "global";
	global.env["MERGED"] = "global";
	global.git.name = "Global Name";
	global.git.email = "global@example.com";

	SandboxConfig agentTypeConfig;
	agentTypeConfig.paths[agentTypeDir] = PathMode.rw;
	agentTypeConfig.env["AGENT_ONLY"] = "agent";
	agentTypeConfig.env["MERGED"] = "agent";
	agentTypeConfig.git.name = "Agent Type Name";

	SandboxConfig workspace;
	workspace.paths[workspaceDir] = PathMode.rw;
	workspace.env["WORKSPACE_ONLY"] = "workspace";
	workspace.env["MERGED"] = "workspace";
	workspace.git.email = "workspace@example.com";

	bool configureCalled;
	AgentSandboxConfig agent;
	agent.configureSandbox = (ref PathMode[string] paths, ref string[string] env) {
		configureCalled = true;
		assert(env["GLOBAL_ONLY"] == "global");
		assert(env["AGENT_ONLY"] == "agent");
		assert(env["WORKSPACE_ONLY"] == "workspace");
		assert(env["MERGED"] == "workspace");
		assert(paths[wsRoot] == PathMode.ro);
		assert(paths[projectDir] == PathMode.ro);
		assert(paths[globalDir] == PathMode.ro);
		assert(paths[agentTypeDir] == PathMode.ro);
		assert(paths[workspaceDir] == PathMode.ro);
		paths[agentStateDir] = PathMode.rw;
		env["AGENT_ADDED"] = "present";
	};
	agent.gitName = "Agent Default Name";
	agent.gitEmail = "agent@example.com";

	auto resolved = resolveSandbox(global, agentTypeConfig, workspace, agent,
		projectDir, wsRoot, true);
	assert(configureCalled);
	assert(resolved.paths[wsRoot] == PathMode.ro);
	assert(resolved.paths[projectDir] == PathMode.ro);
	assert(resolved.paths[globalDir] == PathMode.ro);
	assert(resolved.paths[agentTypeDir] == PathMode.ro);
	assert(resolved.paths[workspaceDir] == PathMode.ro);
	assert(resolved.paths[agentStateDir] == PathMode.rw);
	assert(resolved.env["AGENT_ADDED"] == "present");
	assert(resolved.gitName == "Agent Type Name");
	assert(resolved.gitEmail == "workspace@example.com");
}

unittest
{
	import std.exception : assertThrown;
	import std.file : mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;

	auto root = buildPath(realPath("/tmp"), "cydo-sandbox-symlink");
	if (exists(root))
		rmdirRecurse(root);
	scope(exit)
		if (exists(root))
			rmdirRecurse(root);

	// ws/.cydo/tasks is an absolute symlink whose target spelling traverses
	// another (relative) symlink, mirroring a tasks directory relocated to
	// another volume that is itself reached through a symlink.
	auto wsRoot = buildPath(root, "ws");
	auto movedTasks = buildPath(root, "moved", "tasks");
	auto taskDir = buildPath(movedTasks, "1");
	auto hop = buildPath(root, "hop"); // hop → moved
	auto tasksLink = buildPath(wsRoot, ".cydo", "tasks"); // → hop/tasks
	mkdirRecurse(buildPath(wsRoot, ".cydo"));
	mkdirRecurse(taskDir);
	symlink("moved", hop);
	symlink(buildPath(hop, "tasks"), tasksLink);
	auto logicalTaskDir = buildPath(tasksLink, "1");

	// The ro wsRoot mount exposes the tasks symlink inside the sandbox, so
	// the spelling is rewritten to its target. The hop symlink inside the
	// target spelling is exposed by nothing and stays literal — it will
	// materialize as a plain directory.
	PathMode[string] paths = [wsRoot: PathMode.ro, logicalTaskDir: PathMode.rw];
	rewriteSandboxPaths(paths, null);
	assert(paths == [wsRoot: PathMode.ro, buildPath(hop, "tasks", "1"): PathMode.rw]);

	// With no mount exposing the tasks symlink, bwrap materializes the
	// spelling as plain directories — it is kept as-is.
	PathMode[string] uncovered = [logicalTaskDir: PathMode.rw];
	rewriteSandboxPaths(uncovered, null);
	assert(uncovered == [logicalTaskDir: PathMode.rw]);

	// Builtin renderer mounts provide visibility like configured ones.
	PathMode[string] viaBuiltin = [logicalTaskDir: PathMode.rw];
	rewriteSandboxPaths(viaBuiltin, [wsRoot]);
	assert(viaBuiltin == [buildPath(hop, "tasks", "1"): PathMode.rw]);

	// Two spellings rewriting to the same path with conflicting modes.
	auto tasksLink2 = buildPath(wsRoot, ".cydo", "tasks2"); // → hop/tasks too
	symlink(buildPath(hop, "tasks"), tasksLink2);
	PathMode[string] conflicting = [
		wsRoot: PathMode.ro,
		logicalTaskDir: PathMode.rw,
		buildPath(tasksLink2, "1"): PathMode.ro,
	];
	assertThrown(rewriteSandboxPaths(conflicting, null));
}

unittest
{
	import std.process : environment;

	auto oldHome = environment.get("HOME", "");
	scope(exit)
		environment["HOME"] = oldHome;

	environment["HOME"] = "/tmp/cydo-sandbox-home";

	SandboxConfig workspace;
	workspace.env["CYDO_TEMPLATE"] = "{{ env.HOME }}/cfg:~/bin";

	AgentSandboxConfig agent;
	agent.configureSandbox = (ref PathMode[string] paths, ref string[string] env) {};

	auto resolved = resolveSandbox(SandboxConfig.init, SandboxConfig.init,
		workspace, agent, "", "");
	assert(resolved.env["CYDO_TEMPLATE"] == "/tmp/cydo-sandbox-home/cfg:/tmp/cydo-sandbox-home/bin");
}
