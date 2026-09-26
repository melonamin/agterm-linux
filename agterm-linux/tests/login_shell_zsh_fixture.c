#define _GNU_SOURCE
#include <dlfcn.h>
#include <pwd.h>
#include <sys/types.h>
#include <unistd.h>

/* Let an isolated Live-mode test run under a developer account whose passwd shell is fish.
 * Everything except pw_shell comes from the real account entry. */
struct passwd *getpwuid(uid_t uid) {
    static struct passwd copy;
    static struct passwd *(*real_getpwuid)(uid_t);
    if (!real_getpwuid) real_getpwuid = dlsym(RTLD_NEXT, "getpwuid");
    if (!real_getpwuid) return 0;
    struct passwd *entry = real_getpwuid(uid);
    if (!entry || uid != getuid()) return entry;
    copy = *entry;
    copy.pw_shell = "/usr/bin/zsh";
    return &copy;
}
