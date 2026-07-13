module cydo.workflow.tasks.subtask_delivery;

import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.logger : errorf, infof, tracef, warningf;
import std.process : execute;
import std.range : retro;
import std.string : splitLines, strip;

import ae.utils.json : toJson;
import ae.utils.promise : Promise;

import cydo.domain.tasks.model : TaskData, TaskStatus;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.foundation.system.known_messages : KnownSystemMessageKind;
import cydo.mcp : McpResult;
import cydo.mcp.payloads : TaskResult;

package(cydo):

struct SubtaskResultDeliveryHost
{
	TaskData* delegate(int tid) getTask;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) worktreePath;
	bool delegate(string projectPath, string taskTypeName) taskProducesCommitOutput;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;
	void delegate(int tid, string resultText) persistResultText;
	bool delegate(int tid, out Promise!(McpResult) pending) readPendingSubTask;
	void delegate(int tid) clearPendingSubTask;
	int delegate(int childTid) parentTaskForChild;
	int[] delegate(int parentTid) childTaskIds;
	bool delegate(int childTid) wasLiveDelivered;
	void delegate(int childTid) markLiveDelivered;
	Promise!void delegate(int tid) ensureProcessQueueAlive;
	bool delegate(int tid, out string sessionState) canSendSystemMessage;
	void delegate(int tid, KnownSystemMessageKind kind, string body) sendKnownSystemMessage;
	void delegate(int parentTid, int childTid) removeTaskDependency;
	bool delegate(int tid) taskAlive;
	void delegate(void delegate() cb) onNextTick;
}

class SubtaskResultDelivery
{
private:
	SubtaskResultDeliveryHost host_;

public:
	this(SubtaskResultDeliveryHost host)
	{
		host_ = host;
	}

	bool finalizeCompletedSubTask(int childTid, bool eagerDepCleanup = false)
	{
		import ae.utils.json : toJson;

		auto td = host_.getTask(childTid);
		if (td is null)
			return false;

		host_.persistResultText(childTid, td.resultText);
		host_.transitionTaskFrom(childTid,
			[TaskStatus.active, TaskStatus.alive, TaskStatus.waiting],
			TaskStatus.completed, TaskNotificationChange.preserve);

		Promise!(McpResult) pending;
		if (!host_.readPendingSubTask(childTid, pending))
			return false;

		auto taskResult = buildTaskResult(childTid);
		auto resultJson = toJson(taskResult);
		pending.fulfill(McpResult.structured(resultJson));
		host_.clearPendingSubTask(childTid);

		// Early result delivery can race onExit for agents with synchronous stdin
		// close. Record this child so onExit does not trigger duplicate fallback.
		if (eagerDepCleanup)
			host_.markLiveDelivered(childTid);

		return true;
	}

	bool deliverFailedPendingSubTaskResult(int tid)
	{
		import ae.utils.json : toJson;

		Promise!(McpResult) pending;
		if (!host_.readPendingSubTask(tid, pending))
			return false;

		auto taskResult = buildTaskResult(tid);
		auto resultJson = toJson(taskResult);
		pending.fulfill(McpResult.structured(resultJson, true));
		host_.clearPendingSubTask(tid);
		return true;
	}

	void deliverWaitingParentResultsIfReady(int tid)
	{
		auto parentTid = host_.parentTaskForChild(tid);
		if (parentTid <= 0)
			return;

		if (host_.wasLiveDelivered(tid))
		{
			tracef("onExit Branch B: child tid=%d already delivered to live batch, skipping fallback",
				tid);
			return;
		}

		auto td = requireTask(tid, "Completed child task must exist while delivering parent fallback results");
		tracef("onExit Branch B: child tid=%d (status=%s) finished, parent tid=%d",
			tid, td.status, parentTid);

		if (host_.getTask(parentTid) is null)
		{
			tracef("onExit Branch B: parent tid=%d not in tasks", parentTid);
			return;
		}

		foreach (childTid; host_.childTaskIds(parentTid))
		{
			auto child = host_.getTask(childTid);
			if (child !is null
				&& child.status != "completed"
				&& child.status != "failed")
			{
				tracef("onExit Branch B: sibling tid=%d still %s, deferring batch delivery",
					childTid, child.status);
				return;
			}
		}

		deliverBatchResults(parentTid);
	}

	void deliverBatchFallbackIfReady(int parentTid)
	{
		if (host_.getTask(parentTid) is null)
			return;

		auto children = host_.childTaskIds(parentTid);
		if (children.length == 0)
			return;

		foreach (childTid; children)
		{
			auto child = host_.getTask(childTid);
			if (child !is null
				&& child.status != "completed"
				&& child.status != "failed")
				return;
		}

		deliverBatchResults(parentTid);
	}

	void deliverBatchResults(int parentTid)
	{
		if (host_.getTask(parentTid) is null)
			return;

		host_.ensureProcessQueueAlive(parentTid).then(() {
			actuallyDeliverBatchResults(parentTid);
		}).except((Exception e) {
			errorf("deliverBatchResults: failed for parent %d: %s", parentTid, e.msg);
		});
	}

