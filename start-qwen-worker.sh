#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="${QWEN_RUNPOD_BASE:-/opt/qwen-runpod}"

# Heure de départ conservée même lors du détachement dans tmux.
WORKER_START_EPOCH="${QWEN_WORKER_START_EPOCH:-$(date +%s)}"

BOOTSTRAP_SECONDS=0
GIT_TEST_SECONDS=0
VLLM_SECONDS=0
QWEN_TEST_SECONDS=0

format_duration() {
    local total="${1:-0}"
    printf '%dm %02ds' "$((total / 60))" "$((total % 60))"
}

echo_phase_time() {
    local name="$1"
    local seconds="$2"
    echo "⏱  $name : $(format_duration "$seconds")"
}

# ------------------------------------------------------------
# 1. tmux doit exister avant de pouvoir détacher le worker
# ------------------------------------------------------------

if ! command -v tmux >/dev/null 2>&1; then
    echo "Installation minimale de tmux..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
fi

# ------------------------------------------------------------
# 2. Détacher automatiquement le worker de la connexion SSH
# ------------------------------------------------------------

if [[ -z "${TMUX:-}" && "${QWEN_WORKER_DETACHED:-0}" != "1" ]]; then

    if tmux has-session -t qwen-worker 2>/dev/null; then
        echo "✅ qwen-worker tourne déjà."
        echo "Suivi : tail -f /workspace/qwen-worker.log"
        exit 0
    fi

    tmux new-session -d -s qwen-worker \
        "export QWEN_WORKER_DETACHED=1; \
         export QWEN_WORKER_START_EPOCH=$WORKER_START_EPOCH; \
         cd \"$BOOTSTRAP_DIR\" && \
         ./start-qwen-worker.sh 2>&1 | tee /workspace/qwen-worker.log"

    echo "✅ qwen-worker lancé en arrière-plan."
    echo "Une coupure SSH ne l'arrêtera plus."
    echo "Suivi : tail -f /workspace/qwen-worker.log"
    exit 0
fi

echo "=== QWEN WORKER START ==="
echo "Début initialisation : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo

# ------------------------------------------------------------
# 3. Bootstrap complet si le Pod est vierge
# ------------------------------------------------------------

BOOTSTRAP_START="$(date +%s)"

if [[ ! -x "$BASE/bin/qwen" || \
      ! -x "$BASE/venv/bin/vllm" || \
      ! -x "$BASE/bin/node" || \
      ! -f "$BASE/env.sh" ]]; then

    echo "Environnement absent -> bootstrap"

    "$BOOTSTRAP_DIR/bootstrap-qwen.sh"
else
    echo "✅ Environnement déjà installé -> bootstrap ignoré"
fi

BOOTSTRAP_SECONDS=$(( $(date +%s) - BOOTSTRAP_START ))
echo_phase_time "Bootstrap" "$BOOTSTRAP_SECONDS"

# ------------------------------------------------------------
# 4. Charger la configuration créée par le bootstrap
# ------------------------------------------------------------

source "$BASE/env.sh"
source "$BASE/qwen-config.env"

# ------------------------------------------------------------
# 5. Préflight rapide
# ------------------------------------------------------------

FAILED=0

command -v nvidia-smi >/dev/null 2>&1 \
    && echo "✅ NVIDIA GPU" \
    || { echo "❌ NVIDIA GPU"; FAILED=1; }

[[ -x "$BASE/bin/node" ]] \
    && echo "✅ Node.js" \
    || { echo "❌ Node.js"; FAILED=1; }

[[ -x "$BASE/bin/qwen" ]] \
    && echo "✅ Qwen Code" \
    || { echo "❌ Qwen Code"; FAILED=1; }

[[ -x "$BASE/venv/bin/vllm" ]] \
    && echo "✅ vLLM" \
    || { echo "❌ vLLM"; FAILED=1; }

[[ -d "$REPO_DIR/.git" ]] \
    && echo "✅ Repository" \
    || { echo "❌ Repository"; FAILED=1; }

[[ -n "${GITHUB_TOKEN:-}" ]] \
    && echo "✅ GITHUB_TOKEN" \
    || { echo "❌ GITHUB_TOKEN"; FAILED=1; }

[[ -n "${RUNPOD_CONTROL_API_KEY:-}" ]] \
    && echo "✅ RUNPOD_CONTROL_API_KEY" \
    || { echo "❌ RUNPOD_CONTROL_API_KEY"; FAILED=1; }

[[ -n "${RUNPOD_POD_ID:-}" ]] \
    && echo "✅ RUNPOD_POD_ID" \
    || { echo "❌ RUNPOD_POD_ID"; FAILED=1; }

[[ -f "$BOOTSTRAP_DIR/autosave.sh" ]] \
    && echo "✅ autosave.sh maître" \
    || { echo "❌ autosave.sh maître absent"; FAILED=1; }

