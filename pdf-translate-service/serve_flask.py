"""pdf2zh Flask HTTP API 的 WSGI 入口（gunicorn 生产模式）。

复用 pdf2zh.backend 中的同一个 Flask 应用（flask_app），对外暴露为
`app` 对象，由 gunicorn 以 `serve_flask:app` 加载，替代 Flask 内置的
开发服务器（flask_app.run() 会打印 "This is a development server" 警告，
且单进程能力有限，不适合生产）。

该进程只负责接收 /v1/translate 任务提交、查询状态与下载结果，实际的
翻译（含版面分析模型加载）发生在 Celery worker 进程中，因此这里无需
加载模型。

与 worker 进程保持一致，在启动前设置 Celery result_expires（任务结果在
Redis 中的保留时长，默认 1 小时，可用 PDF2ZH_RESULT_EXPIRES 环境变量调整）。
"""

import os

from pdf2zh.backend import celery_app, flask_app

celery_app.conf.result_expires = int(os.environ.get("PDF2ZH_RESULT_EXPIRES", "3600"))

# gunicorn WSGI 入口：gunicorn --chdir /opt serve_flask:app
app = flask_app

if __name__ == "__main__":
    # 仅用于本地调试；生产环境请使用 gunicorn（见 entrypoint.sh）
    flask_app.run(host="0.0.0.0", port=11008, threaded=True)
