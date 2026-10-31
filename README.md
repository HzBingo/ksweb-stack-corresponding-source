# Corresponding Source — KSWEB Stack v53 (`0.1.0-p14.0`)

This repository is the **corresponding source** offered with the KSWEB Stack Android release
package, for the two components that are distributed **in object code only** under copyleft
licences (`libsmtp.so` = msmtp 1.8.27, GNU GPL-3.0; `libsqld-10-4-34-api24.so` = MariaDB 10.4.34,
GNU GPL-2.0). It contains everything we added or changed to build those two components for
Android/arm64, identified by the exact upstream tarball each was built from.

Binary this source corresponds to:

    package      dev.kswebstack.app
    versionCode  53
    versionName  0.1.0-p14.0
    apk size     134,233,757 B
    apk sha256   db560f88196b110edbbe1e7f5c4b6cb3e9098981280c26f5e556041b8a62760b

The licence texts, the written offer itself and the list of obligations are delivered inside the
release ZIP (`legal/`, alongside this APK); `legal/SOURCE-OFFER.txt` names these files.

## 这份仓库是什么

本项目是 KSWEB 的 **clean-room 功能重建**：Kotlin 侧代码、配置模板、构建脚本均为自研，不含 KSLabs
的源码、资源或字符串；与 KSWEB 的关系仅是机制与广播协议兼容。

发布物里有两件 copyleft 产物**只以目标码形式**分发，本仓库就是随包要约所指向的「对应完整源码」中
**由我们提供的那一部分**（上游 tarball 由原作者的公开归档点提供，按下面的 sha256 自证）。
目录结构与被用来构建的那棵构建仓库**逐字同路径**，这样 `legal/SOURCE-OFFER.txt` 里写哪一条，
你在仓库里就能按同一条路径找到它。

## 内容清单

以下每一行就是 `legal/SOURCE-OFFER.txt` 里「我们施加的修改」所点名的文件，路径与构建仓库逐字相同
（两处都由 `tools/legal-bundle.sh` 的同一段数组生成，所以不可能各说各话）：

    tools/build-msmtp.sh  7,565 B
        交叉编译配方（--host / --with-tls=no / --disable-nls / --sysconfdir）
    upstream/android-compat/getpass.c  1,709 B
        bionic 没有 getpass(3) 的补齐件，加在 make 的 LDFLAGS 上
    tools/_xc-env.sh  7,311 B
        NDK r27 工具链与暂存盘变量
    tools/build-mariadb.sh  12,693 B
        交叉编译配方（Android arm64、绑回环、只留必要引擎）
    tools/patch-mariadb-android.py  17,360 B
        源码补丁（Bionic 差异）
    tools/host-cc-mariadb.py  2,161 B
        宿主编译器分派
    tools/stage-mysql.py  11,274 B
        拼 bootstrap.sql 的脚本；生成的 SQL（2,155,829 B，去掉 4 行 @current_hostname）在这颗 zip 里的条目 components/mysql/sbin/share/bootstrap.sql
    app/src/main/assets/install/mysql.zip  538,725 B
        （与上一行同属要约里的同一条修改）
    upstream/msmtp-1.8.27.tar.xz  440,000 B
        上游源码包本身，sha256 见下节

自证（在本仓库根目录）：

    sha256sum -c SHA256SUMS.txt

## 上游源码包

    msmtp   1.8.27      upstream/msmtp-1.8.27.tar.xz      94030580a63a747faa0a3b9b1b264ae355aad33a4d94b832bfeb5b21633c965e
    MariaDB 10.4.34     mariadb-10.4.34.tar.gz  c657bdbca790c3106dc781a207f4b67d467571945164725d37cc7e42cc2a590a

msmtp 那颗直接放在本仓库里，按上面的 sha256 自证即可。
MariaDB 那颗 98,597,674 B（约 94 MiB），超过 GitHub 网页端单文件上传上限（25 MiB），因此不放在这里；
官方归档点为 <https://archive.mariadb.org/mariadb-10.4.34/source/>（同名下有一颗 `mariadb-10.4.34.tar.gz`）。
**这颗归档点上的文件已实测核对过**（2026-10-31 下载：98,597,674 B、sha256 与上面那串逐字相等）
⇒ 你从官方归档拿到的就是我们所编译的那一份，无需再向我们索取。
（若想让本仓库也带上它：命令行推文件的上限是 100 MiB，这颗刚好在限内，用 `git` 而非网页上传即可。）

## 不包含在本仓库里的东西

本项目自研的 Kotlin/Compose 代码不属于上述两件 copyleft 产物的对应源码，因此不在这里
（`legal/SOURCE-OFFER.txt` 同一条也这么写）；设备自带的 bionic 库由 OEM 提供，也不在其中。

## 要约的期限、渠道与联系方式

随本发布物分发的**每一份副本**均附本要约：GPL-3 依 §6(b) 提供、期限不少于三年；GPL-2 依 §3 提供
「全部我们手上持有的对应完整源码」。下面两行与 `legal/SOURCE-OFFER.txt` 里的两行**必须逐字一致**：

    获取方式：https://github.com/HzBingo/ksweb-stack-corresponding-source
    联系方式：HzBingo@users.noreply.github.com

> 上面两行只要还是生成器留下的**括号占位说明**（也就是没填），本仓库就**不要对外挂出去** ——
> 渠道或联系方式缺失、或与 `legal/SOURCE-OFFER.txt` 不一致，等于给接收方两份互相矛盾的条款。
> 这两行由 `tools/legal-bundle.sh` 的 `KSLEGAL_HOWTO` / `KSLEGAL_CONTACT` 生成，
> 「对应哪颗二进制」那一组字节数与 sha256 由 `APK=<发布包路径>` 给出；没给 APK 时那两行留的也是占位说明。
