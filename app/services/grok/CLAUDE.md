# grok - Grok 业务服务模块

封装所有与 Grok Web API 交互的业务逻辑，含三个子模块：`services/`（核心业务）、`utils/`（通用工具）、`batch_services/`（批量管理）。

## 对外接口

### services/

| 文件 | 类/方法 | 用途 |
|:--|:--|:--|
| `model.py` | `ModelService.get()`, `.valid()`, `.to_grok()`, `.pool_candidates_for_model()` | 模型注册表与映射（唯一权威源） |
| `chat.py` | `ChatService.completions()` | 对话补全（流式/非流式） |
| `responses.py` | `ResponsesService.create()` | OpenAI Responses API 桥接 |
| `image.py` | `ImageGenerationService.generate()` | 图片生成（WebSocket 链路） |
| `image_edit.py` | `ImageEditService.edit()` | 图片编辑 |
| `video.py` | `VideoService.completions()` | 视频生成（链式扩展 6→30 秒） |
| `video_extend.py` | `VideoExtendService` | 视频扩展和超分 |
| `voice.py` | — | LiveKit WebSocket 语音 |

### utils/

| 文件 | 用途 |
|:--|:--|
| `process.py` | 响应处理器基类（StreamProcessor / CollectProcessor），idle timeout |
| `stream.py` | `wrap_stream_with_usage()` 流完成后记录消耗 |
| `retry.py` | `pick_token()` Token 轮换选择，`rate_limited()` / `transient_upstream()` 判断 |
| `tool_call.py` | Tool calling 提示词构建与 `<tool_call>` XML 标签解析 |
| `upload.py` | `UploadService` 资源上传到 assets.grok.com |
| `download.py` | `DownloadService` 资源下载与本地缓存 |
| `cache.py` | `CacheService` 本地缓存管理（image/video 目录，自动清理） |
| `response.py` | OpenAI 格式响应构建工具 |

### batch_services/

| 文件 | 用途 |
|:--|:--|
| `usage.py` | 批量刷新 Token 用量/配额 |
| `nsfw.py` | 批量开启 NSFW Unhinged 模式 |
| `assets.py` | 批量查询/删除 Grok 资产 |

## ModelInfo 数据结构

- `model_id`: 对外暴露的模型 ID（如 `grok-4`）
- `grok_model` / `model_mode`: Grok 内部模型名和模式
- `tier`: BASIC / SUPER（决定 Token 池）
- `cost`: LOW (扣 1) / HIGH (扣 4)
- `is_image` / `is_image_edit` / `is_video`: 模型类型标记

## FAQ

- **工具调用如何实现？** 提示词模拟：将 tool 定义注入 system prompt，解析 `<tool_call>` XML 标签
- **图片生成有几条链路？** 两条：WebSocket (grok-imagine-1.0) 和 AppChat 瀑布流 (grok-imagine-1.0-fast)
- **视频超过 6 秒怎么处理？** 链式扩展：先生成 6 秒片段，再循环 extend 至目标时长
- **修改 Chat/Image 服务后怎么验证？** 需手动测试流式和非流式两种模式