[[ -f "$BOOTSTRAP_DIR/run-v2.sh" ]] \
    && echo "✅ run-v2.sh maître" \
    || { echo "❌ run-v2.sh maître absent"; FAILED=1; }

command -v flock >/dev/null 2>&1 \
    && echo "✅ flock" \
    || { echo "❌ flock"; FAILED=1; }

command -v timeout >/dev/null 2>&1 \
    && echo "✅ timeout" \
    || { echo "❌ timeout"; FAILED=1; }

if [[ "$FAILED" != "0" ]]; then
    echo "❌ PREFLIGHT LOCAL FAILED"
    echo "Qwen et vLLM ne seront pas lancés."
    exit 20
fi

# ------------------------------------------------------------
# 6. Vérifier qu'on est bien sur la branche attendue
# ------------------------------------------------------------

CURRENT_BRANCH="$(git -C "$REPO_DIR" branch --show-current)"

if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    echo "❌ Mauvaise branche Git."
    echo "Attendue : $BRANCH"
    echo "Actuelle : $CURRENT_BRANCH"
    exit 21
fi

echo "✅ Branche Git : $CURRENT_BRANCH"

# ------------------------------------------------------------
# 7. Vérifier l'accès GitHub
# ------------------------------------------------------------

if (
    cd "$REPO_DIR"

    GIT_ASKPASS="$BASE/git-askpass.sh" \
    GIT_TERMINAL_PROMPT=0 \
    git ls-remote origin HEAD >/dev/null 2>&1
); then
    echo "✅ GitHub accès lecture"
else
    echo "❌ GitHub accès impossible"
    echo "Qwen et vLLM ne seront pas lancés."
    exit 22
fi

# ------------------------------------------------------------
# 8. Vérifier l'API RunPod
# ------------------------------------------------------------

HTTP_CODE="$(
    curl -sS \
        -o /tmp/qwen-runpod-preflight.json \
        -w '%{http_code}' \
        --connect-timeout 10 \
        --max-time 20 \
        -H "Authorization: Bearer $RUNPOD_CONTROL_API_KEY" \
        "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID" \
        || true
)"

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✅ RunPod API HTTP 200"
else
    echo "❌ RunPod API HTTP $HTTP_CODE"
    echo "Qwen et vLLM ne seront pas lancés."
    exit 23
fi

# ------------------------------------------------------------
# 9. Éviter de lancer deux agents
# ------------------------------------------------------------

if tmux has-session -t qwen-v2 2>/dev/null; then
    echo "❌ qwen-v2 tourne déjà."
    exit 24
fi

# ------------------------------------------------------------
# 10. Installer les scripts maîtres
# ------------------------------------------------------------

echo
echo "=== INSTALLATION SCRIPTS MAÎTRES ==="

install -m 755 \
    "$BOOTSTRAP_DIR/autosave.sh" \
    "$BASE/autosave.sh"

install -m 755 \
    "$BOOTSTRAP_DIR/run-v2.sh" \
    "$REPO_DIR/tools/qwen/run-v2.sh"

bash -n "$BASE/autosave.sh"
bash -n "$REPO_DIR/tools/qwen/run-v2.sh"

echo "✅ autosave.sh installé"
echo "✅ run-v2.sh installé"
echo "✅ Syntaxe scripts valide"

# ------------------------------------------------------------
# 11. TEST RÉEL : commit + push + comparaison du SHA
# ------------------------------------------------------------

echo
echo "=== TEST RÉEL GIT COMMIT + PUSH ==="

GIT_TEST_START="$(date +%s)"

if ! "$BASE/autosave.sh" test; then
    GIT_TEST_SECONDS=$(( $(date +%s) - GIT_TEST_START ))
    echo_phase_time "Test Git" "$GIT_TEST_SECONDS"

    echo
    echo "❌ TEST COMMIT/PUSH GITHUB FAILED"
    echo "vLLM et Qwen ne seront PAS lancés."
    echo "Le Pod reste disponible pour diagnostic."
    exit 25
fi

GIT_TEST_SECONDS=$(( $(date +%s) - GIT_TEST_START ))

echo "✅ COMMIT/PUSH GITHUB VALIDÉ"
echo_phase_time "Test Git" "$GIT_TEST_SECONDS"

# ------------------------------------------------------------
# 12. Démarrer vLLM seulement après validation Git
# ------------------------------------------------------------

echo
echo "=== VLLM ==="

VLLM_START="$(date +%s)"

if curl -fsS \
    "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" \
    >/dev/null 2>&1; then

    echo "✅ vLLM déjà prêt"

