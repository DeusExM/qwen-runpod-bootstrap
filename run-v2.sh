#!/usr/bin/env bash
set -Eeuo pipefail

# CONFIG_V2_PATCH
QWEN_RUNPOD_BASE="/workspace/qwen-runpod"

source "$QWEN_RUNPOD_BASE/env.sh"
source "$QWEN_RUNPOD_BASE/qwen-config.env"

# Qwen Code -> vLLM local
export OPENAI_API_KEY="local-vllm"
export OPENAI_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}/v1"
export OPENAI_MODEL="$MODEL_ID"
export QWEN_MODEL="$MODEL_ID"

# Variables nécessaires aux sous-processus/watchdogs
export WORK_MINUTES FINALIZE_MINUTES WATCHDOG_MINUTES
export FAILURE_GRACE_MINUTES MAX_SESSION_TURNS

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

cd "$REPO"

# ------------------------------------------------------------
# Hard watchdog: 90 minutes from NOW, completely independent.
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
  RUNPOD_API_KEY="$RUNPOD_CONTROL_API_KEY" \
    runpodctl pod stop "$RUNPOD_POD_ID" || true
fi
' >> "$LOGDIR/hard-stop-v2-$RUN_ID.log" 2>&1 &

WATCHDOG_PID=$!

echo "Hard watchdog PID: $WATCHDOG_PID"
echo "Absolute maximum Pod runtime from runner start: $WATCHDOG_MINUTES min"

# ------------------------------------------------------------
# Deadline information visible to Qwen.
# ------------------------------------------------------------

START_EPOCH="$(date +%s)"
FINALIZE_EPOCH=$((START_EPOCH + WORK_MINUTES*60))

FINALIZE_UTC="$(date -u -d "@$FINALIZE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"

cat > QWEN_DEADLINE.md <<DEADLINE
# QWEN DEADLINE

RUN_ID: $RUN_ID
RUN_STARTED_UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
FINALIZATION_DEADLINE: $FINALIZE_UTC

At or before FINALIZATION_DEADLINE:
- stop starting new features;
- finish the current safe edit;
- update QWEN_PROGRESS.md;
- leave the repository in a coherent state.

A separate finalization agent will then run tests, inspect the diff and create QWEN_REPORT.md.
DEADLINE

cat > QWEN_PROGRESS.md <<PROGRESS
# QWEN_PROGRESS

Run: $RUN_ID
Started UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Status: starting autonomous run

Waiting for Qwen Code.
PROGRESS

cat > QWEN_EXIT.log <<EXITLOG
run_id=$RUN_ID
started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
status=RUNNING
EXITLOG

# Reset run-specific telemetry.
echo 'timestamp_utc,requests_running,requests_waiting,kv_cache_pct,kv_context_equivalent,max_context,prompt_tokens_total,generation_tokens_total,gpu_util_pct,vram_used_mib,vram_total_mib' > QWEN_TELEMETRY.csv

# ------------------------------------------------------------
# Start / verify vLLM.
# ------------------------------------------------------------

if curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
  echo "vLLM already running."
