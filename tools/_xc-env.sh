#!/usr/bin/env bash
# 交叉编译公共环境（被 build-*.sh source，不要直接执行）
#
# 这套东西是踩了十几个坑之后收敛出来的，改之前先看 HANDOFF §6.6「构建 msmtp 踩的坑」。

# 1) 沙箱把 rm 换成了「安全删除」shell 函数，autotools 清不掉 conftest* 会卡死
unset -f rm 2>/dev/null || true

# 2) 只排除 -D 参数的路径转换；对 make 那一步还要额外关全局转换（见各 build 脚本）
export MSYS2_ARG_CONV_EXCL='-D*'

NDK="${ANDROID_NDK_HOME:-C:/Android/Sdk/ndk/27.2.12479018}"
XC_API="${XC_API:-24}"
XC_ABI="${XC_ABI:-arm64-v8a}"
XC_TRIPLE="${XC_TRIPLE:-aarch64-linux-android}"

XC_TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
XC_PREBUILT="$NDK/prebuilt/windows-x86_64/bin"

if [ ! -f "$XC_TOOLCHAIN/clang.exe" ]; then
  echo "[err] 找不到 NDK clang：$XC_TOOLCHAIN/clang.exe" >&2
  echo "      装 NDK：sdkmanager \"ndk;27.2.12479018\"" >&2
  exit 1
fi

# 3) PATH 必须用 /c/... 形式，Git Bash 才认；NDK 的 make.exe 在 prebuilt/ 下
export PATH="$(cygpath -u "$XC_PREBUILT" 2>/dev/null || echo "/c/Android/Sdk/ndk/27.2.12479018/prebuilt/windows-x86_64/bin"):$PATH"

if ! command -v make >/dev/null 2>&1; then
  echo "[err] 找不到 make（NDK 自带：$XC_PREBUILT/make.exe）" >&2
  exit 1
fi

export CC="$XC_TOOLCHAIN/clang.exe"
# autoconf 的「头文件/宏是否存在」检查走 $CPP，而 $CPP 默认是 `$CC -E` ——
# 不带 --target！Windows 上的 clang.exe 会退回宿主 mingw 头文件，
# 结果 MAP_ANON / PTHREAD_PROCESS_SHARED / SEM_UNDO 全被误判为不存在
# （APR 的锁实现选择就是这样失败的）。显式给 CPP 带上 target。
export CPP="$XC_TOOLCHAIN/clang.exe --target=$XC_TRIPLE$XC_API -E"
export AR="$XC_TOOLCHAIN/llvm-ar.exe"
export RANLIB="$XC_TOOLCHAIN/llvm-ranlib.exe"
export STRIP="$XC_TOOLCHAIN/llvm-strip.exe"

# 4) 不要用 aarch64-linux-android24-clang.cmd —— 每次起一个 cmd.exe，configure 会慢十倍
export CFLAGS="--target=$XC_TRIPLE$XC_API -O2 -fPIE"
# 共享库不能用 -pie，所以这里保持干净；可执行文件在各自脚本里补 -pie
export LDFLAGS="--target=$XC_TRIPLE$XC_API"

# 5) 16KB page size（targetSdk 35 起 Play 的硬要求）
export XC_PAGE16="-Wl,-z,max-page-size=16384"

XC_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XC_OUT="$XC_BASE/upstream/build-out/$XC_ABI/api$XC_API"

# ---------------------------------------------------------------------------
# 构建根必须**无空格**
#
# 工程路径是 D:\_Hz\deepseek harness project\...，里面有两个空格。autotools 生成的
# Makefile 里有大量不加引号的操作：
#     ln -s $(srcdir)/src/x.c y.c
#     $(prefix)/lib/...
# 一旦路径带空格，这些命令会被拆成两个参数 —— 表现为
#     ln: target 'project/ksweb-re/...: No such file or directory'
#
# 给每个项目单独打引号补丁是不可维护的（PHP/MySQL 的 Makefile 更夸张）。
# 所以：**源码复制到无空格的构建根再编译**，编完只把产物拷回 upstream/build-out。
# ---------------------------------------------------------------------------
XC_STAGE="${XC_STAGE:-$(cygpath -m "$HOME" 2>/dev/null || echo "C:/Users/Bingo")/ksweb-xc}"
XC_DEPS="$XC_STAGE/deps"

