#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${QWEN_RUNPOD_BASE:-/workspace/qwen-runpod}"
VLLM_VERSION="${VLLM_VERSION:-0.28.0}"
QWEN_CODE_VERSION="${QWEN_CODE_VERSION:-0.22.3}"

MODEL_ID="${MODEL_ID:-barrydeen/Qwen3.8-27B-AWQ-4bit}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-128}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-1}"
REASONING_PARSER="${REASONING_PARSER:-qwen3}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-qwen3_coder}"

REPO_URL="${REPO_URL:-https://github.com/DeusExM/jeu-tactical-qwen-test.git}"
REPO_DIR="${REPO_DIR:-/workspace/jeu-tactical-qwen-test}"
BRANCH="${BRANCH:-qwen-autonomous}"

WORK_MINUTES="${WORK_MINUTES:-62}"
FINALIZE_MINUTES="${FINALIZE_MINUTES:-8}"
WATCHDOG_MINUTES="${WATCHDOG_MINUTES:-90}"
FAILURE_GRACE_MINUTES="${FAILURE_GRACE_MINUTES:-15}"
MAX_SESSION_TURNS="${MAX_SESSION_TURNS:-1000}"

echo "=== QWEN POD BOOTSTRAP ==="

command -v nvidia-smi >/dev/null 2>&1 || {
  echo "ERREUR: aucun GPU NVIDIA détecté."
  exit 10
}

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
GPU_VRAM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"

echo "GPU: $GPU_NAME (${GPU_VRAM} MiB)"
echo "Model: $MODEL_ID"
echo "Context: $MAX_MODEL_LEN"

[[ -n "${GITHUB_TOKEN:-}" ]] || {
  echo "ERREUR: GITHUB_TOKEN absent."
  exit 11
}

[[ -n "${RUNPOD_CONTROL_API_KEY:-}" ]] ||   echo "ATTENTION: RUNPOD_CONTROL_API_KEY absent."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y git curl jq tmux ca-certificates python3 python3-venv python3-pip build-essential


# Node.js persistant dans /workspace
NODE_VERSION="${NODE_VERSION:-22.23.2}"
NODE_ROOT="$BASE/node"
NODE_ARCHIVE="/tmp/node-v${NODE_VERSION}-linux-x64.tar.xz"

if [[ ! -x "$NODE_ROOT/bin/node" ]]; then
  echo "Installation Node.js $NODE_VERSION dans $NODE_ROOT..."

  rm -rf "$NODE_ROOT"
  mkdir -p "$NODE_ROOT"

  curl -fsSL \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    -o "$NODE_ARCHIVE"

  tar -xJf "$NODE_ARCHIVE" \
    --strip-components=1 \
    -C "$NODE_ROOT"

  rm -f "$NODE_ARCHIVE"
fi

mkdir -p "$BASE/bin"

ln -sf "$NODE_ROOT/bin/node" "$BASE/bin/node"
ln -sf "$NODE_ROOT/bin/npm" "$BASE/bin/npm"
ln -sf "$NODE_ROOT/bin/npx" "$BASE/bin/npx"
ln -sf "$NODE_ROOT/bin/corepack" "$BASE/bin/corepack"

export PATH="$BASE/bin:$NODE_ROOT/bin:$PATH"

echo "Node: $(node --version)"
echo "npm: $(npm --version)"

mkdir -p "$BASE/bin" "$BASE/logs" "$BASE/qwen-home" /workspace/.cache/huggingface

if [[ ! -x "$BASE/venv/bin/vllm" ]]; then
  python3 -m venv "$BASE/venv"
  "$BASE/venv/bin/python" -m pip install --upgrade pip wheel setuptools
  "$BASE/venv/bin/pip" install "vllm==$VLLM_VERSION"
fi

if [[ ! -x "$BASE/bin/qwen" ]]; then
  npm install --global --prefix "$BASE" "@qwen-code/qwen-code@$QWEN_CODE_VERSION"
fi

