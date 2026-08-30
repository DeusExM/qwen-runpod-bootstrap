# Qwen RunPod Bootstrap

Ce dépôt sert à reconstruire un Pod RunPod jetable et lancer Qwen Code avec vLLM.

## Fichiers

- `bootstrap-qwen.sh`
- `start-qwen-worker.sh`
- `README.md`
- `.gitignore`

## Secrets RunPod

À créer dans RunPod :

- `GITHUB_TOKEN` : accès au dépôt de travail.
- `RUNPOD_CONTROL_API_KEY` : clé RunPod autorisée à lire/arrêter le Pod.

Ne jamais mettre ces clés dans Git.

## Pod neuf

Après avoir cloné ce dépôt :

```bash
chmod +x bootstrap-qwen.sh start-qwen-worker.sh
./start-qwen-worker.sh
```

`start-qwen-worker.sh` lance le bootstrap si Qwen Code ou vLLM ne sont pas installés.

Flux :

Pod neuf -> installation -> vLLM -> Qwen Code -> clone du projet -> préflight -> chargement modèle -> micro-test Qwen -> run autonome.

En cas d'échec du préflight ou du micro-test, le Pod reste allumé.

## Configuration A40 validée

```text
MODEL_ID=barrydeen/Qwen3.8-27B-AWQ-4bit
MAX_MODEL_LEN=131072
GPU_MEMORY_UTILIZATION=0.92
MAX_NUM_SEQS=128
TENSOR_PARALLEL_SIZE=1
VLLM_VERSION=0.28.0
QWEN_CODE_VERSION=0.22.3
```

## Changer de modèle / GPU

Exemple :

```bash
MODEL_ID="autre-modele" \
MAX_MODEL_LEN="65536" \
GPU_MEMORY_UTILIZATION="0.90" \
MAX_NUM_SEQS="64" \
./start-qwen-worker.sh
```

Variables principales :

`MODEL_ID`, `MAX_MODEL_LEN`, `GPU_MEMORY_UTILIZATION`, `MAX_NUM_SEQS`,
`TENSOR_PARALLEL_SIZE`, `REASONING_PARSER`, `TOOL_CALL_PARSER`,
`VLLM_VERSION`, `QWEN_CODE_VERSION`, `REPO_URL`, `REPO_DIR`, `BRANCH`,
`WORK_MINUTES`, `FINALIZE_MINUTES`, `WATCHDOG_MINUTES`,
`FAILURE_GRACE_MINUTES`, `MAX_SESSION_TURNS`.

## Important

Le dépôt de travail doit déjà contenir :

```text
tools/qwen/run-v2.sh
tools/qwen/qwen-telemetry.sh
tools/qwen/qwen-request-telemetry.sh
```

Suivre le runner :

```bash
tail -f "$(ls -t /workspace/qwen-runpod/logs/run-v2-*.log | head -1)"
```

`Ctrl+C` coupe uniquement le suivi du log.
