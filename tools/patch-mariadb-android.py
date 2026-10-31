#!/usr/bin/env python3
r"""
给 MariaDB 10.4.34 打「在 Windows 上编宿主工具 + 在 Android/bionic 上跑」的两类补丁。

用法：
    python tools/patch-mariadb-android.py <mariadb-src-dir>

每一处替换都是**精确字符串 + 计数断言**，要么匹配一次、要么直接失败退出 ——
不做正则模糊匹配，也不静默跳过（静默跳过会让「补丁没打上」表现为十几分钟后
的编译错误，而错误行和根因隔着好几个头文件）。

补丁分两组，原因完全不同：

────────────────────────────────────────────────────────────────────────────
A 组：宿主编译（Windows + zig mingw），只为编出 comp_err 等 5 个自举工具
────────────────────────────────────────────────────────────────────────────
1. include/my_pthread.h
   `localtime_r` / `gmtime_r` 在 `#ifdef __WIN__` 分支里被重定义成
   `localtime_s`/`gmtime_s` 的 static inline 包装。mingw-w64 的 <time.h> **已经**
   声明了 POSIX 版，于是 `mysys/my_pthread.c:67` 的静态定义与头文件声明冲突
   （redefinition）。改成 mingw 下只写 extern 声明。

2. mysys/stacktrace.c
   `my_safe_print_str` 用 MSVC 的 SEH（`__try/__except`）兜「用户给了野指针」。
   mingw 没有 SEH 语法，clang 报 `use of undeclared identifier '__try'`。
   mingw 分支直接 write —— 这条路径只在宿主工具里跑到（且只有 dump 时才走）。

────────────────────────────────────────────────────────────────────────────
B 组：Android / bionic 交叉编译
────────────────────────────────────────────────────────────────────────────
3. cmake/readline.cmake
   `FIND_CURSES()` 在非 WIN32 上无条件 `FIND_PACKAGE(Curses REQUIRED)`；
   Android 没有 ncurses，而且我们根本不编 client（只编 mysqld）。
   **坑点**：这是一个 MACRO，不是 FUNCTION —— 在宏里写 `RETURN()` 会退出
   *调用者* 的文件作用域，也就是整个顶层 CMakeLists 立刻结束。现象是
   cmake 打印 "Configuring done" 却只生成了 wsrep-lib/zlib 两个目录，
   `sql/`、`mysys/`、`client/` 全都不存在，`ninja --target mysqld` 报
   "unknown target"。所以这里必须用 IF/ELSE 包住剩余语句，不能 return。

4. mysys/get_password.c
   bionic 不像 glibc 那样通过别的头文件把 <ctype.h> 的
   `iscntrl`/`isspace` 声明漏进来，新版 clang 对隐式声明是**硬错误**。

5. mysys/mf_pack.c
   bionic 有 `getpwnam()` 但没有 `endpwent()`/`getpwent()` 整族
   （Android 不向应用暴露 passwd 数据库遍历）。去掉这次收尾调用即可：
   这里只做一次按名字查询，不存在句柄泄漏。

6. include/my_global.h
   bionic 的 <sys/types.h> 定义 `uint` 但**不**定义 `ushort`
   （glibc 在 __USE_MISC 下两个都定义）。于是 configure 的 HAVE_UINT 探测
   被 uint 满足，整块 typedef 被跳过 → MariaDB/Aria/MyISAM 的源码全部报
   `use of undeclared identifier 'ushort'`。

7. sql/wsrep_utils.cc
   `process::spawn()` 用的是 `posix_spawnp` + `posix_spawnattr_*` +
   `posix_spawn_file_actions_*`。bionic 的 <spawn.h> 给这一整族标了
   `__INTRODUCED_IN(28)`，我们按 KSWEB 的档位编 api24 —— 于是它们连**声明**都
   不存在（不是运行时缺符号，是编译期 undeclared identifier）。
   这里不是「随便找个替代」：这段代码只在 galera 的 SST 脚本拉起子进程时用，
   而我们的构建根本没有 wsrep provider（`-DWITH_WSREP` 未开、也没编 galera）。
   所以用 fork/exec 复刻同一组语义（空信号掩码、默认处置、把管道的子进程端
   接到 stdin/stdout、env 透传），行为等价，且不引入任何 API 28 依赖。

8. wsrep-lib/src/CMakeLists.txt
   `target_link_libraries(wsrep-lib ... pthread ...)` 里的裸 `pthread` 在 bionic
   上不存在（整个 pthread API 都在 libc 里，没有 libpthread.a/-lpthread）。
   最终 mysqld 链接报 `ld.lld: error: unable to find library -lpthread`。
"""

import io
import os
import sys

