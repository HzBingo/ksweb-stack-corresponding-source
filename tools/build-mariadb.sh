#!/usr/bin/env bash
# 交叉编译 MariaDB 10.4.34 server（Android arm64-v8a / API 24）。
#
# 产物：upstream/build-out/arm64-v8a/api24/libsqld-10-4-34-api24.so
#       名字与 KSWEB 的 components/mysql/sbin/libsqld-10-4-34-api24.so 逐字一致；
#       放进 jniLibs/arm64-v8a/ 之后由 App 以 nativeLibraryDir 里的绝对路径 exec
#       （SELinux 只允许执行 lib 目录里的文件，见 tools/build-php.sh 同一段说明）。
#
# 用法：
#   bash tools/build-mariadb.sh              # 增量构建
#   bash tools/build-mariadb.sh --clean      # 删掉两个构建目录重来（源码不重拷）
#   bash tools/build-mariadb.sh --jobs 8     # 默认 4（C: 只剩十几 GB，别开太大）
#
# 前置：
#   * 源码 upstream/mariadb-10.4.34/（tools/dl-mariadb.sh 下载的 tar.gz 解开）
#   * NDK r27（ANDROID_NDK_HOME 可覆盖）、CMake 3.22、ninja（SDK 自带）
#   * zig 在 $XC_STAGE/toolchain/zig-windows-x86_64-0.13.0/zig.exe（宿主自举工具用）
#
# 这个配方踩过的坑（改之前先看 patch-mariadb-android.py 的文件头）：
#   1. cmake/readline.cmake 的 FIND_CURSES 是 MACRO：里面写 RETURN() 会退出
#      **调用者**的文件作用域 —— 顶层 CMakeLists 静默中止，cmake 仍然打印
#      "Configuring done"，但只生成 wsrep-lib/zlib 两个目录，ninja 报
#      "unknown target 'mysqld'"。修法见补丁 3/4（IF/ELSE，不许 RETURN）。
#   2. 宿主自举工具必须在**本机**跑（comp_err 生成错误码表），不能用交叉编译器。
#      本机没有 MSVC，zig 走 mingw 目标；CMake 从 Windows 平台带下来的
#      ws2_32.lib 这类 MSVC 命名要翻译成 -lws2_32（tools/host-cc-mariadb.py）。
#   3. bionic 与 glibc 的四处差异（ctype.h、endpwent、ushort、
#      posix_spawn 族的 API 28 门槛）全部落在补丁里，脚本只负责调用。
#   4. Windows 上源码文件被 clang 打开时写不进去（EINVAL / WinError 5）——
#      补丁脚本的 _write_file 用「临时文件 + mv -f 重试」绕开；如果它仍然报
#      「文件被占用」，先把上一轮 ninja 停掉再跑。
#   5. 构建目录必须无空格（工程路径含空格）。源码先 stage 到 $XC_STAGE 再编。

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_xc-env.sh"

MDB_VER=10.4.34
API="$XC_API"
ABI="$XC_ABI"
SRC_NAME="mariadb-$MDB_VER"
HOST_BUILD="$XC_STAGE/mariadb-host-build"
ANDROID_BUILD="$XC_STAGE/mariadb-android-build"
LOG_HOST="$XC_STAGE/mariadb-host-build.log"
LOG_ANDROID="$XC_STAGE/mariadb-android-build.log"
JOBS=4
CLEAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --jobs) JOBS="${2:?--jobs 需要一个数字}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "[err] 不认识的参数：$1" >&2; exit 2 ;;
  esac
done

CMAKE="${CMAKE_BIN:-C:/Android/Sdk/cmake/3.22.1/bin/cmake.exe}"
NINJA="${NINJA_BIN:-C:/Android/Sdk/cmake/3.22.1/bin/ninja.exe}"
for tool in "$CMAKE" "$NINJA"; do
  if [ ! -x "$tool" ] && [ ! -f "$tool" ]; then
    echo "[err] 找不到 $tool（可用 CMAKE_BIN / NINJA_BIN 覆盖）" >&2
    exit 1
  fi
