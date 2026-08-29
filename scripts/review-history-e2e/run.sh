#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/review-history-e2e/run.sh [options]

Builds and launches the real CodexReviewMonitor app, completes a real review,
relaunches the app with the same isolated SQLite database, and verifies restored
history plus MCP session isolation.

Options:
  --artifacts-dir <path>        Use a new, non-existing artifact directory.
  --port <port>                 Use an unused dedicated port other than 9417.
  --review-timeout <seconds>    Bound each real review request (default: 900).
  --keep-restored-app-running   Leave only the verified second app process alive
                                for a manual UI screenshot. Its exact PID and stop
                                command are printed and saved in the artifacts.
  -h, --help                    Show this help.
EOF
}

die() {
  echo "review-history-e2e: $*" >&2
  exit 1
}

require_command() {
  local command_path="$1"
  [[ -x "$command_path" ]] || die "required executable is unavailable: $command_path"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

artifacts_dir=""
requested_port=""
review_timeout_seconds=900
keep_restored_app_running=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir)
      [[ $# -ge 2 ]] || die "--artifacts-dir requires a path"
      artifacts_dir="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      requested_port="$2"
      shift 2
      ;;
    --review-timeout)
      [[ $# -ge 2 ]] || die "--review-timeout requires a value"
      review_timeout_seconds="$2"
      shift 2
      ;;
    --keep-restored-app-running)
      keep_restored_app_running=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

is_positive_integer "$review_timeout_seconds" \
  || die "--review-timeout must be a positive integer"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
codex_command="/opt/homebrew/bin/codex"
app_name="CodexReviewMonitor"
app_project="$repo_root/Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj"
app_scheme="CodexReviewMonitor"
terminate_source="$repo_root/scripts/review-history-e2e/terminate-application.swift"
fixture_source_directory="$repo_root/scripts/review-history-e2e/fixture"

[[ "$(uname -s)" == "Darwin" ]] || die "this E2E requires macOS"
[[ "$(uname -m)" == "arm64" ]] || die "this E2E currently builds the arm64 app target"
require_command /usr/bin/curl
require_command /usr/bin/git
require_command /usr/bin/jq
require_command /usr/bin/sqlite3
require_command /usr/bin/xcodebuild
require_command /usr/bin/xcrun
require_command /usr/sbin/lsof
require_command "$codex_command"
[[ -f "$app_project/project.pbxproj" ]] || die "ReviewMonitor Xcode project is missing"
[[ -f "$terminate_source" ]] || die "termination helper source is missing"
[[ -f "$fixture_source_directory/AGENTS.md" ]] || die "fixture contract is missing"
[[ -f "$fixture_source_directory/AccessGate.baseline.swift" ]] \
  || die "fixture baseline is missing"
[[ -f "$fixture_source_directory/AccessGate.uncommitted.swift" ]] \
  || die "fixture change is missing"

if ! /usr/bin/grep -R -q 'testHistoryPathKey' \
  "$repo_root/Tools/ReviewMonitor/CodexReviewMonitor" \
  || ! /usr/bin/grep -R -q 'REVIEW_MONITOR_TEST_HISTORY_PATH' \
  "$repo_root/Sources"; then
  die "app integration prerequisite is missing: REVIEW_MONITOR_TEST_HISTORY_PATH"
fi

if [[ -n "$artifacts_dir" ]]; then
  [[ "$artifacts_dir" = /* ]] || artifacts_dir="$PWD/$artifacts_dir"
  [[ ! -e "$artifacts_dir" ]] \
    || die "refusing to replace existing artifact path: $artifacts_dir"
  /bin/mkdir -p "$artifacts_dir"
  /bin/chmod 700 "$artifacts_dir"
else
  artifacts_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-review-history-e2e.XXXXXX")"
fi

derived_data_path="$artifacts_dir/DerivedData"
fixture_path="$artifacts_dir/fixture"
history_directory="$artifacts_dir/history"
history_path="$history_directory/review-history.sqlite"
live_diagnostics_path="$artifacts_dir/diagnostics-live.json"
restored_diagnostics_path="$artifacts_dir/diagnostics-restored.json"
build_log_path="$artifacts_dir/xcodebuild.log"
terminate_helper="$artifacts_dir/terminate-application"
current_app_pid=""
current_app_log_path=""
current_app_phase=""
e2e_succeeded=false

force_stop_owned_app() {
  local process_identifier="$1"
  local expected_executable="$2"
  local observed_executable
  local process_state
  local attempt

  [[ -n "$process_identifier" ]] || return 0
  if ! /bin/kill -0 "$process_identifier" 2>/dev/null; then
    wait "$process_identifier" 2>/dev/null || true
    return 0
  fi

  process_state="$(/bin/ps -p "$process_identifier" -o stat= 2>/dev/null \
    | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ "$process_state" == Z* ]]; then
    wait "$process_identifier" 2>/dev/null || true
    return 0
  fi
  observed_executable="$(/bin/ps -p "$process_identifier" -o command= 2>/dev/null \
    | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ "$observed_executable" != "$expected_executable" ]]; then
    echo "Refusing signal fallback: PID $process_identifier no longer owns $expected_executable" >&2
    return 1
  fi

  /bin/kill -TERM "$process_identifier" 2>/dev/null || true
  attempt=0
  while /bin/kill -0 "$process_identifier" 2>/dev/null && [[ "$attempt" -lt 50 ]]; do
    /bin/sleep 0.1
    attempt=$((attempt + 1))
  done
  if /bin/kill -0 "$process_identifier" 2>/dev/null; then
    process_state="$(/bin/ps -p "$process_identifier" -o stat= 2>/dev/null \
      | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$process_state" == Z* ]]; then
      wait "$process_identifier" 2>/dev/null || true
      return 0
    fi
    observed_executable="$(/bin/ps -p "$process_identifier" -o command= 2>/dev/null \
      | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$observed_executable" != "$expected_executable" ]]; then
      echo "Refusing KILL fallback: PID $process_identifier changed ownership" >&2
      return 1
    fi
    /bin/kill -KILL "$process_identifier" 2>/dev/null || true
  fi
  wait "$process_identifier" 2>/dev/null || true
}

cleanup() {
  local exit_status=$?
  local expected_executable="${app_binary:-}"
  trap - EXIT
  set +e

  if [[ -n "$current_app_pid" ]] && /bin/kill -0 "$current_app_pid" 2>/dev/null; then
    echo "Cleaning up owned $current_app_phase app PID $current_app_pid" >&2
    if [[ -x "$terminate_helper" && -n "$expected_executable" ]]; then
      "$terminate_helper" "$current_app_pid" "$expected_executable" 30 \
        >>"$artifacts_dir/cleanup.log" 2>&1
    fi
    if /bin/kill -0 "$current_app_pid" 2>/dev/null; then
      force_stop_owned_app "$current_app_pid" "$expected_executable" \
        >>"$artifacts_dir/cleanup.log" 2>&1
    else
      wait "$current_app_pid" 2>/dev/null
    fi
  fi

  if [[ "$e2e_succeeded" == true ]]; then
    echo "E2E artifacts: $artifacts_dir"
  else
    echo "E2E failed; artifacts retained at: $artifacts_dir" >&2
    if [[ -n "$current_app_log_path" ]]; then
      echo "Last app log: $current_app_log_path" >&2
    fi
  fi
  exit "$exit_status"
}

trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

select_port() {
  local candidate
  local attempt=0

  if [[ -n "$requested_port" ]]; then
    is_positive_integer "$requested_port" || die "--port must be an integer"
    [[ "$requested_port" -le 65535 ]] || die "--port must not exceed 65535"
    [[ "$requested_port" -ne 9417 ]] || die "port 9417 is reserved for the existing ReviewMonitor"
    candidate="$requested_port"
    if [[ -n "$(/usr/sbin/lsof -nP -iTCP:"$candidate" -sTCP:LISTEN 2>/dev/null)" ]]; then
      die "requested port is already listening: $candidate"
    fi
    echo "$candidate"
    return
  fi

  while [[ "$attempt" -lt 100 ]]; do
    candidate=$((49152 + (RANDOM % 15000)))
    attempt=$((attempt + 1))
    [[ "$candidate" -ne 9417 ]] || continue
    if [[ -z "$(/usr/sbin/lsof -nP -iTCP:"$candidate" -sTCP:LISTEN 2>/dev/null)" ]]; then
      echo "$candidate"
      return
    fi
  done
  die "could not select an unused dedicated TCP port"
}

mcp_decode_response() {
  local response_body="$1"
  local decoded_path="$2"
  local sse_payload_path="$decoded_path.sse-payload"

  if /usr/bin/jq -e 'type == "object"' "$response_body" >/dev/null 2>&1; then
    /usr/bin/jq . "$response_body" >"$decoded_path"
    return
  fi

  /usr/bin/awk '
    /^data: / {
      payload = substr($0, 7)
      if (length(payload) > 0) {
        last_payload = payload
      }
    }
    END {
      if (length(last_payload) > 0) {
        print last_payload
      }
    }
  ' "$response_body" >"$sse_payload_path"
  /usr/bin/jq -e 'type == "object"' "$sse_payload_path" >"$decoded_path" \
    || die "MCP response did not contain a valid JSON or SSE JSON object: $response_body"
}

mcp_post() {
  local endpoint="$1"
  local session_identifier="$2"
  local request_path="$3"
  local response_prefix="$4"
  local timeout_seconds="$5"
  local header_path="$response_prefix.headers"
  local body_path="$response_prefix.body"
  local json_path="$response_prefix.json"
  local curl_arguments=(
    --silent
    --show-error
    --fail-with-body
    --max-time "$timeout_seconds"
    --dump-header "$header_path"
    --output "$body_path"
    --request POST
    --header 'Content-Type: application/json'
    --header 'Accept: text/event-stream, application/json'
    --data-binary "@$request_path"
  )

  if [[ -n "$session_identifier" ]]; then
    curl_arguments+=(--header "MCP-Session-Id: $session_identifier")
  fi
  /usr/bin/curl "${curl_arguments[@]}" "$endpoint"
  mcp_decode_response "$body_path" "$json_path"
}

wait_for_diagnostics() {
  local diagnostics_path="$1"
  local jq_filter="$2"
  local timeout_seconds="$3"
  local description="$4"
  local deadline_epoch

  deadline_epoch=$(( $(/bin/date +%s) + timeout_seconds ))
  while [[ "$(/bin/date +%s)" -lt "$deadline_epoch" ]]; do
    if [[ -s "$diagnostics_path" ]] \
      && /usr/bin/jq -e "$jq_filter" "$diagnostics_path" >/dev/null 2>&1; then
      return
    fi
    if [[ -n "$current_app_pid" ]] && ! /bin/kill -0 "$current_app_pid" 2>/dev/null; then
      die "$current_app_phase app exited while waiting for $description"
    fi
    /bin/sleep 0.2
  done
  die "timed out waiting for $description in $diagnostics_path"
}

launch_app() {
  local diagnostics_path="$1"
  local log_path="$2"
  local phase="$3"

  [[ ! -e "$diagnostics_path" ]] \
    || die "refusing to replace existing diagnostics: $diagnostics_path"
  current_app_log_path="$log_path"
  current_app_phase="$phase"

  REVIEW_MONITOR_TEST_PORT="$mcp_port" \
  REVIEW_MONITOR_TEST_CODEX_COMMAND="$codex_command" \
  REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH="$diagnostics_path" \
  REVIEW_MONITOR_TEST_HISTORY_PATH="$history_path" \
    "$app_binary" >"$log_path" 2>&1 &
  current_app_pid=$!
  echo "$current_app_pid" >"$artifacts_dir/app-$phase.pid"

  /bin/sleep 0.1
  /bin/kill -0 "$current_app_pid" 2>/dev/null \
    || die "$phase app exited immediately after launch"
}

terminate_current_app() {
  local process_identifier="$current_app_pid"
  local wait_status=0

  [[ -n "$process_identifier" ]] || die "no owned app process is available to terminate"
  "$terminate_helper" "$process_identifier" "$app_binary" 30 \
    >>"$artifacts_dir/termination.log" 2>&1 \
    || die "NSRunningApplication termination failed for PID $process_identifier"
  wait "$process_identifier" || wait_status=$?
  current_app_pid=""
  [[ "$wait_status" -eq 0 ]] \
    || die "app PID $process_identifier exited with status $wait_status"
}

assert_no_diagnostic_transcript_fields() {
  local diagnostics_path="$1"
  /usr/bin/jq -e '
    [
      paths as $path
      | ($path[-1] | tostring | ascii_downcase)
      | select(
          . == "logs"
          or . == "logtext"
          or . == "rawlogtext"
          or . == "commandoutput"
          or . == "reasoning"
          or . == "toolresult"
          or . == "transcript"
          or . == "sessionid"
          or . == "threadid"
          or . == "turnid"
        )
    ] | length == 0
  ' "$diagnostics_path" >/dev/null \
    || die "diagnostics exposed a transcript/runtime-only field: $diagnostics_path"
}

assert_database_contract() {
  local table_names_path="$artifacts_dir/database-table-names.json"
  local workspace_columns_path="$artifacts_dir/database-workspace-columns.json"
  local record_columns_path="$artifacts_dir/database-record-columns.json"
  local finding_columns_path="$artifacts_dir/database-finding-columns.json"
  local semantic_record_path="$artifacts_dir/database-semantic-record.json"
  local findings_path="$artifacts_dir/database-findings.json"
  local database_text_path="$artifacts_dir/database-text-values.txt"

  [[ -f "$history_path" ]] || die "history database was not created at the dedicated path"

  /usr/bin/sqlite3 -json "$history_path" \
    "SELECT name FROM pragma_table_list WHERE schema = 'main' AND name NOT LIKE 'sqlite_%' ORDER BY name" \
    >"$table_names_path"
  /usr/bin/sqlite3 -json "$history_path" \
    "SELECT name FROM pragma_table_info('review_workspaces') ORDER BY cid" \
    >"$workspace_columns_path"
  /usr/bin/sqlite3 -json "$history_path" \
    "SELECT name FROM pragma_table_info('review_records') ORDER BY cid" \
    >"$record_columns_path"
  /usr/bin/sqlite3 -json "$history_path" \
    "SELECT name FROM pragma_table_info('review_findings') ORDER BY cid" \
    >"$finding_columns_path"

  /usr/bin/jq -e '[.[].name] == [
    "grdb_migrations",
    "review_findings",
    "review_records",
    "review_workspaces"
  ]' "$table_names_path" >/dev/null || die "history database table inventory changed"
  /usr/bin/jq -e '[.[].name] == ["cwd", "sortOrder"]' \
    "$workspace_columns_path" >/dev/null || die "workspace schema inventory changed"
  /usr/bin/jq -e '[.[].name] == [
    "id", "cwd", "sortOrder", "targetKind", "targetBranch",
    "targetCommitSHA", "targetCommitTitle", "targetInstructions",
    "startedModel", "startedAt", "phase", "terminalModel", "terminalKind",
    "interruptionKind", "cancellationSource", "cancellationMessage",
    "terminalMessage", "endedAt", "summary", "canonicalReview",
    "parsedState", "parsedFindingCount", "parsedSource", "parserVersion",
    "terminalCommittedAt", "createdAt", "updatedAt"
  ]' "$record_columns_path" >/dev/null || die "review schema inventory changed"
  /usr/bin/jq -e '[.[].name] == [
    "id", "reviewID", "ordinal", "priority", "title", "body", "path",
    "startLine", "endLine"
  ]' "$finding_columns_path" >/dev/null || die "finding schema inventory changed"

  /usr/bin/sqlite3 -json "$history_path" \
    "SELECT id, cwd, targetKind, startedModel, phase, terminalModel, terminalKind, summary, canonicalReview, parsedState, parsedFindingCount, parsedSource, parserVersion FROM review_records" \
    >"$semantic_record_path"
  /usr/bin/sqlite3 -json "$history_path" \
    "SELECT reviewID, ordinal, priority, title, body, path, startLine, endLine FROM review_findings ORDER BY ordinal" \
    >"$findings_path"

  /usr/bin/jq -e --arg job_id "$job_id" --arg cwd "$fixture_path" '
    length == 1
    and .[0].id == $job_id
    and .[0].cwd == $cwd
    and .[0].targetKind == "uncommittedChanges"
    and .[0].phase == "terminal"
    and .[0].terminalKind == "completed"
    and ((.[0].terminalModel // .[0].startedModel) | type == "string" and length > 0)
    and (.[0].summary | type == "string" and length > 0)
    and (.[0].canonicalReview | type == "string" and length > 0)
    and .[0].parsedState == "hasFindings"
    and (.[0].parsedFindingCount | type == "number" and . > 0)
    and .[0].parsedSource == "parsedFinalReviewText"
    and (.[0].parserVersion | type == "number" and . > 0)
  ' "$semantic_record_path" >/dev/null || die "database terminal record is incomplete"
  /usr/bin/jq -e --arg job_id "$job_id" --slurpfile record "$semantic_record_path" '
    length == $record[0][0].parsedFindingCount
    and length > 0
    and all(.[];
      .reviewID == $job_id
      and (.ordinal | type == "number")
      and (.title | type == "string" and length > 0)
      and (.body | type == "string")
    )
    and ([.[].ordinal] == [range(0; length)])
  ' "$findings_path" >/dev/null || die "database findings are incomplete or unordered"

  /usr/bin/sqlite3 -noheader "$history_path" \
    "SELECT value FROM (SELECT summary AS value FROM review_records UNION ALL SELECT canonicalReview FROM review_records UNION ALL SELECT title FROM review_findings UNION ALL SELECT body FROM review_findings) WHERE value IS NOT NULL" \
    >"$database_text_path"
  if /usr/bin/grep -E -i -q \
    'rawLogText|logText|commandOutput|toolResult|threadId|turnId|sessionId|MCP codex_review|Ran command for|reasoning transcript' \
    "$database_text_path"; then
    die "database semantic text contains a runtime transcript marker"
  fi

  /usr/bin/sqlite3 "$history_path" '.schema' >"$artifacts_dir/database-schema.sql"
}

mcp_port="$(select_port)"
echo "Artifacts: $artifacts_dir"
echo "Dedicated MCP port: $mcp_port"
echo "Building $app_name into dedicated DerivedData..."

(
  cd "$repo_root"
  /usr/bin/git status --porcelain=v1
) >"$artifacts_dir/checkout-status-before-build.txt"

/usr/bin/xcrun swiftc "$terminate_source" -framework AppKit -o "$terminate_helper" \
  >"$artifacts_dir/terminate-helper-build.log" 2>&1

(
  cd "$repo_root"
  /usr/bin/xcodebuild build \
    -project "$app_project" \
    -scheme "$app_scheme" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data_path" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
) >"$build_log_path" 2>&1

(
  cd "$repo_root"
  /usr/bin/git status --porcelain=v1
) >"$artifacts_dir/checkout-status-after-build.txt"
/usr/bin/diff -u \
  "$artifacts_dir/checkout-status-before-build.txt" \
  "$artifacts_dir/checkout-status-after-build.txt" \
  >"$artifacts_dir/checkout-status.diff" \
  || die "xcodebuild modified the source checkout"

app_binary="$derived_data_path/Build/Products/Debug/$app_name.app/Contents/MacOS/$app_name"
require_command "$app_binary"

/bin/mkdir -p "$history_directory" "$fixture_path"
/bin/chmod 700 "$history_directory" "$fixture_path"
(
  cd "$fixture_path"
  /usr/bin/git init -q -b main
  /usr/bin/git config user.name 'CodexReviewKit E2E'
  /usr/bin/git config user.email 'codex-review-e2e@example.invalid'
  /bin/cp "$fixture_source_directory/AGENTS.md" AGENTS.md
  /bin/cp "$fixture_source_directory/AccessGate.baseline.swift" AccessGate.swift
  /usr/bin/git add AGENTS.md AccessGate.swift
  /usr/bin/git \
    -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null \
    commit -q -m 'Add secure access gate fixture'
  /bin/cp "$fixture_source_directory/AccessGate.uncommitted.swift" AccessGate.swift
  [[ "$(/usr/bin/git status --short)" == ' M AccessGate.swift' ]] \
    || die "review fixture does not contain exactly one uncommitted source change"
  /usr/bin/git diff --check
)

launch_app "$live_diagnostics_path" "$artifacts_dir/app-live.log" live
wait_for_diagnostics \
  "$live_diagnostics_path" \
  '.historyAvailability == "available" and (.serverURL | type == "string" and length > 0)' \
  60 \
  'available history and the MCP endpoint'

endpoint="$(/usr/bin/jq -r '.serverURL' "$live_diagnostics_path")"
/usr/bin/jq -n --arg endpoint "$endpoint" --argjson port "$mcp_port" '
  ($endpoint | test("^http://(localhost|127\\.0\\.0\\.1):" + ($port | tostring) + "/mcp$"))
' | /usr/bin/jq -e . >/dev/null || die "app published an unexpected MCP endpoint: $endpoint"

/usr/bin/jq -n '{
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: {name: "CodexReviewHistoryE2E", version: "1.0"}
  }
}' >"$artifacts_dir/initialize-live.request.json"
mcp_post \
  "$endpoint" \
  "" \
  "$artifacts_dir/initialize-live.request.json" \
  "$artifacts_dir/initialize-live.response" \
  30
/usr/bin/jq -e '.result.protocolVersion == "2025-11-25"' \
  "$artifacts_dir/initialize-live.response.json" >/dev/null \
  || die "initialize response did not accept the requested MCP protocol"
live_session_id="$(/usr/bin/awk '
  tolower($0) ~ /^mcp-session-id:/ {
    sub(/^[^:]*:[[:space:]]*/, "")
    sub(/\r$/, "")
    session_id = $0
  }
  END { print session_id }
' "$artifacts_dir/initialize-live.response.headers")"
[[ -n "$live_session_id" ]] || die "initialize response omitted MCP-Session-Id"

/usr/bin/jq -n --arg cwd "$fixture_path" '{
  jsonrpc: "2.0",
  id: 2,
  method: "tools/call",
  params: {
    name: "review_start",
    arguments: {cwd: $cwd, target: {type: "uncommittedChanges"}}
  }
}' >"$artifacts_dir/review-start.request.json"
mcp_post \
  "$endpoint" \
  "$live_session_id" \
  "$artifacts_dir/review-start.request.json" \
  "$artifacts_dir/review-start.response" \
  "$review_timeout_seconds"
/usr/bin/jq -e '.result.isError == false' \
  "$artifacts_dir/review-start.response.json" >/dev/null \
  || die "real review_start returned an error"
job_id="$(/usr/bin/jq -r '.result.structuredContent.jobId // empty' \
  "$artifacts_dir/review-start.response.json")"
[[ -n "$job_id" ]] || die "review_start response omitted jobId"

review_request_id=3
review_status=""
while true; do
  /usr/bin/jq -n --argjson id "$review_request_id" --arg job_id "$job_id" '{
    jsonrpc: "2.0",
    id: $id,
    method: "tools/call",
    params: {name: "review_await", arguments: {jobId: $job_id}}
  }' >"$artifacts_dir/review-await-$review_request_id.request.json"
  mcp_post \
    "$endpoint" \
    "$live_session_id" \
    "$artifacts_dir/review-await-$review_request_id.request.json" \
    "$artifacts_dir/review-await-$review_request_id.response" \
    "$review_timeout_seconds"
  /usr/bin/jq -e '.result.isError == false' \
    "$artifacts_dir/review-await-$review_request_id.response.json" >/dev/null \
    || die "real review_await returned an error"
  review_status="$(/usr/bin/jq -r '.result.structuredContent.lifecycle.status // empty' \
    "$artifacts_dir/review-await-$review_request_id.response.json")"
  case "$review_status" in
    succeeded)
      final_review_response="$artifacts_dir/review-await-$review_request_id.response.json"
      break
      ;;
    queued|running)
      review_request_id=$((review_request_id + 1))
      [[ "$review_request_id" -le 5 ]] \
        || die "real review remained active after three review_await calls"
      ;;
    *)
      die "real review reached unexpected terminal status: ${review_status:-missing}"
      ;;
  esac