# ---------------------------------------------------------------------------
# 补丁定义： (相对路径, 锚点, 原文, 替换后, 说明)
#
# 幂等判据用「替换后」里独有的一句话：第二次跑时锚点已经变成替换后，
# 原文匹配不上，但那一句能命中 → 视为已打补丁，跳过而不是报错。
# ---------------------------------------------------------------------------


def p_my_pthread():
    return (
        "include/my_pthread.h",
        "static inline struct tm *localtime_r(const time_t *timep, struct tm *tmp)",
        """static inline struct tm *localtime_r(const time_t *timep, struct tm *tmp)
{
  localtime_s(tmp, timep);
  return tmp;
}

static inline struct tm *gmtime_r(const time_t *clock, struct tm *res)
{
  gmtime_s(res, clock);
  return res;
}
""",
        """/* mingw (used by the zig host build) already provides POSIX localtime_r/gmtime_r;
   defining them here collides with <time.h>. Android never defines __WIN__. */
#if defined(__MINGW32__)
/* mingw-w64 only declares these when _POSIX_C_SOURCE is set; MariaDB calls them
   from files that do not. Declare them here (same prototypes, extern). */
extern struct tm *localtime_r(const time_t *, struct tm *);
extern struct tm *gmtime_r(const time_t *, struct tm *);
#else
static inline struct tm *localtime_r(const time_t *timep, struct tm *tmp)
{
  localtime_s(tmp, timep);
  return tmp;
}

static inline struct tm *gmtime_r(const time_t *clock, struct tm *res)
{
  gmtime_s(res, clock);
  return res;
}
#endif /* !__MINGW32__ */
""",
        "localtime_r/gmtime_r 在 mingw 下只声明不定义（宿主工具构建）",
        "mingw (used by the zig host build) already provides POSIX",
    )


def p_stacktrace():
    return (
        "mysys/stacktrace.c",
        "int my_safe_print_str(const char *val, size_t len)",
        """  __try
  {
    my_write_stderr(val, len);
  }
  __except(EXCEPTION_EXECUTE_HANDLER)
  {
    my_safe_printf_stderr("%s", "is an invalid string pointer");
  }
""",
        """#if defined(__MINGW32__)
  /* mingw has no MSVC SEH (__try/__except); only the host tool build hits this. */
  my_write_stderr(val, len);
#else
  __try
  {
    my_write_stderr(val, len);
  }
  __except(EXCEPTION_EXECUTE_HANDLER)
  {
    my_safe_printf_stderr("%s", "is an invalid string pointer");
  }
#endif
""",
        "SEH 在 mingw 下不成立（宿主工具构建）",
        "mingw has no MSVC SEH",
    )


def p_readline_head():
    return (
        "cmake/readline.cmake",
        "MACRO (FIND_CURSES)",
        """ IF(ANDROID)
   # Android has no ncurses. We do not ship the client anyway; the bundled
   # readline in extra/readline provides its own termcap, so an empty
   # CURSES_LIBRARY is sufficient and FIND_PACKAGE(Curses REQUIRED) must not run.
   SET(CURSES_FOUND TRUE)
   SET(CURSES_LIBRARY "" CACHE STRING "" FORCE)
   SET(CURSES_INCLUDE_PATH "" CACHE STRING "" FORCE)
   SET(CURSES_HAVE_CURSES_H FALSE)
   RETURN()
 ENDIF()
 FIND_PACKAGE(Curses REQUIRED)
""",
        """ IF(ANDROID)
   # Android has no ncurses. We do not ship the client anyway; the bundled
   # readline in extra/readline provides its own termcap, so an empty
   # CURSES_LIBRARY is sufficient and FIND_PACKAGE(Curses REQUIRED) must not run.
   #
   # NOTE: do NOT use RETURN() here. FIND_CURSES is a MACRO (not a FUNCTION),
   # so return() would leave the *caller* file scope -- i.e. abort the whole
   # top-level CMakeLists right after readline.cmake is included. That is
   # completely silent: cmake reports "Configuring done" while sql/, mysys/,
   # client/ etc. never get added. Use IF/ELSE instead.
   SET(CURSES_FOUND TRUE)
   SET(CURSES_LIBRARY "" CACHE STRING "" FORCE)
   SET(CURSES_INCLUDE_PATH "" CACHE STRING "" FORCE)
   SET(CURSES_HAVE_CURSES_H FALSE)
 ELSE()
 FIND_PACKAGE(Curses REQUIRED)
""",
        "FIND_CURSES 的 Android 分支改成 IF/ELSE（宏里 return 会中断顶层 CMakeLists）",
        "NOTE: do NOT use RETURN() here",
    )


