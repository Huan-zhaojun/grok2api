# 搜索信源透传

> grok2api 将 Grok 搜索引擎返回的信源透传给下游消费者（ChatUI、GrokSearch MCP 等），包含两类独立的信源机制。

## 两类信源

Grok 搜索响应中包含两类本质不同的信源数据：

| 维度 | 内联引用 `[[N]](url)` | 搜索结果 `webSearchResults` + `xSearchResults` |
|:--|:--|:--|
| **本质** | 模型在正文中**主动标注**的引用 | 搜索引擎**返回的全量结果** |
| **数量** | 5-15 个 | 44-400+ 个 |
| **质量** | 高——模型认为值得引用 | 混杂——含大量无关/噪音 |
| **在 content 中有位置** | ✅ 有精确的 start/end index | ❌ 不在正文中 |
| **传递方式** | `annotations` 字段（结构化）| `## Sources` 段落（纯文本）|
| **客户端渲染** | CherryStudio 引用卡片/弹窗 | Markdown 链接列表 |
| **实现状态** | ✅ 内联输出 + annotations 均已实现 | ✅ 已实现 |

两者互补，不是替代关系：
- **annotations** = "正文引用了哪些 URL"（精准、结构化、有文本位置）
- **`## Sources`** = "模型搜索过程中看了哪些网页"（全量、参考性质、无文本位置）

### 三层 URL 体系

```
┌──────────────────────────────────────────────────────────────┐
│  webSearchResults + xSearchResults (去重): 44-400 URLs        │
│  = Grok 搜索引擎返回的全部不重复网页（模型"看过"的）          │
│  → 传递方式: ## Sources 段落（features.show_search_sources）  │
│                                                               │
│  ┌──────────────────────────────────────────────────────────┐│
│  │  inline citations [[N]](url): 5-15 URLs                  ││
│  │  = 模型在正文中实际引用标注的 URL（严格子集）             ││
│  │  → 传递方式: annotations 字段（未实现）                   ││
│  └──────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘

UI "sources" 数 = modelResponse 原始累积(含跨轮重复) + X 帖子
```

---

## 功能 1：内联引用 `[[N]](url)`（已实现）

Grok 的 SSE 流中，模型通过 `<grok:render>` 标签输出引用。grok2api 的 `StreamAdapter._render_replace()` 将其转换为 `[[N]](url)` markdown 内联链接：

```markdown
美军从昨日起在**霍尔木兹海峡**实施选择性封锁。[[1]](https://www.guancha.cn/...)
沙特正在施压美国取消封锁。[[2]](https://www.wsj.com/...)
```

### 实现细节（`xai_chat.py` StreamAdapter）

- `_citation_map`: URL → 引用序号的映射
- `_citation_order`: 按出现顺序排列的 URL 列表
- `_last_citation_index`: 连续相同引用去重
- `_render_replace()`: `<grok:render>` → `[[N]](url)` 格式转换 + 记录引用元数据到 `_pending_citations`
- `_clean_token()`: 返回 `(cleaned_text, local_annotations)`，从 cleaned 中定位引用的局部位置
- `_pending_citations`: `_render_replace` 产出的待定位引用 `[{url, title, needle}]`
- `_annotations`: 已定位的完整 annotations（绝对位置）
- `_text_offset`: 累计文本长度，用于局部→绝对位置转换
- `FrameEvent("annotation")`: 通过 `annotation_data` 字段传递结构化 annotation 到消费端
- 相关提交：PR #449（`5261deca`）

### annotations 输出（已实现）

`_render_replace()` 生成 `[[N]](url)` 时同步构建 annotations（URL、标题、文本位置），通过 `FrameEvent("annotation")` 传递到三个 API 端点。

**数据源**：
- **URL**：`_card_cache` 中的 citation card（仅含 `id, type, cardType, url`，无 title）
- **Title**：从 `webSearchResults` 中按 URL 匹配获取页面标题，fallback 到 URL 本身
- **位置**：`_text_offset` 累计偏移 + token 内局部定位

