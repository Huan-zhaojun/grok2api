#!/usr/bin/env bash
# 推送守卫自测：只在系统临时目录内创建/推送，不接触网络，不触碰任何真实远端仓库。
#
# 精确表述（不含糊）：脚本对 $SB 之外的访问只有两处，且都是**只读**：
#   1) 读取仓库里的 tools/pre-push-guard.sh（作为 cp 的源）
#   2) 读取 git 的 system/global 配置项 core.hooksPath
# 其余所有创建、写入、git push 的目标一律在 $SB 之下。
#
# 为什么这样测既安全又等效：
#   1) 守卫（L2）的判定输入只有两个字符串 —— 目标远端名、目标 URL，从不依赖网络可达性。
#      所以用「本地裸库 + 字面包含 chenyme/grok2api 的目录名」即可完整复现真实场景。
#   2) L1（remote.pushurl）的语义也只涉及「用哪个地址去推送」，同样可在本地裸库上验证。
#   3) 即便守卫/L1 完全失效，所有推送的落点也只是临时目录里的裸库，不可能到达 GitHub。
#
# 本脚本中出现的 https://github.com/... 字符串仅作为「参数」喂给守卫脚本做字符串比对，
# 从不作为任何 git 命令的目标。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/tools/pre-push-guard.sh"
if [ ! -f "$GUARD" ]; then
  echo "找不到守卫脚本：$GUARD" >&2
  exit 1
fi

# 沙盒路径前置校验：必须在做任何操作之前完成。
# 否则一旦 mktemp 失败，SB 为空串，"$SB/src" 会退化成根级路径 "/src"。
SB=$(mktemp -d) || { echo "mktemp 创建临时目录失败，已中止（未执行任何操作）" >&2; exit 1; }
if [ -z "${SB:-}" ] || [ ! -d "$SB" ]; then
  echo "沙盒目录无效（SB='${SB:-}'），已中止（未执行任何操作）" >&2
  exit 1
fi

