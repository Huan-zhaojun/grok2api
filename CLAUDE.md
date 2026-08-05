# Grok2API

多账号 Grok API 网关：**Build / Web / Console** 三条独立号池 → OpenAI / Anthropic 兼容接口。  
栈：Go 1.26 + Gin 后端 + React 19 管理端。版本号在根目录 `VERSION`（展示走 `application/updatecheck`）。

Fork：`upstream` = chenyme/grok2api，`origin` = Huan-zhaojun/grok2api。  
`CLAUDE.md` / `AGENTS.md`（符号链接）为 fork 独有，上游没有这两个文件，合并不会触碰。

---

## 架构

```text
Client  --Bearer g2a_*-->  /v1/*             -->  Gateway --> 选定 Provider 后池内调度
Admin   --JWT----------->  /api/admin/v1/*   -->  各用例服务

分层：Transport → Application → Domain；Infra（Provider/持久化/Egress/媒体/Redis）经接口注入
启动：cli.Run → config.Load → app.New → Application.Run
就绪：/readyz 分层就绪；TrafficReady=false 期间 /v1 → 503 service_reconciling
```

**硬约束**：选定 Provider 后，选号/粘滞/额度/冷却/计费/多轮 **不跨池**。  
Web ↔ Build/Console 仅弱关联：共享匿名出口身份；管理端支持关联展示/筛选/关联删除/清理；凭据与运行态互不共享。

| Provider | ID | 凭据目录 | 额度模型 | 能力要点 |
|:--|:--|:--|:--|:--|
| Build | `grok_build` | remote | billing（free 估 500k tokens/24h 滚动） | Responses/Chat/Messages/compact/stored/Video；失效 Build 凭据支持手动重试 |
| Web | `grok_web` | static+tier | remote_window | 对话 + Image/Edit/Video（直传走 v2 uploads） |
| Console | `grok_console` | static | local_window | 无状态对话 |

公开模型名无前缀；内部路由用 `Build/` `Web/` `Console/` 前缀。同名多来源时先定 Provider 再池内换号。  
路由重试上限 = 管理端运行设置 `routing.maxAttempts`（热加载，无硬编码上限）。

### 代码地图

```text
backend/
  cmd/grok2api/            入口（CLI 仅 --config / --listen）
  internal/
    cli/                   参数与信号
    app/                   组装 / startup / readyz
    domain/                规则
    application/           用例：gateway（核心）、account、accountsync、invalidation、
                           quotarecovery、audit、media、model、settings、clientkey、
                           dashboard、adminauth、egress、updatecheck
    infra/
      provider/            cli | web | console | conversation | searchresult
                           | sessionidentity | browserheaders
                           definition.go（Provider 声明边界）  import_json.go
                           account_block.go  rate_limit.go
      config/ egress/ media/ observability/ persistence/ runtime/ security/
    pkg/                   batch | neterror | perfmetrics | reasoningreplay
                           | resultcache | signerurl
    repository/            持久化接口
    transport/http/        路由与 DTO（account adminauth audit clientkey dashboard
                           egress inference media middleware model settings system）
  docs/                    swag 产物（make swagger；CI 校验无漂移）
frontend/src/
  app/                     router / auth-boundary / shell
  features/                accounts audits auth client-keys creative-console
                           dashboard docs media models settings system
  shared/                  api auth
```

Gateway 核心：`application/gateway` — 入口 `CreateResponse|ChatCompletion|Message|CompactResponse`（`service.go`）；选号 `selector*.go`（凭据延迟水合：先 routing projection，命中后才查完整凭据）；失败分类 `failure.go` / `attempt.go`。  
Provider 边界：`infra/provider/definition.go` 的 `Definition` —— Gateway 只按声明调度，不感知实现细节。

### HTTP 面

| 前缀 | 鉴权 |
|:--|:--|
| `/healthz` `/readyz` 部分媒体 | 公共 |
| `/api/admin/v1/*` | 登录接口公开，其余 AdminAuth（JWT） |
| `/v1/*` | 并发门禁 + ClientAuth `Bearer g2a_…` |
| `frontend.staticPath` | SPA（默认 `./frontend/dist`） |

管理端路由：`/dashboard` `/accounts` `/models` `/creative-console` `/client-keys` `/gallery` `/video-gallery` `/request-audits` `/docs` `/settings`。  
请求审计：含首 token 延迟（`first_token_ms`）与官方定价重建明细（`domain/audit ReconstructOfficialCost`）。

