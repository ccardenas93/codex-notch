#include "PTYShim.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int codex_notch_spawn_pty(
    const char *shell_path,
    const char *working_directory,
    int *master_fd,
    pid_t *child_pid
) {
    if (shell_path == NULL || master_fd == NULL || child_pid == NULL) {
        errno = EINVAL;
        return -1;
    }

    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, NULL);
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        struct termios settings;
        if (tcgetattr(STDIN_FILENO, &settings) == 0) {
            settings.c_lflag &= ~(ECHO | ECHONL);
            tcsetattr(STDIN_FILENO, TCSANOW, &settings);
        }

        if (working_directory != NULL) {
            chdir(working_directory);
        }

        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("PROMPT", "", 1);
        setenv("PS1", "", 1);
        setenv("RPROMPT", "", 1);

        execl(shell_path, shell_path, "-f", "-i", (char *)NULL);
        _exit(127);
    }

    *master_fd = fd;
    *child_pid = pid;
    return 0;
}
