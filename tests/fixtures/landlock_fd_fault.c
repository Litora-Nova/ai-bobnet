/* Test-only fault setup, linked with the real helper. No Landlock syscall is
 * replaced. The constructor runs after the dynamic loader has opened its
 * libraries, so exhausting descriptors cannot accidentally test the loader. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

static int failed_fd = -1;
int __real_fcntl(int fd, int command, ...);
int __real_close(int fd);

__attribute__((constructor)) static void exhaust_fds(void) {
    const char *mode = getenv("TEST_FD_FAILURE");
    if (!mode || strcmp(mode, "dup")) return;
    struct rlimit limit = {32, 32};
    if (setrlimit(RLIMIT_NOFILE, &limit)) _exit(90);
    /* fd 8 is the trace; fd 9 is the helper's status channel. */
    for (int fd = 3; fd < 32; ++fd) {
        if (fd != 8 && fd != 9 && dup2(2, fd) < 0) _exit(91);
    }
}

int __wrap_fcntl(int fd, int command, ...) {
    va_list args;
    va_start(args, command);
    int flags = va_arg(args, int);
    va_end(args);
    const char *mode = getenv("TEST_FD_FAILURE");
    if (mode && !strcmp(mode, "fcntl") && fd != 9 && command == F_SETFD) {
        failed_fd = fd;
        errno = EIO;
        return -1;
    }
    return __real_fcntl(fd, command, flags);
}

int __wrap_close(int fd) {
    if (fd == failed_fd) (void)write(8, "saved fd closed\n", 16);
    return __real_close(fd);
}
