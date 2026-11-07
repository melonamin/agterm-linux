#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Observe the real process boundary; record only our app's initialization, never environment values. */
static pid_t owner;
static int output = -1;

__attribute__((constructor)) static void initialize(void) {
    owner = getpid();
    const char *path = getenv("AGTERM_STARTUP_AUDIT_LOG");
    if (path) output = open(path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0600);
}

static void record(const char *event) {
    if (output >= 0 && getpid() == owner) write(output, event, strlen(event));
}

int setenv(const char *name, const char *value, int replace) {
    int (*original)(const char *, const char *, int) = dlsym(RTLD_NEXT, "setenv");
    if (!strcmp(name, "GHOSTTY_RESOURCES_DIR")) record("resources\n");
    return original(name, value, replace);
}

int unsetenv(const char *name) {
    int (*original)(const char *) = dlsym(RTLD_NEXT, "unsetenv");
    if (!strcmp(name, "GHOSTTY_RESOURCES_DIR")) record("resources\n");
    return original(name);
}

int ghostty_init(uintptr_t argc, char **argv) {
    int (*original)(uintptr_t, char **) = dlsym(RTLD_NEXT, "ghostty_init");
    record("ghostty\n");
    return original(argc, argv);
}

void *adw_application_new(const char *application_id, unsigned flags) {
    void *(*original)(const char *, unsigned) = dlsym(RTLD_NEXT, "adw_application_new");
    record("gtk\n");
    return original(application_id, flags);
}
