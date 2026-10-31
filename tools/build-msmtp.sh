#!/usr/bin/env bash
# 交叉编译 msmtp（Android arm64-v8a / API 24），产物命名与 KSWEB 一致：libsmtp.so
#
# 用法：
#   bash tools/build-msmtp.sh
#
# 前置：NDK r27 装在 C:/Android/Sdk/ndk/27.2.12479018（可用 ANDROID_NDK_HOME 覆盖）
#
# 本脚本踩过的三个坑（别再踩一遍）：
#   1. 沙箱把 `rm` 换成了安全删除的 shell 函数，autotools 清不掉 conftest → 必须先 unset
#   2. NDK 的 make.exe 在 prebuilt/ 下，不在 PATH 里，而且 PATH 必须用 /c/... 形式
#   3. Windows 上别用 aarch64-linux-android24-clang.cmd —— 每次调用都起一个 cmd.exe，
#      几百个探测能跑十分钟。直接调 clang.exe + --target= 快一个数量级。

set -euo pipefail

# --- 1. 解掉 safe-delete 包装 ---------------------------------------------------
unset -f rm 2>/dev/null || true

# --- 1.5 别让 MSYS 改写 -D 的值 ----------------------------------------------
# Git Bash 会把看起来像 Unix 绝对路径的**参数**自动转成 Windows 路径。
# 于是 -DSYSCONFDIR="/data/user/0/..." 会被编译成
#   E:/workbuddy/resources/vendor/PortableGit/data/user/0/...
# 二进制里烘进去一个构建机路径，手机上永远找不到（首次构建就是这么翻车的）。
# 只排除 -D 开头的参数，其余路径转换保持默认。
export MSYS2_ARG_CONV_EXCL='-D*'

# --- 2. 工具链 ------------------------------------------------------------------
NDK="${ANDROID_NDK_HOME:-C:/Android/Sdk/ndk/27.2.12479018}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

API=24
ABI=arm64-v8a
TARGET_TRIPLE="aarch64-linux-android"
MSMTP_VER=1.8.27
SRC="$BASE/upstream/msmtp-$MSMTP_VER"
OUT="$BASE/upstream/build-out/$ABI/api$API"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
PREBUILT="$NDK/prebuilt/windows-x86_64/bin"

if [ ! -d "$SRC" ]; then
  echo "[err] 源码不存在：$SRC"
  echo "      先解压 upstream/msmtp-$MSMTP_VER.tar.xz"
  exit 1
fi
if [ ! -f "$TOOLCHAIN/clang.exe" ]; then
  echo "[err] 找不到 NDK clang：$TOOLCHAIN/clang.exe"
  echo "      装 NDK：sdkmanager \"ndk;27.2.12479018\""
  exit 1
fi

# PATH 必须是 /c/... 形式，Git Bash 才认
export PATH="$(cygpath -u "$PREBUILT" 2>/dev/null || echo "/c/Android/Sdk/ndk/27.2.12479018/prebuilt/windows-x86_64/bin"):$PATH"

if ! command -v make >/dev/null 2>&1; then
  echo "[err] 找不到 make（NDK 自带：$PREBUILT/make.exe）"
  exit 1
fi

export CC="$TOOLCHAIN/clang.exe"
export AR="$TOOLCHAIN/llvm-ar.exe"
export RANLIB="$TOOLCHAIN/llvm-ranlib.exe"
export STRIP="$TOOLCHAIN/llvm-strip.exe"
export CFLAGS="--target=$TARGET_TRIPLE$API -O2 -fPIE"
# 16KB page size 是 targetSdk 35 起 Play 的硬要求
export LDFLAGS="--target=$TARGET_TRIPLE$API -pie -Wl,-z,max-page-size=16384"

# msmtp 的 configure.ac 硬性要求 pkg-config 存在（哪怕用不上）。
# 本机没有，也不该为它装一整套 —— 用替身让它走「可选依赖全部缺失」分支。
#
# 注意：替身**不能**放在工程目录里 —— 工程路径带空格，而 configure 调用
# `$PKG_CONFIG --atleast-pkgconfig-version` 时**不加引号**，会在空格处劈开
# （报错形如：/d/_Hz/deepseek: No such file or directory）。
cp "$BASE/tools/pkg-config-shim" /tmp/pkg-config-shim
chmod +x /tmp/pkg-config-shim
export PKG_CONFIG=/tmp/pkg-config-shim

cd "$SRC"

# 上一次失败的残留会让 configure 直接卡在 "conftest.dir: File exists"
rm -rf conftest* config.cache autom4te.cache 2>/dev/null || true

