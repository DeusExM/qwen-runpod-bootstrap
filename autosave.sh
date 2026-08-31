#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${QWEN_RUNPOD_BASE:-/opt/qwen-runpod}"

source "$BASE/env.sh"
source "$BASE/qwen-config.env"

DATA_ROOT="${QWEN_DATA_ROOT:-/opt/qwen-data}"
REPO="${REPO_DIR:-$DATA_ROOT/jeu-tactical-qwen-test}"
BRANCH="${BRANCH:-qwen-autonomous}"
INTERVAL="${AUTOSAVE_INTERVAL:-300}"

LOCK_FILE="$BASE/autosave.lock"
ASKPASS="$BASE/git-askpass.sh"

mkdir -p "$BASE"

# ------------------------------------------------------------
# Sauvegarde du travail courant
# ------------------------------------------------------------

save_once() {
    (
        # Empêche deux autosaves de travailler sur Git en même temps.
        flock -w 30 9 || {
            echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Autosave déjà en cours, skip."
            return 0
        }

        if [[ ! -d "$REPO/.git" ]]; then
            echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ATTENTION: dépôt Git absent: $REPO"
            return 1
        fi

        cd "$REPO"

        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Autosave..."

        # Sauvegarde absolument tout le travail courant :
        # - code
        # - QWEN_PROGRESS.md
        # - QWEN_REPORT.md
        # - QWEN_EXIT.log
        # - télémétrie
        # - timing d'initialisation
        # - suppressions éventuelles de fichiers
        git add -A || true

        if ! git diff --cached --quiet 2>/dev/null; then
            git commit \
                -m "Qwen checkpoint $(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
                || true
        else
            echo "Aucun changement à commit."
        fi

        # Le push ne doit JAMAIS bloquer indéfiniment le Pod.
        timeout 60s env \
            GIT_ASKPASS="$ASKPASS" \
            GIT_TERMINAL_PROMPT=0 \
            git push origin "$BRANCH" \
            || echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ATTENTION: push autosave échoué ou timeout."

    ) 9>"$LOCK_FILE"
}

# ------------------------------------------------------------
# Vrai test Git avant de charger le modèle
#
# Crée volontairement un commit vide, le pousse,
# puis vérifie que le SHA distant correspond exactement.
# ------------------------------------------------------------

test_git() {
    (
        flock -w 30 9 || {
            echo "❌ Impossible d'obtenir le verrou Git."
            return 1
        }

        if [[ ! -d "$REPO/.git" ]]; then
            echo "❌ Dépôt Git absent: $REPO"
            return 1
        fi

        cd "$REPO"

        echo "=== TEST COMMIT + PUSH ==="

        git commit --allow-empty \
            -m "Qwen autosave preflight $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

        timeout 60s env \
            GIT_ASKPASS="$ASKPASS" \
            GIT_TERMINAL_PROMPT=0 \
            git push origin "$BRANCH"

        LOCAL_SHA="$(git rev-parse HEAD)"

        REMOTE_SHA="$(
            timeout 60s env \
                GIT_ASKPASS="$ASKPASS" \
                GIT_TERMINAL_PROMPT=0 \
                git ls-remote origin "refs/heads/$BRANCH" \
                | awk '{print $1}'
        )"

        if [[ -z "$REMOTE_SHA" ]]; then
            echo "❌ TEST GIT FAILED"
            echo "Impossible de lire le SHA distant."
            return 1
        fi

        if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
            echo "❌ TEST GIT FAILED"
            echo "Local  : $LOCAL_SHA"
            echo "Remote : $REMOTE_SHA"
            return 1
        fi

        echo "✅ AUTOSAVE COMMIT/PUSH TEST OK"
        echo "SHA: $LOCAL_SHA"

    ) 9>"$LOCK_FILE"
}

# ------------------------------------------------------------
# Modes
# ------------------------------------------------------------

case "${1:-once}" in

    test)
        test_git
        ;;

    once)
        save_once
        ;;

    loop)
        echo "Autosave actif toutes les ${INTERVAL}s."

        while true; do
            save_once || true
            sleep "$INTERVAL"
        done
        ;;

    *)
        echo "Usage: $0 [test|once|loop]"
        exit 2
        ;;

esac
