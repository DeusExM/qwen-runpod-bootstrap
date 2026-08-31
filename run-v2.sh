#!/usr/bin/env bash
set -Eeuo pipefail

QWEN_RUNPOD_BASE="${QWEN_RUNPOD_BASE:-/opt/qwen-runpod}"

source "$QWEN_RUNPOD_BASE/env.sh"
source "$QWEN_RUNPOD_BASE/qwen-config.env"

export OPENAI_API_KEY="local-vllm"
export OPENAI_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}/v1"
export OPENAI_MODEL="$MODEL_ID"
export QWEN_MODEL="$MODEL_ID"

export WORK_MINUTES FINALIZE_MINUTES WATCHDOG_MINUTES
export FAILURE_GRACE_MINUTES MAX_SESSION_TURNS
export RUNPOD_POD_ID RUNPOD_CONTROL_API_KEY

REPO="$REPO_DIR"
LOGDIR="$QWEN_RUNPOD_BASE/logs"
RUN_ID="$(date -u '+%Y%m%d-%H%M%S')"

mkdir -p "$LOGDIR"

MAIN_LOG="$LOGDIR/qwen-main-$RUN_ID.log"
FINAL_LOG="$LOGDIR/qwen-final-$RUN_ID.log"
RUN_LOG="$LOGDIR/run-v2-$RUN_ID.log"
STOP_LOG="$LOGDIR/runpod-stop-$RUN_ID.log"

exec > >(tee -a "$RUN_LOG") 2>&1

echo "=== QWEN RUN V2 ==="
echo "Run ID: $RUN_ID"
echo "Started: $(date -u)"
echo

require_var() {
    [[ -n "${!1:-}" ]] || {
        echo "ERROR: missing environment variable $1"
        exit 20
    }
}

require_var GITHUB_TOKEN
require_var RUNPOD_POD_ID
require_var RUNPOD_CONTROL_API_KEY

[[ -d "$REPO/.git" ]] || {
    echo "ERROR: repository absent: $REPO"
    exit 21
}

[[ -x "$QWEN_RUNPOD_BASE/autosave.sh" ]] || {
    echo "ERROR: autosave absent: $QWEN_RUNPOD_BASE/autosave.sh"
    exit 22
}

[[ -x "$QWEN_RUNPOD_BASE/bin/qwen" ]] || {
    echo "ERROR: Qwen Code absent."
    exit 23
}

cd "$REPO"

[[ -f QWEN_MISSION.md ]] || {
    echo "ERROR: QWEN_MISSION.md absent."
    exit 24
}

STOP_ON_EXIT=1
STOP_ALREADY_SENT=0

stop_pod_best_effort() {
    if [[ "$STOP_ALREADY_SENT" == "1" ]]; then
        return 0
    fi

    STOP_ALREADY_SENT=1

    echo
    echo "=== STOPPING RUNPOD ==="
    echo "Timestamp: $(date -u)" | tee -a "$STOP_LOG"

    local success=0
    local code=""

    for attempt in 1 2 3 4 5; do
        echo "Attempt $attempt" | tee -a "$STOP_LOG"

        code="$(
            curl -sS \
                -o /tmp/qwen-stop-response \
                -w "%{http_code}" \
                --connect-timeout 10 \
                --max-time 30 \
                -X POST \
                "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID/stop" \
                -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY" \
                || true
        )"

        echo "HTTP=$code" | tee -a "$STOP_LOG"
        cat /tmp/qwen-stop-response 2>/dev/null | tee -a "$STOP_LOG" || true

        if [[ "$code" == "200" || "$code" == "202" || "$code" == "204" ]]; then
            success=1
            break
        fi

        sleep 10
    done

    if [[ "$success" != "1" ]]; then
        echo "REST stop failed. Trying runpodctl fallback." | tee -a "$STOP_LOG"

        timeout 30s env \
            RUNPOD_API_KEY="$RUNPOD_CONTROL_API_KEY" \
            runpodctl pod stop "$RUNPOD_POD_ID" \
            >> "$STOP_LOG" 2>&1 || true
    fi

    echo "Stop command sent."
}

