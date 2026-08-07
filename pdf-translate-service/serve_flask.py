"""启动 pdf2zh 的 Flask HTTP API，监听 0.0.0.0:11008。

官方命令 `pdf2zh --flask` 最终调用 flask_app.run(port=11008)，默认只绑定
127.0.0.1，容器外部无法访问；这里复用同一个 Flask 应用（pdf2zh.backend），
显式指定 host="0.0.0.0"。

该进程只负责接收 /v1/translate 任务提交、查询状态与下载结果，实际的翻译
（含版面分析模型加载）发生在 Celery worker 进程中，因此这里无需加载模型。
"""

from pdf2zh.backend import flask_app

if __name__ == "__main__":
    flask_app.run(host="0.0.0.0", port=11008, threaded=True)
