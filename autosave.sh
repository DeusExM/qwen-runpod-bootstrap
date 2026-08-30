
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${QWEN_RUNPOD_BASE:-/workspace/qwen-runpod}"

source "$BASE/env.sh"
source "$BASE/qwen-config.env"

REPO="${REPO_DIR:-/workspace/jeu-tactical-qwen-test}"
BRANCH="${BRANCH:-qwen-autonomous}"
INTERVAL="${AUTOSAVE_INTERVAL:-300}"

LOCK_FILE="$BASE/autosave.lock"
ASKPASS="$BASE/git-askpass.sh"

mkdir -p "$BASE"

save_once() {
    (
        flock -w 30 9 || {
            echo "[$(date -u)] Autosave déjà en cours, skip."
            return 0
        }

        cd "$REPO" || return 0

        echo "[$(date -u)] Autosave..."

        # Sauvegarde tout le travail courant de Qwen :
        # code, QWEN_PROGRESS.md, QWEN_REPORT.md, télémétrie, etc.
        git add -A || true

        if ! git diff --cached --quiet 2>/dev/null; then
            git commit \
                -m "Qwen checkpoint $(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
                || true
        fi

        # Le push ne doit jamais bloquer indéfiniment le runner.
        timeout 60s env \
            GIT_ASKPASS="$ASKPASS" \
            GIT_TERMINAL_PROMPT=0 \
            git push origin "$BRANCH" \
            || echo "[$(date -u)] ATTENTION: push autosave échoué ou timeout."

    ) 9>"$LOCK_FILE"
}

case "${1:-once}" in
    once)
        save_once
        ;;

    loop)
        echo "Autosave actif toutes les ${INTERVAL}s."

        while true; do
            save_once
            sleep "$INTERVAL"
        done
        ;;

    *)
        echo "Usage: $0 [once|loop]"
        exit 2
        ;;
esac
