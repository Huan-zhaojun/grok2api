# token - Token 号池管理模块

管理 Grok SSO Token 生命周期：导入、存储、选择、消耗、冷却、刷新、过期。支持两级号池（Basic/Super），加权随机选择，配额感知调度。

## 对外接口

| 文件 | 类/函数 | 用途 |
|:--|:--|:--|
| `manager.py` | `TokenManager`, `get_token_manager()` | 单例管理器（增删改查、消耗、刷新、持久化） |
| `pool.py` | `TokenPool` | 单个池的加权随机选择、状态过滤 |
| `models.py` | `TokenInfo`, `TokenStatus`, `EffortType` | 数据模型与枚举 |
| `service.py` | `TokenService` | 管理 API 服务（供 admin 路由调用） |
| `scheduler.py` | `TokenRefreshScheduler` | 定时刷新调度器（lifespan 中启动） |

## TokenInfo 关键字段

- `token`: SSO Token 字符串（导入时自动规范化 Unicode 零宽字符）
- `status`: ACTIVE / DISABLED / EXPIRED / COOLING
- `quota`: 剩余配额（Basic 默认 80，Super 默认 140）
- `consumed`: 累计消耗次数
- `tags`: 标签列表（用于 `prefer_tags` 选择）

## 选择算法

- **默认模式**: 优先选 `quota` 最大的 ACTIVE Token
- **Consumed 模式**: 优先选 `consumed` 最小的 ACTIVE Token
- 支持 `exclude` 排除集和 `prefer_tags` 偏好标签

## 消耗流程

1. `consume(effort)` → 扣减 quota，quota=0 时进入 COOLING
2. `record_fail(status_code)` → 仅 401 计入失败，达阈值（默认 5）标记 EXPIRED
3. `record_success()` → 清空失败计数
4. 定时刷新 → 检查 Rate Limits API，配额恢复则转 ACTIVE

## 注意事项

- `save_tokens` 有防清空保护（不会写入空数据覆盖已有 Token），这会导致管理面板删除最后一个 Token 时静默失败
- Token 导入支持 `sso=xxx` 或裸 Token 格式
- Basic/Super 导入时按池名区分，模型根据 tier 选池
