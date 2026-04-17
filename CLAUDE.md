# Grok2API

## 项目概述

Grok2API 是一个 Grok Web 端（grok.com）逆向代理服务，将聊天、图片生成/编辑、视频生成/超分等能力封装为 **OpenAI / Anthropic 兼容的 REST API**。基于 FastAPI + Granian 构建，支持多 Token 号池并发、自动负载均衡、配额管理、流式/非流式响应。

## 开发命令

```bash
# 安装依赖（需要 Python 3.13+，uv 包管理器）
uv sync

# 启动开发服务器（必须使用 granian，禁止直接 python main.py）
uv run granian --interface asgi --host 0.0.0.0 --port 8000 --workers 1 app.main:app

# 代码检查
uv run ruff check .

# Docker 部署
docker compose up -d
# 自定义端口：HOST_PORT=9000 SERVER_PORT=8011 docker compose up -d
```

- **测试**：`tests/` 目录下为手动集成测试脚本（无 pytest），单独运行：`python tests/test_tool_calls_live.py`
- **管理面板**：`http://localhost:8000/admin` （默认密码 `grok2api`，对应配置项 `app.app_key`）

## 架构

```
请求（OpenAI/Anthropic 格式，Bearer Token 认证）
  → FastAPI 路由层 (app/products/)
    → Dataplane 执行层 (app/dataplane/)
      → AccountDirectory 选取可用 SSO Token
      → 逆向接口层 (app/dataplane/reverse/) protocol + transport 调用 grok.com
    → 响应转换为 OpenAI SSE / Anthropic SSE 格式返回
```

### 核心层级

| 层级 | 路径 | 职责 |
|:--|:--|:--|
| **入口** | `app/main.py` | FastAPI 应用工厂、生命周期管理（leader election）、路由注册 |
| **OpenAI API** | `app/products/openai/` | OpenAI 兼容端点（chat、images、video、models、files、responses） |
| **Anthropic API** | `app/products/anthropic/` | Anthropic Messages 兼容端点（`/v1/messages`） |
| **Web** | `app/products/web/` | 管理面板（`admin/`）+ WebUI（`webui/`：聊天、图片、语音） |
| **控制面板** | `app/control/` | Account 管理（多后端存储）、Model 注册表、Proxy 管理 |
| **数据面板** | `app/dataplane/` | 请求执行：account/proxy 运行时选择、reverse protocol + transport |
| **平台层** | `app/platform/` | 配置、认证、日志、存储抽象、启动迁移、运行时工具 |
| **前端** | `app/statics/` | 管理面板和 WebUI 的静态资源（HTML/CSS/JS/i18n） |

### 关键设计模式

- **全异步 I/O**：所有服务、逆向调用、存储操作均使用 `async/await`
- **Control + Dataplane 分离**：`control/` 管理状态与配置，`dataplane/` 处理请求执行
- **三层 Token 池**：`Basic`（免费号，80 次/20h）、`Super`（付费号，140 次/2h）、`Heavy`（重型号，140 次/2h）；模型按 Tier 选池
- **Protocol + Transport 分离**：`dataplane/reverse/protocol/` 处理协议解析（chat、image、video 等 12 个模块），`dataplane/reverse/transport/` 处理传输层（HTTP、WebSocket、gRPC-Web、LiveKit 等 6 个模块）
- **多后端存储**：Account、Config 均支持 Local/Redis/MySQL/PostgreSQL，通过 Factory 模式切换
- **Leader Election**：多 Worker 部署时通过 advisory file lock 选举唯一 scheduler leader，非 leader worker 仅运行轻量 sync loop
- **Adaptive Sync Loop**：检测到变更后 3s 快速轮询，空闲后回落到 30s 间隔
- **浏览器指纹伪装**：`curl_cffi` 的 `impersonate` 参数模拟 Chrome，绕过 Cloudflare
- **工具调用**：通过 system prompt 注入 + XML 标签解析实现（非原生 function calling）
- **图片生成双链路**：WebSocket（grok-imagine-1.0）和 HTTP 瀑布流（grok-imagine-1.0-fast）
- **代理池 Failover**：支持 direct / single_proxy / proxy_pool 三种出口模式，sticky 选择 + 故障轮换
- **SSE 安全包装**：`_safe_sse_stream()` 确保流式错误以 SSE event 返回而非断连
- **模型注册表**：`app/control/model/registry.py` 的 `MODELS` 元组是所有模型定义的唯一权威源（含 Capability、Tier、ModeId 元数据）
- **搜索信源透传**（详见 `docs/search-sources.md`）：
  - **内联引用**：`StreamAdapter._render_replace()` 将 `<grok:render>` 标签转为 `[[N]](url)` 内联链接（5-15 条高质量引用）
  - **annotations**：`_render_replace()` 生成引用时同步构建 `url_citation` annotations（URL、title、文本位置），通过 `FrameEvent("annotation")` 传递到三个 API 端点。Responses API 含 `annotation.added` 流式事件；Chat Completions 在 final chunk 的 `delta.annotations`（嵌套格式）；Anthropic 作为自定义扩展。CherryStudio 仅从 Responses API 渲染引用卡片
  - **全量信源**：`StreamAdapter` 逐帧采集 `webSearchResults` + `xSearchResults`（44-400+ 条），去重后始终以 `search_sources` 结构化字段输出（`[{url, title, type}]`）；`features.show_search_sources` 控制是否同时追加 `## Sources` 正文
  - 两类信源独立：内联引用通过 `annotations` 字段输出（有文本位置），全量信源通过 `search_sources` 字段输出（无文本位置）
  - 多轮对话自动剥离前轮 `## Sources`，防止上下文膨胀