# 安全清理：不用 rm -rf。先加密写权限 -> 删文件/链接 -> 自底向上 rmdir 空目录。
# 并做路径自检，只允许清理形似临时目录的路径。
cleanup() {
  case "${SB:-}" in
    */tmp.*|*/Temp/*|*/temp/*) ;;
    *) echo "跳过清理（路径不像临时目录，为安全起见不动它）：${SB:-}"; return 0 ;;
  esac
  find "$SB" -type f -exec chmod u+w {} + 2>/dev/null
  find "$SB" -type f -delete 2>/dev/null
  find "$SB" -type l -delete 2>/dev/null
  find "$SB" -depth -type d -exec rmdir {} + 2>/dev/null
}
# 立即安装 trap：这样即便后面在 hooksPath 校验处早退，沙盒也会被清掉。
trap cleanup EXIT

echo "沙盒目录：$SB"

# hooks 发现路径前置校验，作用于沙盒仓库的是 system 与 global 两层配置（沙盒仓库自身尚无配置），
# 因此显式指定 scope，避免依赖调用者的当前目录。
HOOKS_PATH_CFG=""
for scope in --system --global; do
  value=$(git config "$scope" --get core.hooksPath 2>/dev/null || true)
  if [ -n "$value" ]; then
    HOOKS_PATH_CFG="$scope -> $value"
  fi
done
if [ -n "$HOOKS_PATH_CFG" ]; then
  echo "检测到 core.hooksPath=$HOOKS_PATH_CFG，它会覆盖仓库内的 .git/hooks。" >&2
  echo "本自测依赖 .git/hooks 被发现，故中止以免结论失真。请先临时取消该配置再跑。" >&2
  exit 1
fi

pass=0
fail=0

expect() { # expect <期望退出码> <描述> <实际退出码>
  if [ "$3" = "$1" ]; then
    printf '  [PASS] %s\n' "$2"; pass=$((pass + 1))
  else
    printf '  [FAIL] %s（期望退出码 %s，实际 %s）\n' "$2" "$1" "$3"; fail=$((fail + 1))
  fi
}

expect_nonzero() { # expect_nonzero <描述> <实际退出码>
  if [ "$2" -ne 0 ]; then
    printf '  [PASS] %s（退出码 %s）\n' "$1" "$2"; pass=$((pass + 1))
  else
    printf '  [FAIL] %s（期望失败，实际却成功）\n' "$1"; fail=$((fail + 1))
  fi
}

echo
echo "==== A. 单元级：直接喂参数给守卫脚本（不启动 git、不接触网络）===="
unit() { # unit <期望退出码> <描述> <远端名> <URL> <远端ref> [放行变量]
  printf 'refs/heads/pr/test %s %s %s\n' \
    "1111111111111111111111111111111111111111" "$5" \
    "2222222222222222222222222222222222222222" \
    | env ${6:-X=} sh "$GUARD" "$3" "$4" >/dev/null 2>&1
  expect "$1" "$2" "$?"
}

echo "  -- 规则一 / 规则二：推向上游一律拦截 --"
unit 1 "命名远端 upstream"                     upstream "https://github.com/chenyme/grok2api.git" refs/heads/pr/test
unit 1 "命名远端 UPSTREAM（大小写变体）"        UPSTREAM "https://github.com/chenyme/grok2api.git" refs/heads/pr/test
unit 1 "任意命名，URL 指向上游（https）"        whatever "https://github.com/chenyme/grok2api.git" refs/heads/pr/test
unit 1 "URL 大小写变体 Chenyme/Grok2API"        whatever "https://github.com/Chenyme/Grok2API.git" refs/heads/pr/test
unit 1 "URL 为 SSH 形态"                        whatever "git@github.com:chenyme/grok2api.git"     refs/heads/pr/test
unit 1 "URL 无 .git 后缀"                       whatever "https://github.com/chenyme/grok2api"     refs/heads/pr/test

echo "  -- 裸 URL 写法（git 手册：未用命名远端时 \$1 与 \$2 为同一值）--"
unit 1 '裸 URL 推上游（$1=$2=URL）'             "https://github.com/chenyme/grok2api.git"      "https://github.com/chenyme/grok2api.git"      refs/heads/pr/test
unit 0 '裸 URL 推自己的 fork（$1=$2=URL）'      "https://github.com/Huan-zhaojun/grok2api.git"  "https://github.com/Huan-zhaojun/grok2api.git"  refs/heads/pr/test

echo "  -- 规则三：非 origin 远端的主线分支拦截，origin 豁免 --"
unit 1 "非 origin 远端推 main"                  backup   "https://example.com/team/backup.git"     refs/heads/main
unit 1 "非 origin 远端推 master"                backup   "https://example.com/team/backup.git"     refs/heads/master
unit 0 "豁免：origin 推 main"                   origin   "https://github.com/Huan-zhaojun/grok2api.git" refs/heads/main
unit 0 "豁免：ORIGIN 推 main（大小写变体）"      ORIGIN   "https://github.com/Huan-zhaojun/grok2api.git" refs/heads/main
unit 0 "refs/heads/Main 不算 main（git ref 大小写敏感）" backup "https://example.com/team/backup.git" refs/heads/Main

echo "  -- 正常放行 --"
unit 0 "推 origin 的 pr 分支"                   origin   "https://github.com/Huan-zhaojun/grok2api.git" refs/heads/pr/test
unit 0 "推 tag"                                 origin   "https://github.com/Huan-zhaojun/grok2api.git" refs/tags/v3.1.7

echo "  -- 逃生舱 --"
unit 0 "ALLOW_PROTECTED_PUSH=1 时放行 upstream"  upstream "https://github.com/chenyme/grok2api.git" refs/heads/main ALLOW_PROTECTED_PUSH=1

echo
echo "==== B. 端到端：真 git push，但目标全是本地裸库（证明 git 确实会调用并遵守守卫）===="

git init -q "$SB/src" 2>/dev/null
git -C "$SB/src" config user.email "selftest@local"
git -C "$SB/src" config user.name "selftest"
echo selftest > "$SB/src/README"
git -C "$SB/src" add README
git -C "$SB/src" -c commit.gpgsign=false commit -qm "selftest init"

git init -q --bare "$SB/fork.git"      # 对应 origin
git init -q --bare "$SB/u.git"         # 对应 upstream（只让名字命中规则一）
git init -q --bare "$SB/bk.git"        # 对应 backup（只让规则三命中）
mkdir -p "$SB/chenyme"
git init -q --bare "$SB/chenyme/grok2api.git"   # 对应 eu（只让 URL 命中规则二）

git -C "$SB/src" remote add origin   "$SB/fork.git"
git -C "$SB/src" remote add upstream "$SB/u.git"
git -C "$SB/src" remote add backup   "$SB/bk.git"
git -C "$SB/src" remote add eu       "$SB/chenyme/grok2api.git"

mkdir -p "$SB/src/.git/hooks"
cp "$GUARD" "$SB/src/.git/hooks/pre-push"
chmod +x "$SB/src/.git/hooks/pre-push"

e2e_block() { # e2e_block <描述> <remote> <远端ref>
  git -C "$SB/src" push "$2" "HEAD:$3" >/dev/null 2>&1
  expect_nonzero "$1" "$?"
}

e2e_block "真 push 到 upstream（规则一）"      upstream refs/heads/pr/a
e2e_block "真 push 到 eu（规则二）"            eu       refs/heads/pr/b
e2e_block "真 push 到 backup 的 main（规则三）" backup  refs/heads/main

git -C "$SB/src" push origin "HEAD:refs/heads/pr/ok" >/dev/null 2>&1
expect 0 "真 push 到 origin 的 pr 分支（放行）" $?

git -C "$SB/src" push origin "HEAD:refs/heads/main" >/dev/null 2>&1
expect 0 "真 push 到 origin 的 main（规则三豁免）" $?

# 反证组：证明拦截是守卫造成的，而非"推送本身坏掉"导致的假通过
if git -C "$SB/fork.git" rev-parse --verify -q refs/heads/pr/ok >/dev/null 2>&1; then
  printf '  [PASS] 反证：被放行的 pr 分支确实落地\n'; pass=$((pass + 1))
else
  printf '  [FAIL] 反证：被放行的 pr 分支没落地 —— 测试装置本身有问题\n'; fail=$((fail + 1))
fi

if git -C "$SB/fork.git" rev-parse --verify -q refs/heads/main >/dev/null 2>&1; then
  printf '  [PASS] 反证：被放行的 origin main 确实落地\n'; pass=$((pass + 1))
else
  printf '  [FAIL] 反证：被放行的 origin main 没落地\n'; fail=$((fail + 1))
fi

for pair in "u.git:refs/heads/pr/a:upstream 推送" "bk.git:refs/heads/main:backup main 推送"; do
  repo=${pair%%:*}; rest=${pair#*:}; ref=${rest%%:*}; desc=${rest#*:}
  if git -C "$SB/$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
    printf '  [FAIL] 被拦截的%s竟然落地了\n' "$desc"; fail=$((fail + 1))
  else
    printf '  [PASS] 反证：被拦截的%s确实没有落地\n' "$desc"; pass=$((pass + 1))
  fi
done

echo
echo "==== C. L1 语义验证：remote.pushurl（全程本地裸库，零网络）===="

git init -q --bare "$SB/l1-up.git"
git -C "$SB/src" remote add up2 "$SB/l1-up.git"

git -C "$SB/src" push up2 "HEAD:refs/heads/pr/l1" >/dev/null 2>&1
expect 0 "基线：未设 pushurl 时推送到 up2 成功（说明该远端本身可用）" $?

# 采用绝对且确定不存在的地址：报错与调用者的当前目录无关（相对路径的组合依赖 cwd，不可靠）
git -C "$SB/src" remote set-url --push up2 "file:///nonexistent/grok2api-push-disabled.git"
expect 0 "设置 pushurl 为禁用地址成功（纯本地配置操作）" $?

L1_ERR=$(git -C "$SB/src" push up2 "HEAD:refs/heads/pr/l1b" 2>&1 >/dev/null)
expect_nonzero "加固后：推送到 up2 被拒绝" $?
printf '         报错原文：%s\n' "$(printf '%s' "$L1_ERR" | head -n 1)"

git -C "$SB/src" fetch up2 >/dev/null 2>&1
expect 0 "加固后：fetch up2 仍然成功" $?
if git -C "$SB/src" rev-parse -q --verify refs/remotes/up2/pr/l1 >/dev/null 2>&1; then
  printf '  [PASS] 加固后：fetch 确实拉到了远端分支（证明 fetch 真的可用，而非空跑）\n'; pass=$((pass + 1))
else
  printf '  [FAIL] 加固后：fetch 没拉到任何远端分支，无法证明 fetch 可用\n'; fail=$((fail + 1))
fi

git -C "$SB/src" push origin "HEAD:refs/heads/pr/l1c" >/dev/null 2>&1
expect 0 "作用域隔离：推送到 origin 完全不受影响" $?

git -C "$SB/src" remote set-url --push up2 "$SB/l1-up.git"
git -C "$SB/src" push up2 "HEAD:refs/heads/pr/l1d" >/dev/null 2>&1
expect 0 "可逆性：恢复 pushurl 后推送到 up2 重新成功" $?

printf '         up2 的 fetch url：%s\n' "$(git -C "$SB/src" remote get-url up2)"
printf '         up2 的 push  url：%s\n' "$(git -C "$SB/src" remote get-url --push up2)"

echo
echo "==== D. 已知局限演示：--no-verify 会绕过守卫（git 官方既定行为）===="
if git -C "$SB/src" push --no-verify upstream "HEAD:refs/heads/pr/bypass" >/dev/null 2>&1; then
  echo "  [注意] --no-verify 确实绕过了守卫（落点是本地裸库 $SB/u.git，无任何外网影响）"
  echo "         这正是「硬断必须做在 config 层」的原因："
  echo "         git remote set-url --push upstream \"file:///nonexistent/grok2api-push-disabled.git\""
else
  echo "  [信息] 本次 --no-verify 未绕过守卫（与预期不符，请复查）"
fi

echo
echo "==================== 汇总 ===================="
echo "  通过 $pass 项，失败 $fail 项"
if [ "$fail" -eq 0 ]; then
  echo "  结论：守卫与 L1 均按设计工作（拦截与放行全部符合预期）"
else
  echo "  结论：存在不符合预期的项，请勿安装"
fi
exit $fail
