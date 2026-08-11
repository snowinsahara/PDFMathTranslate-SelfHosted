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
# 此外串行触发一次翻译缓存数据库初始化（pdf2zh/cache.py 在模块级调用
# init_db() 建表）：worker 与 flask 进程若同时首次 import pdf2zh，会并发
# 执行 CREATE TABLE，SQLite 写锁竞争导致 "database is locked" 双双崩溃；
# 这里先建好库表，后续进程的建表走幂等快速路径（safe=True 只读检查）。
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

# import 即触发 cache.py 模块级的 init_db()；显式再调一次以明确语义
from pdf2zh.cache import init_db

init_db()
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
# 用 python 包装 `pdf2zh --celery worker`，以便在启动前设置 Celery 配置：
#   - result_expires：任务结果（状态 + 翻译后的 PDF 二进制）在 Redis 中的
#     保留时长，默认 1 小时（3600 秒），可用 PDF2ZH_RESULT_EXPIRES 调整
#   - 并发：默认由 Celery 按 CPU 核数自动决定（prefork），可用
#     WORKER_CONCURRENCY 显式指定，或沿用 WORKER_ARGS 透传 celery 参数
echo "[entrypoint] Starting Celery worker (concurrency=${WORKER_CONCURRENCY:-auto}, result_expires=${PDF2ZH_RESULT_EXPIRES:-3600}s)"
python - <<'PY' &
import os
import shlex

from pdf2zh.backend import celery_app
from pdf2zh.doclayout import ModelInstance, OnnxModel

celery_app.conf.result_expires = int(os.environ.get("PDF2ZH_RESULT_EXPIRES", "3600"))

# 与官方 `pdf2zh --celery worker` 一致：fork 前先加载版面分析模型
# （从镜像内置的 babeldoc 缓存读取，不联网；子进程 fork 共享内存）。
# 官方 CLI 的 main() 里 ModelInstance.value = OnnxModel.load_available()，
# 直接调 celery_app.start() 会跳过这步，导致 translate_task 以 model=None
# 崩溃（'NoneType' object has no attribute 'predict'）。
ModelInstance.value = OnnxModel.load_available()

worker_args = ["worker"]
if os.environ.get("WORKER_CONCURRENCY"):
    worker_args += ["--concurrency", os.environ["WORKER_CONCURRENCY"]]
if os.environ.get("WORKER_ARGS"):
    worker_args += shlex.split(os.environ["WORKER_ARGS"])

celery_app.start(argv=worker_args)
PY
pids+=("$!")

# ---- 3. Flask HTTP API（监听 0.0.0.0:11008，gunicorn 生产模式）-------------
# 用 gunicorn 替代 Flask 内置开发服务器（flask_app.run()）：生产级 WSGI
# 服务器，支持多 worker/线程并发、超时保护、优雅关闭与结构化访问日志。
# 该 API 层负载轻（提交/查询/下载，翻译在 Celery worker 中执行），
# 默认 2 worker × 8 线程，可用 FLASK_WORKERS / FLASK_THREADS 调整；
# --timeout 120 避免下载大 PDF 时 worker 被误杀。
echo "[entrypoint] Starting Flask HTTP API on 0.0.0.0:11008 (gunicorn, workers=${FLASK_WORKERS:-2}, threads=${FLASK_THREADS:-8})"
gunicorn \
    --chdir /opt \
    --bind 0.0.0.0:11008 \
    --workers "${FLASK_WORKERS:-2}" \
    --threads "${FLASK_THREADS:-8}" \
    --timeout 120 \
    --graceful-timeout 60 \
    --access-logfile - \
    --error-logfile - \
    serve_flask:app &
pids+=("$!")

# 任一进程退出即终止整个容器，便于编排系统（docker --restart 等）自动重启
wait -n "${pids[@]}"
shutdown