done
if [ ! -x "$XC_PY" ]; then
  echo "[err] 找不到 python：$XC_PY（XC_PY 可覆盖）" >&2
  exit 1
fi
if [ ! -x "$XC_ZIG" ]; then
  echo "[err] 找不到 zig：$XC_ZIG（宿主自举工具要用）" >&2
  exit 1
fi

# OpenSSL 必须与 PHP 用同一颗（1.1.1w 静态库）。分叉会让 mysqld 与 php-cgi
# 各自静态链一份不同版本的 libcrypto —— 不冲突，但多几十 MB 且升级时容易漂。
OPENSSL_ROOT="${OPENSSL_ROOT:-$XC_STAGE/openssl-php}"
if [ ! -f "$OPENSSL_ROOT/lib/libssl.a" ]; then
  echo "[err] 找不到静态 OpenSSL：$OPENSSL_ROOT/lib/libssl.a" >&2
  echo "      先跑 tools/build-openssl.sh（PHP 依赖链会顺带产出它）" >&2
  exit 1
fi

if [ "$CLEAN" = 1 ]; then
  echo "[clean] 删掉 $HOST_BUILD 与 $ANDROID_BUILD"
  rm -rf "$HOST_BUILD" "$ANDROID_BUILD"
fi
mkdir -p "$XC_STAGE" "$XC_OUT"

# ---------------------------------------------------------------------------
# 1. 源码 stage 到无空格路径 + 打补丁
# ---------------------------------------------------------------------------
if [ ! -d "$XC_BASE/upstream/$SRC_NAME" ]; then
  echo "[err] 源码不存在：$XC_BASE/upstream/$SRC_NAME" >&2
  echo "      先解压 upstream/$SRC_NAME.tar.gz（或跑 tools/dl-mariadb.sh）" >&2
  exit 1
fi
# xc_stage_src 会 cd 进目标目录；它只在 dst 缺项时才重拷，所以打过补丁的
# stage 副本不会被仓库里的「干净源码」覆盖掉。
xc_stage_src "$XC_BASE/upstream/$SRC_NAME" "$SRC_NAME"
SRC="$XC_STAGE/$SRC_NAME"

echo "=== 源码补丁（幂等） ==="
PYTHONIOENCODING=utf-8 "$XC_PY" "$XC_BASE/tools/patch-mariadb-android.py" "$SRC"

# ---------------------------------------------------------------------------
# 2. 宿主自举工具链（zig + .lib 翻译）的四个 .cmd 转发
#
# 必须是 .cmd（不是 .exe 也不是 shell 脚本）：CMake 在 Windows 上生成 ninja
# 规则时会用 cmd.exe 展开，只有 .cmd 能被直接 exec。路径一律 cygpath -m
# （C:/... 混合形态）—— 写 /c/... 会被 Windows 当相对路径。
# ---------------------------------------------------------------------------
HOST_PY="$(cygpath -m "$XC_BASE/tools/host-cc-mariadb.py")"
write_wrapper() { # $1 = .cmd 名，$2 = 模式
  cat > "$XC_STAGE/$1.cmd" <<EOF
@echo off
"$XC_PY" "$HOST_PY" $2 %*
EOF
}
write_wrapper mdbhost-cc cc
write_wrapper mdbhost-cxx c++
write_wrapper mdbhost-ar ar
write_wrapper mdbhost-ranlib ranlib
echo "[host] 转发器：$XC_STAGE/mdbhost-{cc,cxx,ar,ranlib}.cmd → $HOST_PY"