def p_readline_tail():
    return (
        "cmake/readline.cmake",
        ' CHECK_LIBRARY_EXISTS(${CURSES_LIBRARY} vidattr "" HAVE_VIDATTR)\nENDMACRO()',
        ' CHECK_LIBRARY_EXISTS(${CURSES_LIBRARY} vidattr "" HAVE_VIDATTR)\n ENDIF() # ANDROID\nENDMACRO()',
        "FIND_CURSES 的 Android 分支收尾 ENDIF",
        "ENDIF() # ANDROID\nENDMACRO()",
    )


def p_get_password():
    return (
        "mysys/get_password.c",
        "#include <m_ctype.h>",
        """#include <m_ctype.h>
""",
        """#include <m_ctype.h>
/* Bionic (Android) does not pull <ctype.h> in through the headers above, so
   iscntrl()/isspace() would be implicit declarations (hard error with newer
   clang). glibc happens to leak the declarations, which is why upstream's
   Linux-only CI never noticed. */
#include <ctype.h>
""",
        "get_password.c 缺 <ctype.h>（bionic）",
        "Bionic (Android) does not pull <ctype.h>",
    )


def p_mf_pack():
    return (
        "mysys/mf_pack.c",
        "    endpwent();",
        """    endpwent();
""",
        """#ifndef __ANDROID__
    /* Bionic has getpwnam() but no endpwent()/getpwent() family (they need
       the platform passwd database, which Android does not expose). Skipping
       the cleanup is fine here: getpwnam() is the only lookup we do. */
    endpwent();
#endif
""",
        "bionic 没有 endpwent（mf_pack.c 的 ~user 展开）",
        "Bionic has getpwnam() but no endpwent()",
    )


def p_my_global():
    return (
        "include/my_global.h",
        "#if !defined(HAVE_UINT)",
        """#if !defined(HAVE_UINT)
#undef HAVE_UINT
#define HAVE_UINT
typedef unsigned int uint;
typedef unsigned short ushort;
#endif
""",
        """#if !defined(HAVE_UINT)
#undef HAVE_UINT
#define HAVE_UINT
typedef unsigned int uint;
typedef unsigned short ushort;
#elif defined(__ANDROID__)
/*
  Bionic's <sys/types.h> defines `uint` but not `ushort` (glibc defines both
  under __USE_MISC, so the HAVE_UINT probe is satisfied by uint alone and this
  block used to be skipped). Without this, MariaDB/Aria/MyISAM sources die on
  `use of undeclared identifier 'ushort'`.
*/
typedef unsigned short ushort;
#endif
""",
        "bionic 的 <sys/types.h> 只有 uint 没有 ushort",
        "Bionic's <sys/types.h> defines `uint` but not `ushort`",
    )


def p_wsrep_head():
    return (
        "sql/wsrep_utils.cc",
        "    posix_spawnattr_t attr;",
        """    posix_spawnattr_t attr;
    err_= posix_spawnattr_init (&attr);
""",
        """#if !defined(__ANDROID__) || __ANDROID_API__ >= 28
    posix_spawnattr_t attr;
    err_= posix_spawnattr_init (&attr);
""",
        "wsrep 的 posix_spawn 族在 bionic 上是 API 28（这里按 api24 编）",
        "#if !defined(__ANDROID__) || __ANDROID_API__ >= 28",
    )


def p_wsrep_tail():
    return (
        "sql/wsrep_utils.cc",
        "cleanup_attr:",
        """cleanup_attr:
    err= posix_spawnattr_destroy (&attr);
    if (err)
    {
        WSREP_ERROR ("posix_spawnattr_destroy() failed: %d (%s)",
                     err, strerror(err));
    }

cleanup_pipe:
""",
        """#else
    /* bionic's <spawn.h> only declares the posix_spawn() family from API 28
       (__INTRODUCED_IN(28)); we compile for android-24, so the calls above are
       not even declared. SST script spawning is a galera-only feature and this
       build has no wsrep provider, so a plain fork/exec reproduces what the
       attrs/file_actions asked for: empty signal mask, default dispositions,
       child stdin/stdout bound to our pipe, environment passed through. */
    /* `pid` is declared without an initializer on purpose: C++ forbids jumping
       (the `goto cleanup_pipe` above) over an initialized declaration. */
    pid_t pid;
    pid= fork();
    if (pid < 0)
    {
        err_= errno;
        WSREP_ERROR ("fork() failed: %d (%s)", err_, strerror(err_));
        goto cleanup_pipe;
    }

    if (0 == pid)
    {
        sigset_t sigmask_empty; sigemptyset(&sigmask_empty);
        sigprocmask (SIG_SETMASK, &sigmask_empty, NULL);

        static const int dfl[]=
        { SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGCHLD };
        for (size_t i= 0; i < sizeof(dfl) / sizeof(dfl[0]); ++i)
        {
            struct sigaction sa;
            memset (&sa, 0, sizeof(sa));
            sa.sa_handler= SIG_DFL;
            sigemptyset (&sa.sa_mask);
            sigaction (dfl[i], &sa, NULL);
        }

        if (pipe_fds[child_end] != close_fd)
        {
            if (dup2 (pipe_fds[child_end], close_fd) < 0) _exit (127);
            close (pipe_fds[child_end]);
        }

        execvpe ("sh", pargv, env);
        _exit (127); /* exec failed: never return into mysqld's own code */
    }

    pid_= pid;
    io_= fdopen (pipe_fds[parent_end], type);
    if (io_)
    {
        pipe_fds[parent_end]= -1; // skip close on cleanup
    }
    else
    {
        err_= errno;
        WSREP_ERROR ("fdopen() failed: %d (%s)", err_, strerror(err_));
    }
#endif

cleanup_pipe:
""",
        "wsrep_utils.cc 的 API 28 依赖换成 fork/exec",
        "SST script spawning is a galera-only feature",
    )


