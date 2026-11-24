#!/bin/sh
# Streams this machine's live T3 Code threads, one JSON line per change:
#   {"env":"<environmentId>","threads":[{"id","title","project","input","question","since"}]}
# "input" is 1 when the thread waits on the user; "question" is what it asks.
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
  SELECT thread_id, min(coalesce(json_extract(payload_json, '\$.startedAt'), requested_at)) AS since
  FROM orchestration_v2_projection_runs
  WHERE status IN ('queued', 'preparing', 'starting', 'running', 'waiting')
  GROUP BY thread_id
), ask AS (
  SELECT thread_id, runtime_request_id, kind, min(created_at) AS since
  FROM orchestration_v2_projection_runtime_requests
  WHERE status = 'pending'
  GROUP BY thread_id
), rows AS (
  SELECT t.thread_id AS id, t.title, coalesce(p.title, '') AS project,
         a.thread_id IS NOT NULL AS input, coalesce(a.since, l.since) AS since,
         CASE WHEN a.thread_id IS NULL THEN '' ELSE coalesce((
           SELECT json_extract(i.payload_json, '\$.questions[0].question')
           FROM orchestration_v2_projection_turn_items i
           WHERE i.thread_id = a.thread_id AND i.type = 'user_input_request'
             AND json_extract(i.payload_json, '\$.requestId') = a.runtime_request_id
         ), '') END AS question
  FROM orchestration_v2_projection_threads t
  JOIN live l ON l.thread_id = t.thread_id
  LEFT JOIN ask a ON a.thread_id = t.thread_id
  LEFT JOIN projection_projects p ON p.project_id = t.project_id
  WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
    AND coalesce(json_extract(t.payload_json, '\$.lineage.relationshipToParent'), '') <> 'subagent'
  ORDER BY input DESC, since DESC
  LIMIT 50
)
SELECT json_group_array(json_object('id', id, 'title', substr(title, 1, 120),
  'project', substr(project, 1, 60), 'input', input,
  'question', substr(question, 1, 300), 'since', since)) FROM rows;"

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
