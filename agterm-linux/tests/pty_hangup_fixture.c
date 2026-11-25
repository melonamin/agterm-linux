// Delay the app's readable PTY poll until its real hangup arrives, preserving the OS event flags.
// This makes the fast-exit IN|HUP race deterministic without changing terminal bytes or libghostty.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int (*original_poll)(struct pollfd *, nfds_t, int);
static pid_t app_pid;
static bool is_app;
static const char *gate_path;
static const char *observed_path;
static atomic_bool used;

__attribute__((constructor)) static void initialize(void) {
    original_poll = dlsym(RTLD_NEXT, "poll");
    app_pid = getpid();
    char executable[PATH_MAX];
    ssize_t count = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
    if (count > 0) {
        executable[count] = '\0';
        const char *name = strrchr(executable, '/');
        name = name ? name + 1 : executable;
        is_app = !strcmp(name, "AgtermLinux") || !strcmp(name, "agterm-linux.bin");
    }
    gate_path = getenv("AGTERM_TEST_PTY_HUP_GATE");
    observed_path = getenv("AGTERM_TEST_PTY_HUP_OBSERVED");
}

int poll(struct pollfd *fds, nfds_t count, int timeout) {
    int result = original_poll(fds, count, timeout);
    if (result <= 0 || !is_app || getpid() != app_pid || !gate_path || !observed_path
        || atomic_load(&used) || access(gate_path, F_OK) != 0) return result;

    for (nfds_t index = 0; index < count; index++) {
        if (!(fds[index].revents & POLLIN) || !isatty(fds[index].fd)) continue;
        bool expected = false;
        if (!atomic_compare_exchange_strong(&used, &expected, true)) return result;
        // The program has received its DSR reply and is about to write its final bytes and exit.
        // Give that real exit time to close the slave, while leaving its output unread on the master.
        for (int attempt = 0; attempt < 1500; attempt++) {
            struct pollfd probe = {.fd = fds[index].fd, .events = POLLIN};
            if (original_poll(&probe, 1, 0) > 0 && (probe.revents & (POLLIN | POLLHUP)) == (POLLIN | POLLHUP)) {
                fds[index].revents = probe.revents;
                int marker = open(observed_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
                if (marker >= 0) {
                    const char message[] = "readable PTY hangup\n";
                    (void)write(marker, message, sizeof(message) - 1);
                    close(marker);
                }
                return result;
            }
            struct timespec delay = {.tv_nsec = 1000000};
            nanosleep(&delay, NULL);
        }
        return result;
    }
    return result;
}