xc_stage_src() {
  # $1 = 仓库里的源码目录；$2 = 构建根下的名字
  local src="$1"
  local name="$2"
  local dst="$XC_STAGE/$name"
  local tmp="$dst.partial"
  mkdir -p "$XC_STAGE"
  # 「dst 目录存在」不等于「树完整」：cp -r 中途被打断（Ctrl-C / 任务超时 /
  # 机器休眠）会留下一棵半树，configure 要跑到
  # 「cannot find sources (main/php_version.h)」才炸，白烧一轮 configure。
  # 所以先拷到 .partial，拷成功了才原子地换成 dst —— dst 要么不存在要么完整。
  if [ -d "$dst" ]; then
    local n_src n_dst
    n_src="$(ls -A "$src" | wc -l)"
    n_dst="$(ls -A "$dst" | wc -l)"
    if [ "$n_dst" -lt "$n_src" ]; then
      # 兜住本次改造之前遗留的半树（条目数只多不少，正常的构建产物不会误伤）
      echo "[stage] $dst 不完整（$n_dst/$n_src 项），丢弃重拷"
      rm -rf "$dst"
    fi
  fi
  if [ -d "$dst" ]; then
    echo "[stage] 复用 $dst"
  else
    echo "[stage] $src -> $dst"
    rm -rf "$tmp"
    cp -r "$src" "$tmp" || { echo "[err] 源码拷贝失败，保留 $dst 现状" >&2; rm -rf "$tmp"; return 1; }
    # 用显式 if，别写成 `[ -d x ] && mv`：后者在条件为假时整条返回 1，
    # set -e 会直接把构建脚本判成失败退出。
    if [ -d "$dst" ]; then
      mv "$dst" "$dst.old"
    fi
    mv "$tmp" "$dst" || { echo "[err] $tmp -> $dst 换位失败" >&2; return 1; }
    rm -rf "$dst.old"
  fi
  cd "$dst" || exit 1
  rm -rf conftest* config.cache autom4te.cache 2>/dev/null || true
}

# pkg-config 替身：msmtp/lighttpd 的 configure 硬性要求它存在。
# 必须放无空格路径（configure 调 $PKG_CONFIG 时不加引号，工程路径带空格会被劈开）。
mkdir -p "$XC_OUT" 2>/dev/null || true
cp "$XC_BASE/tools/pkg-config-shim" /tmp/pkg-config-shim
chmod +x /tmp/pkg-config-shim
export PKG_CONFIG=/tmp/pkg-config-shim

xc_prepare_src() {
  # $1 = 源码目录
  cd "$1" || exit 1
  rm -rf conftest* config.cache autom4te.cache 2>/dev/null || true
}

xc_fail_if_host_paths() {
  # $1 = 产物文件
  local f="$1"
  if grep -aqE 'PortableGit|workbuddy|D:/_Hz|C:/Users' "$f"; then
    echo "" >&2
    echo "[err] 产物里含构建机路径，拒绝出包：$f" >&2
    grep -aoE "[A-Za-z]:/[ -~]*" "$f" | head -5 >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 宿主编译器（host cc）
#
# 有些项目在构建期需要**在本机运行**的工具，例如 lighttpd 的 lemon（生成
# src/configparser.c）、MySQL 的 comp_err。这些不能用交叉编译器编。
#
# 本机没有 gcc / cc / clang / MSVC（`which cc` 全空）。用 zig：单文件、自带
# mingw-w64 头文件与 libc，`zig cc` 就是可用的宿主 C 编译器。
#
# zig 解压到无空格构建根：$XC_STAGE/toolchain/zig-windows-x86_64-<ver>/zig.exe
# 这里生成 $XC_STAGE/cc.cmd 转发，供 Makefile/ninja 里裸调 `cc` 的地方使用。
# ---------------------------------------------------------------------------
XC_ZIG="${XC_ZIG:-$XC_STAGE/toolchain/zig-windows-x86_64-0.13.0/zig.exe}"
XC_PY="${XC_PY:-C:/Users/Bingo/.workbuddy/binaries/python/versions/3.13.12/python.exe}"
if [ -x "$XC_ZIG" ] && [ -x "$XC_PY" ]; then
  # cc.cmd 只是转发到 host-cc.py —— 参数解析（-o、空格、退出码）交给 Python，
  # 原因见 tools/host-cc.py 的说明。
  #
  # 注意路径必须转成 Windows 形式（cygpath -m）：$XC_BASE 是 /d/_Hz/... 这种 Unix 路径，
  # 直接写进 .cmd 会被 Windows 解释成 C:\d\_Hz\...，然后找不到文件。
  HOST_CC_PY="$(cygpath -m "$XC_BASE/tools/host-cc.py" 2>/dev/null || echo "$XC_BASE/tools/host-cc.py")"
  cat > "$XC_STAGE/cc.cmd" <<EOF
@echo off
"$XC_PY" "$HOST_CC_PY" %*
EOF
  export XC_ZIG
  export PATH="$(cygpath -u "$XC_STAGE" 2>/dev/null || echo "$XC_STAGE"):$PATH"
  echo "[host-cc] zig=$(basename "$XC_ZIG")"
else
  echo "[warn] 缺 zig 或 python，构建期自举工具（lemon 等）可能失败" >&2
fi