---

## 命令

### 首次

```bash
cp config.example.yaml config.yaml
# 必改 secrets.jwtSecret / credentialEncryptionKey / bootstrapAdmin.password
# 本地建议 swaggerEnabled: true；单实例默认 sqlite + memory（无需 PG/Redis）
# 密钥：openssl rand -hex 32  |  openssl rand -base64 32
```

### 开发

```bash
# 后端 :8000（默认推荐）
make run
make run CONFIG=/path/to.yaml
make run RUN_ARGS='--listen 127.0.0.1:8000'
# 等价（Windows 无 make 时）
cd backend && go run ./cmd/grok2api --config ../config.yaml --listen 127.0.0.1:8000
# 相对路径锚点 = 配置文件所在目录，非 cwd

# 前端 :5173 → 代理 /api /v1 /healthz /readyz → :8000
cd frontend && pnpm install && pnpm dev
# VITE_DEV_API_TARGET=http://127.0.0.1:9000 pnpm dev
# Vite 若只绑 ::1 导致 127.0.0.1 连不上：pnpm exec vite --host 127.0.0.1 --port 5173

# 探针 / 文档
curl --noproxy "*" http://127.0.0.1:8000/healthz
curl --noproxy "*" http://127.0.0.1:8000/readyz
# Swagger 仅 server.swaggerEnabled: true → /swagger/index.html
```

### 校验（每轮改完代码必做，禁止只改不检）

| 改动面 | 最低必做 |
|:--|:--|
| 后端 Go | `gofmt` + 相关包 `go test` + `go vet` |
| 前端 TS/TSX | 改动文件 `pnpm exec eslint <files>`；合并前 `pnpm lint` + `pnpm build` |
| 双端 | 上两行都做 |

```bash
# —— 后端（在 backend/ 下；根 Makefile 只有 run / swagger 两个目标）——
cd backend
gofmt -w <改动的 .go 文件>          # 改完先格式化（仅格式化改动文件，见下）
go test ./...                        # 全量单测
go vet ./...                         # 全量 vet
go test ./internal/application/gateway -run TestSelector -count=1   # 定向示例

# —— 前端 ——
cd frontend
pnpm exec eslint src/features/accounts/accounts-page.tsx   # 改哪些就 eslint 哪些
pnpm lint                                                  # eslint .  合并前必跑
pnpm build                                                 # tsc -b && vite build

# —— 文档 / CI 对齐 ——
make swagger   # 改 swag 注释后必跑
```

CI：`.github/workflows/ghcr-image.yml`（test / vet / swagger / lint / build；push main 推镜像）；另有 `codeql.yml` / `stale.yml`。

**Windows 开发注意**：
- `gofmt -l` 会因 CRLF 行尾（`text=auto`）把全仓列为"未格式化"，是误报；**禁止** `gofmt -w` 全仓，只格式化改动文件，提交时 git 自动归一 LF。
- 高负载 runner 下偶发抖动：上游 `TestWebAccountScriptsRejectConcurrentWorkForTheSameAccount`（3s 墙钟超时 + 全仓最重包），CI 挂了先看是否与它无关，重跑即可。

### 部署（Docker）

```bash
# 需已有可用 config.yaml；数据卷 grok2api-data → /app/data
docker compose pull && docker compose up -d
docker compose logs -f grok2api
# 覆盖：GROK2API_IMAGE / GROK2API_PORT / GROK2API_CONFIG / TZ
# 镜像入口：--listen 0.0.0.0:8000；配置挂到 /run/grok2api/config.yaml
```

配套服务（`warp` / `flaresolverr`）在 compose 文件中**默认整段注释**：先取消注释，再 `docker compose --profile warp|flaresolverr up -d`。  
本地数据：`./data/backend.db`、`./data/media`（相对 config 文件目录）。日志：JSON → stdout，级别写死 Info。

---

## 配置

| 载体 | 内容 |
|:--|:--|
| `config.yaml`（启动期） | server / auth / secrets / bootstrapAdmin / frontend / database / runtimeStore / deployment / media / routing / audit |
| 管理端运行设置（多数热加载） | Provider 容量、批量并发、路由细节（含 maxAttempts）、媒体清理、egress 绑定（节点分页/筛选/批量 Clearance）、Clearance、**Build 失败分类与 403 作废规则**、响应头超时… |

| 部署形态 | database | runtimeStore | media |
|:--|:--|:--|:--|
| 单实例 | sqlite | memory | 本地 |
| 多实例 | postgres | redis | 共享卷 + deployment.* |