**三端点格式**：

Responses API（扁平，含流式 `annotation.added` 实时事件）：
```jsonc
// output_text.annotations[] / response.output_text.annotation.added
{
  "type": "url_citation",
  "url": "https://nodejs.org/en/blog/release/v25.0.0",
  "title": "Node.js 25.0.0 (Current)",
  "start_index": 50,
  "end_index": 111
}
```

Chat Completions（嵌套，非流式 `message.annotations` / 流式 `delta.annotations` 仅 final chunk）：
```jsonc
// choices[].message.annotations 或 choices[].delta.annotations
{
  "type": "url_citation",
  "url_citation": {
    "url": "https://nodejs.org/en/blog/release/v25.0.0",
    "title": "Node.js 25.0.0 (Current)",
    "start_index": 50,
    "end_index": 111
  }
}
```

Anthropic Messages（扁平，同 Responses API 格式，自定义扩展）：
- 非流式：TextBlock 上 `annotations` 字段
- 流式：`message_delta.delta.annotations`

### 设计决策备忘

以下几处非直觉的选择是刻意设计或已知妥协，避免以后重复讨论：

#### A. Anthropic 为何使用 `annotations` 自定义扩展，而非标准 `citations`？

Anthropic 官方 `citations` 格式要求两个字段**我们无法提供**：

- **`encrypted_index`（必填）**：Anthropic 专有的隐私保护加密索引，没有公开算法，**无法在逆向侧生成**
- **`cited_text`（必填）**：要求是被引用**源网页的原文片段**，Grok SSE 流中不提供此数据

伪造这两个字段 = 输出"看起来标准但数据无效"的结构，客户端解析可能报错，比没有更糟。
所以借用 `search_sources` 的 precedent（自定义扩展）直接复用 OpenAI 扁平格式。CherryStudio Anthropic 模式不消费此字段（不会渲染引用卡片），数据留给自建客户端或下游消费者使用。

#### B. 流式 Anthropic 放 `message_delta.delta` 而非 `content_block_delta`？

Anthropic 官方流式 citations 通过 `content_block_delta` 的 `citations_delta` 承载，同样依赖 `encrypted_index`——既然走的是自定义扩展路线，放 `message_delta.delta`（流的倒数第二个事件）更简单：annotations 需要完整文本才能定位，本来就只能在流结束时一次性发送，与 `search_sources` 的放置位置天然一致。

#### C. Chat Completions 流式为何放 `delta.annotations` 而非 `choice.annotations`？

初版计划放 `choice.annotations` 躲 Vercel AI SDK 的 strict schema（类比 `search_sources` 放 chunk 根对象的处理）。实际查 Vercel AI SDK 源码（CherryStudio 使用）：

```typescript
// packages/openai/src/chat/openai-chat-language-model.ts
if (validated.choices[0].delta.annotations) {
    annotations.push(...validated.choices[0].delta.annotations);
}
```

- `annotations` 是 OpenAI **标准字段**，SDK 的 Zod schema 里有精确定义，**必须放 `delta.annotations`** 才会被消费
- `search_sources` 是自定义字段，SDK 不识别，放 `message`/`delta` 会被 strict schema 拒绝 → 只能放根对象
- 两者是不同字段类别，不能套用同一套规避逻辑

OpenAI 的实际行为：annotations **仅在 final chunk**（`finish_reason: "stop"`）随 delta 一次性发送，不逐条流式推送。

#### D. 位置定位采用 per-token 方案（`_clean_token` 返回元组）

`_clean_token()` 返回 `(cleaned_text, local_annotations)`，annotations 的绝对位置在 feed 循环内由 `_text_offset` 累加得出。没有选择"流结束后对 full_text 全局搜索"的原因：

- **精确匹配**：`str.find(" [[N]](url)")` 在单个 token 内搜索（几十字符），不会被 URL 中的 `)` 截断
- **UTF-16 偏差影响可控**：只涉及当前 token 范围，如需转换 code unit 也更轻
- **title 直接命中**：`_render_replace` 生成时 card 元数据就在手里，不需要后续扫 `_web_search_results`（400+ 条）
- **`annotation.added` 事件自然可发**：构建 annotation 时顺带 yield 一条事件

