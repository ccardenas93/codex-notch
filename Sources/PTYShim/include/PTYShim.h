#ifndef PTY_SHIM_H
#define PTY_SHIM_H

#include <sys/types.h>

int codex_notch_spawn_pty(
    const char *shell_path,
    const char *working_directory,
    int *master_fd,
    pid_t *child_pid
);

#endif
