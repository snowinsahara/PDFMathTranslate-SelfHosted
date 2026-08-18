# PDFMathTranslate HTTP API 服务（Docker）

基于 [PDFMathTranslate](https://github.com/PDFMathTranslate/PDFMathTranslate) 构建的 PDF 文档翻译 HTTP API 后端镜像，
保留论文排版（公式、图表、版式），对应官方文档 [docs/APIS.md#api-http](https://github.com/PDFMathTranslate/PDFMathTranslate/blob/main/docs/APIS.md#api-http)。

镜像内由 [`entrypoint.sh`](entrypoint.sh) 统一启动三个组件：

| 组件 | 说明 |
| --- | --- |
| Redis | Celery 任务队列 / 结果存储（可改用外部 Redis） |
| Celery worker | 执行实际翻译，启动时加载版面分析模型；**并发默认 = CPU 核数** |
| Flask HTTP API | 任务提交 / 查询 / 下载接口，端口 `11008` |

## 版本

| 版本 | 说明 |
| --- | --- |
| `1.5.0` | **docx 与翻译同步生成**：worker 在产出 PDF 翻译结果的同时，用 [pdf2docx](https://github.com/ArtifexSoftware/pdf2docx) 直接生成 docx 翻译结果（一 PDF 页一 Word 节，多页结构正确），下载接口直接交付该 docx，不再事后转换 PDF（取代 1.4.0 的 LibreOffice 方案，该方案会把整篇内容挤进一页）；docx 生成失败时接口自动回退交付 PDF |
| `1.4.0` | **mono/dual 下载接口交付 .docx**：下载时由 LibreOffice 实时转换（`Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document`）；**排版混乱，已被 1.5.0 取代** |
| `1.3.0` | HTTP API 升级为 **gunicorn 生产模式**（默认 2 worker × 8 线程，`FLASK_WORKERS` / `FLASK_THREADS` 可调），替代 Flask 开发服务器 |
| `1.2.0` | 构建末尾新增内网资源完整性硬验证（字体 / babeldoc 模型 / tiktoken 缓存缺失即构建失败）；修复启动期并发 SQLite 锁崩溃与 worker 模型未预加载问题 |
| `1.1.0` | 内网部署支持（运行期外网资源全部内置到镜像）、任务结果过期时间默认 1 小时、worker 并发自动/可调 |
| `1.0.0`（latest 首个版本） | 首个版本 |

## 构建

> 注意：构建上下文必须是**仓库根目录**；构建机需能访问外网（下载字体、Python 依赖、模型）。

```bash
docker build -f pdf-translate-service/Dockerfile -t pdf2zh-api:1.5.0 .
docker tag pdf2zh-api:1.5.0 pdf2zh-api:latest   # 可选，方便默认引用
```

首次构建会安装全部 Python 依赖、下载翻译字体并预热版面分析模型（`babeldoc --warmup`），耗时较长属正常现象。构建末尾会自动验证所有内网资源已内置，**任一项缺失会直接构建失败**（而不是留到内网运行时才暴露）。

## 运行

```bash
docker run -d --name pdf2zh-api -p 11008:11008 pdf2zh-api:1.5.0
```

启动后需等待约 30–45 秒（worker 加载模型），确认就绪：

```bash
curl http://localhost:11008/v1/translate/health-check   # 返回 {"state":"PENDING"} 即就绪
```

### 内网部署（无法访问外网）

镜像已内置全部运行期离线资源，**容器启动和文档翻译都不访问外网**：

- 版面分析 ONNX 模型、表格检测 rapidocr 模型 → 构建时 `babeldoc --warmup` 已缓存
- 翻译所需字体（GoNotoKurrent + SourceHanSerif CN/TW/JP/KR）→ 构建时已下载到 `/app/`

内网环境下将翻译服务配置为**内网 OpenAI 兼容接口**（如 vLLM、OneAPI、Xinference 等，支持任意地址的 OpenAI 格式 API）：

```bash
docker run -d --name pdf2zh-api -p 11008:11008 \
  -e OPENAI_BASE_URL="http://内网LLM地址:8000/v1" \
  -e OPENAI_API_KEY="内网服务的任意密钥" \
  -e OPENAI_MODEL="你的模型名" \
  pdf2zh-api:1.5.0
```

提交任务时 `service` 填 `openai`（见下文接口示例）。

### HTTP API 生产模式（gunicorn）

API 层（任务提交 / 查询 / 下载）由 **gunicorn** 提供，替代 Flask 开发服务器：多进程多线程并发、120s 超时保护、优雅关闭、访问日志输出到容器日志。

- 默认 `2 worker × 8 线程`，可调整：
  - `-e FLASK_WORKERS=4`（进程数）
  - `-e FLASK_THREADS=16`（每进程线程数）
- API 层不加载翻译模型、负载轻，一般无需调整；高并发下载场景可适当加大线程数

### worker 并发控制

- **默认**：并发数 = CPU 核数（Celery 自动检测，每个 worker 进程加载一份模型，约 300MB 内存）
- **环境变量 `WORKER_CONCURRENCY`**：显式指定，如 `-e WORKER_CONCURRENCY=4`
- 兼容旧参数：`-e WORKER_ARGS="--concurrency=1"`（透传任意 celery worker 参数）

### 任务结果过期时间

任务状态与翻译结果（mono/dual 的 PDF 与同步生成的 docx 二进制）保存在 Redis，**默认保留 1 小时**（TTL 到期自动删除，之后无法再下载）。

- 环境变量 `PDF2ZH_RESULT_EXPIRES`：单位秒，如 `-e PDF2ZH_RESULT_EXPIRES=86400` 改回 1 天

### 使用外部 Redis（可选）

默认使用镜像内置的 Redis；若已有 Redis 实例：

```bash
docker run -d --name pdf2zh-api -p 11008:11008 \
  -e CELERY_BROKER=redis://your-redis:6379/0 \
  -e CELERY_RESULT=redis://your-redis:6379/0 \
  pdf2zh-api:1.5.0
```

## 接口示例

```bash
# 1. 提交翻译任务（英文 -> 中文；service 可选 google / openai / deepL 等）
curl http://localhost:11008/v1/translate \
  -F "file=@example.pdf" \
  -F 'data={"lang_in":"en","lang_out":"zh","service":"openai","thread":4}'
# {"id":"d9894125-2f4e-45ea-9d93-1a9068d2045a"}

# 2. 查询进度
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a
# {"info":{"n":13,"total":506},"state":"PROGRESS"}  或  {"state":"SUCCESS"}

# 3. 下载翻译结果（mono=单语 / dual=双语，均交付 .docx 文件）
#    —— worker 翻译时已与 PDF 同步生成 docx（一 PDF 页一 Word 节），
#       下载接口直接返回该 docx；docx 生成失败时回退返回 PDF
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a/mono --output example-mono.docx
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a/dual --output example-dual.docx

# 4. 中断并删除任务
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a -X DELETE
```

`data` 参数说明（均可选）：

| 字段 | 说明 | 示例值 |
| --- | --- | --- |
| `lang_in` | 源语言 | `en` |
| `lang_out` | 目标语言 | `zh`、`ja`、`ko`、`fr`、`de` 等 |
| `service` | 翻译服务商 | `google`（需外网）、`openai`（内网/外网均可）、`deepL`、`azure`、`ollama`、`deeplx` 等 |
| `thread` | 并发翻译线程数 | `4` |

其他服务商密钥/端点见官方文档 [docs/ADVANCED.md](https://github.com/PDFMathTranslate/PDFMathTranslate/blob/main/docs/ADVANCED.md)（如 DeepL 用 `DEEPL_AUTH_KEY`，OpenAI 兼容接口用 `OPENAI_BASE_URL` / `OPENAI_API_KEY` / `OPENAI_MODEL`）。
