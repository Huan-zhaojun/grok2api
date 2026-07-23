# Grok2API

多账号 Grok API 网关：**Build / Web / Console** 独立号池 → OpenAI / Anthropic 兼容接口。  
栈：Go 1.26 + Gin + React 19 管理端。版本：根目录 `VERSION`。

Fork：`upstream` = chenyme/grok2api，`origin` = 本仓库；给上游的 PR 从 `upstream/main` 开分支。  
`AGENTS.md` → 符号链接 `CLAUDE.md`。

## 命令

```bash
cp config.example.yaml config.yaml   # 必改 secrets + bootstrapAdmin.password
make run                             # 后端，默认 :8000
make swagger                         # 改 swag 注释后；CI 校验 backend/docs 无漂移

cd backend && go test ./... && go vet ./...
cd backend && go test ./internal/application/gateway -run TestSelector -count=1

cd frontend && pnpm install && pnpm dev   # :5173 → 代理 :8000
cd frontend && pnpm lint && pnpm build    # dist/ 由 Go 托管

docker compose pull && docker compose up -d
# docker compose --profile flaresolverr|warp up -d
```

探针：`/healthz` `/readyz`。Swagger：仅 `server.swaggerEnabled: true` → `/swagger/index.html`。  
CI：`.github/workflows/ghcr-image.yml`（test/vet/swagger/lint/build；push main 推镜像）。

## 架构

```text
Client  --g2a_*-->  /v1/*              -->  Gateway --> Provider 池内调度
Admin   --JWT---->  /api/admin/v1/*    -->  用例服务

依赖：Transport → Application → Domain ；Infra（Provider/DB/Redis/Egress）经接口注入
启动：cli.Run → config.Load → app.New → Application.Run
      /readyz 分层就绪；TrafficReady=false 时 /v1 → service_reconciling
```

**硬约束**：选定 Provider 后，选号/粘滞/额度/冷却/计费/多轮 **不跨池**。  
Web↔Build/Console 弱关联只共享匿名出口身份与展示，不共享凭据与运行态。

| Provider | ID | 目录 | 额度 | 能力要点 |
|:--|:--|:--|:--|:--|
| Build | `grok_build` | remote | billing | Responses/Chat/Messages/compact/stored/Video |
| Web | `grok_web` | static+tier | remote_window | 对话 + Image/Edit/Video |
| Console | `grok_console` | static | local_window | 无状态对话 |

公开模型名无前缀；内部路由 `Build/` `Web/` `Console/`。

### 路径索引

```text
backend/cmd/grok2api              入口
backend/internal/cli              参数与信号
backend/internal/app              组装 / startup / readyz
backend/internal/domain/*         规则
backend/internal/application/*    用例（gateway 为核心）
backend/internal/infra/*          provider(cli|web|console) egress DB runtime config security
backend/internal/transport/http   路由与 DTO
backend/internal/repository       持久化接口
backend/docs/                     swag 产物

frontend/src/app/                 router / auth-boundary / shell
frontend/src/features/            accounts models client-keys dashboard audits media settings …
frontend/src/shared/              api auth
```

Gateway：`application/gateway` — `CreateResponse|ChatCompletion|Message|CompactResponse`；选号 `selector*.go`；失败 `failure.go` / `attempt.go`。  
Provider 边界：`infra/provider/definition.go` 的 `Definition`（Gateway 只按声明调度）。

### HTTP

| 前缀 | 鉴权 |
|:--|:--|
| `/healthz` `/readyz` 部分媒体 | 公共 |
| `/api/admin/v1/*` | 登录公开 + AdminAuth |
| `/v1/*` | 并发门禁 + ClientAuth `Bearer g2a_…` |
| `frontend.staticPath` | SPA（默认 `./frontend/dist`） |

管理端：`/dashboard` `/accounts` `/models` `/client-keys` `/gallery` `/video-gallery` `/request-audits` `/settings` `/docs/...` `/creative-console`。

## 配置

| 载体 | 内容 |
|:--|:--|
| `config.yaml` | 监听、密钥、DB、runtimeStore、media 路径、routing 缓存、audit 批写… |
| 管理端运行设置 | Provider 容量、批量并发、路由细节、媒体清理、egress、Clearance、**Build 403 规则**、响应头超时…（多数热加载） |

| 部署 | database | runtimeStore | media |
|:--|:--|:--|:--|
| 单实例 | sqlite | memory | 本地 |
| 多实例 | postgres | redis | 共享卷 + deployment.* |

- Redis 不替代关系库。  
- `credentialEncryptionKey` 长期固定。  
- Build 默认客户端：`RecommendedBuildClientVersion` = **0.2.110**（`infra/config`）。  
- 403 作废账号：可配置规则（settings + gateway `failure`）。  
- 账号导入 JSON/JSONL：UTF-8 BOM 兼容（`infra/provider/import_json.go`）。  
- 版本展示：`VERSION` + `application/updatecheck`。

## 客户端 API

`Authorization: Bearer g2a_…`

| | |
|:--|:--|
| 模型 | `GET /v1/models` |
| 对话 | `POST /v1/responses` `.../compact` `chat/completions` `messages` |
| stored | `GET\|DELETE /v1/responses/{id}` |
| 媒体 | `images/*` `videos/*` `media/images|videos/{id}` |

细节 → `README.zh-CN.md`、管理端 `/docs`。stored/compact 取决于落地 Provider。

模型：Build 动态目录以管理端 / `/v1/models` 为准；Web `grok-chat-*` / `grok-imagine-*`；Console `grok-4.3` / `grok-4.20-*` 等（无状态）。同名多来源时先定 Provider 再池内换号。

## 边界

- 勿提交：`config.yaml` `.env*` `data/` 真实凭据 HAR/pcap  
- 日志/错误勿回传明文 SSO/OAuth/Cookie  
- Egress 仅对提交前连接错误有限重试  
- 粘性代理用户名 `{account}` → 稳定匿名身份  

## Fork 同步

```bash
git fetch upstream --tags
git checkout main && git merge upstream/main && git push origin main
```

- 上游贡献：`git checkout -b pr/… upstream/main`  
- 下游定制留在 `main` / `feature/*`  
- 整树强制对齐上游（罕见）：`merge -s ours` + `read-tree`（语言级重写用过）

## Windows / Docker 行尾

`.gitattributes`：`*.sh` `docker/**` `Dockerfile*` `Makefile` → **LF**（防本地 docker build 把 CRLF 拷进 entrypoint）。  
检查：`git ls-files --eol -- docker/entrypoint.sh` → `i/lf w/lf`。

## 文档索引

| 路径 | |
|:--|:--|
| `README.zh-CN.md` `README.md` | 部署 / API / 多实例 |
| `backend/README.md` `frontend/README.md` | 分端说明 |
| `config.example.yaml` | 启动字段 |
| `backend/docs/` | Swagger（`make swagger`） |
