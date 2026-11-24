#!/bin/sh
# Streams this machine's live T3 Code threads, one JSON line per change:
#   {"env":"<environmentId>","threads":[{
#     "id","title","project",
#     "state",      starting | working | input (a question) | perm (an approval) | done | failed
#     "askKind",    the pending request's kind, for input and perm
#     "question",   what an input thread asks
#     "step",       [type, detail] of a working thread's latest item
#     "pr",         {n, state, checks, review} of its newest pull request
#     "since",      when the run (or the pending request) started
#     "ended"}]}    when a done or failed run ended; those stay listed for 2 minutes
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
), ended AS (
  -- SQLite takes the bare columns from the row holding max(completed_at).
  SELECT thread_id, status, coalesce(json_extract(payload_json, '\$.startedAt'), requested_at) AS since,
         max(completed_at) AS ended
  FROM orchestration_v2_projection_runs
  WHERE status IN ('completed', 'failed')
    AND completed_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-120 seconds')
    AND thread_id NOT IN (SELECT thread_id FROM live)
  GROUP BY thread_id
), act AS (
  SELECT thread_id, since, NULL AS ended, NULL AS outcome, running FROM live
  UNION ALL
  SELECT thread_id, since, ended, status, 1 FROM ended
), ask AS (
  SELECT thread_id, runtime_request_id, kind, min(created_at) AS since
  FROM orchestration_v2_projection_runtime_requests
  WHERE status = 'pending' AND kind <> 'dynamic_tool_call'
  GROUP BY thread_id
), rows AS (
  SELECT t.thread_id AS id, t.title, coalesce(p.title, '') AS project,
    CASE
      WHEN x.outcome = 'completed' THEN 'done'
      WHEN x.outcome = 'failed' THEN 'failed'
      WHEN a.kind IN ('command', 'file-read', 'file-change', 'permission') THEN 'perm'
      WHEN a.thread_id IS NOT NULL THEN 'input'
      WHEN x.running = 0 THEN 'starting'
      ELSE 'working'
    END AS state,
    coalesce(a.kind, '') AS askKind,
    coalesce(a.since, x.since) AS since,
    coalesce(x.ended, '') AS ended,
    CASE WHEN a.kind = 'user_input' THEN coalesce((
      SELECT json_extract(i.payload_json, '\$.questions[0].question')
      FROM orchestration_v2_projection_turn_items i
      WHERE i.thread_id = t.thread_id AND i.type = 'user_input_request'
        AND json_extract(i.payload_json, '\$.requestId') = a.runtime_request_id
    ), '') ELSE '' END AS question,
    CASE WHEN x.ended IS NULL THEN (
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
  LIMIT 50
)
SELECT json_group_array(json_object('id', id, 'title', substr(title, 1, 120),
  'project', substr(project, 1, 60), 'state', state, 'askKind', askKind,
  'question', substr(question, 1, 300), 'step', json(step), 'pr', json(pr),
  'since', since, 'ended', ended)) FROM rows;"

last=
tick=0
while :; do
  rows=$(sqlite3 -readonly -noheader "file:$db?mode=ro" "$sql" </dev/null 2>/dev/null)
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