找不到 needle 时 **fail-closed**（跳过此 annotation），宁可丢位置也不伪造。

#### E. `content_part.added` 事件的 `annotations: []` 是刻意保留

Responses API 流式事件链中 `response.content_part.added` 是**初始化事件**（在正文流出之前发出），此时尚未产生任何 annotation，空数组符合 OpenAI 标准行为。完整数组在 `content_part.done` / `output_item.done` 事件中填充。

#### F. UTF-16 索引偏差（已知妥协）

`start_index` / `end_index` 使用 Python `str` 的 code-point 偏移；JS/Electron 客户端（CherryStudio 等）使用 UTF-16 code unit。

| 字符范围 | 影响 |
|:--|:--|
| BMP 内（含所有中文、英文、常用符号） | 无偏差 |
| Astral plane（emoji、𝕏、𝐀 等数学斜体） | 每个字符在 JS 中占 2 code unit，Python 中占 1，偏 1 |

当前未转换，理由：
- Grok 搜索回答中 astral 字符罕见（正文以文字为主）
- 即使 position 偏了，引用卡片仍能渲染（CherryStudio 主要靠 URL/title，position 是辅助）
- 实测出现问题时，再追加 `_utf16_offset()` 转换即可

#### G. Title 三级 fallback

Grok citation card 仅含 `[id, type, cardType, url]`，**无 title 字段**。取 title 的顺序：

1. `card.get("title", "")` — card 里的 title（通常为空）
2. 遍历 `_web_search_results`，按 URL 匹配 `item.get("title", "")`
3. 都拿不到 → 使用 URL 本身作为 title

是"能拿到就拿到"的柔性策略，不会因缺 title 丢 annotation。

---

## 功能 2：搜索信源 `## Sources`（已实现）

当 Grok 执行网络搜索时，SSE 流中包含两类搜索结果：

| 字段 | 内容 | 结构 |
|:--|:--|:--|
| `webSearchResults` | 网页搜索结果 | `{results: [{url, title, preview}]}` |
| `xSearchResults` | X/Twitter 帖子 | `{results: [{postId, username, name, text, createTime, ...}]}` |

`StreamAdapter` 逐帧累积两类结果，去重后在响应末尾追加 `## Sources` 段落：

```markdown
...正文...

## Sources
[grok2api-sources]: #
- [Python Release](https://www.python.org/downloads/release/python-3140/)
- [𝕏/@markgurman: Apple's upcoming AI smart glasses will c...](https://x.com/markgurman/status/2043332839433998383)
```

### 配置

`features.show_search_sources`（默认 `false`），管理面板可开关。

- 开启：搜索响应末尾追加 `## Sources` 到 content 正文
- 关闭：不追加正文（非搜索查询始终不追加）

> 注意：结构化 `search_sources` 字段始终输出，不受此开关控制。详见功能 3。

### 各模型信源数量（实测）

通过浏览器端实测观察：

| 模型 | webSearchResults 去重 | xSearchResults 去重 | 合计 |
|:--|:--|:--|:--|
| Fast | 24 | 20 | 44 |
| Expert | 124 | 69 | 193 |
| Heavy | 295 | ~100+ | ~400 |

GrokSearch MCP 端到端 `sources_count`：Fast 37-41、Expert 52、Heavy 98。

### 实现细节

#### 采集（`xai_chat.py` StreamAdapter）

- **webSearchResults**：直接使用原始 `url` + `title`
- **xSearchResults**：
  - URL 拼接：`https://x.com/{username}/status/{postId}`
  - Title 构造：`𝕏/@{username}: {text前50字}...`（text 为空退回 `𝕏/@{username}`）
  - 空白归一化：`\r`、`\n`、`\t`、连续空白压平为单个空格