on_exit() {
    local status=$?

    if [[ "$STOP_ON_EXIT" == "1" ]]; then
        echo "Runner exiting with status $status -> fail-safe Pod stop."
        stop_pod_best_effort || true
    fi
}

trap on_exit EXIT

# ------------------------------------------------------------
# Hard watchdog: independent maximum runtime from runner start.
# ------------------------------------------------------------

nohup bash -lc '
sleep "$((WATCHDOG_MINUTES * 60))"

echo "[$(date -u)] HARD WATCHDOG FIRED"

CODE=$(curl -sS \
  -o /tmp/qwen-hard-stop-response \
  -w "%{http_code}" \
  --connect-timeout 10 \
  --max-time 30 \
  --retry 3 \
  --retry-delay 5 \
  -X POST \
  "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID/stop" \
  -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY" || true)

echo "HTTP=$CODE"
cat /tmp/qwen-hard-stop-response 2>/dev/null || true

if [[ "$CODE" != "200" && "$CODE" != "202" && "$CODE" != "204" ]]; then
  echo "REST stop failed; trying runpodctl"

  timeout 30s env \
    RUNPOD_API_KEY="$RUNPOD_CONTROL_API_KEY" \
    runpodctl pod stop "$RUNPOD_POD_ID" || true
fi
' >> "$LOGDIR/hard-stop-v2-$RUN_ID.log" 2>&1 &

WATCHDOG_PID=$!

echo "Hard watchdog PID: $WATCHDOG_PID"
echo "Absolute maximum Pod runtime from runner start: $WATCHDOG_MINUTES min"

# ------------------------------------------------------------
# Run-specific files and deadline.
# ------------------------------------------------------------

START_EPOCH="$(date +%s)"
FINALIZE_EPOCH=$((START_EPOCH + WORK_MINUTES * 60))
FINALIZE_UTC="$(date -u -d "@$FINALIZE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
STARTED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat > QWEN_DEADLINE.md <<DEADLINE
# QWEN DEADLINE

RUN_ID: $RUN_ID
RUN_STARTED_UTC: $STARTED_UTC
FINALIZATION_DEADLINE: $FINALIZE_UTC

At or before FINALIZATION_DEADLINE:
- stop starting new features;
- finish the current safe edit;
- update QWEN_PROGRESS.md;
- update QWEN_REPORT.md;
- leave the repository in a coherent state.

A separate finalization agent will then validate the current state and update the existing QWEN_REPORT.md.
DEADLINE

cat > QWEN_PLAN.md <<PLAN
# QWEN_PLAN

Run: $RUN_ID
Started UTC: $STARTED_UTC

Qwen has not written the plan for this run yet.
PLAN

cat > QWEN_PROGRESS.md <<PROGRESS
# QWEN_PROGRESS

Run: $RUN_ID
Started UTC: $STARTED_UTC
Deadline UTC: $FINALIZE_UTC

## Current status

- Timestamp UTC: $STARTED_UTC
- Phase: starting
- Current task: repository inspection
- Work completed since previous update: autonomous run initialized
- Files currently being modified: none
- Last command/test executed: none
- Result: pending
- Current blocker: none
- Next step: inspect repository and create the prioritized plan

## Activity log

- $STARTED_UTC — autonomous run initialized.
PROGRESS

cat > QWEN_REPORT.md <<REPORT
# QWEN_REPORT

Run: $RUN_ID
Started UTC: $STARTED_UTC
Last update UTC: $STARTED_UTC
Status: RUNNING

## Work completed

Autonomous run initialized. Qwen has not completed repository inspection yet.

## Files / features changed

None yet.

## Tests executed

None yet.

## Known issues / blockers

None identified yet.

## Remaining work

- inspect the repository;
- create QWEN_PLAN.md;
- execute the prioritized work;
- validate the repository.

## Recommendations

Pending.

## Repository safe to continue from

Unknown until validation is performed.
REPORT

cat > QWEN_EXIT.log <<EXITLOG
run_id=$RUN_ID
started_utc=$STARTED_UTC
status=RUNNING
EXITLOG

echo 'timestamp_utc,requests_running,requests_waiting,kv_cache_pct,kv_context_equivalent,max_context,prompt_tokens_total,generation_tokens_total,gpu_util_pct,vram_used_mib,vram_total_mib' > QWEN_TELEMETRY.csv

# Save the run initialization immediately.
timeout 90s "$QWEN_RUNPOD_BASE/autosave.sh" once || true

# ------------------------------------------------------------
# Verify vLLM.
# start-qwen-worker.sh normally already started and tested it.
# ------------------------------------------------------------

if curl -fsS "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
    echo "vLLM already running."
else
    echo "Starting vLLM..."

    tmux kill-session -t vllm 2>/dev/null || true

    tmux new-session -d -s vllm \
        "bash -lc '$QWEN_RUNPOD_BASE/start_vllm.sh >> $LOGDIR/vllm-$RUN_ID.log 2>&1'"

    echo "Waiting for vLLM API..."

    READY=0

    for i in $(seq 1 144); do
        if curl -fsS "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
            READY=1
            break
        fi

        sleep 5
    done

    if [[ "$READY" != "1" ]]; then
        echo "ERROR: vLLM failed to become ready within 12 minutes."
        echo "status=VLLM_START_FAILED" >> QWEN_EXIT.log

        timeout 90s "$QWEN_RUNPOD_BASE/autosave.sh" once || true
        stop_pod_best_effort || true
        STOP_ON_EXIT=0
        exit 30
    fi
fi

echo "vLLM READY: $(date -u)"

curl -s "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" \
    | jq '.data[0] | {id,max_model_len}' || true

# ------------------------------------------------------------
# Telemetry.
# ------------------------------------------------------------

echo "Starting telemetry."

if [[ -x "$REPO/tools/qwen/qwen-telemetry.sh" ]]; then
    "$REPO/tools/qwen/qwen-telemetry.sh" \
        >> "$LOGDIR/telemetry-$RUN_ID.log" 2>&1 &
    TELEMETRY_PID=$!
else
    TELEMETRY_PID=""
    echo "WARNING: qwen-telemetry.sh absent."
fi

if [[ -x "$REPO/tools/qwen/qwen-request-telemetry.sh" ]]; then
    "$REPO/tools/qwen/qwen-request-telemetry.sh" \
        >> "$LOGDIR/request-telemetry-$RUN_ID.log" 2>&1 &
    REQUEST_TELEMETRY_PID=$!
else
    REQUEST_TELEMETRY_PID=""
    echo "WARNING: qwen-request-telemetry.sh absent."
fi

echo "Telemetry PID: ${TELEMETRY_PID:-none}"
echo "Request telemetry PID: ${REQUEST_TELEMETRY_PID:-none}"

# ------------------------------------------------------------
# External Git autosave every ~5 minutes.
# ------------------------------------------------------------

"$QWEN_RUNPOD_BASE/autosave.sh" loop \
    >> "$LOGDIR/autosave-$RUN_ID.log" 2>&1 &
AUTOSAVE_PID=$!

echo "Autosave PID: $AUTOSAVE_PID"

# ------------------------------------------------------------
# Main Qwen run.
# ------------------------------------------------------------

echo
echo "=== MAIN QWEN AGENT ==="
echo "Maximum work phase: $WORK_MINUTES minutes"
echo "Finalization deadline: $FINALIZE_UTC"

RUNTIME_DIRECTIVES=$(cat <<'DIRECTIVES'

## RUNTIME DIRECTIVES — MANDATORY

These directives supplement the mission and override any conflicting reporting timing.

1. `QWEN_REPORT.md` ALREADY EXISTS. Do not wait until finalization to create it.
2. Maintain BOTH `QWEN_PROGRESS.md` and `QWEN_REPORT.md` throughout the run.
3. Update them after every meaningful implementation step, before/after important validation commands, on blockers/errors, and at least once every 5 minutes while actively working.
4. Always use the real UTC time from `date -u`.
5. `QWEN_REPORT.md` must always contain the best currently known state:
   - last update UTC;
   - work completed;
   - files/features changed;
   - exact tests/commands run and results;
   - known issues/blockers;
   - remaining work;
   - recommendations;
   - whether the repository is currently safe to continue from.
6. External automation commits and pushes regularly. Save files frequently. Do not commit or push yourself.
7. Work in small, concrete steps. Prefer tool actions and code changes over long explanations.
8. Keep intermediate responses concise. Do not produce huge narrative responses or repeatedly restate the repository, plan, diffs, or entire files.
9. When a command can establish a fact, run it instead of writing a long speculative explanation.
10. Before the deadline, leave the worktree coherent and update both progress/report even if the full plan is unfinished.

DIRECTIVES
)

MAIN_PROMPT="$(cat QWEN_MISSION.md)

$RUNTIME_DIRECTIVES"

MAIN_STARTED_EPOCH="$(date +%s)"

set +e

env \
    -u GITHUB_TOKEN \
    -u GH_TOKEN \
    -u GIT_ASKPASS \
    -u RUNPOD_API_KEY \
    -u RUNPOD_CONTROL_API_KEY \
    QWEN_CODE_SUPPRESS_YOLO_WARNING=1 \
    "$QWEN_RUNPOD_BASE/bin/qwen" \
        -p "$MAIN_PROMPT" \
        --yolo \
        --max-wall-time "${WORK_MINUTES}m" \
        --max-session-turns "$MAX_SESSION_TURNS" \
        2>&1 | tee "$MAIN_LOG"

MAIN_STATUS=${PIPESTATUS[0]}

set -e

MAIN_RUNTIME=$(( $(date +%s) - MAIN_STARTED_EPOCH ))

echo "main_exit_code=$MAIN_STATUS" >> QWEN_EXIT.log
echo "main_runtime_seconds=$MAIN_RUNTIME" >> QWEN_EXIT.log
echo "main_finished_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> QWEN_EXIT.log

if [[ "$MAIN_STATUS" == "0" ]]; then
    echo "Main agent finished normally."
elif [[ "$MAIN_STATUS" == "55" ]]; then
    echo "Main agent reached its configured wall-time/budget limit (exit 55)."
else
    echo "Main agent exited with code $MAIN_STATUS."
fi

# Unexpected very-early failures keep a short diagnostic grace period.
if [[ "$MAIN_STATUS" != "0" && "$MAIN_STATUS" != "55" && "$MAIN_RUNTIME" -lt 180 ]]; then
    echo
    echo "=== EARLY QWEN FAILURE ==="
    echo "Exit code: $MAIN_STATUS"
    echo "Runtime: ${MAIN_RUNTIME}s"
    echo "Pod kept for $FAILURE_GRACE_MINUTES minutes for diagnosis."

    echo "status=EARLY_QWEN_FAILURE" >> QWEN_EXIT.log

    [[ -z "${TELEMETRY_PID:-}" ]] || kill "$TELEMETRY_PID" 2>/dev/null || true
    [[ -z "${REQUEST_TELEMETRY_PID:-}" ]] || kill "$REQUEST_TELEMETRY_PID" 2>/dev/null || true
    kill "$AUTOSAVE_PID" 2>/dev/null || true

    timeout 90s "$QWEN_RUNPOD_BASE/autosave.sh" once || true

    # Hard watchdog is replaced by a shorter grace stop.
    kill "$WATCHDOG_PID" 2>/dev/null || true

    nohup bash -lc '
      sleep "$((FAILURE_GRACE_MINUTES * 60))"

      CODE=$(curl -sS \
        -o /tmp/qwen-grace-stop-response \
        -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID/stop" \
        -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY" || true)

      echo "HTTP=$CODE"
      cat /tmp/qwen-grace-stop-response 2>/dev/null || true

      if [[ "$CODE" != "200" && "$CODE" != "202" && "$CODE" != "204" ]]; then
        timeout 30s env \
          RUNPOD_API_KEY="$RUNPOD_CONTROL_API_KEY" \
          runpodctl pod stop "$RUNPOD_POD_ID" || true
      fi
    ' >> "$LOGDIR/grace-stop-$RUN_ID.log" 2>&1 &

    echo "Grace-stop PID: $!"

    STOP_ON_EXIT=0
    exit "$MAIN_STATUS"
fi

timeout 90s "$QWEN_RUNPOD_BASE/autosave.sh" once || true

# ------------------------------------------------------------
# Dedicated finalizer.
# Report exists already: update it FIRST, then validate.
# ------------------------------------------------------------

echo
echo "=== FINALIZATION AGENT ==="
echo "Maximum finalization phase: $FINALIZE_MINUTES minutes"

FINAL_PROMPT=$(cat <<'FINAL'
You are the finalization engineer for this autonomous run.

DO NOT start a new feature.

Read:
- QWEN_MISSION.md
- QWEN_PLAN.md if present
- QWEN_PROGRESS.md
- QWEN_REPORT.md
- QWEN_DEADLINE.md
- git status
- git diff

The report already exists. Your first action after inspection must be to update
QWEN_REPORT.md with the best current state BEFORE running lengthy validation.

Then:

1. Finish only a tiny incomplete edit if leaving it unfinished would break the repository.
2. Update QWEN_PROGRESS.md and QWEN_REPORT.md.
3. Run practical validation gates:
   - pnpm lint
   - pnpm build
   - pnpm test
   - pnpm security:audit
   Use the safest reasonable subset if environment limitations prevent a command.
4. After EACH important validation command, immediately update QWEN_REPORT.md with the exact result.
5. Do NOT disable or weaken tests.
6. Inspect the final diff.
7. Remove temporary/debug artifacts created by the coding work.
8. Update QWEN_PROGRESS.md with final status.
9. Update the EXISTING QWEN_REPORT.md with:
   - work completed;
   - files/features changed;
   - exact tests run;
   - pass/fail results;
   - unresolved failures;
   - known issues;
   - recommended next steps;
   - whether the repository is safe to continue from.
10. Do not commit or push. External automation handles Git persistence.

Keep responses concise and spend the time on commands, validation and file updates,
not long narrative output. Finish cleanly and promptly.
FINAL
)

set +e

env \
    -u GITHUB_TOKEN \
    -u GH_TOKEN \
    -u GIT_ASKPASS \
    -u RUNPOD_API_KEY \
    -u RUNPOD_CONTROL_API_KEY \
    QWEN_CODE_SUPPRESS_YOLO_WARNING=1 \
    "$QWEN_RUNPOD_BASE/bin/qwen" \
        -p "$FINAL_PROMPT" \
        --yolo \
        --max-wall-time "${FINALIZE_MINUTES}m" \
        --max-session-turns "150" \
        2>&1 | tee "$FINAL_LOG"

FINAL_STATUS=${PIPESTATUS[0]}

set -e

echo "finalizer_exit_code=$FINAL_STATUS" >> QWEN_EXIT.log
echo "finalizer_finished_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> QWEN_EXIT.log

if [[ "$FINAL_STATUS" == "0" ]]; then
    echo "Finalizer finished normally."
elif [[ "$FINAL_STATUS" == "55" ]]; then
    echo "Finalizer reached its configured wall-time/budget limit (exit 55)."
else
    echo "Finalizer exited with code $FINAL_STATUS."
fi

# ------------------------------------------------------------
# Stop telemetry/autosave and persist final state.
# ------------------------------------------------------------

[[ -z "${TELEMETRY_PID:-}" ]] || kill "$TELEMETRY_PID" 2>/dev/null || true
[[ -z "${REQUEST_TELEMETRY_PID:-}" ]] || kill "$REQUEST_TELEMETRY_PID" 2>/dev/null || true

[[ -z "${TELEMETRY_PID:-}" ]] || wait "$TELEMETRY_PID" 2>/dev/null || true
[[ -z "${REQUEST_TELEMETRY_PID:-}" ]] || wait "$REQUEST_TELEMETRY_PID" 2>/dev/null || true

kill "$AUTOSAVE_PID" 2>/dev/null || true
wait "$AUTOSAVE_PID" 2>/dev/null || true

echo "status=FINISHED" >> QWEN_EXIT.log
echo "finished_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> QWEN_EXIT.log

echo
echo "=== FINAL GIT CHECKPOINT (BEST EFFORT) ==="

timeout 90s "$QWEN_RUNPOD_BASE/autosave.sh" once \
    || echo "WARNING: final autosave failed or timed out; Pod shutdown continues."

git status || true

# ------------------------------------------------------------
# ALWAYS stop the Pod even if report/final push failed.
# ------------------------------------------------------------

stop_pod_best_effort || true
STOP_ON_EXIT=0

exit 0
