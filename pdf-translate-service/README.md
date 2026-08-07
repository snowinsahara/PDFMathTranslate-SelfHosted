# PDFMathTranslate HTTP API 服务（Docker）

基于 [PDFMathTranslate](https://github.com/PDFMathTranslate/PDFMathTranslate) 构建的 PDF 文档翻译 HTTP API 后端镜像，
保留论文排版（公式、图表、版式），对应官方文档 [docs/APIS.md#api-http](https://github.com/PDFMathTranslate/PDFMathTranslate/blob/main/docs/APIS.md#api-http)。

镜像内由 [`entrypoint.sh`](entrypoint.sh) 统一启动三个组件：

| 组件 | 命令 | 说明 |
| --- | --- | --- |
| Redis | `redis-server` | Celery 任务队列 / 结果存储（可改用外部 Redis） |
| Celery worker | `pdf2zh --celery worker` | 执行实际翻译，启动时加载版面分析模型 |
| Flask HTTP API | `pdf2zh.backend` | 任务提交 / 查询 / 下载接口，端口 `11008` |

## 构建

> 注意：构建上下文必须是**仓库根目录**（Dockerfile 需要引用全部源码）。

```bash
docker build -f pdf-translate-service/Dockerfile -t pdf2zh-api .
```

首次构建会安装全部 Python 依赖并预热版面分析模型（`babeldoc --warmup`），耗时较长属正常现象。

## 运行

```bash
docker run -d --name pdf2zh-api -p 11008:11008 pdf2zh-api
```

低内存环境可限制 worker 并发（每个 worker 进程都会加载一份模型）：

```bash
docker run -d --name pdf2zh-api -p 11008:11008 \
  -e WORKER_ARGS="--concurrency=1" \
  pdf2zh-api
```

### 使用外部 Redis（可选）

默认使用镜像内置的 Redis；若已有 Redis 实例，可通过环境变量指定：

```bash
docker run -d --name pdf2zh-api -p 11008:11008 \
  -e CELERY_BROKER=redis://your-redis:6379/0 \
  -e CELERY_RESULT=redis://your-redis:6379/0 \
  pdf2zh-api
```

## 接口示例

```bash
# 1. 提交翻译任务（英文 -> 中文，Google 翻译）
curl http://localhost:11008/v1/translate \
  -F "file=@example.pdf" \
  -F 'data={"lang_in":"en","lang_out":"zh","service":"google","thread":4}'
# {"id":"d9894125-2f4e-45ea-9d93-1a9068d2045a"}

# 2. 查询进度
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a
# {"info":{"n":13,"total":506},"state":"PROGRESS"}  或  {"state":"SUCCESS"}

# 3. 下载翻译结果（mono=单语 / dual=双语）
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a/mono --output example-mono.pdf
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a/dual --output example-dual.pdf

# 4. 中断并删除任务
curl http://localhost:11008/v1/translate/d9894125-2f4e-45ea-9d93-1a9068d2045a -X DELETE
```

翻译服务商（`service` 字段）支持 google / deepL / openai 兼容接口等，配置方式见官方文档 [docs/ADVANCED.md](https://github.com/PDFMathTranslate/PDFMathTranslate/blob/main/docs/ADVANCED.md)。