done

/usr/bin/jq -e '
  .result.structuredContent.lifecycle.terminal.kind == "completed"
  and (.result.structuredContent.output.review | type == "string" and length > 0)
  and .result.structuredContent.output.reviewResult.state == "hasFindings"
  and (.result.structuredContent.output.reviewResult.findingCount | type == "number" and . > 0)
  and (.result.structuredContent.output.reviewResult.findings | type == "array" and length > 0)
' "$final_review_response" >/dev/null \
  || die "real review did not produce the required structured finding"

wait_for_diagnostics \
  "$live_diagnostics_path" \
  ".historyAvailability == \"available\" and ([.jobs[] | select(.id == \"$job_id\" and .status == \"succeeded\" and .terminal.kind == \"completed\" and .parsedResult.state == \"hasFindings\" and (.parsedResult.findings | length > 0))] | length == 1)" \
  30 \
  'the live terminal semantic history row'
assert_no_diagnostic_transcript_fields "$live_diagnostics_path"
/usr/bin/jq -e --arg job_id "$job_id" --arg cwd "$fixture_path" '
  .historyAvailability == "available"
  and (.jobs | length == 1)
  and .jobs[0].id == $job_id
  and .jobs[0].cwd == $cwd
  and .jobs[0].target == {type: "uncommittedChanges"}
  and .jobs[0].origin == "live"
  and .jobs[0].status == "succeeded"
  and .jobs[0].terminal.kind == "completed"
  and (.jobs[0].model | type == "string" and length > 0)
  and (.jobs[0].summary | type == "string" and length > 0)
  and (.jobs[0].canonicalReview | type == "string" and length > 0)
  and .jobs[0].parsedResult.state == "hasFindings"
  and (.jobs[0].parsedResult.findingCount | type == "number" and . > 0)
  and (.jobs[0].parsedResult.findings | length > 0)
