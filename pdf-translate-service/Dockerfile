# ============================================================================
# PDFMathTranslate (pdf2zh) — PDF 翻译 HTTP API 后端服务镜像
#
# 版本：1.2.0
# 变更：
#   1.2.0  构建末尾新增内网资源完整性硬验证（字体 / babeldoc 模型 /
#          tiktoken 缓存缺失即构建失败）+ pdf2zh import 链完整性检查；
#         修复启动期两个崩溃：worker/flask 并发初始化翻译缓存 SQLite
#         导致 "database is locked"（entrypoint 串行预建库表）、worker
#         未预加载版面分析模型导致任务 model=None 崩溃（fork 前加载）
#   1.1.0  内网部署支持：运行时字体（GoNotoKurrent / SourceHanSerif 系列）
#         提前下载到 /app/ 随镜像分发；翻译走内网 OpenAI 兼容接口时无需外网
#         1.0.0  首个版本（对应 v1.0.0：Redis + Celery worker + Flask API）
#
# 基于 PDFMathTranslate 项目构建一个提供 PDF 文档翻译（保留论文排版）
# 功能的 HTTP API 服务，对应官方文档 docs/APIS.md 中的 "API HTTP" 一节。
#
# 镜像包含三个组件（由 entrypoint.sh 统一启动）：
#   1. Redis               — Celery 任务队列 / 结果存储（可通过
#                            CELERY_BROKER / CELERY_RESULT 环境变量改用外部 Redis）
#   2. Celery worker       — `pdf2zh --celery worker` 的等价实现，执行实际
#                            翻译任务（并发默认 = CPU 核数，可用 WORKER_CONCURRENCY
#                            控制；任务结果在 Redis 中默认保留 1 小时）
#   3. Flask HTTP API      — `pdf2zh --flask` 的等价实现，监听 0.0.0.0:11008
#
# 内网部署：镜像已内置全部运行期离线资源（版面分析 ONNX 模型 + rapidocr +
# 翻译所需字体），容器启动与文档翻译均不访问外网；翻译服务建议配置内网
# OpenAI 兼容接口（见 README.md）。
#
# 构建（注意：构建上下文必须是仓库根目录，构建机需能访问外网下载资源）：
#   docker build -f pdf-translate-service/Dockerfile -t pdf2zh-api:1.2.0 .
#   docker tag pdf2zh-api:1.2.0 pdf2zh-api:latest
#
# 运行：
#   docker run -p 11008:11008 pdf2zh-api:1.2.0
#
# 常用接口（详见 docs/APIS.md#api-http）：
#   POST   /v1/translate                         提交翻译任务
#   GET    /v1/translate/<task-id>               查询进度
#   GET    /v1/translate/<task-id>/mono          下载单语 PDF
#   GET    /v1/translate/<task-id>/dual          下载双语 PDF
#   DELETE /v1/translate/<task-id>               中断并删除任务
# ============================================================================

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    UV_NO_CACHE=1

LABEL org.opencontainers.image.title="pdf2zh-api" \
      org.opencontainers.image.description="PDF translation HTTP API service (PDFMathTranslate)" \
      org.opencontainers.image.version="1.2.0"