- **去重**：共享 `_web_search_urls_seen` set，webSearchResults 中的 x.com URL 与 xSearchResults 自动去重
- **输出**：`references_suffix()` 统一转义 Markdown 字符（`\` `[` `]`）后输出

#### 多轮剥离（`chat.py` _extract_message）

前轮 `## Sources` 在下一轮发给 Grok 前被剥离，防止上下文膨胀。

- **标记行**：`[grok2api-sources]: #`（CommonMark link reference definition，渲染器不显示）
- **正则**：`(?:^|\r?\n\r?\n)## Sources\r?\n\[grok2api-sources\]: #\r?\n[\s\S]*$`
  - `(?:^|\r?\n\r?\n)` — 同时覆盖"正文后追加"和"block 开头"两种场景
  - CRLF 兼容 — `\r?\n` 处理 Windows 客户端回传
- **覆盖路径**：string content（line 195）+ block list content（line 208），先 regex 再 strip
- **安全性**：标记行 `[grok2api-sources]: #` 必须存在才匹配，用户自写的 `## Sources` 不受影响

#### 渲染器兼容性

标记行 `[grok2api-sources]: #` 是 CommonMark 标准的 link reference definition，已验证不可见：
CherryStudio、LobeChat、NextChat、ChatBox、marked.js、CommonMark dingus。

---

## 功能 3：`search_sources` 结构化字段（始终输出）

当 Grok 执行网络搜索时，API 响应中**始终**包含 `search_sources` 结构化字段（无需任何配置）。
客户端不认识此字段会自动忽略，零成本无害。

### 字段格式

```json
"search_sources": [
  {"url": "https://example.com/article", "title": "Example Article", "type": "web"},
  {"url": "https://x.com/user/status/123", "title": "𝕏/@user: Tweet content...", "type": "x_post"}
]
```

| 字段 | 说明 |
|:--|:--|
| `url` | 信源 URL |
| `title` | 信源标题（X 帖子格式为 `𝕏/@username: text前50字...`） |
| `type` | 来源类型：`web`（webSearchResults）/ `x_post`（xSearchResults） |

### 与 `## Sources` 的关系

`search_sources` 字段与 `## Sources` 正文独立运作，数据源相同但输出通道不同：

| `show_search_sources` | `search_sources` 字段 | `## Sources` 正文 |
|:--|:--|:--|
| `false`（默认） | ✅ 始终输出 | ❌ |
| `true` | ✅ 始终输出 | ✅ 也追加 |

### 各端点输出格式

#### Chat Completions — 非流式

**响应根对象** `search_sources`（不在 `message` 内部——Vercel AI SDK 等客户端对 `message` 使用严格 schema 校验，未知字段会报错）：

```json
{
  "id": "chatcmpl-xxx",
  "object": "chat.completion",
  "model": "grok-3",
  "search_sources": [
    {"url": "https://python.org/downloads/", "title": "Python Release", "type": "web"},
    {"url": "https://x.com/gaborbernat/status/123", "title": "𝕏/@gaborbernat: Python 3.14 is out...", "type": "x_post"}
  ],
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Python 3.14 已于 2025 年发布..."
    },
    "finish_reason": "stop"
  }]
}
```

#### Chat Completions — 流式

仅 **final chunk** 的根对象携带 `search_sources`（信源需整个流结束后才完整）：

```json
data: {
  "id": "chatcmpl-xxx",
  "object": "chat.completion.chunk",
  "model": "grok-3",
  "search_sources": [
    {"url": "https://python.org/downloads/", "title": "Python Release", "type": "web"},
    {"url": "https://x.com/gaborbernat/status/123", "title": "𝕏/@gaborbernat: Python 3.14 is out...", "type": "x_post"}
  ],
  "choices": [{
    "index": 0,
    "delta": {"content": ""},
    "finish_reason": "stop"
  }]
}
```

> **为什么放根对象？** Vercel AI SDK（CherryStudio 等客户端使用）对 `choices[].message` 和 `choices[].delta` 使用 `z.object()` 严格校验，未知字段会触发 `Invalid JSON response` 错误。根对象使用 `z.looseObject()`，允许自定义字段通过。

