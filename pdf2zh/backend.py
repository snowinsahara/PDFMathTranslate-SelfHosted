from flask import Flask, request, send_file
from celery import Celery, Task
from celery.result import AsyncResult
from pdf2zh import translate_stream
from pdf2zh.docx_output import convert_pdf_to_docx
import tqdm
import json
import io
import logging
from string import Template
from pdf2zh.doclayout import ModelInstance
from pdf2zh.config import ConfigManager

DOCX_MIMETYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

logger = logging.getLogger(__name__)

flask_app = Flask("pdf2zh")
flask_app.config.from_mapping(
    CELERY=dict(
        broker_url=ConfigManager.get("CELERY_BROKER", "redis://127.0.0.1:6379/0"),
        result_backend=ConfigManager.get("CELERY_RESULT", "redis://127.0.0.1:6379/0"),
    )
)


def celery_init_app(app: Flask) -> Celery:
    class FlaskTask(Task):
        def __call__(self, *args, **kwargs):
            with app.app_context():
                return self.run(*args, **kwargs)

    celery_app = Celery(app.name)
    celery_app.config_from_object(app.config["CELERY"])
    celery_app.Task = FlaskTask
    celery_app.set_default()
    celery_app.autodiscover_tasks()
    app.extensions["celery"] = celery_app
    return celery_app


celery_app = celery_init_app(flask_app)


@celery_app.task(bind=True)
def translate_task(
    self: Task,
    stream: bytes,
    args: dict,
):
    def progress_bar(t: tqdm.tqdm):
        self.update_state(state="PROGRESS", meta={"n": t.n, "total": t.total})  # noqa
        print(f"Translating {t.n} / {t.total} pages")

    if "prompt" in args:
        args["prompt"] = Template(args["prompt"])

    doc_mono, doc_dual = translate_stream(
        stream,
        callback=progress_bar,
        model=ModelInstance.value,
        **args,
    )
    # 与 PDF 翻译结果同步生成 docx 版本（一 PDF 页一 Word 页），
    # 下载接口直接交付 docx；docx 生成失败时返回 None，不阻断翻译任务
    docx_mono = _try_to_docx(doc_mono, "mono")
    docx_dual = _try_to_docx(doc_dual, "dual")
    return doc_mono, doc_dual, docx_mono, docx_dual


def _try_to_docx(pdf_bytes: bytes, label: str):
    try:
        return convert_pdf_to_docx(pdf_bytes)
    except Exception:
        logger.exception(f"[{label}] docx generation failed, will serve PDF instead")
        return None


@flask_app.route("/v1/translate", methods=["POST"])
def create_translate_tasks():
    file = request.files["file"]
    stream = file.stream.read()
    print(request.form.get("data"))
    args = json.loads(request.form.get("data"))
    task = translate_task.delay(stream, args)
    return {"id": task.id}


@flask_app.route("/v1/translate/<id>", methods=["GET"])
def get_translate_task(id: str):
    result: AsyncResult = celery_app.AsyncResult(id)
    if str(result.state) == "PROGRESS":
        return {"state": str(result.state), "info": result.info}
    else:
        return {"state": str(result.state)}


@flask_app.route("/v1/translate/<id>", methods=["DELETE"])
def delete_translate_task(id: str):
    result: AsyncResult = celery_app.AsyncResult(id)
    result.revoke(terminate=True)
    return {"state": str(result.state)}


@flask_app.route("/v1/translate/<id>/<format>")
def get_translate_result(id: str, format: str):
    result = celery_app.AsyncResult(id)
    if not result.ready():
        return {"error": "task not finished"}, 400
    if not result.successful():
        return {"error": "task failed"}, 400
    # 结果：mono/dual 的 PDF 字节 + 同步生成的 docx 字节（docx 可能为 None）
    task_result = result.get()
    if len(task_result) == 4:
        doc_mono, doc_dual, docx_mono, docx_dual = task_result
    else:
        # 兼容旧版本 worker 遗留的 2 元组结果
        doc_mono, doc_dual = task_result
        docx_mono = docx_dual = None

    to_send_docx = docx_mono if format == "mono" else docx_dual
    if to_send_docx is not None:
        return send_file(
            io.BytesIO(to_send_docx),
            mimetype=DOCX_MIMETYPE,
            as_attachment=True,
            download_name=f"{id}-{format}.docx",
        )
    # 降级：docx 生成失败时回退交付 PDF
    to_send = doc_mono if format == "mono" else doc_dual
    return send_file(
        io.BytesIO(to_send),
        mimetype="application/pdf",
        as_attachment=True,
        download_name=f"{id}-{format}.pdf",
    )


if __name__ == "__main__":
    flask_app.run()
