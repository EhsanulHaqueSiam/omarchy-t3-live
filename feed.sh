#!/bin/sh
# Streams this machine's live T3 Code threads, one JSON line per change:
#   {"env":"<environmentId>","threads":[{
#     "id","title","project",
#     "state",      starting | working | input (a question) | perm (an approval) |
#                   waiting (T3's "Waiting": its turn ended but it still watches a
#                   pull request or has background work, or it waits on another
#                   thread) | done | failed | limited (stopped at a usage limit)
#     "failure",    {class, message, retryable, resetAt} for failed and limited
#     "recovery",   T3's own {autoResume, snooze} for this limit, when armed
#     "askKind",    the pending request's kind, for input and perm
#     "question",   what an input thread asks
#     "permDetail", the command or file a perm thread asks about
#     "step",       [type, detail] of a working thread's latest item, or of what
#                   a waiting one waits on
#     "pr",         {n, state, checks, review} of its newest pull request
#     "issue",      its first linked issue, as T3 shows it ("#40471")
#     "projectColor" the project's T3 icon color name ("gray", "blue", ...)
#     "since",      when the run (or the pending request) started
#     "ended"}]}    when the run ended. Done threads stay listed for 2 minutes;
#                   failed ones for 12 hours, limited ones until 12 hours past
#                   their reset (so a resume planned for the reset still fires),
#                   until settled or resumed, and not while T3 snoozes them
# Run it locally with `sh feed.sh`, or on another machine with
# `ssh <host> sh -s < feed.sh`. Pass `once` to print the current state and exit.
# It only reads T3's database, opened read-only.
data="${T3CODE_HOME:-$HOME/.t3}/userdata"
db="$data/statev2.sqlite"
env=$(cat "$data/environment-id" 2>/dev/null)
case "$env" in *[!0-9a-fA-F-]*|"") echo "feed.sh: no T3 Code data in $data" >&2; exit 1 ;; esac
command -v sqlite3 >/dev/null || { echo "feed.sh: sqlite3 is not installed" >&2; exit 1; }

