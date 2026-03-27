# reverse - Grok 逆向接口模块

封装所有与 grok.com 的底层通信，通过 HTTP (curl_cffi)、WebSocket (aiohttp)、gRPC 模拟浏览器行为访问 Grok 官方 API。此层最容易受 Grok 官方变更影响。

## 对外接口

| 文件 | 类 | 用途 |
|:--|:--|:--|
| `app_chat.py` | `AppChatReverse` | 核心对话接口（`grok.com/rest/app-chat`，流式 SSE） |
| `ws_imagine.py` | `ImagineWebSocketReverse` | WebSocket 图片生成 |
| `ws_livekit.py` | `LivekitTokenReverse`, `LivekitWebSocketReverse` | LiveKit 语音 WebSocket |
| `media_post.py` | `MediaPostReverse` | 媒体上传/发布 |
| `media_post_link.py` | `MediaPostLinkReverse` | 媒体链接获取 |
| `assets_upload.py` | `AssetsUploadReverse` | 资源上传（assets.grok.com） |
| `assets_download.py` | `AssetsDownloadReverse` | 资源下载 |
| `assets_list.py` | `AssetsListReverse` | 资源列表查询 |
| `assets_delete.py` | `AssetsDeleteReverse` | 资源删除 |
| `rate_limits.py` | `RateLimitsReverse` | 查询 Token 配额 |
| `nsfw_mgmt.py` | `NsfwMgmtReverse` | NSFW/Unhinged 模式管理 |
| `video_upscale.py` | `VideoUpscaleReverse` | 视频超分辨率 |
| `set_birth.py` | `SetBirthReverse` | 设置生日（绕过年龄限制） |
| `accept_tos.py` | — | 接受服务条款 |

## utils/

| 文件 | 用途 |
|:--|:--|
| `session.py` | `ResettableSession` — 可重置的 AsyncSession，收到特定状态码时自动重建连接 |
| `headers.py` | `build_headers()` — 构建模拟浏览器请求头（Cookie、UA、Statsig） |
| `statsig.py` | `StatsigGenerator` — 生成 Statsig ID（Grok 反爬指纹） |
| `retry.py` | `retry_on_status()` — 状态码驱动重试 + 指数退避 |
| `websocket.py` | `WebSocketClient` — WebSocket 连接管理 |
| `grpc.py` | gRPC 协议工具 |

## FAQ

- **403 错误怎么处理？** ResettableSession 自动重建连接；持续 403 检查代理和 cf_clearance
- **SOCKS5 代理为什么改成 socks5h？** curl_cffi 需要 `socks5h://` 让代理端做 DNS 解析
- **请求头怎么构建？** SSO Cookie (`sso={token};sso.sig=...`) + Statsig ID + CF Clearance + 模拟 Chrome UA
