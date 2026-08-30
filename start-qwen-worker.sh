#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="${QWEN_RUNPOD_BASE:-/workspace/qwen-runpod}"

echo "=== QWEN WORKER START ==="

if [[ ! -x "$BASE/bin/qwen" || ! -x "$BASE/venv/bin/vllm" ]]; then
  echo "Environnement absent -> bootstrap"
  "$BOOTSTRAP_DIR/bootstrap-qwen.sh"
fi

source "$BASE/env.sh"
source "$BASE/qwen-config.env"

FAILED=0

command -v nvidia-smi >/dev/null 2>&1   && echo "✅ NVIDIA GPU"   || { echo "❌ NVIDIA GPU"; FAILED=1; }

[[ -x "$BASE/bin/qwen" ]]   && echo "✅ Qwen Code"   || { echo "❌ Qwen Code"; FAILED=1; }

[[ -x "$BASE/venv/bin/vllm" ]]   && echo "✅ vLLM"   || { echo "❌ vLLM"; FAILED=1; }

[[ -d "$REPO_DIR/.git" ]]   && echo "✅ Repository"   || { echo "❌ Repository"; FAILED=1; }

[[ -n "${GITHUB_TOKEN:-}" ]]   && echo "✅ GITHUB_TOKEN"   || { echo "❌ GITHUB_TOKEN"; FAILED=1; }

[[ -n "${RUNPOD_CONTROL_API_KEY:-}" ]]   && echo "✅ RUNPOD_CONTROL_API_KEY"   || { echo "❌ RUNPOD_CONTROL_API_KEY"; FAILED=1; }

[[ -n "${RUNPOD_POD_ID:-}" ]]   && echo "✅ RUNPOD_POD_ID"   || { echo "❌ RUNPOD_POD_ID"; FAILED=1; }

if [[ -d "$REPO_DIR/.git" && -n "${GITHUB_TOKEN:-}" ]]; then
  if (
    cd "$REPO_DIR"
    GIT_ASKPASS="$BASE/git-askpass.sh"     GIT_TERMINAL_PROMPT=0     git ls-remote origin HEAD >/dev/null 2>&1
  ); then
    echo "✅ GitHub accès"
  else
    echo "❌ GitHub accès"
    FAILED=1
  fi
fi

if [[ -n "${RUNPOD_CONTROL_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
  HTTP_CODE="$(
    curl -sS       -o /tmp/qwen-runpod-preflight.json       -w '%{http_code}'       --connect-timeout 10       --max-time 20       -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY"       "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID"       || true
  )"

  [[ "$HTTP_CODE" == "200" ]]     && echo "✅ RunPod API HTTP 200"     || { echo "❌ RunPod API HTTP $HTTP_CODE"; FAILED=1; }
fi

if [[ "$FAILED" != "0" ]]; then
  echo "PREFLIGHT FAILED - le Pod reste allumé."
  exit 20
fi

if curl -fsS "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
  echo "✅ vLLM déjà prêt"
else
  echo "Démarrage vLLM..."
  mkdir -p "$BASE/logs"
  tmux kill-session -t vllm 2>/dev/null || true
  tmux new-session -d -s vllm     "bash -lc '$BASE/start_vllm.sh > $BASE/logs/vllm-worker.log 2>&1'"

  READY=0
  for i in $(seq 1 180); do
    if curl -fsS "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
      READY=1
      break
    fi

    if (( i % 6 == 0 )); then
      echo "Chargement... $((i*5)) sec"
    fi
    sleep 5
  done

  if [[ "$READY" != "1" ]]; then
    echo "❌ vLLM non prêt après 15 min."
    tail -60 "$BASE/logs/vllm-worker.log" 2>/dev/null || true
    echo "Le Pod reste allumé."
    exit 30
  fi
fi

SERVED_MODEL="$(
  curl -fsS "http://${VLLM_HOST}:${VLLM_PORT}/v1/models"   | jq -r '.data[0].id // empty'
)"
[[ -n "$SERVED_MODEL" ]] || {
  echo "❌ Aucun modèle servi."
  exit 31
}
echo "✅ Modèle servi: $SERVED_MODEL"

set +e
QWEN_TEST_OUTPUT="$(
  QWEN_CODE_SUPPRESS_YOLO_WARNING=1   OPENAI_API_KEY="local-vllm"   OPENAI_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}/v1"   OPENAI_MODEL="$MODEL_ID"   QWEN_MODEL="$MODEL_ID"   "$BASE/bin/qwen"     -p "Ne modifie aucun fichier. Réponds uniquement exactement par QWEN_WORKER_OK"     --yolo     --max-wall-time 2m     --max-session-turns 2     2>&1
)"
QWEN_TEST_STATUS=$?
set -e

echo "$QWEN_TEST_OUTPUT"

if [[ "$QWEN_TEST_STATUS" -ne 0 ]] || ! grep -q "QWEN_WORKER_OK" <<< "$QWEN_TEST_OUTPUT"; then
  echo "❌ MICRO-TEST QWEN FAILED - le Pod reste allumé."
  exit 40
fi

RUNNER="$REPO_DIR/tools/qwen/run-v2.sh"
[[ -x "$RUNNER" ]] || {
  echo "❌ Runner absent: $RUNNER"
  exit 50
}
bash -n "$RUNNER"

if tmux has-session -t qwen-v2 2>/dev/null; then
  echo "❌ qwen-v2 existe déjà."
  exit 60
fi

echo "✅ ALL CHECKS PASSED"
tmux new-session -d -s qwen-v2   "bash -lc 'cd "$REPO_DIR" && ./tools/qwen/run-v2.sh'"

sleep 2

if tmux has-session -t qwen-v2 2>/dev/null; then
  echo "✅ qwen-v2 lancé."
  tmux ls
else
  echo "❌ qwen-v2 s'est terminé immédiatement."
  exit 70
fi