- **多 Agent 思维链**：详细模式（默认）透传原始多 Agent 思考流含身份标识和工具调用；精简模式（`features.thinking_summary`）输出结构化摘要
- **认证双模式**：同时支持 `Authorization: Bearer` 和 `X-API-Key` header（兼容 Anthropic SDK）
- **SQL 存储增强**：SSL 选项（PostgreSQL/MySQL）、连接池配置（pool_size 等）、serverless 支持、启动时共享 engine
- **Proxy Clearance 调度器**：定时刷新 + 预热，代理故障反馈抽象（`_proxy_feedback.py`）
- **日志可配置**：`[logging]` section 支持文件等级和轮转天数，管理面板可热更新

### 模型体系

模型通过 `ModelSpec` 定义，包含三个核心维度：

- **ModeId**：`FAST`（非推理）/ `AUTO`（自动）/ `EXPERT`（推理）/ `HEAVY`（重型）
- **Tier**：`BASIC`（免费池）/ `SUPER`（付费池）/ `HEAVY`（重型池）
- **Capability**：`CHAT` / `IMAGE` / `IMAGE_EDIT` / `VIDEO` / `VOICE` / `ASSET`（位掩码组合）

当前注册 19 个模型：14 Chat（含 4 个 prefer-best 别名） + 3 Image + 1 Image Edit + 1 Video。

- **prefer_best 模型**：`grok-4.20-{fast,auto,expert,heavy}` 无版本后缀，反转池选择顺序（heavy → super → basic），优先使用最高 Tier 账号

## 配置系统

- **默认配置**：`config.defaults.toml`（14 个 section）
- **运行时覆盖**：`data/config.toml`（深度合并覆盖默认值）
- **环境变量**：`LOG_LEVEL`、`LOG_FILE_ENABLED`、`DATA_DIR`、`SERVER_PORT`、`SERVER_WORKERS`、`ACCOUNT_STORAGE`（local/redis/mysql/postgresql）、`ACCOUNT_REDIS_URL`、`ACCOUNT_MYSQL_URL`、`ACCOUNT_POSTGRESQL_URL`、`ACCOUNT_SYNC_INTERVAL`、`ACCOUNT_SYNC_ACTIVE_INTERVAL`、`ACCOUNT_SQL_POOL_SIZE`、`ACCOUNT_SQL_MAX_OVERFLOW`、`ACCOUNT_SQL_POOL_TIMEOUT`、`ACCOUNT_SQL_POOL_RECYCLE`
- **存储后端**：local（TOML/JSON 文件）、Redis、MySQL（`mysql+aiomysql://`）、PostgreSQL（`postgresql+asyncpg://`）
- **自动迁移**：首次启动自动执行 config seed 和旧版账号数据迁移

### 配置 Section 概览

| Section | 说明 |
|:--|:--|
| `[app]` | 管理密码、API Key、WebUI 开关 |
| `[logging]` | 文件日志等级、日志轮转保留天数 |
| `[features]` | 临时对话、记忆、流式、思考输出、搜索信源透传、动态 Statsig 指纹、NSFW、自定义指令、图片/视频返回格式 |
| `[proxy.egress]` | 出口模式（direct/single_proxy/proxy_pool）、资源代理 |
| `[proxy.clearance]` | Cloudflare 绕过（none/manual/flaresolverr） |
| `[retry]` | Session 重建状态码、换号重试策略 |
| `[account.refresh]` | Basic/Super/Heavy 号池刷新周期、并发数 |
| `[chat]` / `[image]` / `[video]` / `[voice]` | 各功能超时配置 |
| `[asset]` | 资源上传/下载/列表/删除超时 |
| `[nsfw]` | NSFW 检查超时 |
| `[batch]` | 批量操作并发限制（NSFW/Usage/Asset） |

## 技术栈

- **运行时**：Python 3.13+ / FastAPI / Granian（ASGI）
- **HTTP 客户端**：`curl_cffi`（浏览器指纹模拟）
- **WebSocket**：`aiohttp` + `websockets`
- **数据库 ORM**：`sqlalchemy`（异步，支持 MySQL/PostgreSQL）
- **序列化**：`orjson`
- **日志**：`loguru`
- **数据模型**：`pydantic`
- **Token 计数**：`tiktoken`
- **包管理**：`uv`
- **代码检查**：`ruff`

## 编码规范

- 代码中使用中文注释；日志/调试输出使用英文
- 错误格式对齐 OpenAI：`{"error": {"message": ..., "type": ..., "code": ...}}`
- 并发控制：`asyncio.Semaphore`（限流）+ `asyncio.Lock`（互斥）

## 文档

| 路径 | 说明 |
|:--|:--|
| `docs/search-sources.md` | 搜索信源透传：两类信源区分、采集/剥离机制、annotations 设计、new-api 透传验证 |
| `docs/README.en.md` | 英文 README |
