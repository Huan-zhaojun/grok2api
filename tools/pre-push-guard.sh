#!/bin/sh
# 上游推送守卫（pre-push hook）
#
# 目的：防止误把内容推送到上游仓库 chenyme/grok2api，或误推其它远端的主线分支。
# 定位：本机「防手滑网」，**不是安全边界** —— 边界见下方「能力边界」。
#
# ── 安装 ───────────────────────────────────────────────────────────────
#   cp tools/pre-push-guard.sh .git/hooks/pre-push && chmod +x .git/hooks/pre-push
#   hook 不受版本控制；换机器 / 重新 clone 后需重新安装。
#
# ── 拦截规则 ───────────────────────────────────────────────────────────
#   一：目标远端名是 upstream
#   二：目标地址含 chenyme/grok2api（覆盖 https / ssh / git 协议，以及任意命名的远端）
#   三：目标是 refs/heads/main 或 refs/heads/master，且目标远端不是 origin
#   规则一、二对大小写不敏感（GitHub 仓库路径不区分大小写）；
#   规则三刻意大小写敏感 —— git ref 本身区分大小写，refs/heads/Main 不是 main。
#
# ── 放行 ───────────────────────────────────────────────────────────────
#   ALLOW_PROTECTED_PUSH=1 git push ...
#
# ── 能力边界（务必知悉）────────────────────────────────────────────────
#   1. `git push --no-verify` 完全绕过本 hook。git-push 手册原文：
#      "With --no-verify, the hook is bypassed completely."
#   2. `git -c core.hooksPath=<其它目录> push ...` 把 hook 发现路径改向，等效绕过。
#   3. git 别名内部若嵌了 `--no-verify`，同样绕过。
#   4. 不经过 transport_push() 的底层命令不跑任何 hook —— 例如
#      `git send-pack <url> <refspec>`。此类需故意手打，不在防手滑范围内。
#   5. 若本机 core.hooksPath 被设置（例如引入 husky），装在 .git/hooks 的守卫会被
#      静默忽略。安装后请确认 `git config --get core.hooksPath` 为空。
#
#   → 因此针对「绝不能推到上游」这一条，真正的硬断应做在 config 层：
#       git remote set-url --push upstream "file:///nonexistent/grok2api-push-disabled.git"
#     它不经过 hook，故 1~3 均绕不过；而 `git fetch upstream` 不受影响
#     （pushurl 只作用于推送）。注意：该硬断生效时，`git push upstream` 会在
#     transport 建立阶段就失败，**hook 根本不会被执行** —— 两道闸是短路关系，
#     更硬的那道先响。
#
# ── 自测 ───────────────────────────────────────────────────────────────
#   bash tools/pre-push-guard-selftest.sh
#   全程在系统临时目录内运行：零网络、零真实推送；失败项数即退出码。
#
# ── 接口依据 git 官方手册 githooks[5] ──────────────────────────────────
#   参数 $1 = 目标远端名，$2 = 目标位置（未用命名远端时两者为同一值）
#   stdin 每行 4 个字段：<本地ref> <本地OID> <远端ref> <远端OID>
#   非零退出 -> git push 中止，不推送任何内容

set -u

if [ "${ALLOW_PROTECTED_PUSH:-0}" = "1" ]; then
  exit 0
fi

remote_name="$1"
remote_url="$2"

# GitHub 的仓库路径不区分大小写，故统一转小写后比对
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

deny() {
  echo "pre-push 已阻止：$1" >&2
  echo "本次推送未执行。确需推送请显式放行：ALLOW_PROTECTED_PUSH=1 git push ..." >&2
  exit 1
}

name_lc=$(to_lower "$remote_name")
url_lc=$(to_lower "$remote_url")

# fail-closed 自检：非空输入却归一化出空结果，说明 to_lower 异常。
# 此时无法可靠判定目标，一律拒绝 —— 否则规则一、二会被静默跳过，成为 fail-open。
if [ -n "$remote_name" ] && [ -z "$name_lc" ]; then
  deny "远端名归一化失败，无法判定推送目标，按 fail-closed 拒绝（$remote_name）"
fi
if [ -n "$remote_url" ] && [ -z "$url_lc" ]; then
  deny "目标地址归一化失败，无法判定推送目标，按 fail-closed 拒绝（$remote_url）"
fi

# 规则一：目标远端名是 upstream
case "$name_lc" in
  upstream)
    deny "禁止向 remote '$remote_name' 推送（$remote_url）"
    ;;
esac

# 规则二：目标地址指向上游仓库 —— 覆盖 https / ssh / git 协议，以及任意命名的远端
case "$url_lc" in
  *chenyme/grok2api*)
    deny "目标仓库是上游 chenyme/grok2api（$remote_url）"
    ;;
esac

# 规则三：禁止直接推送主线分支，但豁免 origin（本仓库的默认远端，推它是日常操作）。
# 注意 git ref 区分大小写，故 remote_ref 不做小写化。
while read -r local_ref local_oid remote_ref remote_oid; do
  [ -n "${remote_ref:-}" ] || continue
  case "$remote_ref" in
    refs/heads/main|refs/heads/master)
      if [ "$name_lc" != "origin" ]; then
        deny "禁止直接推送主线分支 '$remote_ref' 到 '$remote_name'（本地 $local_ref -> $local_oid）"
      fi
      ;;
  esac
done

exit 0