' "$live_diagnostics_path" >/dev/null || die "live diagnostics semantic row is incomplete"
/usr/bin/jq -S --arg job_id "$job_id" '
  .jobs[] | select(.id == $job_id) | del(.origin)
' "$live_diagnostics_path" >"$artifacts_dir/job-semantic-live.json"

terminate_current_app
assert_database_contract

launch_app "$restored_diagnostics_path" "$artifacts_dir/app-restored.log" restored
wait_for_diagnostics \
  "$restored_diagnostics_path" \
  ".historyAvailability == \"available\" and ([.jobs[] | select(.id == \"$job_id\" and .origin == \"restoredHistory\" and .status == \"succeeded\" and .terminal.kind == \"completed\" and .parsedResult.state == \"hasFindings\" and (.parsedResult.findings | length > 0))] | length == 1) and (.serverURL | type == \"string\" and length > 0)" \
  60 \
  'the restored semantic history row and MCP endpoint'
assert_no_diagnostic_transcript_fields "$restored_diagnostics_path"
/usr/bin/jq -e --arg job_id "$job_id" --arg cwd "$fixture_path" '
  .historyAvailability == "available"
  and (.jobs | length == 1)
  and .jobs[0].id == $job_id
  and .jobs[0].cwd == $cwd
  and .jobs[0].target == {type: "uncommittedChanges"}
  and .jobs[0].origin == "restoredHistory"
  and .jobs[0].status == "succeeded"
  and .jobs[0].terminal.kind == "completed"
  and (.jobs[0].model | type == "string" and length > 0)
  and (.jobs[0].summary | type == "string" and length > 0)
  and (.jobs[0].canonicalReview | type == "string" and length > 0)
  and .jobs[0].parsedResult.state == "hasFindings"
  and (.jobs[0].parsedResult.findingCount | type == "number" and . > 0)
  and (.jobs[0].parsedResult.findings | length > 0)