def p_wsrep_lib_pthread():
    return (
        "wsrep-lib/src/CMakeLists.txt",
        "target_link_libraries(wsrep-lib wsrep_api_v26 pthread",
        """target_link_libraries(wsrep-lib wsrep_api_v26 pthread ${WSREP_LIB_LIBDL})
""",
        """if(ANDROID)
  # bionic has no libpthread: the whole pthread API lives in libc, and there is
  # no libpthread.a/-lpthread to link against. Without this the final mysqld
  # link dies with "ld.lld: error: unable to find library -lpthread".
  target_link_libraries(wsrep-lib wsrep_api_v26 ${WSREP_LIB_LIBDL})
else()
  target_link_libraries(wsrep-lib wsrep_api_v26 pthread ${WSREP_LIB_LIBDL})
endif()
""",
        "wsrep-lib 显式链 -lpthread（bionic 没有这个库）",
        "bionic has no libpthread",
    )


PATCHES = [
    p_my_pthread,
    p_stacktrace,
    p_readline_head,
    p_readline_tail,
    p_get_password,
    p_mf_pack,
    p_my_global,
    p_wsrep_head,
    p_wsrep_tail,
    p_wsrep_lib_pthread,
]


def _write_file(path, text):
    """
    落盘。Windows 上目标文件可能正被编译器打开（构建在跑），
    普通 open("w") 会 EINVAL、os.replace 会 WinError 5。
    先写同目录临时文件，再交给 msys 的 mv（它对共享冲突会重试），
    全部失败才报错 —— 不在半路留下半份源码。
    """
    tmp = path + ".patchtmp"
    with io.open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    try:
        os.replace(tmp, path)
        return
    except OSError:
        pass
    import subprocess
    for _ in range(5):
        rc = subprocess.call(["mv", "-f", tmp, path],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if rc == 0:
            return
        import time
        time.sleep(1.0)
    if os.path.exists(tmp):
        os.remove(tmp)
    raise OSError("替换 %s 失败（文件被占用？先停掉构建再跑补丁）" % path)


def patch_one(src, factory):
    # 多数工厂带一个 `anchor`（给人看的定位提示，patch_one 不用它）；
    # 少数只有 (rel, old, new, why, marker)。两种形状都收，免得为了对齐而
    # 给没用的字段编一个值。
    parts = factory()
    if len(parts) == 5:
        rel, old, new, why, marker = parts
    else:
        rel, _anchor, old, new, why, marker = parts
    path = os.path.join(src, rel)
    if not os.path.isfile(path):
        print("[err] 找不到 %s" % path)
        return False
    with io.open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read()

    if marker in text:
        print("[skip] %s：已打过（%s）" % (rel, why))
        return True

    if text.count(old) != 1:
        print("[err] %s：原文匹配 %d 次（期望 1 次），拒绝猜一处改（%s）"
              % (rel, text.count(old), why))
        return False

    _write_file(path, text.replace(old, new, 1))
    print("[ok] %s：%s" % (rel, why))
    return True


def main():
    if len(sys.argv) != 2:
        print("用法：python tools/patch-mariadb-android.py <mariadb-src-dir>")
        return 2
    src = sys.argv[1]
    if not os.path.isfile(os.path.join(src, "CMakeLists.txt")):
        print("[err] %s 不像 MariaDB 源码根（没有 CMakeLists.txt）" % src)
        return 1
    ok = 0
    for factory in PATCHES:
        if not patch_one(src, factory):
            return 1
        ok += 1
    print("[done] %d 处补丁全部就位" % ok)
    return 0


if __name__ == "__main__":
    sys.exit(main())
