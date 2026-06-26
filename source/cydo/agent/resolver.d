module cydo.agent.resolver;

import std.conv : to;

import cydo.agent.contract : Agent;
import cydo.agent.drivers.registry : agentRegistry;
import cydo.runtime.config : AgentConfig, AgentDriver, CydoConfig;

struct ResolvedAgent
{
	string name;
	AgentConfig config;
	AgentDriver driver;
}

ResolvedAgent resolveConfiguredAgent(ref CydoConfig config, string agentName)
{
	auto ac = agentName in config.agents;
	if (!ac)
		throw new Exception("Unknown configured agent: " ~ agentName);
	if (!ac.driver.set)
		throw new Exception("Configured agent is missing a driver: " ~ agentName);
	return ResolvedAgent(agentName, *ac, ac.driver.value);
}

bool isConfiguredAgentName(ref CydoConfig config, string agentName)
{
	return (agentName in config.agents) !is null;
}

Agent createAgentByDriver(AgentDriver driver)
{
	auto driverName = to!string(driver);
	foreach (ref entry; agentRegistry)
		if (entry.name == driverName)
			return entry.create();
	throw new Exception("Unknown driver: " ~ driverName);
}

Agent createConfiguredAgent(ref CydoConfig config, string agentName)
{
	auto resolved = resolveConfiguredAgent(config, agentName);
	return createAgentByDriver(resolved.driver);
}

Agent tryCreateConfiguredAgent(ref CydoConfig config, string agentName)
{
	if (!isConfiguredAgentName(config, agentName))
		return null;
	return createConfiguredAgent(config, agentName);
}

string effectiveDefaultAgentName(ref CydoConfig config, string workspaceName = "")
{
	if (workspaceName.length > 0)
	{
		foreach (ref ws; config.workspaces)
			if (ws.name == workspaceName && ws.default_agent.length > 0)
			{
				if (!isConfiguredAgentName(config, ws.default_agent))
					throw new Exception("Workspace '" ~ workspaceName
						~ "' default_agent references unknown configured agent: "
						~ ws.default_agent);
				return ws.default_agent;
			}
	}

	if (config.default_agent.length > 0)
	{
		if (!isConfiguredAgentName(config, config.default_agent))
			throw new Exception("default_agent references unknown configured agent: "
				~ config.default_agent);
		return config.default_agent;
	}

	if (isConfiguredAgentName(config, "claude"))
		return "claude";

	string[] claudeAgentNames;
	foreach (name, ref ac; config.agents)
	{
		if (!ac.driver.set)
			throw new Exception("Configured agent is missing a driver: " ~ name);
		if (ac.driver.value == AgentDriver.claude)
			claudeAgentNames ~= name;
	}

	if (claudeAgentNames.length == 1)
		return claudeAgentNames[0];
	if (claudeAgentNames.length > 1)
		throw new Exception("Multiple Claude-configured agents exist; set default_agent explicitly");

	throw new Exception("No default agent could be resolved");
}

string displayNameForDriver(AgentDriver driver)
{
	auto driverName = to!string(driver);
	foreach (ref entry; agentRegistry)
		if (entry.name == driverName)
			return entry.displayName;
	return driverName;
}

unittest
{
	CydoConfig config;
	AgentConfig workClaude;
	workClaude.driver = typeof(workClaude.driver)(AgentDriver.claude, true);
	config.agents["work-claude"] = workClaude;

	auto resolved = resolveConfiguredAgent(config, "work-claude");
	assert(resolved.name == "work-claude");
	assert(resolved.driver == AgentDriver.claude);
	assert(resolved.config.driver.set);
	assert(resolved.config.driver.value == AgentDriver.claude);
}

unittest
{
	CydoConfig config;
	try
	{
		resolveConfiguredAgent(config, "missing");
		assert(false, "expected resolveConfiguredAgent to throw");
	}
	catch (Exception e)
		assert(e.msg == "Unknown configured agent: missing");
}
