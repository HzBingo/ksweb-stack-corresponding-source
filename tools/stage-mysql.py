#!/usr/bin/env python3
"""把 MariaDB 10.4.34 的**运行时数据文件**铺进 app/src/main/assets/install/mysql.zip。

## 为什么需要这一步（而不是像 PHP 那样只拷二进制）

`libsqld-10-4-34-api24.so`（jniLibs）只是引擎。mariadbd 起得来还需要三样**数据**：

  1. `share/charsets/*.xml` —— 字符集定义。缺了它 `SET NAMES utf8mb4` 直接报
     `Unknown character set`，而服务器本身「看起来」是好的。
  2. `share/mysql/english/errmsg.sys` —— 全部错误消息文本（由 `comp_err` 从
     `sql/share/errmsg-utf8.txt` 生成）。缺了它每条错误只剩错误号，
     排查时等于什么都不知道。
  3. `share/bootstrap.sql` —— 首次初始化 datadir 的 SQL（见下）。

这三样都必须与**这颗二进制**同源同版本：`errmsg.sys` 里的错误号顺序是编译期
生成的，与二进制对不上时消息会串行（最坏情况是「错误 1045 显示成语法错误」）。

## 为什么不预初始化 datadir（与 KSWEB 的关键偏离）

KSWEB 的两个 mysql zip 都随包带一份**已经初始化好的 datadir**（ibdata1、
ib_logfile0/1 各 48 MB、整套系统表 .frm）。我们**不这么做**，原因有三条：

  - clean-room 红线：那份 datadir 是 KSLabs 的发行物（系统表里还带着他们
    构建机的痕迹），整包拷过来等于把他们的产物搬进我们的 APK；
  - 版本锁定：预初始化的 datadir 把 `mysql_upgrade_info` 钉死，以后换 MariaDB
    小版本必须重做 zip，否则 `mariadbd` 会要求 upgrade；
  - `server-uuid`：MySQL 5.7 那份把 `auto.cnf` 的 uuid 写死了，两台的复制会撞。

替代方案是**装机时就地 bootstrap**：`MysqlServer` 发现 datadir 里没有
`mysql/` 就 `mariadbd --bootstrap` 读 `share/bootstrap.sql`。产物由同一颗
二进制生成，天然同版本。

### bootstrap.sql 是怎么来的

MariaDB 10.4 **没有** MySQL 5.7 的 `--initialize`，官方初始化路径是
`scripts/mysql_install_db.sh`：它把几份 SQL 拼起来（`cat_sql()`）喂给
`mariadbd --bootstrap`，成功后再写 `datadir/mysql_upgrade_info`。
本脚本复刻的就是那个拼接，**只有一处刻意的偏离**：

    sed -e '/@current_hostname/d'

即 `--cross-bootstrap` 的过滤（见 mysql_install_db.sh:530-538）。不过滤的话
设备主机名（vivo 上是 `vivo-iQOO-Neo`）会被写进 `mysql.global_priv` /
`proxies_priv`，产生一条 `root@<设备名>` 账户 —— 换个机名就对不上，
而且把设备名带进了数据库。过滤后只剩 `localhost` / `127.0.0.1` / `::1`。

拼接顺序（与 cat_sql 逐行一致）：

    create database if not exists mysql;
    use mysql;
    SET @auth_root_socket=NULL;      ← NULL = 经典空口令 root（非 unix_socket 插件）
    mysql_system_tables.sql
    mysql_performance_tables.sql
    mysql_system_tables_data.sql
    fill_help_tables.sql
    maria_add_gis_sp_bootstrap.sql

`mysql_test_db.sql` 与 `mysql_test_data_timezone.sql` **不含**：前者建一个
`test` 库（KSWEB 的 datadir 里也没有），后者只服务 mysql-test 套件。

## 用法

    python tools/stage-mysql.py --dry-run     # 只核对输入、不写包
    python tools/stage-mysql.py              # 重建 mysql.zip

输入：
  - 源码：`$XC_STAGE/mariadb-10.4.34`（`tools/build-mariadb.sh` 用的同一份）
  - 生成物：`$XC_STAGE/mariadb-android-build/sql/share/english/errmsg.sys`
    （`comp_err` 的产物，交叉构建里生成；它是**目标机格式**，与宿主无关）
  - 生成物：`$XC_STAGE/mariadb-android-build/scripts/maria_add_gis_sp_bootstrap.sql`
    （configure 期从 `.sql.in` 渲染，含 DEFINER=`mariadb.sys`@`localhost`）

改完 assets 要 bump `versionCode`（D28 的规矩），否则老设备不会重走安装链。
"""