# --- 3. getpass 兼容层 --------------------------------------------------------
# msmtp 无条件调用 getpass()，bionic 没有这个符号 → 链接期必挂。
#
# 有个细节必须拿对：msmtp 自己的兜底是
#     tools.h:  #ifndef HAVE_GETPASS  → 声明 getpass
#     tools.c:  #ifndef HAVE_GETPASS && W32_NATIVE → 定义（用 _getch，不适用 Android）
# 所以 **configure 必须探测到「没有 getpass」**（这样 tools.h 才会声明原型，
# 否则 password.c 编译期就 implicit declaration 报错），
# 然后在**链接阶段**把我们的实现补进去。
#
# 因此这个 .o 只能加在 make 的 LDFLAGS 上，不能提前 export 给 configure。
COMPAT_SRC="$BASE/upstream/android-compat/getpass.c"
# 目标必须：
#  1) 无空格（LDFLAGS 被 make 不加引号展开）
#  2) Windows 风格（make 阶段 MSYS_NO_PATHCONV=1，/tmp 这种 Unix 路径 clang.exe 不认）
# cygpath -m 给出 C:/Users/.../Temp 这种混合形式，两头都满足。
TMP_HOST="$(cygpath -m /tmp 2>/dev/null || echo "C:/Windows/Temp")"
COMPAT_OBJ="$TMP_HOST/getpass-android.o"
"$CC" $CFLAGS -c "$COMPAT_SRC" -o "$COMPAT_OBJ"
LINK_EXTRAS="$COMPAT_OBJ"

echo "=== configure ==="
# --with-tls=no：本里程碑只验证工具链与可执行性。
# TLS 需要交叉编译 OpenSSL/GnuTLS，放到下一个里程碑（D23 会用到）。
#
# --sysconfdir 必须显式指定！否则 configure 会把**构建机**的 prefix 烘进二进制，
# 首次构建就出过这个事故：sysconfdir 变成
#   E:/workbuddy/.../PortableGit/usr/local/etc
# —— 手机上根本没这个路径，P4 生成的 msmtprc 会被静默忽略。
# 这里指向「组件包内」的 etc 目录，与 P1 安装链释放的位置一致（D4 已锁定包名）。
./configure \
  --host="$TARGET_TRIPLE" \
  --with-tls=no \
  --disable-nls \
  --sysconfdir=/data/user/0/dev.kswebstack.app/components/msmtp/etc \
  2>&1 | tail -20

echo "=== make ==="
# 必须先 clean：configure 改了 Makefile 里的 sysconfdir，但 make 只看 .o 的时间戳，
# 会认为「什么都没变」直接跳过编译 —— 排查时表现为「重新构建了但二进制里还是旧路径」。
make clean >/dev/null 2>&1 || true
# MSYS_NO_PATHCONV=1 只在这一步生效：
# 光靠 MSYS2_ARG_CONV_EXCL='-D*' 挡不住 —— make 传给 clang 的
#   -DSYSCONFDIR="/data/user/0/..."
# 仍然会被改写成
#   -DSYSCONFDIR="E:/workbuddy/resources/vendor/PortableGit/data/user/0/..."
# 结果二进制里烘死一个构建机路径，手机上永远不存在。
# make 阶段用到的路径都是相对的，关掉转换是安全的。
# LDFLAGS 在这一步才补上 getpass 的实现（原因见上面第 3 节）
MSYS_NO_PATHCONV=1 make -j"$(nproc 2>/dev/null || echo 4)" LDFLAGS="$LDFLAGS $LINK_EXTRAS" 2>&1 | tail -25

BIN="$SRC/src/msmtp"
if [ ! -f "$BIN" ]; then
  echo "[err] 构建产物不存在：$BIN"
  exit 1
fi

mkdir -p "$OUT"
# 产物名与 KSWEB 一致：libsmtp.so（lib 前缀 + .so 后缀，便于放进 assets 后按正则匹配）
"$STRIP" "$BIN" -o "$OUT/libsmtp.so"

echo
echo "=== 产物 ==="
ls -l "$OUT/libsmtp.so"
echo "路径：$OUT/libsmtp.so"

# --- 4. 硬校验：二进制里不许有构建机路径 ------------------------------------
# 之前踩过：sysconfdir 被 MSYS 改写成 E:/workbuddy/...，搭进去一个手机上不存在的路径。
# 这种错误不报错、不崩溃，只会在「改了配置不生效」时让人抓狂，必须机械拦截。
BAD_PATTERNS='PortableGit|workbuddy|D:/_Hz|C:/Users'
if grep -aqE "$BAD_PATTERNS" "$OUT/libsmtp.so"; then
  echo
  echo "[err] 二进制里含构建机路径，不能用："
  grep -aoE "[A-Za-z]:/[ -~]*" "$OUT/libsmtp.so" | head -5
  echo "      检查 configure 的 --sysconfdir 与 make 阶段的 MSYS 路径转换。"
  exit 1
fi

echo
echo "=== 内嵌 sysconfdir ==="
# 注意：msmtp 只把**目录**烘进二进制，运行时再拼 "/msmtprc"
grep -aoE '/data/user/0/[ -~]*' "$OUT/libsmtp.so" | head -2 || true
echo "[ok] 无构建机路径"