	void sendSystemRestartNudge(int tid)
	{
		if (host_.getTask(tid) is null)
			return;

		host_.onNextTick(() {
			if (host_.getTask(tid) is null)
				return;
			if (!host_.taskAlive(tid))
				return;

			enum nudgeBody = "Your session was interrupted by a backend restart. "
				~ "Continue from where you left off. If you had a tool call in progress "
				~ "(Task, Handoff, SwitchMode, or any other tool), retry it.";
			host_.sendKnownSystemMessage(tid, KnownSystemMessageKind.restartNudge,
				nudgeBody);
		});
	}

private:
	TaskResult buildTaskResult(int tid)
	{
		auto td = requireTask(tid, "Task must exist when building sub-task result");
		auto tdOut = host_.outputPath(td);
		bool hasOutput = tdOut.length > 0 && exists(tdOut);
		bool hasWorktree = td.hasWorktree;
		bool isFailed = td.status == "failed";
		auto summary = td.resultText;
		auto talkNote = " Use mcp__cydo__Ask(question, " ~ to!string(tid) ~ ") to ask follow-up questions.";
		string note;
		if (hasOutput && hasWorktree)
			note = "Read the output file for full findings. The worktree path is included for adopting changes." ~ talkNote;
		else if (hasOutput)
			note = "Read the output file for full findings." ~ talkNote;
		else if (hasWorktree)
			note = "The worktree contains the implementation." ~ talkNote;

		auto result = TaskResult(
			summary: summary,
			output_file: hasOutput ? tdOut : null,
			worktree: hasWorktree ? host_.worktreePath(td) : null,
			note: note.length > 0 ? note : td.resultNote,
			error: isFailed ? summary : null,
			status: isFailed ? "error" : "success",
		);
		result.tid = tid;

		if (host_.taskProducesCommitOutput(td.projectPath, td.taskType) && td.hasWorktree)
		{
			if (td.taskStartHead.length == 0)
			{
				warningf("Task %d has no task start HEAD; commit list is unavailable for pre-upgrade task", tid);
				result.commits = ["(not available - check git log)"];
				note = "The commit list is unavailable for this pre-upgrade task. Check git log in the worktree." ~ talkNote;
			}
			else
			{
				auto logResult = execute(["git", "-C", host_.worktreePath(td),
					"log", "--format=%H", td.taskStartHead ~ "..HEAD"]);
				enforce(logResult.status == 0,
					"Failed to collect commits for task " ~ to!string(tid)
					~ " (git status " ~ to!string(logResult.status) ~ "): "
					~ logResult.output.strip);
				if (logResult.output.strip.length > 0)
					result.commits = logResult.output.strip.splitLines;
				if (result.commits.length > 0)
					note = "Cherry-pick commits from the worktree: git cherry-pick "
						~ result.commits.retro.join(" ") ~ talkNote;
			}
			result.note = note.length > 0 ? note : td.resultNote;
		}

		return result;
	}

	void actuallyDeliverBatchResults(int parentTid)
	{
		import ae.utils.json : toJson;

		if (host_.getTask(parentTid) is null)
		{
			tracef("deliverBatchResults: parent tid=%d not in tasks, skipping", parentTid);
			return;
		}

		string sessionState;
		if (!host_.canSendSystemMessage(parentTid, sessionState))
		{
			warningf("actuallyDeliverBatchResults: parent tid=%d session %s, retrying via deliverBatchResults",
				parentTid, sessionState);
			deliverBatchResults(parentTid);
			return;
		}

		auto children = host_.childTaskIds(parentTid);
		if (children.length == 0)
		{
			tracef("deliverBatchResults: parent tid=%d has no children in taskDeps", parentTid);
			return;
		}

		string[] resultJsons;
		foreach (childTid; children)
		{
			if (host_.getTask(childTid) is null)
				continue;
			resultJsons ~= toJson(buildTaskResult(childTid));
		}

		if (resultJsons.length == 0)
			return;

		infof("deliverBatchResults: delivering %d result(s) to parent tid=%d",
			resultJsons.length, parentTid);

		auto resultsArray = "[" ~ resultJsons.join(",") ~ "]";
		auto body = "The following sub-task(s) completed while your session was interrupted. "
			~ "Their results are provided below exactly as they would have been "
			~ "returned by the Task tool.\n\n"
			~ "<task_results>\n" ~ resultsArray ~ "\n</task_results>\n\n"
			~ "Continue from where you left off. Process these results as if they "
			~ "were returned normally by the Task tool.";
		auto td = requireTask(parentTid,
			"Parent task must exist after sub-task batch result delivery");
		if (td.status == TaskStatus.waiting)
			host_.transitionTask(parentTid, TaskStatus.waiting, TaskStatus.alive,
				TaskNotificationChange.preserve);

		host_.sendKnownSystemMessage(parentTid, KnownSystemMessageKind.subTaskResults,
			body);

		foreach (childTid; children)
			host_.removeTaskDependency(parentTid, childTid);
	}

	TaskData* requireTask(int tid, string message)
	{
		auto td = host_.getTask(tid);
		enforce(td !is null, message);
		return td;
	}
}