- Redis 只做运行态，不替代关系库。
- `credentialEncryptionKey` 长期固定，改了会解不开旧凭据。
- Build 默认客户端版本：`RecommendedBuildClientVersion` = **0.2.111**（`infra/config/config.go`）。
- Build 账号支持批量额度重置（`application/quotarecovery`）；403 作废账号规则可配置（settings + gateway `failure.go`）。
- 账号导入 JSON/JSONL：UTF-8 BOM 兼容（`infra/provider/import_json.go`）。
- 客户端密钥（`g2a_*`）可限定 **Provider / Tier / 模型** 范围（`domain/clientkey` AccountScope）；空 scope 归一化为全放行，显式收窄后 fail-closed——存量密钥零迁移。

---

## 客户端 API

`Authorization: Bearer g2a_…`

| | |
|:--|:--|
| 模型 | `GET /v1/models`（按密钥 scope 过滤路由） |
| 对话 | `POST /v1/responses` `.../compact` `chat/completions` `messages` |
| stored | `GET\|DELETE /v1/responses/{id}` |
| 媒体 | `images/*` `videos/*` `media/images\|videos/{id}` |

stored/compact 能力取决于落地 Provider。细节 → `README.zh-CN.md`、管理端 `/docs`。  
模型目录：Build 动态目录以管理端 / `/v1/models` 为准；Web `grok-chat-*` / `grok-imagine-*`；Console `grok-4.3` / `grok-4.20-*` 等（无状态）。  
Build Responses 整型工具参数按 schema 归一化（兼容 Codex 等严格客户端，`infra/provider/cli/responses_arguments.go`）。

---

## Fork 与上游的差异（以树差为准）

判定方法：`git diff upstream/main..main --name-status` —— 看**树差**，不看历史提交（v2 时代的历史提交仍在祖先链上，但其内容早已放弃）。

**常驻差异（fork 独有元文件，上游永远没有，合并不会触碰）**：  
`CLAUDE.md`、`AGENTS.md`（符号链接）、`.gitattributes`、`.gitignore`。

**规则**：新增下游定制前，先确认上游没有等价实现；评估合并影响时用树差，不要按提交名字猜。

---

## 规范与边界

### 临时目录 `tmp/`

- 临时探针 / 一次性脚本 / 抓包产物 / 本地 SSO 样本：只放仓库根目录 `tmp/`（已 gitignore）。
- **禁止**写入 `backend/`、`frontend/` 或其它源码树；用完可删，勿提交。

### 绿地重建

本地 dev 实例的 `./data/`（sqlite/媒体/运行态）**全部是随时可清可重建的测试数据**：
破坏性验证、大批量导入、清池直接在 dev 环境做，**不必另起 tmp 隔离实例**；
彻底重置 = 停服后挪走 `./data/backend.db` 再启动（管理端按 bootstrapAdmin 自动重建）。

### 安全边界

- 勿提交：`config.yaml`、`.env*`、`data/`、真实凭据、HAR/pcap。
- 日志/错误响应勿回传明文 SSO/OAuth/Cookie。
- Egress 仅对提交前连接错误做有限重试。
- 粘性代理用户名 `{account}` → 稳定匿名出口身份。

---

## Fork 同步

```bash
git fetch upstream --tags
git checkout main && git merge upstream/main && git push origin main
```

**给上游的 PR 流程**：

```bash
<main 上提交修复>                     # 先在自己的 main 落地并通过 fork CI
git checkout -b pr/<主题> upstream/main   # 一律从最新 upstream/main 开分支
git cherry-pick <main 上的提交>
git push -u origin pr/<主题>          # -u 会同步把跟踪改到 origin（裸 checkout -b 会默认跟踪 upstream/main）
gh pr create --repo chenyme/grok2api --base main --head Huan-zhaojun:pr/<主题> --title ... --body-file docs/pr-<主题>.md
```

---

## 文档索引

| 路径 | 内容 |
|:--|:--|
| `README.zh-CN.md` `README.md` | 部署 / API / 多实例 |
| `backend/README.md` `frontend/README.md` | 分端说明 |
| `config.example.yaml` | 启动期配置字段 |
| `backend/docs/` | Swagger 产物（`make swagger`） |
| `docs/sso-account-invalidation.md` | SSO 失效语义与落库 |
| `docs/deployment-bind-mount.md` | 部署挂载说明 |

