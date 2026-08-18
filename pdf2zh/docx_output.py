"""从翻译产物 PDF 字节生成 DOCX 翻译结果（与 PDF 产物同步产出）。

工具选型：pdf2docx（Artifex 维护的成熟 PDF->DOCX 库，PyMuPDF 提取版式 +
python-docx 生成 Word，按 PDF 页切分 Word 节实现"一 PDF 页一 Word 页"），
配合项目钉住的 pymupdf<1.25.3（上游为 arm64 wheel 可用性而钉，见
pyproject.toml 注释）使用 0.5.8 版本。

pdf2docx 0.5.8 与 pymupdf 1.25 存在一个已知兼容缺陷：pymupdf 1.25 返回的
span 颜色是带符号整数（黑色 = -16777216），而 rgb_component() 用
hex(srgb)[2:] 取十六进制，负数会切出 'x1000000' 这类非法串，导致转换时
整页被跳过（报 "invalid literal for int() with base 16: 'x1'"）。
这里在导入 pdf2docx 前打一个最小补丁：颜色值先按位与 0xFFFFFF 归一为
无符号整数再转十六进制。
"""

import logging
import os
import shutil
import tempfile
from pathlib import Path

logger = logging.getLogger(__name__)

_patched = False


def _patch_pdf2docx() -> None:
    """给 pdf2docx.rgb_component 打负数颜色兼容补丁（幂等）。"""
    global _patched
    if _patched:
        return

    def rgb_component(srgb: int) -> list:
        # pymupdf 1.25 颜色可能是负数（如黑色 -16777216），归一为无符号再转
        s = hex(srgb & 0xFFFFFF)[2:].zfill(6)
        return [int(s[i : i + 2], 16) for i in (0, 2, 4)]

    from pdf2docx.common import share

    share.rgb_component = rgb_component
    # TextSpan 在 import 时已把 rgb_component 绑定进自身命名空间，
    # 只改 share 上的引用无效，需同步替换
    import pdf2docx.text.TextSpan as TextSpan

    TextSpan.rgb_component = rgb_component
    _patched = True


def convert_pdf_to_docx(pdf_bytes: bytes) -> bytes:
    """将翻译后的 PDF 字节转换为 DOCX 字节（一个 PDF 页对应一个 Word 页）。

    转换失败时抛出异常，由调用方决定是否降级（例如回退交付 PDF）。
    """
    _patch_pdf2docx()
    from pdf2docx import Converter

    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp_pdf:
        tmp_pdf.write(pdf_bytes)
        pdf_path = tmp_pdf.name

    tmpdir = tempfile.mkdtemp(prefix="pdf2zh_docx_")
    try:
        docx_path = str(Path(tmpdir) / "out.docx")
        cv = Converter(pdf_path)
        try:
            # page_breaks=True：每个 PDF 页生成一个 Word 节（节起始即新页），
            # 避免所有内容挤进同一页
            cv.convert(docx_path, page_breaks=True)
        finally:
            cv.close()

        docx_bytes = Path(docx_path).read_bytes()
        logger.info("PDF->DOCX: %d bytes PDF -> %d bytes DOCX",
                    len(pdf_bytes), len(docx_bytes))
        return docx_bytes
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        try:
            os.unlink(pdf_path)
        except OSError:
            pass