import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
TARGET = os.path.join(PROJECT, "app", "src", "main", "assets", "install", "mysql.zip")

MDB_VER = "10.4.34"

# zip 内的统一根：与 KSWEB 同形（`components/mysql/{conf,sbin/...}`），
# 换掉的只有包名与谁生成内容。MysqlConf / MysqlServer 的路径常量由此固定。
PREFIX = "components/mysql/"

# 装机包里 my.ini 只有一行占位：真实内容由 MysqlConf.prepare() 生成（含 dataDir
# 绝对路径，装机前不可能知道）。判「可整份替换」的形态与 msmtprc 相同 —— 只有注释。
MY_INI_PLACEHOLDER = (
    "# P1 占位。真实配置由 App 的 MysqlConf.prepare() 生成（含 #begin_paths / "
    "#begin_datadir 锚点）。\n"
)

# 拼接顺序即 mysql_install_db.sh 的 cat_sql()。前三条是 preamble，后面按名字取源码文件。
PREAMBLE = (
    "create database if not exists mysql;\n"
    "use mysql;\n"
    "SET @auth_root_socket=NULL;\n"
)
SYSTEM_SQL = [
    "scripts/mysql_system_tables.sql",
    "scripts/mysql_performance_tables.sql",
    "scripts/mysql_system_tables_data.sql",
    "scripts/fill_help_tables.sql",
]


def stage_root():
    """构建暂存根：与 tools/_xc-env.sh 的 XC_STAGE 同一个算法。"""
    env = os.environ.get("XC_STAGE")
    if env:
        return env.replace("\\", "/")
    home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return (home.replace("\\", "/").rstrip("/") + "/ksweb-xc")


def need(path, what):
    if not os.path.isfile(path):
        sys.exit("[err] 缺%s：%s" % (what, path.replace("\\", "/")))
    size = os.path.getsize(path)
    if size == 0:
        sys.exit("[err] %s 是空文件：%s" % (what, path.replace("\\", "/")))
    return path, size


def build_bootstrap(src):
    """拼出 bootstrap.sql（返回文本与来源清单）。"""
    parts = [("(preamble)", PREAMBLE)]
    for rel in SYSTEM_SQL:
        path, size = need(os.path.join(src, rel), "源码 SQL")
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        if not text.endswith("\n"):
            text += "\n"
        parts.append((rel, text))

    gis = os.path.join(stage_root(), "mariadb-android-build", "scripts",
                       "maria_add_gis_sp_bootstrap.sql")
    need(gis, "渲染好的 maria_add_gis_sp_bootstrap.sql")
    with open(gis, "r", encoding="utf-8") as fh:
        text = fh.read()
    if not text.endswith("\n"):
        text += "\n"
    parts.append(("(build)/scripts/maria_add_gis_sp_bootstrap.sql", text))

    merged = []
    dropped = 0
    for name, text in parts:
        kept = []
        for line in text.splitlines(True):
            # cross_bootstrap 的过滤：见文件头。注意被丢掉的行里既有 SET 也有用它的
            # REPLACE/INSERT，只留一半会让 @current_hostname 变成 NULL 参与比较。
            if "@current_hostname" in line:
                dropped += 1
                continue
            kept.append(line)
        merged.append((name, "".join(kept)))
    return merged, dropped


def make_zip(out_path, entries, dry_run):
    """写包。entries = [(zip 内名字, bytes 或 None=目录)]，保持给定顺序。"""
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, blob in entries:
            info = zipfile.ZipInfo(name)
            if blob is None:
                info.external_attr = 0o40755 << 16
                zf.writestr(info, b"")
            else:
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(info, blob)


