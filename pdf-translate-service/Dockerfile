# ============================================================================
# PDFMathTranslate (pdf2zh) — PDF 翻译 HTTP API 后端服务镜像
#
# 基于 PDFMathTranslate 项目构建一个提供 PDF 文档翻译（保留论文排版）
# 功能的 HTTP API 服务，对应官方文档 docs/APIS.md 中的 "API HTTP" 一节。
#
# 镜像包含三个组件（由 entrypoint.sh 统一启动）：
#   1. Redis               — Celery 任务队列 / 结果存储（可通过
#                            CELERY_BROKER / CELERY_RESULT 环境变量改用外部 Redis）
#   2. Celery worker       — `pdf2zh --celery worker`，执行实际翻译任务
#   3. Flask HTTP API      — `pdf2zh --flask` 的等价实现，监听 0.0.0.0:11008
#
# 构建（注意：构建上下文必须是仓库根目录）：
#   docker build -f pdf-translate-service/Dockerfile -t pdf2zh-api .
#
# 运行：
#   docker run -p 11008:11008 pdf2zh-api
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
    # 预热 babeldoc 模型资源（含 PDF 版面分析 ONNX 模型），
    # 避免首个翻译任务在请求时临时下载模型
    babeldoc --warmup

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