# 系统依赖：
#   - libgl1 / libglib2.0-0 / libxext6 / libsm6 / libxrender1
#     onnxruntime、opencv 等原生库运行所需（解决 "libGL.so.1 not found"）
#   - redis-server         嵌入式 Redis，作为 Celery broker / result backend
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
        libgl1 \
        libglib2.0-0 \
        libxext6 \
        libsm6 \
        libxrender1 \
        redis-server \
    && rm -rf /var/lib/apt/lists/*

# 翻译所需字体：pdf2zh 的 download_remote_fonts() 优先使用 /app/<字体名>
# （存在则不再联网下载），内网部署时翻译任意目标语言（含中文/日文/韩文）
# 都不需要访问外网。GoNotoKurrent 为通用默认字体，SourceHanSerif 系列
# 覆盖 zh/ja/ko（zh-CN/zh-TW 不同字形）。
ADD "https://github.com/satbyy/go-noto-universal/releases/download/v7.0/GoNotoKurrent-Regular.ttf" /app/
ADD "https://github.com/timelic/source-han-serif/releases/download/main/SourceHanSerifCN-Regular.ttf" /app/
ADD "https://github.com/timelic/source-han-serif/releases/download/main/SourceHanSerifTW-Regular.ttf" /app/
ADD "https://github.com/timelic/source-han-serif/releases/download/main/SourceHanSerifJP-Regular.ttf" /app/
ADD "https://github.com/timelic/source-han-serif/releases/download/main/SourceHanSerifKR-Regular.ttf" /app/

# 第一层：仅复制依赖声明并安装核心依赖，pyproject.toml 不变时该层可被缓存复用
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml

# 第二层：复制全部源码，安装项目本体及 HTTP API 所需的 [backend] 扩展
# （flask、celery、redis 客户端，对应官方文档的 `pip install pdf2zh[backend]`）
COPY . .

RUN uv pip install --system --no-cache ".[backend]" && \
    uv pip install --system --no-cache -U \
        "babeldoc<0.3.0" \
        "pymupdf<1.25.3" \
        "pdfminer-six==20250416" && \
    # tencentcloud-sdk-python-tmt==3.1.129（当前最新）移除了 pdf2zh 依赖的
    # TextTranslateRequest/TextTranslateResponse 类，导致 worker 导入失败，
    # 钉住仍兼容的 3.1.121（上游 pdf2zh v1.9.11 的已知兼容问题）
    uv pip install --system --no-cache "tencentcloud-sdk-python-tmt==3.1.121" && \
    babeldoc --version && \
    # 预热 babeldoc 模型资源（含 PDF 版面分析 ONNX 模型 + 表格检测
    # rapidocr 模型 + 内置字体 + tiktoken 编码缓存），
    # 避免首个翻译任务在请求时临时下载模型
    babeldoc --warmup

# 内网部署硬验证：确认所有运行期外网资源都已随镜像内置（与运行时同用户
# root、同 HOME，缓存路径一致）。任何一项缺失即构建失败，杜绝"构建成功
# 但内网启动时联网"的假象。
RUN python - <<'PY'
import os
from pathlib import Path

home = Path(os.environ["HOME"])
cache = home / ".cache"

# 翻译字体（pdf2zh download_remote_fonts 优先取 /app/<字体名>）
fonts = [
    "GoNotoKurrent-Regular.ttf",
    "SourceHanSerifCN-Regular.ttf",
    "SourceHanSerifTW-Regular.ttf",
    "SourceHanSerifJP-Regular.ttf",
    "SourceHanSerifKR-Regular.ttf",
]

# babeldoc 运行时模型（doclayout 版面分析 / rapidocr 表格检测）
models = [
    cache / "babeldoc" / "models" / "doclayout_yolo_docstructbench_imgsz1024.onnx",
    cache / "babeldoc" / "models" / "ch_PP-OCRv4_det_infer.onnx",
]

# babeldoc 内置字体（warmup 下载到 ~/.cache/babeldoc/fonts/）
babeldoc_fonts = sorted((cache / "babeldoc" / "fonts").glob("*.ttf"))

# tiktoken 编码缓存：babeldoc.const 在 import 时强制把 TIKTOKEN_CACHE_DIR
# 指向 ~/.cache/babeldoc/tiktoken（会覆盖外部设置的环境变量），因此
# warmup 中 encoding_for_model("gpt-4o") 预热即落到该目录，运行时同路径
# 命中，内网无需访问 openai 公共 blob。缓存文件名是 blob 路径的 sha1，
# 如 fb374d419588a4632f3f557e76b4b70aebbca790
tiktoken_dir = cache / "babeldoc" / "tiktoken"
tiktoken_files = list(tiktoken_dir.glob("*"))

missing = []
for f in fonts:
    if not (Path("/app") / f).exists():
        missing.append(f"/app/{f}")
for f in models:
    if not f.exists():
        missing.append(str(f))
if not babeldoc_fonts:
    missing.append(str(cache / "babeldoc" / "fonts") + "/*.ttf")
if not tiktoken_files:
    missing.append(str(tiktoken_dir) + "/*")

if missing:
    print("OFFLINE ASSETS MISSING:\n  " + "\n  ".join(missing))
    raise SystemExit(1)

print(f"[verify] offline assets OK: {len(fonts)} fonts in /app, "
      f"{len(babeldoc_fonts)} babeldoc fonts, {len(models)} models, "
      f"{len(tiktoken_files)} tiktoken cache")

# import 完整性检查：worker 与 flask 进程的完整导入链（会触发
# cache.py 模块级 init_db() 建表、ConfigManager 读配置），构建期
# 提前暴露 "import 即崩溃" 类问题，并顺带把翻译缓存数据库打进镜像
from pdf2zh.cache import init_db  # noqa: E402
from pdf2zh.backend import celery_app, flask_app  # noqa: E402

init_db()
print("[verify] pdf2zh import chain OK, translation cache db initialized")
PY

# HTTP API 启动器（监听 0.0.0.0）与多进程入口脚本
COPY pdf-translate-service/serve_flask.py /opt/serve_flask.py
COPY pdf-translate-service/entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

# Flask HTTP API 端口（与 pdf2zh/backend.py 中 flask_app.run(port=11008) 一致）
EXPOSE 11008

# 健康检查：任意 id 的 GET /v1/translate/<id> 都会返回 200（state 为 PENDING 等）
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:11008/v1/translate/health-check', timeout=5)"

# 启动 Redis + Celery worker + Flask API（详见 entrypoint.sh）
CMD ["/opt/entrypoint.sh"]