' "$restored_diagnostics_path" >/dev/null \
  || die "restored diagnostics semantic row is incomplete"
/usr/bin/jq -S --arg job_id "$job_id" '
  .jobs[] | select(.id == $job_id) | del(.origin)
' "$restored_diagnostics_path" >"$artifacts_dir/job-semantic-restored.json"
/usr/bin/diff -u \
  "$artifacts_dir/job-semantic-live.json" \
  "$artifacts_dir/job-semantic-restored.json" \
  >"$artifacts_dir/job-semantic.diff" \
  || die "restored job semantic state differs from the live terminal state"

restored_endpoint="$(/usr/bin/jq -r '.serverURL' "$restored_diagnostics_path")"
[[ "$restored_endpoint" == "$endpoint" ]] \
  || die "relaunch published a different isolated MCP endpoint"

/usr/bin/jq -n '{
  jsonrpc: "2.0",
  id: 10,
  method: "initialize",
  params: {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: {name: "CodexReviewHistoryE2ERestoredSession", version: "1.0"}
  }
}' >"$artifacts_dir/initialize-restored.request.json"
mcp_post \
  "$restored_endpoint" \
  "" \
  "$artifacts_dir/initialize-restored.request.json" \
  "$artifacts_dir/initialize-restored.response" \
  30
