/*
 * getpass(3) 的 Android 兼容实现。
 *
 * 为什么需要：msmtp 的 src/password.c:215 无条件调用 getpass()，
 * 但 Android bionic 从来没提供过这个函数（glibc 有，且已被标记 obsolescent）。
 * configure 里即使探测到 "getpass: no"，msmtp 也没有 HAVE_GETPASS 的兜底分支 ——
 * 结果是链接期 undefined symbol，编译能过、链接必挂。
 *
 * 实现要点：
 *  - 只从 /dev/tty 读，不回落到 stdin（msmtp 的正文走 stdin，混读会吃掉邮件内容）
 *  - 关闭 ECHO，读完恢复
 *  - 打开 /dev/tty 失败时返回 NULL（调用方会退化成「无口令」）
 */

#include <stdio.h>
#include <termios.h>
#include <unistd.h>

#define GETPASS_BUF 256

char *getpass(const char *prompt)
{
    static char buf[GETPASS_BUF];
    struct termios oldt, newt;
    int fd;
    int changed = 0;
    size_t len;

    FILE *tty = fopen("/dev/tty", "r+");
    if (tty == NULL) {
        return NULL;
    }

    fputs(prompt, tty);
    fflush(tty);

    fd = fileno(tty);
    if (tcgetattr(fd, &oldt) == 0) {
        newt = oldt;
        newt.c_lflag &= ~(tcflag_t)ECHO;
        if (tcsetattr(fd, TCSAFLUSH, &newt) == 0) {
            changed = 1;
        }
    }

    if (fgets(buf, sizeof buf, tty) == NULL) {
        buf[0] = '\0';
    }

    if (changed) {
        tcsetattr(fd, TCSAFLUSH, &oldt);
    }

    /* 输入时回显被关掉了，补一个换行，行为与 glibc 一致 */
    fputc('\n', tty);
    fflush(tty);
    fclose(tty);

    len = 0;
    while (buf[len] != '\0') {
        len++;
    }
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[--len] = '\0';
    }

    return buf;
}