#### Responses API — 非流式

`output[].search_sources`（message item 级别）：

```json
{
  "id": "resp-xxx",
  "output": [{
    "id": "msg-xxx",
    "type": "message",
    "role": "assistant",
    "content": [{"type": "output_text", "text": "Python 3.14...", "annotations": []}],
    "search_sources": [
      {"url": "https://python.org/downloads/", "title": "Python Release", "type": "web"}
    ],
    "status": "completed"
  }]
}
```

#### Responses API — 流式

`response.output_item.done` 事件的 item 对象携带 `search_sources`：

```
event: response.output_item.done
data: {
  "type": "response.output_item.done",
  "output_index": 0,
  "item": {
    "id": "msg-xxx",
    "type": "message",
    "role": "assistant",
    "content": [{"type": "output_text", "text": "...", "annotations": []}],
    "search_sources": [
      {"url": "https://python.org/downloads/", "title": "Python Release", "type": "web"}
    ],
    "status": "completed"
  }
}
```

#### Anthropic Messages — 非流式

顶层 `search_sources`（与 `id`、`content`、`stop_reason` 同级）：

```json
{
  "id": "msg-xxx",
  "type": "message",
  "role": "assistant",
  "model": "grok-3",
  "content": [{"type": "text", "text": "Python 3.14..."}],
  "search_sources": [
    {"url": "https://python.org/downloads/", "title": "Python Release", "type": "web"}
  ],
  "stop_reason": "end_turn"
}
```

#### Anthropic Messages — 流式

`message_delta` 事件（流的倒数第二个事件）的 `delta` 内：

```
event: message_delta
data: {
  "type": "message_delta",
  "delta": {
    "stop_reason": "end_turn",
    "stop_sequence": null,
    "search_sources": [
      {"url": "https://python.org/downloads/", "title": "Python Release", "type": "web"}
    ]
  },
  "usage": {"output_tokens": 150}
}
```

### new-api 透传

`search_sources` 作为自定义字段，在 new-api 默认 OpenAI 直通模式下 **100% 透传**（原始字节流不经过 struct roundtrip）。

当 `forceFormat=true` 或 `thinkToContent=true` 时，Chat Completions 会经过 Go struct roundtrip，
此时 `search_sources` 会被丢弃（Message struct 无此字段）——与 `reasoning_content` 相同的已知限制。

### 实现细节

- **数据源**：与 `## Sources` 共用 `StreamAdapter._web_search_results`，采集时标记 `type` 字段
- **方法**：`StreamAdapter.search_sources_list()` 返回 `[{url, title, type}]` 或 `None`
- **无配置依赖**：不读取任何配置开关，有数据即输出
- **与 content 无关**：不参与多轮剥离（`_extract_message()` 只处理 content 字符串）

---

## xSearchResults 研究发现

- **无 URL 字段**：需从 `postId` + `username` 拼接（已验证 HTTP 200）
- **无 title 字段**：需从 `text` 构造
- **citationId 始终为空**：无法过滤"被模型引用的"帖子
- **信噪比低**：大量无关外语推文，但 Fast 模式仅 20 条，开销可接受
- **Grok 不用 `[[N]](url)` 引用 X 帖子**：正文中 X 链接以裸 URL 形式出现
- **webSearchResults 已含部分 X 帖子**：搜索引擎认为重要的 X 帖子会出现在 webSearchResults 中（有完整 URL + title）
- SSE 流中搜索相关字段**仅有两个**：`webSearchResults` 和 `xSearchResults`

---

## 中转层探索（new-api 透传验证）

### 研究背景