# ---------------------------------------------------------------------------
# 3. 宿主构建：只要 5 个能在本机跑的自举工具
#    comp_err（错误码表） / comp_sql（sql_yacc 预处理） / factorial /
#    gen_lex_hash / gen_lex_token。它们的产物路径写进 import_executables.cmake，
#    交叉构建时被 add_executable(... IMPORTED) 引用 —— 所以两边**必须**共用
#    同一份源码树（否则 .c 文件哈希对不上，ninja 会认为需要重新生成）。
# ---------------------------------------------------------------------------
if [ ! -f "$HOST_BUILD/import_executables.cmake" ]; then
  echo "=== 宿主 configure ==="
  "$CMAKE" -G Ninja -S "$SRC" -B "$HOST_BUILD" \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_C_COMPILER="$XC_STAGE/mdbhost-cc.cmd" \
    -DCMAKE_CXX_COMPILER="$XC_STAGE/mdbhost-cxx.cmd" \
    -DCMAKE_AR="$XC_STAGE/mdbhost-ar.cmd" \
    -DCMAKE_RANLIB="$XC_STAGE/mdbhost-ranlib.cmd" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_FLAGS="-DHAVE_GMTIME_R=1 -DHAVE_LOCALTIME_R=1" \
    -DCMAKE_CXX_FLAGS="-DHAVE_GMTIME_R=1 -DHAVE_LOCALTIME_R=1" \
    -DWITH_SSL=bundled \
    -DWITH_UNIT_TESTS=OFF \
    -DPLUGIN_ROCKSDB=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO \
    2>&1 | tee "$LOG_HOST"
else
  echo "[host] 复用 $HOST_BUILD（import_executables.cmake 已在）"
fi

echo "=== 宿主构建 · 自举工具 ==="
"$CMAKE" --build "$HOST_BUILD" --target import_executables -- -j"$JOBS" 2>&1 | tee -a "$LOG_HOST"

for exe in extra/comp_err.exe scripts/comp_sql.exe dbug/factorial.exe \
           sql/gen_lex_hash.exe sql/gen_lex_token.exe; do
  if [ ! -f "$HOST_BUILD/$exe" ]; then
    echo "[err] 宿主工具缺失：$HOST_BUILD/$exe" >&2
    exit 1
  fi
done
echo "[ok] 5 个宿主工具就位"

# ---------------------------------------------------------------------------
# 4. 交叉 configure
#
# - I(MPORT_EXECUTABLES) 指向上一步导出的文件 —— MariaDB 的交叉构建**不支持**
#   在目标机不认识可执行文件时自己生成错误码表；没有它 configure 会尝试运行
#   arm64 的 comp_err 并失败。
# - WITHOUT_*：这些存储引擎要么依赖编译不过的第三方库，要么在 Android 上没有意义。
#   KSWEB 那颗也只带 InnoDB/MyISAM/Aria（见 mysql.zip 的 datadir 内容）。
# - WITH_ZLIB/PCRE=bundled：Android 没有系统 zlib 的静态库可用，bundled 更省事。
# - max-page-size=16384：targetSdk 35 起 Play 的 16 KB page 要求（与其余产物一致）。
#
# -ffile-prefix-map：源码里有大量 assert/错误信息把 `__FILE__` 烧进二进制
#   （`sql/slave.cc`、`sql/sql_table.cc`…），不映射的话产物里会带着
#   C:/Users/Bingo/ksweb-xc/... 这种构建机路径 —— 既被 xc_fail_if_host_paths
#   拦下，也让「路径泄漏」这条纪律失守。映射成 /mariadb-10.4.34 后，
#   真机上打印的栈信息仍然可读、且不含本机路径。
# 注意：这里**不要** source 出来的 CFLAGS/LDFLAGS。它们带 `-fPIE` 且目标是
# aarch64-linux-android24（不带 NDK 的 sysroot 选择），会和 toolchain file 打架。
# 清掉环境变量，让 android.toolchain.cmake 独占编译参数。
# STRIP 要先留一份：它是 _xc-env.sh 设的 NDK llvm-strip，unset 之后第 5 步就没得用了。
# ---------------------------------------------------------------------------
PREFIX_MAP="-ffile-prefix-map=$SRC=/mariadb-$MDB_VER -ffile-prefix-map=$OPENSSL_ROOT=/openssl"
STRIP_TOOL="$STRIP"
unset CC CXX CPP CFLAGS CXXFLAGS LDFLAGS AR RANLIB STRIP 2>/dev/null || true