def main(argv):
    dry = "--dry-run" in argv
    root = stage_root()
    src = os.path.join(root, "mariadb-%s" % MDB_VER)
    if not os.path.isdir(src):
        sys.exit("[err] 找不到源码目录 %s（先跑 tools/build-mariadb.sh，它会解到 XC_STAGE）"
                 % src.replace("\\", "/"))

    entries = []           # (zip 名, bytes|None)
    dirs = [
        PREFIX,
        PREFIX + "conf/",
        PREFIX + "sbin/",
        PREFIX + "sbin/data/",
        PREFIX + "sbin/share/",
        PREFIX + "sbin/share/charsets/",
        PREFIX + "sbin/share/mysql/",
        PREFIX + "sbin/share/mysql/english/",
    ]

    # ---- 1. 字符集（24 个 xml + Index.xml + README；languages.html 不进包，KSWEB 也没有）
    charset_dir = os.path.join(src, "sql", "share", "charsets")
    if not os.path.isdir(charset_dir):
        sys.exit("[err] 找不到字符集目录：%s" % charset_dir.replace("\\", "/"))
    charset_files = []
    for name in sorted(os.listdir(charset_dir)):
        if name.endswith(".xml") or name in ("README",):
            charset_files.append(name)
    if len(charset_files) < 20:
        sys.exit("[err] 字符集文件只有 %d 个，不像完整的一套：%s"
                 % (len(charset_files), charset_dir.replace("\\", "/")))
    charset_bytes = 0
    for name in charset_files:
        path, size = need(os.path.join(charset_dir, name), "字符集文件")
        with open(path, "rb") as fh:
            entries.append((PREFIX + "sbin/share/charsets/" + name, fh.read()))
        charset_bytes += size

    # ---- 2. errmsg.sys（comp_err 的产物，与二进制同源）
    errmsg = os.path.join(stage_root(), "mariadb-android-build", "sql", "share",
                          "english", "errmsg.sys")
    path, errmsg_size = need(errmsg, "errmsg.sys（交叉构建的 comp_err 产物）")
    with open(path, "rb") as fh:
        entries.append((PREFIX + "sbin/share/mysql/english/errmsg.sys", fh.read()))

    # ---- 3. bootstrap.sql
    merged, dropped = build_bootstrap(src)
    bootstrap = "".join(text for _name, text in merged).encode("utf-8")
    entries.append((PREFIX + "sbin/share/bootstrap.sql", bootstrap))

    # ---- 4. 占位 my.ini + 空 datadir + 说明
    entries.append((PREFIX + "conf/my.ini", MY_INI_PLACEHOLDER.encode("utf-8")))
    entries.append((PREFIX + "sbin/data/.keep", b""))

    full = []
    for d in dirs:
        full.append((d, None))
    # 目录条目在前、文件在后；zip 本身不要求这个顺序，但解压顺序稳定便于核对
    full.extend(entries)

    print("构建暂存根：%s" % root)
    print("源码：%s" % src.replace("\\", "/"))
    print("  charsets        %2d 个文件 %8d 字节" % (len(charset_files), charset_bytes))
    print("  errmsg.sys              %8d 字节  %s" % (errmsg_size, path.replace("\\", "/")))
    print("  bootstrap.sql           %8d 字节（%d 段，过滤 @current_hostname %d 行）"
          % (len(bootstrap), len(merged), dropped))
    for name, text in merged:
        print("      %-52s %8d 字节" % (name, len(text.encode("utf-8"))))
    print("  my.ini 占位             %8d 字节" % len(MY_INI_PLACEHOLDER))

    if dry:
        print("\n[dry-run] 未写包。条目数：%d" % len(full))
        return

    tmp = TARGET + ".partial"
    make_zip(tmp, full, dry)
    os.replace(tmp, TARGET)
    size = os.path.getsize(TARGET)
    total = sum(len(b) for _n, b in entries if b is not None)
    print("\n[done] %s" % TARGET.replace("\\", "/"))
    print("       条目 %d 个，未压缩合计 %d 字节 → 压缩后 %d 字节" % (len(full), total, size))


if __name__ == "__main__":
    main(sys.argv[1:])