/usr/bin/jq -e '.result.protocolVersion == "2025-11-25"' \
  "$artifacts_dir/initialize-restored.response.json" >/dev/null \
  || die "restored initialize response did not accept the MCP protocol"
restored_session_id="$(/usr/bin/awk '
  tolower($0) ~ /^mcp-session-id:/ {
    sub(/^[^:]*:[[:space:]]*/, "")
    sub(/\r$/, "")
    session_id = $0
  }
  END { print session_id }
' "$artifacts_dir/initialize-restored.response.headers")"
[[ -n "$restored_session_id" ]] || die "restored initialize response omitted MCP-Session-Id"
[[ "$restored_session_id" != "$live_session_id" ]] \
  || die "relaunch reused the previous process MCP session"

/usr/bin/jq -n '{
  jsonrpc: "2.0",
  id: 11,
  method: "tools/call",
  params: {name: "review_list", arguments: {limit: 20}}
}' >"$artifacts_dir/restored-list.request.json"
mcp_post \
  "$restored_endpoint" \
  "$restored_session_id" \
  "$artifacts_dir/restored-list.request.json" \
  "$artifacts_dir/restored-list.response" \
  30
/usr/bin/jq -e '.result.isError == false and .result.structuredContent.items == []' \
  "$artifacts_dir/restored-list.response.json" >/dev/null \
  || die "new MCP session listed previous-process history"