else
    echo "Démarrage vLLM..."

    mkdir -p "$BASE/logs"

    tmux kill-session -t vllm 2>/dev/null || true

    tmux new-session -d -s vllm \
        "bash -lc '$BASE/start_vllm.sh > $BASE/logs/vllm-worker.log 2>&1'"

    READY=0

    for i in $(seq 1 180); do

        if curl -fsS \
            "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" \
            >/dev/null 2>&1; then

            READY=1
            break
        fi

        if (( i % 6 == 0 )); then
            echo "Chargement... $((i * 5)) sec"
        fi

        sleep 5
    done

    if [[ "$READY" != "1" ]]; then
        VLLM_SECONDS=$(( $(date +%s) - VLLM_START ))
        echo_phase_time "Chargement vLLM/modèle" "$VLLM_SECONDS"

        echo "❌ vLLM non prêt après 15 min."
        tail -60 "$BASE/logs/vllm-worker.log" 2>/dev/null || true
        echo "Le Pod reste disponible pour diagnostic."
        exit 30
    fi
fi

VLLM_SECONDS=$(( $(date +%s) - VLLM_START ))

SERVED_MODEL="$(
    curl -fsS \
        "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" \
        | jq -r '.data[0].id // empty'
)"

if [[ -z "$SERVED_MODEL" ]]; then
    echo "❌ Aucun modèle servi."
    exit 31
fi

echo "✅ Modèle servi : $SERVED_MODEL"
echo_phase_time "Chargement vLLM/modèle" "$VLLM_SECONDS"

# ------------------------------------------------------------
# 13. Micro-test réel Qwen -> vLLM
# ------------------------------------------------------------

echo
echo "=== MICRO-TEST QWEN ==="

QWEN_TEST_START="$(date +%s)"

set +e

QWEN_TEST_OUTPUT="$(
    QWEN_CODE_SUPPRESS_YOLO_WARNING=1 \
    OPENAI_API_KEY="local-vllm" \
    OPENAI_BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}/v1" \
    OPENAI_MODEL="$MODEL_ID" \
    QWEN_MODEL="$MODEL_ID" \
    "$BASE/bin/qwen" \
        -p "Ne modifie aucun fichier. Réponds uniquement exactement par QWEN_WORKER_OK" \
        --yolo \
        --max-wall-time 2m \
        --max-session-turns 2 \
        2>&1
)"

QWEN_TEST_STATUS=$?

set -e

QWEN_TEST_SECONDS=$(( $(date +%s) - QWEN_TEST_START ))

echo "$QWEN_TEST_OUTPUT"
echo_phase_time "Micro-test Qwen" "$QWEN_TEST_SECONDS"

if [[ "$QWEN_TEST_STATUS" -ne 0 ]] || \
   ! grep -q "QWEN_WORKER_OK" <<< "$QWEN_TEST_OUTPUT"; then

    echo "❌ MICRO-TEST QWEN FAILED"
    echo "Le run autonome ne sera pas lancé."
    exit 40
fi

echo "✅ QWEN_WORKER_OK"

# ------------------------------------------------------------
# 14. Dernière vérification du runner
# ------------------------------------------------------------

RUNNER="$REPO_DIR/tools/qwen/run-v2.sh"

[[ -x "$RUNNER" ]] || {
    echo "❌ Runner absent : $RUNNER"
    exit 50
}

bash -n "$RUNNER"

# ------------------------------------------------------------
# 15. Lancer le vrai run autonome
# ------------------------------------------------------------

echo
echo "=== ALL CHECKS PASSED ==="
echo "Git commit/push : ✅"
echo "RunPod API      : ✅"
echo "vLLM            : ✅"
echo "Qwen Code       : ✅"
echo
echo "Lancement qwen-v2..."

tmux new-session -d -s qwen-v2 \
    "bash -lc 'cd \"$REPO_DIR\" && ./tools/qwen/run-v2.sh'"

sleep 2

if tmux has-session -t qwen-v2 2>/dev/null; then

    TOTAL_SECONDS=$(( $(date +%s) - WORKER_START_EPOCH ))

    echo "✅ qwen-v2 lancé."
    echo
    tmux ls
    echo

    {
        echo
        echo "=== TEMPS INITIALISATION ==="
        printf 'Bootstrap          : %s\n' "$(format_duration "$BOOTSTRAP_SECONDS")"
        printf 'Test Git           : %s\n' "$(format_duration "$GIT_TEST_SECONDS")"
        printf 'Chargement vLLM    : %s\n' "$(format_duration "$VLLM_SECONDS")"
        printf 'Micro-test Qwen    : %s\n' "$(format_duration "$QWEN_TEST_SECONDS")"
        echo "--------------------------------"
        printf 'TOTAL              : %s\n' "$(format_duration "$TOTAL_SECONDS")"
        echo "Qwen autonome prêt : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo
    } | tee "$REPO_DIR/QWEN_INIT_TIMING.md"
    timeout 90s "$BASE/autosave.sh" once || true
    
    echo "Suivi :"
    echo "tail -f /workspace/qwen-worker.log"

else
    echo "❌ qwen-v2 s'est terminé immédiatement."
    exit 70
fi