echo "=== 交叉 configure（$ABI / api$API） ==="
"$CMAKE" -G Ninja -S "$SRC" -B "$ANDROID_BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DANDROID_STL=c++_static \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DIMPORT_EXECUTABLES="$HOST_BUILD/import_executables.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$PREFIX_MAP" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
  -DCMAKE_MODULE_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
  -DWITH_SSL=system \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_ROOT/include" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_ROOT/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_ROOT/lib/libcrypto.a" \
  -DWITH_ZLIB=bundled -DWITH_PCRE=bundled \
  -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF \
  -DTHREADS_PREFER_PTHREAD_FLAG=ON \
  -DWITHOUT_TOKUDB=ON -DWITHOUT_MROONGA=ON -DWITHOUT_OQGRAPH=ON \
  -DWITHOUT_SPIDER=ON -DWITHOUT_CONNECT=ON -DWITHOUT_ROCKSDB=ON \
  -DWITHOUT_CASSANDRA=ON -DWITHOUT_COLUMNSTORE=ON \
  2>&1 | tee "$LOG_ANDROID"

echo
echo "=== 交叉编译 · mysqld ==="
# -k 0：出错也把所有能编的编完，一次看全所有失败点（这个项目每轮都会撞 2-3 处
# bionic 差异，逐个 rerun 太慢）。失败信息已经在日志里，这里只判最终产物。
if ! "$CMAKE" --build "$ANDROID_BUILD" --target mysqld -- -j"$JOBS" -k 0 2>&1 | tee -a "$LOG_ANDROID"; then
  echo "[err] 编译失败，见 $LOG_ANDROID" >&2
  grep -E "^FAILED:" "$LOG_ANDROID" | sort -u | head -20 >&2
  exit 1
fi

BIN="$ANDROID_BUILD/sql/mysqld"
if [ ! -f "$BIN" ]; then
  echo "[err] 构建产物不存在：$BIN" >&2
  echo "      若日志里全是 unknown target，先看 patch-mariadb-android.py 文件头第 1 条" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. 落盘 + 硬校验
# ---------------------------------------------------------------------------
# 版本号里的点必须换成短横线：GSWeb/KSWEB 的组件命名约定是
# lib<name>-<ver 用短横线>-apiNN.so，而 NativeBinaries 也按这个正则找文件。
# 曾经这里写成 $MDB_VER（带点），产物叫 libsqld-10.4.34-api24.so，
# 装到手机上后 App 报「nativeLibraryDir 里没有 libsqld-10-4-34-api*.so」（D55）。
OUT="$XC_OUT/libsqld-${MDB_VER//./-}-api$API.so"
mkdir -p "$XC_OUT"
"$STRIP_TOOL" --strip-all "$BIN" -o "$OUT"

echo
echo "=== 产物 ==="
ls -l "$OUT"

xc_fail_if_host_paths "$OUT"

echo "=== DT_NEEDED ==="
# 期望只有 bionic 的三件套（libc/libm/libdl）。出现 libssl.so / libcrypto.so
# 说明静态 OpenSSL 没被用上 —— 那会在手机上加载不到（我们没带共享版）。
NEEDED="$("$XC_TOOLCHAIN/llvm-readelf.exe" -d "$OUT" | grep -oE 'Shared library: \[[^]]+\]' | sed 's/.*\[//; s/\]//' | sort -u)"
echo "$NEEDED"
BAD="$(echo "$NEEDED" | grep -vE '^(libc|libm|libdl|liblog)\.so$' || true)"
if [ -n "$BAD" ]; then
  echo "[err] 出现了非 bionic 系统库的依赖，手机上会加载失败：" >&2
  echo "$BAD" >&2
  exit 1
fi

echo
echo "=== 机器类型 ==="
"$XC_TOOLCHAIN/llvm-readelf.exe" -h "$OUT" | grep -E "Machine|Type"
echo
echo "[ok] $OUT"