request_id=11
for denied_tool in review_read review_await review_cancel; do
  request_id=$((request_id + 1))
  /usr/bin/jq -n \
    --argjson id "$request_id" \
    --arg tool "$denied_tool" \
    --arg job_id "$job_id" \
    '{
      jsonrpc: "2.0",
      id: $id,
      method: "tools/call",
      params: {name: $tool, arguments: {jobId: $job_id}}
    }' >"$artifacts_dir/restored-$denied_tool.request.json"
  mcp_post \
    "$restored_endpoint" \
    "$restored_session_id" \
    "$artifacts_dir/restored-$denied_tool.request.json" \
    "$artifacts_dir/restored-$denied_tool.response" \
    30
  /usr/bin/jq -e '.result.isError == true and (.result.structuredContent.jobId? == null)' \
    "$artifacts_dir/restored-$denied_tool.response.json" >/dev/null \
    || die "new MCP session accessed restored history through $denied_tool"
done

/usr/bin/jq -n \
  --arg artifacts "$artifacts_dir" \
  --arg appBinary "$app_binary" \
  --arg diagnostics "$restored_diagnostics_path" \
  --arg history "$history_path" \
  --arg fixture "$fixture_path" \
  --arg endpoint "$restored_endpoint" \
  --arg jobID "$job_id" \
  --arg pid "$current_app_pid" \
  '{
    artifactsDirectory: $artifacts,
    appBinary: $appBinary,
    restoredDiagnostics: $diagnostics,
    historyDatabase: $history,
    fixture: $fixture,
    endpoint: $endpoint,
    jobID: $jobID,
    restoredAppPID: ($pid | tonumber)
  }
' >"$artifacts_dir/e2e-summary.json"

if [[ "$keep_restored_app_running" == true ]]; then
  echo "Verified restored app left running for UI inspection: PID $current_app_pid"
  echo "Stop it exactly with:"
  printf '  %q %q %q 30\n' "$terminate_helper" "$current_app_pid" "$app_binary"
  /usr/bin/jq -r '
    "Screenshot context:\n  diagnostics: " + .restoredDiagnostics
    + "\n  database: " + .historyDatabase
    + "\n  job: " + .jobID
  ' "$artifacts_dir/e2e-summary.json"
  disown "$current_app_pid" 2>/dev/null || true
  current_app_pid=""
else
  terminate_current_app
fi

e2e_succeeded=true
echo "Review history E2E passed for job $job_id."
