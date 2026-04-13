# 搜索信源透传

> grok2api 将 Grok 搜索引擎返回的信源（网页 + X 帖子）透传给下游消费者（如 GrokSearch MCP）。

## 功能概述

当 Grok 执行网络搜索时，SSE 流中包含两类搜索结果：

| 字段 | 内容 | 结构 |
|:--|:--|:--|
| `webSearchResults` | 网页搜索结果 | `{results: [{url, title, preview}]}` |
| `xSearchResults` | X/Twitter 帖子 | `{results: [{postId, username, name, text, createTime, ...}]}` |

grok2api 的 `StreamAdapter` 逐帧累积两类结果，去重后在响应末尾追加 `## Sources` 段落：

```markdown
...正文...

## Sources
[grok2api-sources]: #
- [Python Release](https://www.python.org/downloads/release/python-3140/)
- [𝕏/@markgurman: Apple's upcoming AI smart glasses will c...](https://x.com/markgurman/status/2043332839433998383)
```

## 配置

`features.show_search_sources`（默认 `false`），管理面板可开关。

- 开启：搜索响应末尾追加 `## Sources`
- 关闭：不追加（非搜索查询始终不追加）

## 各模型信源数量（实测）

通过浏览器端实测观察：

| 模型 | webSearchResults 去重 | xSearchResults 去重 | 合计 |
|:--|:--|:--|:--|
| Fast | 24 | 20 | 44 |
| Expert | 124 | 69 | 193 |
| Heavy | 295 | ~100+ | ~400 |

GrokSearch MCP 端到端 `sources_count`：Fast 37-41、Expert 52、Heavy 98。

## 实现细节

### 采集（`xai_chat.py` StreamAdapter）

- **webSearchResults**：直接使用原始 `url` + `title`
- **xSearchResults**：
  - URL 拼接：`https://x.com/{username}/status/{postId}`
  - Title 构造：`𝕏/@{username}: {text前50字}...`（text 为空退回 `𝕏/@{username}`）
  - 空白归一化：`\r`、`\n`、`\t`、连续空白压平为单个空格
- **去重**：共享 `_web_search_urls_seen` set，webSearchResults 中的 x.com URL 与 xSearchResults 自动去重
- **输出**：`references_suffix()` 统一转义 Markdown 字符（`\` `[` `]`）后输出

### 多轮剥离（`chat.py` _extract_message）

前轮 `## Sources` 在下一轮发给 Grok 前被剥离，防止上下文膨胀。

- **标记行**：`[grok2api-sources]: #`（CommonMark link reference definition，渲染器不显示）
- **正则**：`(?:^|\r?\n\r?\n)## Sources\r?\n\[grok2api-sources\]: #\r?\n[\s\S]*$`
  - `(?:^|\r?\n\r?\n)` — 同时覆盖"正文后追加"和"block 开头"两种场景
  - CRLF 兼容 — `\r?\n` 处理 Windows 客户端回传
- **覆盖路径**：string content（line 195）+ block list content（line 208），先 regex 再 strip
- **安全性**：标记行 `[grok2api-sources]: #` 必须存在才匹配，用户自写的 `## Sources` 不受影响

### 渲染器兼容性

标记行 `[grok2api-sources]: #` 是 CommonMark 标准的 link reference definition，已验证不可见：
CherryStudio、LobeChat、NextChat、ChatBox、marked.js、CommonMark dingus。

## 三层 URL 体系

```
webSearchResults + xSearchResults (去重): 44-400 URLs
  ← Grok 搜索工具返回的全部信源（网页 + X 帖子）

  ⊃ inline citations [[N]](url): 5-15 URLs
    ← 模型在正文中实际引用标注的（严格子集）

UI "sources" 数 = modelResponse 原始累积(含跨轮重复) + X 帖子
```

## xSearchResults 研究发现

- **无 URL 字段**：需从 `postId` + `username` 拼接（已验证 HTTP 200）
- **无 title 字段**：需从 `text` 构造
- **citationId 始终为空**：无法过滤"被模型引用的"帖子
- **信噪比低**：大量无关外语推文，但 Fast 模式仅 20 条，开销可接受
- **Grok 不用 `[[N]](url)` 引用 X 帖子**：正文中 X 链接以裸 URL 形式出现
- **webSearchResults 已含部分 X 帖子**：搜索引擎认为重要的 X 帖子会出现在 webSearchResults 中（有完整 URL + title）
- SSE 流中搜索相关字段**仅有两个**：`webSearchResults` 和 `xSearchResults`

## 后续路线图

| 优先级 | 改造项 | 效果 |
|:--|:--|:--|
| P1 | GrokSearch MCP 新增 `[[N]](url)` 内联引用提取 | Config 不开也有 5-15 信源 |
| P2 | grok2api Chat Completions 填充 annotations 字段 | 直连场景结构化数据 |
| P3 | GrokSearch MCP 读取 annotations | 直连场景优先使用结构化数据 |
