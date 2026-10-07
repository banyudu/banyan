#define _GNU_SOURCE
#include "CTerminalPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <limits.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#include <sys/syscall.h>
#endif

int banyan_pty_spawn(const char *path, char *const argv[], char *const envp[],
                     unsigned short columns, unsigned short rows, int *master, pid_t *pid) {
    int slave, errors[2];
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    if (openpty(master, &slave, NULL, NULL, &size) < 0) return errno;
    if (pipe(errors) < 0) {
        int error = errno; close(*master); close(slave); return error;
    }
    // Descriptors owned by the bridge must not leak to another concurrent spawn.
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);
    fcntl(errors[0], F_SETFD, FD_CLOEXEC);
    fcntl(errors[1], F_SETFD, FD_CLOEXEC);
    long descriptor_limit = sysconf(_SC_OPEN_MAX);
    *pid = fork();
    if (*pid == 0) {
        close(*master); close(errors[0]);
        int error = 0;
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 ||
            dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) error = errno;
        if (slave > STDERR_FILENO) close(slave);
        // Keep only stdio and the exec-error pipe, even when another library
        // opened inheritable descriptors before this bridge was constructed.
        if (errors[1] != 3) { dup2(errors[1], 3); close(errors[1]); }
        fcntl(3, F_SETFD, FD_CLOEXEC);
#ifdef __APPLE__
        for (int fd = 4; fd < descriptor_limit; fd++) close(fd);
#else
#ifdef SYS_close_range
        if (syscall(SYS_close_range, 4U, UINT_MAX, 0) < 0)
#endif
            for (int fd = 4; fd < descriptor_limit; fd++) close(fd);
#endif
        // The TUI ignores these for Dispatch signal sources; children need defaults.
        signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL);
        signal(SIGWINCH, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        sigset_t signals; sigemptyset(&signals); sigprocmask(SIG_SETMASK, &signals, NULL);
        if (!error) { execve(path, argv, envp); error = errno; }
        (void)write(3, &error, sizeof(error));
        _exit(127);
    }
    int error = errno;
    close(slave); close(errors[1]);
    if (*pid < 0) { close(*master); close(errors[0]); return error; }
    ssize_t count;
    do { count = read(errors[0], &error, sizeof(error)); } while (count < 0 && errno == EINTR);
    close(errors[0]);
    if (count > 0) {
        close(*master); banyan_pty_reap(*pid); return error;
    }
    fcntl(*master, F_SETFL, fcntl(*master, F_GETFL) | O_NONBLOCK);
    return 0;
}

int banyan_pty_resize(int master, unsigned short columns, unsigned short rows) {
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    return ioctl(master, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

int banyan_pty_wait(pid_t pid) {
    siginfo_t info;
    int result;
    do { result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    return result == 0 ? (info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status) : -1;
}

void banyan_pty_reap(pid_t pid) {
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}