用户常通过 [new-api](https://github.com/Calcium-Ion/new-api)（Go 编写的 API 中转网关）访问 grok2api。需验证 annotations 等非标字段能否通过中转层。

### 验证方法

1. 部署 new-api Docker 容器（`calciumion/new-api:latest`）
2. 配置渠道指向 mock annotations 服务器
3. 端到端测试三种 API 路径的 annotations 透传

### Go struct 源码分析

**Chat Completions — Message struct（无 annotations 字段）**：

```go
// relay/model/message.go (songquanpeng/one-api)
type Message struct {
    Role             string  `json:"role,omitempty"`
    Content          any     `json:"content,omitempty"`
    ReasoningContent any     `json:"reasoning_content,omitempty"`
    Name             *string `json:"name,omitempty"`
    ToolCalls        []Tool  `json:"tool_calls,omitempty"`
    ToolCallId       string  `json:"tool_call_id,omitempty"`
    // ← 无 Annotations 字段
}
```

**Responses API — ResponsesOutputContent struct（有 annotations 字段）**：

```go
// dto/openai_response.go (Calcium-Ion/new-api)
type ResponsesOutputContent struct {
    Type        string        `json:"type"`
    Text        string        `json:"text"`
    Annotations []interface{} `json:"annotations"`  // ← 有！
}
```

### 端到端测试结果

| 测试 | 直连 mock | 经过 new-api | 结果 |
|:--|:--|:--|:--|
| Chat Completions 非流式 `message.annotations` | ✅ 2 items | ✅ 2 items | **透传**（原始字节透传） |
| Chat Completions 流式末帧 `choice.annotations` | ✅ 1 item | ✅ 1 item | **透传**（原始字节透传） |
| Responses API `annotation.added` 事件 | ✅ | ✅ | **透传**（原始字节透传） |
| Responses API `part.annotations` 数组 | ✅ 1 item | ✅ 1 item | **透传**（原始字节透传 + struct 有字段） |

**注意**：以上为 OpenAI→OpenAI 默认直通模式。当 `forceFormat=true` 或 `thinkToContent=true` 时，new-api 会反序列化到 Go struct 再重序列化：
- Chat Completions annotations → ❌ 被丢弃（struct 无字段）
- Responses API annotations → ✅ 保留（struct 有字段）

### CherryStudio 抓包验证

CherryStudio 通过 new-api xAI 渠道请求 `/v1/responses` 时，xAI 原生返回的 SSE 事件链：

```
event: response.content_part.added     → "annotations": []
event: response.output_text.delta      → 流式文本...
event: response.output_text.delta      → "[[1]](https://...)"
event: response.output_text.annotation.added  ← 每个引用实时推送
event: response.content_part.done      → annotations: [完整数组]
event: response.output_item.done       → annotations: [完整数组]
```

CherryStudio 读取 annotations 后渲染为底部引用卡片（带 favicon + "N 个引用内容"），已实测验证可用。

### CherryStudio 端到端验证（grok2api 实测）

| 端点 | CherryStudio 引用卡片 | 说明 |
|:--|:--|:--|
| Responses API `/v1/responses` | ✅ 显示 | 读取 `annotation.added` 事件 + `content_part.done` annotations |
| Chat Completions `/v1/chat/completions` | ❌ 不显示 | `delta.annotations` 数据正确返回，但 CherryStudio 不消费此字段渲染卡片 |
| Anthropic Messages `/v1/messages` | ❌ 不显示 | `annotations` 是自定义扩展，CherryStudio Anthropic 模式不识别 |

> CherryStudio 用户应使用 Responses API 以获得最佳引用卡片体验。

---

## 后续路线图

| 改造项 | 位置 | 效果 | 状态 |
|:--|:--|:--|:--|
| Responses API annotations | `xai_chat.py` + `responses.py` | CherryStudio 引用卡片 + `annotation.added` 流式事件 | ✅ 已实现 |
| Chat Completions annotations | `_format.py` + `chat.py` | `message.annotations`（非流式）/ `delta.annotations`（流式 final chunk） | ✅ 已实现 |
| Anthropic Messages annotations | `messages.py` | TextBlock / `message_delta` 自定义扩展 | ✅ 已实现 |

> 注：GrokSearch MCP 侧的适配改造（`[[N]]` 提取、annotations 读取、`search_sources` 字段消费）记录在 GrokSearch 项目的 `docs/sources-improvement-plan.md`。