sql="
WITH live AS (
  SELECT thread_id, min(coalesce(json_extract(payload_json, '\$.startedAt'), requested_at)) AS since,
         max(status IN ('running', 'waiting')) AS running
  FROM orchestration_v2_projection_runs
  WHERE status IN ('queued', 'preparing', 'starting', 'running', 'waiting')
  GROUP BY thread_id
), blocked AS (
  -- T3's deriveBlockedOnThreadWait: a running turn whose only running work
  -- waits on another thread (t3_thread_wait, or delegate_task in wait mode).
  SELECT i.thread_id
  FROM orchestration_v2_projection_turn_items i
  JOIN orchestration_v2_projection_runs r ON r.run_id = i.run_id AND r.status = 'running'
  -- Written so SQLite can use T3's partial index on active items.
  WHERE i.status IN ('pending', 'running', 'waiting') AND i.status <> 'pending'
    AND i.type IN ('command_execution', 'dynamic_tool', 'subagent', 'file_change', 'file_search', 'web_search', 'compaction')
    AND NOT (i.type = 'subagent' AND json_extract(i.payload_json, '\$.origin') = 'app_owned')
  GROUP BY i.thread_id
  -- T3's own tool, under T3's server names as written (shortcut: T3 also
  -- accepts other casings of the server name and looser ACP prefixes; only
  -- mcp__t3-code__ appears in practice, upgrade if T3 starts writing others).
  -- Every other item counts as 0, never NULL, so it always breaks the wait.
  HAVING min(coalesce(i.type = 'dynamic_tool' AND (json_extract(i.payload_json, '\$.toolName') IN ('t3_thread_wait', 'mcp__t3-code__t3_thread_wait', 'mcp__t3_code__t3_thread_wait', 'mcp__t3code__t3_thread_wait', 'mcp__t3-code-direct__t3_thread_wait', 'mcp__t3_code_direct__t3_thread_wait', 't3-code.t3_thread_wait', 't3-code:t3_thread_wait', 't3-code/t3_thread_wait', 't3_code.t3_thread_wait', 't3_code:t3_thread_wait', 't3_code/t3_thread_wait', 't3code.t3_thread_wait', 't3code:t3_thread_wait', 't3code/t3_thread_wait', 't3-code-direct.t3_thread_wait', 't3-code-direct:t3_thread_wait', 't3-code-direct/t3_thread_wait', 't3_code_direct.t3_thread_wait', 't3_code_direct:t3_thread_wait', 't3_code_direct/t3_thread_wait', 't3-code · t3_thread_wait', 't3_code · t3_thread_wait', 't3code · t3_thread_wait', 't3-code-direct · t3_thread_wait', 't3_code_direct · t3_thread_wait')
    OR (json_extract(i.payload_json, '\$.toolName') IN ('delegate_task', 'mcp__t3-code__delegate_task', 'mcp__t3_code__delegate_task', 'mcp__t3code__delegate_task', 'mcp__t3-code-direct__delegate_task', 'mcp__t3_code_direct__delegate_task', 't3-code.delegate_task', 't3-code:delegate_task', 't3-code/delegate_task', 't3_code.delegate_task', 't3_code:delegate_task', 't3_code/delegate_task', 't3code.delegate_task', 't3code:delegate_task', 't3code/delegate_task', 't3-code-direct.delegate_task', 't3-code-direct:delegate_task', 't3-code-direct/delegate_task', 't3_code_direct.delegate_task', 't3_code_direct:delegate_task', 't3_code_direct/delegate_task', 't3-code · delegate_task', 't3_code · delegate_task', 't3code · delegate_task', 't3-code-direct · delegate_task', 't3_code_direct · delegate_task') AND json_extract(i.payload_json, '\$.input.mode') = 'wait')), 0)) = 1
), pend AS (
  -- T3's pending background work (derivePendingBackgroundWork), only what
  -- holds the thread's completion (backgroundWorkHoldsCompletion, which the
  -- sidebar's "Waiting" uses): subagents and background tool calls always; a
  -- command or monitor only when the agent marked it awaited (a dev server
  -- left running is not a wait); a pull request watch while its checks run or
  -- it waits for the merge. prio picks the one a row shows.
  SELECT i.thread_id, 1 AS prio, json_array(i.type, coalesce(CASE i.type
      WHEN 'dynamic_tool' THEN json_extract(i.payload_json, '\$.toolName')
      WHEN 'subagent' THEN substr(json_extract(i.payload_json, '\$.title'), 1, 120)
    END, '')) AS step
  FROM orchestration_v2_projection_turn_items i
  WHERE i.type IN ('dynamic_tool', 'subagent') AND i.status IN ('pending', 'running', 'waiting')
    AND NOT (i.type = 'dynamic_tool' AND json_extract(i.payload_json, '\$.input.persistent') IS 1)
    AND coalesce((SELECT r.status FROM orchestration_v2_projection_runs r WHERE r.run_id = i.run_id), '') <> 'rolled_back'
  UNION ALL
  SELECT pt.thread_id, 2, json_array('background', replace(substr(coalesce(json_extract(b.value, '\$.description'), ''), 1, 160), char(10), ' '))
  FROM orchestration_v2_projection_provider_threads pt
  JOIN orchestration_v2_projection_threads t ON t.thread_id = pt.thread_id
  JOIN json_each(pt.payload_json, '\$.pendingBackgroundTasks') b
  WHERE coalesce(json_extract(t.payload_json, '\$.activeProviderThreadId'), pt.provider_thread_id) = pt.provider_thread_id
    AND (json_extract(b.value, '\$.awaited') IS 1 OR json_extract(b.value, '\$.kind') IN ('subagent', 'background_task'))
  UNION ALL
  SELECT t.thread_id, 0, json_array('watch_pr', CAST(json_extract(w.value, '\$.number') AS TEXT))
  FROM orchestration_v2_projection_threads t
  JOIN json_each(t.payload_json, '\$.pullRequests') w
  WHERE json_extract(w.value, '\$.watch') IS NOT NULL AND coalesce(json_extract(w.value, '\$.source'), '') <> 'stack-dismissed'
    AND (json_type(w.value, '\$.watch.checksPending') IS NOT 'false' OR json_extract(w.value, '\$.watch.until') IS 'merged'
      OR json_extract(w.value, '\$.snapshot.state') IS 'merged')
    AND t.deleted_at IS NULL AND t.archived_at IS NULL
), waits AS (
  -- A turn that ended with pending work is waiting, not done (T3 says
  -- "Waiting" and holds the completion). A failed one still shows as failed.
  SELECT r.run_id, r.thread_id, r.completed_at AS since
  FROM orchestration_v2_projection_runs r
  WHERE r.thread_id IN (SELECT thread_id FROM pend) AND r.thread_id NOT IN (SELECT thread_id FROM live)
    AND r.status IN ('completed', 'cancelled', 'interrupted')
    AND r.ordinal = (SELECT max(o.ordinal) FROM orchestration_v2_projection_runs o
                     WHERE o.thread_id = r.thread_id AND o.status <> 'queued')
  UNION ALL
  -- A thread that never ran can still wait on a pull request watch.
  SELECT NULL, t.thread_id, json_extract(t.payload_json, '\$.updatedAt')
  FROM orchestration_v2_projection_threads t
  WHERE t.thread_id IN (SELECT thread_id FROM pend WHERE prio = 0)
    AND NOT EXISTS (SELECT 1 FROM orchestration_v2_projection_runs o WHERE o.thread_id = t.thread_id AND o.status <> 'queued')
    -- Its queued first run already shows it as starting.
    AND t.thread_id NOT IN (SELECT thread_id FROM live)
), waitdone AS (
  -- A wait that ended: a background item finished after the turn did (5 s
  -- later, so the turn's own last writes don't count). Its thread is done for
  -- 2 minutes from then, like any finish; an archived one never gets here.
  -- Only items that could have held it (as in pend): no persistent tools, no
  -- rolled-back runs.
  -- shortcut: only turns that ended in the last 24 h are checked, which keeps
  -- each poll cheap; a longer wait ends without a Done. So does a wait that
  -- is released without a new turn (an awaited provider task or a PR watch
  -- that ends without waking the agent); T3 usually wakes it, and that turn
  -- brings the Done.
  -- Work that was cancelled (a T3 restart, Stop) ended nothing: no Done. The
  -- first finish after the turn is the Done's time, so a later one in the same
  -- 2 minutes can't change its key and toast again.
  SELECT r.thread_id, min(i.updated_at) AS at
  FROM orchestration_v2_projection_runs r
  JOIN orchestration_v2_projection_turn_items i ON i.thread_id = r.thread_id
    AND i.type IN ('dynamic_tool', 'subagent') AND i.status IN ('completed', 'failed')
    AND NOT (i.type = 'dynamic_tool' AND json_extract(i.payload_json, '\$.input.persistent') IS 1)
    AND coalesce((SELECT x.status FROM orchestration_v2_projection_runs x WHERE x.run_id = i.run_id), '') <> 'rolled_back'
    AND i.updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-120 seconds')
    AND i.updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', r.completed_at, '+5 seconds')
  WHERE r.status = 'completed' AND r.completed_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-24 hours')
    AND r.ordinal = (SELECT max(o.ordinal) FROM orchestration_v2_projection_runs o
                     WHERE o.thread_id = r.thread_id AND o.status <> 'queued')
  GROUP BY r.thread_id
), ended AS (
  -- Only a thread's latest run counts: a failure an earlier run had is history.
  SELECT r.run_id, r.thread_id, r.status, coalesce(json_extract(r.payload_json, '\$.startedAt'), r.requested_at) AS since,
         coalesce((SELECT w.at FROM waitdone w WHERE w.thread_id = r.thread_id AND r.status = 'completed'), r.completed_at) AS ended
  FROM orchestration_v2_projection_runs r
  WHERE r.ordinal = (SELECT max(o.ordinal) FROM orchestration_v2_projection_runs o
                     WHERE o.thread_id = r.thread_id AND o.status <> 'queued')
    AND ((r.status = 'completed' AND (r.completed_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-120 seconds')
        OR r.thread_id IN (SELECT thread_id FROM waitdone)))
      OR (r.status = 'failed' AND (r.completed_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-12 hours')
        -- A usage limit stays until 12 hours past its reset, so a resume planned for then fires.
        OR EXISTS (SELECT 1 FROM orchestration_v2_projection_turn_items i
          WHERE i.thread_id = r.thread_id AND i.run_id = r.run_id AND i.type = 'error' AND i.status = 'failed'
            AND json_extract(i.payload_json, '\$.failure.resetAt') > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-12 hours')))))
    AND r.thread_id NOT IN (SELECT thread_id FROM live) AND r.thread_id NOT IN (SELECT thread_id FROM waits)
), act AS (
  SELECT thread_id, since, NULL AS ended, CASE WHEN thread_id IN (SELECT thread_id FROM blocked) THEN 'blocked' END AS outcome,
    running, NULL AS run_id FROM live
  UNION ALL
  SELECT thread_id, since, NULL, 'waiting', 1, run_id FROM waits
  UNION ALL
  SELECT thread_id, since, ended, status, 1, run_id FROM ended
), ask AS (
  -- SQLite takes the bare columns from the row holding min(created_at).
  SELECT thread_id, runtime_request_id, node_id, kind, min(created_at) AS since
  FROM orchestration_v2_projection_runtime_requests
  WHERE status = 'pending' AND kind <> 'dynamic_tool_call'
  GROUP BY thread_id
), rows AS (
  SELECT t.thread_id AS id, t.title, coalesce(p.title, '') AS project,
    coalesce(json_extract(p.project_icon_json, '\$.color'), '') AS projectColor,
    coalesce(json_extract(t.payload_json, '\$.issues[0].displayKey'), '') AS issue,
    (SELECT json_extract(i.payload_json, '\$.failure')
      FROM orchestration_v2_projection_turn_items i
      WHERE x.outcome = 'failed' AND i.thread_id = t.thread_id AND i.run_id = x.run_id
        AND i.type = 'error' AND i.status = 'failed'
      ORDER BY i.ordinal DESC LIMIT 1) AS failure,
    CASE WHEN json_extract(t.payload_json, '\$.limitRecovery.runId') = x.run_id
      THEN json_object('autoResume', json(CASE WHEN json_extract(t.payload_json, '\$.limitRecovery.autoResume') THEN 'true' ELSE 'false' END),
                       'snooze', json(CASE WHEN json_extract(t.payload_json, '\$.limitRecovery.snooze') THEN 'true' ELSE 'false' END))
    END AS recovery,
    CASE
      WHEN x.outcome = 'completed' THEN 'done'
      WHEN x.outcome = 'failed' THEN 'failed'
      WHEN a.kind IN ('command', 'file-read', 'file-change', 'permission') THEN 'perm'
      WHEN a.thread_id IS NOT NULL THEN 'input'
      WHEN x.outcome IN ('waiting', 'blocked') THEN 'waiting'
      WHEN x.running = 0 THEN 'starting'
      ELSE 'working'
    END AS state,
    coalesce(a.kind, '') AS askKind,
    -- The approval's own item (the request node's parent), not just the latest one.
    CASE WHEN a.kind IN ('command', 'file-read', 'file-change', 'permission') THEN coalesce((
      SELECT replace(replace(substr(coalesce(json_extract(i.payload_json, '\$.input'), json_extract(i.payload_json, '\$.fileName'), ''), 1, 160), char(10), ' '), char(13), ' ')
      FROM orchestration_v2_projection_turn_items i
      WHERE i.thread_id = t.thread_id
        AND i.node_id = (SELECT json_extract(n.payload_json, '\$.parentNodeId') FROM orchestration_v2_projection_nodes n WHERE n.node_id = a.node_id)
      LIMIT 1), '') ELSE '' END AS permDetail,
    coalesce(a.since, x.since) AS since,
    coalesce(x.ended, '') AS ended,
    CASE WHEN a.kind = 'user_input' THEN coalesce((
      SELECT json_extract(i.payload_json, '\$.questions[0].question')
      FROM orchestration_v2_projection_turn_items i
      WHERE i.thread_id = t.thread_id AND i.type = 'user_input_request'
        AND json_extract(i.payload_json, '\$.requestId') = a.runtime_request_id
    ), '') ELSE '' END AS question,
    CASE WHEN x.outcome = 'waiting' THEN (SELECT p.step FROM pend p WHERE p.thread_id = t.thread_id ORDER BY p.prio LIMIT 1)
      WHEN x.outcome = 'blocked' THEN json_array('wait_thread', '')
      WHEN x.ended IS NULL THEN (
      SELECT json_array(i.type, coalesce(CASE i.type
        WHEN 'command_execution' THEN replace(replace(substr(json_extract(i.payload_json, '\$.input'), 1, 160), char(10), ' '), char(13), ' ')
        WHEN 'file_change' THEN substr(json_extract(i.payload_json, '\$.fileName'), -120)
        WHEN 'dynamic_tool' THEN json_extract(i.payload_json, '\$.toolName')
        WHEN 'subagent' THEN substr(json_extract(i.payload_json, '\$.title'), 1, 120)
      END, ''))
      FROM orchestration_v2_projection_turn_items i
      WHERE i.thread_id = t.thread_id
      ORDER BY i.ordinal DESC LIMIT 1
    ) END AS step,
    (SELECT json_object('n', json_extract(value, '\$.number'),
        'state', json_extract(value, '\$.snapshot.state'),
        'checks', json_extract(value, '\$.snapshot.checksState'),
        'review', json_extract(value, '\$.snapshot.reviewDecision'))
      FROM json_each(t.payload_json, '\$.pullRequests')
      ORDER BY json_extract(value, '\$.linkedAt') DESC LIMIT 1) AS pr
  FROM orchestration_v2_projection_threads t
  JOIN act x ON x.thread_id = t.thread_id
  LEFT JOIN ask a ON a.thread_id = t.thread_id AND x.ended IS NULL
  LEFT JOIN projection_projects p ON p.project_id = t.project_id
  WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
    AND coalesce(json_extract(t.payload_json, '\$.lineage.relationshipToParent'), '') <> 'subagent'
    -- A failed thread leaves once settled, and hides while T3 has it snoozed.
    AND (x.outcome IS NOT 'failed' OR (json_extract(t.payload_json, '\$.settledAt') IS NULL
      AND coalesce(json_extract(t.payload_json, '\$.snoozedUntil'), '') < strftime('%Y-%m-%dT%H:%M:%fZ', 'now')))
  -- Most urgent first, so the cap never drops a question for a finished thread.
  ORDER BY CASE WHEN state IN ('input', 'perm') THEN 0 WHEN state = 'failed' THEN 1
                WHEN state IN ('working', 'starting') THEN 2 WHEN state = 'waiting' THEN 3 ELSE 4 END, since DESC
  LIMIT 50
)
SELECT json_group_array(json_object('id', id, 'title', substr(title, 1, 120),
  'project', substr(project, 1, 60), 'projectColor', substr(projectColor, 1, 16), 'issue', substr(issue, 1, 24),
  'state', CASE WHEN state = 'failed' AND json_extract(failure, '\$.class') = 'usage_limit' THEN 'limited' ELSE state END,
  'askKind', askKind, 'permDetail', permDetail,
  'failure', CASE WHEN failure IS NULL THEN NULL ELSE json_object('class', json_extract(failure, '\$.class'),
    'message', substr(json_extract(failure, '\$.message'), 1, 200), 'resetAt', json_extract(failure, '\$.resetAt')) END,
  'recovery', json(recovery),
  'question', substr(question, 1, 300), 'step', json(step), 'pr', json(pr),
  'since', since, 'ended', ended)) FROM rows;"

last=
tick=0
fails=0
while :; do
  # A busy database waits up to 2 s. A query that keeps failing (T3 changed
  # its schema, the file is gone) ends the feed, so the bar shows this machine
  # as out of date instead of its last snapshot as if it were live.
  if rows=$(sqlite3 -readonly -noheader -cmd ".timeout 2000" "file:$db?mode=ro" "$sql" </dev/null 2>/dev/null) && [ -n "$rows" ]; then
    fails=0
  else
    fails=$((fails + 1))
    [ "$fails" -ge 3 ] && { echo "feed.sh: cannot read $db" >&2; exit 2; }
    rows=$last
  fi
  if [ -n "$rows" ] && [ "$rows" != "$last" ]; then
    printf '{"env":"%s","threads":%s}\n' "$env" "$rows" || exit 0
    last=$rows
  fi
  [ "$1" = once ] && exit 0
  # A blank line every 30 s: once the reader (the bar, or ssh) is gone the
  # write fails and the loop ends instead of running on the remote host.
  tick=$((tick + 1))
  [ $((tick % 15)) -eq 0 ] && { printf '\n' || exit 0; }
  sleep 2
done
