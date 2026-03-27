# Grok2API

## 项目概述

Grok2API 是一个 Grok Web 端（grok.com）逆向代理服务，将聊天、图片生成/编辑、视频生成/超分等能力封装为 **OpenAI 兼容的 REST API**。基于 FastAPI + Granian 构建，支持多 Token 号池并发、自动负载均衡、配额管理、流式/非流式响应。

## 开发命令

```bash
# 安装依赖（需要 Python 3.13+，uv 包管理器）
uv sync

# 启动开发服务器（必须使用 granian，禁止直接 python main.py）
uv run granian --interface asgi --host 0.0.0.0 --port 8000 --workers 1 main:app

# 代码检查
uv run ruff check .

# Docker 部署
docker compose up -d
# 自定义端口：HOST_PORT=9000 SERVER_PORT=8011 docker compose up -d
```

- **测试**：`test/` 目录下为手动集成测试脚本（无 pytest），单独运行：`python test/test_thinking.py`
- **管理面板**：`http://localhost:8000/admin`（默认密码 `grok2api`，对应配置项 `app.app_key`）

## 架构

```
请求（OpenAI 格式，Bearer Token 认证）
  → FastAPI 路由层 (app/api/v1/)
    → 服务层 (app/services/grok/services/)
      → TokenManager 从号池中选取可用 SSO Token
      → 逆向接口层 (app/services/reverse/) 通过 curl_cffi 调用 grok.com
    → 响应转换为 OpenAI SSE/JSON 格式返回
```

### 核心层级

| 层级 | 路径 | 职责 |
|:--|:--|:--|
| **入口** | `main.py` | FastAPI 应用创建、生命周期管理、路由注册 |
| **API 路由** | `app/api/v1/` | OpenAI 兼容端点（chat、image、video、models、files） |
| **管理 API** | `app/api/v1/admin/` | Token/配置/缓存管理（需 `app_key` 认证） |
| **服务层** | `app/services/grok/services/` | 业务逻辑：ChatService、ImageGenerationService、VideoService、ResponsesService |
| **逆向层** | `app/services/reverse/` | 通过 HTTP (curl_cffi) / WebSocket / gRPC 调用 grok.com |
| **Token 管理** | `app/services/token/` | 号池管理：manager（单例）、pool（加权随机）、scheduler（配额定时刷新） |
| **基础设施** | `app/core/` | 配置、认证、日志、存储抽象、中间件、异常处理 |
| **前端** | `_public/` | 管理面板和功能演示页面的静态资源 |

### 关键设计模式

- **全异步 I/O**：所有服务、逆向调用、存储操作均使用 `async/await`
- **单例模式**：`Config`、`TokenManager`、`StorageFactory` 为应用级单例
- **双层 Token 池**：`ssoBasic`（免费号，80 次/20h）和 `ssoSuper`（付费号，140 次/2h）；模型按 tier 选池
- **浏览器指纹伪装**：`curl_cffi` 的 `impersonate` 参数模拟 Chrome，绕过 Cloudflare
- **工具调用**：通过 system prompt 注入 + XML 标签解析实现（非原生 function calling）
- **图片生成双链路**：WebSocket（grok-imagine-1.0）和 AppChat 瀑布流（grok-imagine-1.0-fast）
- **视频链式扩展**：6→30 秒自动拼接生成 + 超分辨率
- **代理池 Failover**：逗号分隔多代理，sticky 选择 + 故障轮换
- **SSE 安全包装**：`_safe_sse_stream()` 确保流式错误以 SSE event 返回而非断连
- **模型注册表**：`ModelService.MODELS`（`app/services/grok/services/model.py`）是所有模型定义的唯一权威源

## 配置系统

- **默认配置**：`config.defaults.toml`（15 个 section，70+ 配置项）
- **运行时覆盖**：`data/config.toml`（深度合并覆盖默认值）
- **环境变量**：`LOG_LEVEL`、`DATA_DIR`、`SERVER_PORT`、`SERVER_WORKERS`、`SERVER_STORAGE_TYPE`、`SERVER_STORAGE_URL`
- **存储后端**：local（TOML/JSON 文件）、Redis、MySQL（`mysql+aiomysql://`）、PostgreSQL（`postgresql+asyncpg://`）
- **自动迁移**：旧版配置节（`[grok]`、`[network]`、`[security]`）自动迁移到新结构

## 技术栈

- **运行时**：Python 3.13+ / FastAPI / Granian（ASGI）
- **HTTP 客户端**：`curl_cffi`（浏览器指纹模拟）
- **WebSocket**：`aiohttp` + `websockets` + `livekit`
- **序列化**：`orjson`
- **日志**：`loguru`
- **数据模型**：`pydantic`
- **包管理**：`uv`
- **代码检查**：`ruff`

## 编码规范

- 代码中使用中文注释；日志/调试输出使用英文
- 错误格式对齐 OpenAI：`{"error": {"message": ..., "type": ..., "code": ...}}`
- 并发控制：`asyncio.Semaphore`（限流）+ `asyncio.Lock`（互斥）
