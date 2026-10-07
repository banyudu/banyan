#pragma once
#include <sys/types.h>

// Returns errno on failure. Only async-signal-safe C runs between fork and exec.
int banyan_pty_spawn(const char *path, char *const argv[], char *const envp[],
                     unsigned short columns, unsigned short rows, int *master, pid_t *pid);
int banyan_pty_resize(int master, unsigned short columns, unsigned short rows);
// Wait without reaping: the owner serial queue retains PID ownership until reap.
int banyan_pty_wait(pid_t pid);
void banyan_pty_reap(pid_t pid);
// Pipes and an owned direct child for daemon-starting tmux commands. Child stdin
// is /dev/null; no Foundation exit socket is inherited by a daemon grandchild.
int banyan_command_spawn(const char *path, char *const argv[], char *const envp[],
                         const char *cwd, int *output, int *error_output, pid_t *pid);
int banyan_command_buffered(int fd, int *bytes);
