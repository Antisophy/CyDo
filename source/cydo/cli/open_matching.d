module cydo.cli.open_matching;

import std.algorithm : startsWith;

import cydo.foundation.platform.path : canonicalProjectPath;
import cydo.workflow.discovery.scanner : DiscoveredProject;

bool pathIsUnderRoot(string path, string root)
{
	return root == "/" || path == root ||
		(path.length > root.length && path.startsWith(root ~ "/"));
}

string findOpenProjectName(string targetDir, ref DiscoveredProject[] projects)
{
	string bestPath;
	string bestName;
	foreach (ref p; projects)
	{
		auto projectPath = canonicalProjectPath(p.path);
		if (pathIsUnderRoot(targetDir, projectPath) && projectPath.length > bestPath.length)
		{
			bestPath = projectPath;
			bestName = p.name;
		}
	}
	return bestName;
}

version (unittest)
{
	import ae.sys.file : realPath;
	import std.file : exists, mkdirRecurse, rmdirRecurse, symlink;
	import std.path : buildPath;

	unittest
	{
		auto root = buildPath(realPath("/tmp"), "cydo-test-open-path");
		if (exists(root))
			rmdirRecurse(root);
		scope (exit)
			if (exists(root))
				rmdirRecurse(root);

		auto workspace = buildPath(root, "workspace");
		auto workspaceLink = buildPath(root, "workspace-link");
		auto project = buildPath(workspace, "project");
		auto nestedProject = buildPath(project, "nested");
		auto project2 = buildPath(workspace, "project2");
		mkdirRecurse(nestedProject);
		mkdirRecurse(project2);
		symlink(workspace, workspaceLink);

		auto targetFromLink = canonicalProjectPath(buildPath(workspaceLink, "project", "nested"));
		auto targetFromReal = canonicalProjectPath(nestedProject);
		assert(targetFromLink == targetFromReal);
		assert(pathIsUnderRoot(targetFromLink, canonicalProjectPath(workspaceLink)));
		assert(pathIsUnderRoot(targetFromLink, "/"));
		assert(!pathIsUnderRoot(canonicalProjectPath(project2), canonicalProjectPath(project)));

		DiscoveredProject[] projects = [
			DiscoveredProject("workspace", buildPath(workspaceLink, "project"), "project"),
			DiscoveredProject("workspace", nestedProject, "project/nested"),
		];
		assert(findOpenProjectName(targetFromLink, projects) == "project/nested");
		assert(findOpenProjectName(targetFromReal, projects) == "project/nested");
	}
}