cat > "$BASE/qwen-config.env" <<EOF
MODEL_ID="$MODEL_ID"
MAX_MODEL_LEN="$MAX_MODEL_LEN"
GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION"
MAX_NUM_SEQS="$MAX_NUM_SEQS"
TENSOR_PARALLEL_SIZE="$TENSOR_PARALLEL_SIZE"
VLLM_HOST="127.0.0.1"
VLLM_PORT="8000"
REASONING_PARSER="$REASONING_PARSER"
TOOL_CALL_PARSER="$TOOL_CALL_PARSER"
QWEN_AUTH_TYPE="openai"
WORK_MINUTES="$WORK_MINUTES"
FINALIZE_MINUTES="$FINALIZE_MINUTES"
WATCHDOG_MINUTES="$WATCHDOG_MINUTES"
FAILURE_GRACE_MINUTES="$FAILURE_GRACE_MINUTES"
MAX_SESSION_TURNS="$MAX_SESSION_TURNS"
REPO_DIR="$REPO_DIR"
BRANCH="$BRANCH"
TELEMETRY_INTERVAL="10"
REQUEST_TELEMETRY_INTERVAL="0.5"
EOF

cat > "$BASE/env.sh" <<EOF
export QWEN_RUNPOD_BASE="$BASE"
export QWEN_HOME="$BASE/qwen-home"
export HF_HOME="/workspace/.cache/huggingface"
export PATH="$BASE/bin:$BASE/venv/bin:\$PATH"
source "$BASE/qwen-config.env"
export OPENAI_API_KEY="local-vllm"
export OPENAI_BASE_URL="http://127.0.0.1:8000/v1"
export OPENAI_MODEL="\$MODEL_ID"
export QWEN_MODEL="\$MODEL_ID"
EOF

cat > "$BASE/qwen-home/settings.json" <<EOF
{
  "modelProviders": {
    "openai": [{
      "id": "$MODEL_ID",
      "name": "Local vLLM",
      "baseUrl": "http://127.0.0.1:8000/v1",
      "envKey": "OPENAI_API_KEY",
      "generationConfig": {"contextWindowSize": $MAX_MODEL_LEN}
    }]
  },
  "security": {"auth": {"selectedType": "openai"}},
  "model": {"name": "$MODEL_ID"}
}
EOF

cat > "$BASE/git-askpass.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  *Username*) echo "x-access-token" ;;
  *Password*) printf '%s\n' "${GITHUB_TOKEN:?GITHUB_TOKEN missing}" ;;
esac
EOF
chmod 700 "$BASE/git-askpass.sh"

cat > "$BASE/start_vllm.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "$BASE/env.sh"
source "$BASE/qwen-config.env"

echo "GPU: \$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "Model: \$MODEL_ID"
echo "Context: \$MAX_MODEL_LEN"

exec vllm serve "\$MODEL_ID" \
  --host "\$VLLM_HOST" \
  --port "\$VLLM_PORT" \
  --max-model-len "\$MAX_MODEL_LEN" \
  --gpu-memory-utilization "\$GPU_MEMORY_UTILIZATION" \
  --max-num-seqs "\$MAX_NUM_SEQS" \
  --tensor-parallel-size "\$TENSOR_PARALLEL_SIZE" \
  --reasoning-parser "\$REASONING_PARSER" \
  --enable-auto-tool-choice \
  --tool-call-parser "\$TOOL_CALL_PARSER" \
  --language-model-only
EOF
chmod +x "$BASE/start_vllm.sh"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  GIT_ASKPASS="$BASE/git-askpass.sh"   GIT_TERMINAL_PROMPT=0   git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

git config --global --add safe.directory "$REPO_DIR" || true
git config --global user.name "Qwen RunPod"
git config --global user.email "qwen-runpod@users.noreply.github.com"

corepack enable 2>/dev/null || true
cd "$REPO_DIR"
if [[ -f pnpm-lock.yaml ]]; then
  corepack pnpm install --frozen-lockfile || corepack pnpm install || true
fi

echo "BOOTSTRAP_OK"
echo "vLLM: $("$BASE/venv/bin/vllm" --version)"
echo "Qwen: $("$BASE/bin/qwen" --version)"
