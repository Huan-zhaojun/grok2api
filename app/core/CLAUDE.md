# core - 基础设施模块

提供应用核心基础设施：配置管理、认证鉴权、结构化日志、统一存储抽象、全局异常处理、请求中间件、代理池管理、批量任务框架。

## 对外接口

| 文件 | 导出 | 用途 |
|:--|:--|:--|
| `config.py` | `config`, `get_config()`, `register_defaults()` | 全局配置读写，TOML 加载/深度合并/迁移/剪枝 |
| `auth.py` | `verify_api_key()`, `verify_app_key()`, `verify_function_key()` | FastAPI 依赖注入，三级认证 |
| `logger.py` | `logger`, `setup_logging()`, `get_logger()` | Loguru 结构化日志（JSON 文件 + 彩色终端） |
| `storage.py` | `get_storage()`, `BaseStorage`, `LocalStorage`, `RedisStorage`, `SQLStorage` | 统一存储抽象，惰性创建单例 |
| `exceptions.py` | `AppException`, `ValidationException`, `UpstreamException`, `error_response()` | OpenAI 兼容异常体系 |
| `response_middleware.py` | `ResponseLoggerMiddleware` | 请求日志、TraceID、耗时统计 |
| `proxy_pool.py` | `get_current_proxy()`, `rotate_proxy()`, `build_http_proxies()` | 多代理 sticky 选择与 failover |
| `batch.py` | `run_batch()`, `BatchTask`, `create_task()` | 批量并发执行器 + SSE 进度推送 |

## 存储模式

- **Local**: TOML (config) + JSON (tokens)，基于文件锁
- **Redis**: `grok2api:config` / `grok2api:tokens` 键，支持分布式锁
- **SQL**: `grok2api_config` / `grok2api_tokens` 表，支持行级锁

## 配置访问

- 顶层 section: `app`, `proxy`, `retry`, `token`, `log`, `cache`, `chat`, `image`, `imagine_fast`, `video`, `voice`, `asset`, `nsfw`, `usage`
- 读取方式: `get_config("section.key", default)`
- 修改必须通过 `config.update()`，不能直接改 `_config` 字典
- 配置迁移逻辑（`_migrate_deprecated_config`）较复杂，是回归风险点
