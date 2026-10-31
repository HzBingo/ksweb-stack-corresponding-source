#!/usr/bin/env python3
"""MariaDB 宿主自举工具的编译器转发器（zig cc + .lib 翻译）。

`tools/build-mariadb.sh` 的宿主编译用这个脚本，而不是通用的 `tools/host-cc.py`，
原因只有一个：**zig cc 的目标三元组选错了会链接失败**。

zig 在这台机器上默认目标就是 `x86_64-windows-msvc`（走 lld-link），但本机
没有 MSVC 的导入库 —— 链接 mysys 时炸在 `could not open 'ws2_32.lib'`。
改成 `x86_64-windows-gnu` 之后：
  * zig 自带 mingw-w64 头文件与导入库；
  * 链接器换成 lld 的 MinGW 驱动，但 CMake 从 Windows 平台带下来的
    `ws2_32.lib` / `wsock32.lib` 这类**MSVC 命名**仍然要翻译成 `-lws2_32`。

不做参数猜测：只把「以 .lib 结尾的单个参数」按名字翻译，其余原样透传。
`ar` / `ranlib` 走 zig 自己的子命令，不做翻译。

用法（由 build-mariadb.sh 生成的 mdbhost-*.cmd 调用）：
    python tools/host-cc-mariadb.py cc|c++|ar|ranlib <args...>

退出码原样转发 —— ninja 只认 0/非 0。
"""

import os
import subprocess
import sys

# zig 解压在无空格构建根下（见 tools/_xc-env.sh 的 XC_STAGE 说明）
XC_STAGE = os.environ.get(
    "XC_STAGE",
    r"C:/Users/Bingo/ksweb-xc",
)
ZIG = os.environ.get(
    "XC_ZIG",
    XC_STAGE + "/toolchain/zig-windows-x86_64-0.13.0/zig.exe",
)
# 必须 gnu 而不是默认的 msvc：理由见文件头
TARGET = os.environ.get("MDB_HOST_TARGET", "x86_64-windows-gnu")


def translate(args):
    out = []
    for a in args:
        low = a.lower()
        if low.endswith(".lib") and not low.startswith("-"):
            out.append("-l" + a[: -len(".lib")])
        else:
            out.append(a)
    return out


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: host-cc-mariadb.py cc|c++|ar|ranlib <args...>", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    args = translate(sys.argv[2:])
    if mode in ("cc", "c++"):
        cmd = [ZIG, mode, "-target", TARGET] + args
    else:
        cmd = [ZIG, mode] + args
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
