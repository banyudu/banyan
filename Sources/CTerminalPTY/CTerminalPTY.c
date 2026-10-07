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

static void close_inherited(long descriptor_limit) {
#ifdef __APPLE__
    for (int fd = 4; fd < descriptor_limit; fd++) close(fd);
#else
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 4U, UINT_MAX, 0) < 0)
#endif
        for (int fd = 4; fd < descriptor_limit; fd++) close(fd);
#endif
}

static void reset_signals(void) {
    signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL);
    signal(SIGWINCH, SIG_DFL); signal(SIGPIPE, SIG_DFL);
    sigset_t signals; sigemptyset(&signals); sigprocmask(SIG_SETMASK, &signals, NULL);
}

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
        close_inherited(descriptor_limit);
        // The TUI ignores these for Dispatch signal sources; children need defaults.
        reset_signals();
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

int banyan_command_spawn(const char *path, char *const argv[], char *const envp[],
                         const char *cwd, int *output, int *error_output, pid_t *pid) {
    int ends[6], count = 0;
    for (int pair = 0; pair < 3; pair++) {
        if (pipe(&ends[pair * 2]) < 0) {
            int error = errno;
            for (int fd = 0; fd < count; fd++) close(ends[fd]);
            return error;
        }
        count += 2;
    }
    for (int fd = 0; fd < count; fd++) fcntl(ends[fd], F_SETFD, FD_CLOEXEC);
    long descriptor_limit = sysconf(_SC_OPEN_MAX);
    *pid = fork();
    if (*pid == 0) {
        int error = 0;
        int input = open("/dev/null", O_RDONLY);
        if (input < 0 || dup2(input, 0) < 0 || dup2(ends[1], 1) < 0 ||
            dup2(ends[3], 2) < 0 || chdir(cwd) < 0 || setpgid(0, 0) < 0) error = errno;
        // fd 3 carries only an exec error and closes on successful exec.
        if (ends[5] != 3) dup2(ends[5], 3);
        fcntl(3, F_SETFD, FD_CLOEXEC);
        close_inherited(descriptor_limit);
        reset_signals();
        if (!error) { execve(path, argv, envp); error = errno; }
        (void)write(3, &error, sizeof(error));
        _exit(127);
    }
    int error = errno;
    close(ends[1]); close(ends[3]); close(ends[5]);
    if (*pid < 0) { close(ends[0]); close(ends[2]); close(ends[4]); return error; }
    ssize_t bytes;
    do { bytes = read(ends[4], &error, sizeof(error)); } while (bytes < 0 && errno == EINTR);
    close(ends[4]);
    if (bytes > 0) {
        close(ends[0]); close(ends[2]); banyan_pty_reap(*pid); return error;
    }
    *output = ends[0]; *error_output = ends[2];
    fcntl(*output, F_SETFL, fcntl(*output, F_GETFL) | O_NONBLOCK);
    fcntl(*error_output, F_SETFL, fcntl(*error_output, F_GETFL) | O_NONBLOCK);
    return 0;
}

int banyan_command_buffered(int fd, int *bytes) {
    return ioctl(fd, FIONREAD, bytes) == 0 ? 0 : errno;
}