else
  echo "Starting vLLM..."

  tmux kill-session -t vllm 2>/dev/null || true

  tmux new-session -d -s vllm \
    "bash -lc '$QWEN_RUNPOD_BASE/start_vllm.sh >> $LOGDIR/vllm-$RUN_ID.log 2>&1'"

  echo "Waiting for vLLM API..."

  READY=0

  for i in $(seq 1 144); do
    if curl -fsS http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
      READY=1
      break
    fi

    sleep 5
  done

  if [[ "$READY" != "1" ]]; then
    echo "ERROR: vLLM failed to become ready within 12 minutes."
    echo "status=VLLM_START_FAILED" >> QWEN_EXIT.log

    "$QWEN_RUNPOD_BASE/autosave.sh" once || true

    CODE=$(curl -sS \
      -o "$STOP_LOG" \
      -w "%{http_code}" \
      -X POST \
      "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID/stop" \
      -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY" || true)

    echo "Stop HTTP=$CODE" >> "$STOP_LOG"
    exit 30
  fi
fi

echo "vLLM READY: $(date -u)"

curl -s http://127.0.0.1:8000/v1/models \
  | jq '.data[0] | {id,max_model_len}' || true

# ------------------------------------------------------------
# Telemetry
# ------------------------------------------------------------

echo "Starting telemetry."

"$REPO/tools/qwen/qwen-telemetry.sh" \
  >> "$LOGDIR/telemetry-$RUN_ID.log" 2>&1 &
TELEMETRY_PID=$!

"$REPO/tools/qwen/qwen-request-telemetry.sh" \
  >> "$LOGDIR/request-telemetry-$RUN_ID.log" 2>&1 &
REQUEST_TELEMETRY_PID=$!

echo "Telemetry PID: $TELEMETRY_PID"
echo "Request telemetry PID: $REQUEST_TELEMETRY_PID"

# ------------------------------------------------------------
# External Git autosave
# ------------------------------------------------------------

"$QWEN_RUNPOD_BASE/autosave.sh" loop \
  >> "$LOGDIR/autosave-$RUN_ID.log" 2>&1 &
AUTOSAVE_PID=$!

echo "Autosave PID: $AUTOSAVE_PID"

# ------------------------------------------------------------
# MAIN QWEN RUN
# ------------------------------------------------------------

echo
echo "=== MAIN QWEN AGENT ==="
echo "Maximum work phase: $WORK_MINUTES minutes"
echo "Finalization deadline: $FINALIZE_UTC"

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
    -p "$(cat QWEN_MISSION.md)" \
    --yolo \
    --max-wall-time "${WORK_MINUTES}m" \
    --max-session-turns "$MAX_SESSION_TURNS" \
    2>&1 | tee "$MAIN_LOG"

MAIN_STATUS=${PIPESTATUS[0]}

set -e

MAIN_RUNTIME=$(( $(date +%s) - MAIN_STARTED_EPOCH ))

# Si Qwen plante quasi immédiatement, on NE stoppe PAS le Pod tout de suite.
# On laisse FAILURE_GRACE_MINUTES pour corriger le problème.
if [[ "$MAIN_STATUS" -ne 0 && "$MAIN_RUNTIME" -lt 180 ]]; then
    echo
    echo "=== EARLY QWEN FAILURE ==="
    echo "Exit code: $MAIN_STATUS"
    echo "Runtime: ${MAIN_RUNTIME}s"
    echo "Pod conservé pendant $FAILURE_GRACE_MINUTES minutes."

    echo "status=EARLY_QWEN_FAILURE" >> QWEN_EXIT.log
    echo "main_exit_code=$MAIN_STATUS" >> QWEN_EXIT.log
    echo "main_runtime_seconds=$MAIN_RUNTIME" >> QWEN_EXIT.log

    kill "$TELEMETRY_PID" "$REQUEST_TELEMETRY_PID" "$AUTOSAVE_PID" 2>/dev/null || true
    "$QWEN_RUNPOD_BASE/autosave.sh" once || true

    # Remplace le watchdog 90 min par une courte période de grâce.
    kill "$WATCHDOG_PID" 2>/dev/null || true

    nohup bash -lc '
      sleep "$((FAILURE_GRACE_MINUTES * 60))"
      curl -sS -X POST         "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID/stop"         -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY"         >/tmp/qwen-grace-stop.json 2>&1 || true
    ' >> "$LOGDIR/grace-stop-$RUN_ID.log" 2>&1 &

    echo "Grace-stop PID: $!"
    exit "$MAIN_STATUS"
fi

echo "main_exit_code=$MAIN_STATUS" >> QWEN_EXIT.log
echo "main_finished_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> QWEN_EXIT.log

"$QWEN_RUNPOD_BASE/autosave.sh" once || true

# ------------------------------------------------------------
# Dedicated FINALIZER
# ------------------------------------------------------------

echo
echo "=== FINALIZATION AGENT ==="
echo "Maximum finalization phase: $FINALIZE_MINUTES minutes"

FINAL_PROMPT='
You are the finalization engineer for this autonomous run.

DO NOT start a new feature.

Read:
- QWEN_MISSION.md
- QWEN_PLAN.md if present
- QWEN_PROGRESS.md
- QWEN_DEADLINE.md
- git status
- git diff

Your only responsibilities now are:

1. Finish only a small incomplete edit if leaving it unfinished would break the repository.
2. Run the practical validation gates:
   - pnpm lint
   - pnpm build
   - pnpm test
   - pnpm security:audit
   Use the safest reasonable subset if environment limitations prevent a command.
3. Do NOT disable or weaken tests.
4. Inspect the final diff.
5. Remove temporary/debug artifacts created by the coding work.
6. Update QWEN_PROGRESS.md with final status.
7. Create QWEN_REPORT.md containing:
   - work completed
   - files/features changed
   - exact tests run
   - pass/fail results
   - unresolved failures
   - known issues
   - recommended next steps
   - whether the repository is safe to continue from
8. Do not commit or push. External automation handles Git persistence.

Finish cleanly and promptly.
'

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

# ------------------------------------------------------------
# Stop telemetry before final Git checkpoint.
# ------------------------------------------------------------

kill "$TELEMETRY_PID" "$REQUEST_TELEMETRY_PID" 2>/dev/null || true
wait "$TELEMETRY_PID" "$REQUEST_TELEMETRY_PID" 2>/dev/null || true

kill "$AUTOSAVE_PID" 2>/dev/null || true
wait "$AUTOSAVE_PID" 2>/dev/null || true

echo "status=FINISHED" >> QWEN_EXIT.log
echo "finished_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> QWEN_EXIT.log

# ------------------------------------------------------------
# Final Git checkpoint.
# ------------------------------------------------------------

echo
echo "=== FINAL GIT CHECKPOINT ==="

"$QWEN_RUNPOD_BASE/autosave.sh" once || true

GIT_ASKPASS="$QWEN_RUNPOD_BASE/git-askpass.sh" \
GIT_TERMINAL_PROMPT=0 \
git push origin qwen-autonomous || true

git status || true

# ------------------------------------------------------------
# Stop Pod using the CONTROL key that we tested HTTP=200 with.
# ------------------------------------------------------------

echo
echo "=== STOPPING RUNPOD ==="
echo "Timestamp: $(date -u)" | tee -a "$STOP_LOG"

SUCCESS=0

for attempt in 1 2 3 4 5; do

  echo "Attempt $attempt" | tee -a "$STOP_LOG"

  CODE=$(curl -sS \
    -o /tmp/qwen-stop-response \
    -w "%{http_code}" \
    --connect-timeout 10 \
    --max-time 30 \
    -X POST \
    "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID/stop" \
    -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY" || true)

  echo "HTTP=$CODE" | tee -a "$STOP_LOG"
  cat /tmp/qwen-stop-response 2>/dev/null | tee -a "$STOP_LOG" || true

  if [[ "$CODE" == "200" || "$CODE" == "202" || "$CODE" == "204" ]]; then
    SUCCESS=1
    break
  fi

  sleep 10
done

if [[ "$SUCCESS" != "1" ]]; then
  echo "REST stop failed. Trying runpodctl fallback." | tee -a "$STOP_LOG"

  RUNPOD_API_KEY="$RUNPOD_CONTROL_API_KEY" \
    runpodctl pod stop "$RUNPOD_POD_ID" \
    >> "$STOP_LOG" 2>&1 || true
fi

echo "Stop command sent."
