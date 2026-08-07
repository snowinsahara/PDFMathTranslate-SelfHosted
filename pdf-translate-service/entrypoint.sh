#!/usr/bin/env bash
# ============================================================================
# PDFMathTranslate HTTP API 服务入口：依次启动 Redis、Celery worker、Flask API。
# 参考官方文档 docs/APIS.md#api-http 中的：
#   pdf2zh --flask
#   pdf2zh --celery worker
# 所有 API 调用都需要 Redis，这里默认启动嵌入式 Redis；若设置了
# CELERY_BROKER / CELERY_RESULT 环境变量指向外部 Redis，则跳过内置 Redis。
# ============================================================================
set -euo pipefail

pids=()

shutdown() {
    echo "[entrypoint] Shutting down ..."
    for pid in "${pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
}
trap shutdown TERM INT

# ---- 0. 串行预初始化 pdf2zh 配置（Celery broker / result backend）------------
# 必须直接写 JSON 文件，而不能用 ConfigManager._save_config()：
# pdf2zh config.py 的 _remove_circular_references 用 id() 检测循环引用，
# 而 backend.py 中 CELERY_BROKER / CELERY_RESULT 的默认值是同一个字符串
# 常量对象，第二个值会被误判为循环引用写成 null，导致 Celery result
# backend 变为 DisabledBackend（上游 bug，v1.9.11 仍存在）。
# 同时该文件由 worker 与 flask 两个进程共享，这里串行写入一次完整配置，
# 后续进程只会读取、不会再写文件，避免跨进程并发初始化竞态。
# 显式优先环境变量：ConfigManager.get 是“配置文件 > 环境变量 > 默认值”，
# 若直接调用 get，用户通过环境变量更换 Redis 地址时会被旧配置文件覆盖。
python - <<'PY'
import json
import os
from pathlib import Path

config_path = Path.home() / ".config" / "PDFMathTranslate" / "config.json"
config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(
    json.dumps(
        {
            "CELERY_BROKER": os.environ.get("CELERY_BROKER", "redis://127.0.0.1:6379/0"),
            "CELERY_RESULT": os.environ.get("CELERY_RESULT", "redis://127.0.0.1:6379/0"),
        },
        indent=4,
        ensure_ascii=False,
    )
)
PY

# ---- 1. Redis（Celery broker / result backend）------------------------------
if [ -z "${CELERY_BROKER:-}" ] && [ -z "${CELERY_RESULT:-}" ]; then
    echo "[entrypoint] Starting embedded Redis on 127.0.0.1:6379"
    mkdir -p /tmp/redis
    redis-server --dir /tmp/redis --save "" --appendonly no &
    pids+=("$!")
else
    echo "[entrypoint] Using external Redis: CELERY_BROKER=${CELERY_BROKER:-unset} CELERY_RESULT=${CELERY_RESULT:-unset}"
fi

# ---- 2. Celery worker（执行实际翻译，启动时加载版面分析模型）---------------
echo "[entrypoint] Starting Celery worker: pdf2zh --celery worker ${WORKER_ARGS:-}"
pdf2zh --celery worker ${WORKER_ARGS:-} &
pids+=("$!")

# ---- 3. Flask HTTP API（监听 0.0.0.0:11008）---------------------------------
echo "[entrypoint] Starting Flask HTTP API on 0.0.0.0:11008"
python /opt/serve_flask.py &
pids+=("$!")

# 任一进程退出即终止整个容器，便于编排系统（docker --restart 等）自动重启
wait -n "${pids[@]}"
shutdown
