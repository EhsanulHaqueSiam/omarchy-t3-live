#!/bin/sh
# sh tests/feed.test.sh: runs feed.sh against a small fixture database with
# only the columns it reads, and checks the states that come from SQL:
# waiting (held work, a blocking wait, a PR watch), Done after a wait, and the
# cases that must not say Done (cancelled work, persistent tools).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/userdata"
echo "aaaaaaaa-0000-4000-8000-000000000001" > "$home/userdata/environment-id"

sqlite3 "$home/userdata/statev2.sqlite" <<'SQL'
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, title TEXT, project_id TEXT, payload_json TEXT, deleted_at TEXT, archived_at TEXT);
CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, ordinal INT, status TEXT, requested_at TEXT, completed_at TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_turn_items (thread_id TEXT, run_id TEXT, node_id TEXT, ordinal INT, type TEXT, status TEXT, updated_at TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_runtime_requests (thread_id TEXT, runtime_request_id TEXT, node_id TEXT, kind TEXT, status TEXT, created_at TEXT);
CREATE TABLE orchestration_v2_projection_nodes (node_id TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT, thread_id TEXT, payload_json TEXT);
CREATE TABLE projection_projects (project_id TEXT, title TEXT, project_icon_json TEXT);

INSERT INTO orchestration_v2_projection_threads (thread_id, title, project_id, payload_json)
SELECT 'eeeeeeee-0000-4000-8000-00000000000' || k, k, 'p', CASE k
  WHEN '7' THEN '{"pullRequests":[{"number":7,"watch":{"checksPending":true},"source":"link"}]}'
  WHEN '8' THEN '{"pullRequests":[{"number":8,"watch":{"checksPending":false},"source":"link"}]}'
  ELSE '{}' END
FROM (SELECT '1' k UNION SELECT '2' UNION SELECT '3' UNION SELECT '4' UNION SELECT '5' UNION SELECT '6' UNION SELECT '7' UNION SELECT '8' UNION SELECT '9');

-- 1 waits on a running subagent; 2 its subagent finished 30 s ago (Done);
-- 3 its only wait was cancelled (no Done, not even the recent turn's);
-- 4 finished 30 s ago with no wait (Done); 5 a persistent tool ended (nothing);
-- 6 blocks on t3_thread_wait (waiting); 9 waits and runs other work (working);
-- 7 watches a PR with checks running (waiting); 8 its checks are done (nothing).
INSERT INTO orchestration_v2_projection_runs VALUES
  ('r1', 'eeeeeeee-0000-4000-8000-000000000001', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-90 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-60 seconds'), '{}'),
  ('r2', 'eeeeeeee-0000-4000-8000-000000000002', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-400 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-300 seconds'), '{}'),
  ('r3', 'eeeeeeee-0000-4000-8000-000000000003', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-90 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-60 seconds'), '{}'),
  ('r4', 'eeeeeeee-0000-4000-8000-000000000004', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-90 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 seconds'), '{}'),
  ('r5', 'eeeeeeee-0000-4000-8000-000000000005', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-400 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-300 seconds'), '{}'),
  ('r6', 'eeeeeeee-0000-4000-8000-000000000006', 1, 'running', strftime('%Y-%m-%dT%H:%M:%fZ','now','-90 seconds'), NULL, '{}'),
  ('r9', 'eeeeeeee-0000-4000-8000-000000000009', 1, 'running', strftime('%Y-%m-%dT%H:%M:%fZ','now','-90 seconds'), NULL, '{}'),
  ('r7', 'eeeeeeee-0000-4000-8000-000000000007', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-400 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-300 seconds'), '{}'),
  ('r8', 'eeeeeeee-0000-4000-8000-000000000008', 1, 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-400 seconds'), strftime('%Y-%m-%dT%H:%M:%fZ','now','-300 seconds'), '{}');
INSERT INTO orchestration_v2_projection_turn_items VALUES
  ('eeeeeeee-0000-4000-8000-000000000001', 'r1', 'n1', 1, 'subagent', 'running', strftime('%Y-%m-%dT%H:%M:%fZ','now','-50 seconds'), '{"title":"Review"}'),
  ('eeeeeeee-0000-4000-8000-000000000002', 'r2', 'n2', 1, 'subagent', 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 seconds'), '{"title":"Review"}'),
  ('eeeeeeee-0000-4000-8000-000000000003', 'r3', 'n3', 1, 'subagent', 'cancelled', strftime('%Y-%m-%dT%H:%M:%fZ','now','-10 seconds'), '{"title":"Review"}'),
  ('eeeeeeee-0000-4000-8000-000000000005', 'r5', 'n5', 1, 'dynamic_tool', 'completed', strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 seconds'), '{"toolName":"monitor","input":{"persistent":true}}'),
  ('eeeeeeee-0000-4000-8000-000000000006', 'r6', 'n6', 1, 'dynamic_tool', 'running', strftime('%Y-%m-%dT%H:%M:%fZ','now','-50 seconds'), '{"toolName":"mcp__t3-code__t3_thread_wait","input":{}}'),
  ('eeeeeeee-0000-4000-8000-000000000009', 'r9', 'n9', 1, 'dynamic_tool', 'running', strftime('%Y-%m-%dT%H:%M:%fZ','now','-50 seconds'), '{"toolName":"mcp__t3-code__t3_thread_wait","input":{}}'),
  ('eeeeeeee-0000-4000-8000-000000000009', 'r9', 'n10', 2, 'dynamic_tool', 'running', strftime('%Y-%m-%dT%H:%M:%fZ','now','-40 seconds'), '{"toolName":"mcp__t3-code__delegate_task","input":{}}');
SQL

out=$(T3CODE_HOME="$home" sh "$here/feed.sh" once)
got=$(printf '%s' "$out" | jq -r '[.threads[] | "\(.id[-1:])=\(.state)"] | sort | join(" ")')
want="1=waiting 2=done 4=done 6=waiting 7=waiting 9=working"
[ "$got" = "$want" ] || { echo "feed test failed: got '$got', want '$want'" >&2; exit 1; }
# Done after a wait is timed by the wait's end, not the turn's.
ended=$(printf '%s' "$out" | jq -r '.threads[] | select(.id[-1:] == "2") | .ended')
[ "$ended" \> "$(sqlite3 :memory: "select strftime('%Y-%m-%dT%H:%M:%S', 'now', '-60 seconds')")" ] || { echo "feed test failed: done after a wait ended at $ended" >&2; exit 1; }
echo "feed tests passed"
