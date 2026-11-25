// LD_PRELOAD tracer for the retained GL teardown; gl_teardown_analyze.py owns the log grammar. Inert outside the app.
//   cc -shared -fPIC -O2 -o shim.so agterm-linux/tests/gl_teardown_shim.c -ldl
// -O2 is load-bearing: dlsym forwards as a sibling call so glibc still sees the original caller. A plain call would make
// a fixture's dlsym(RTLD_NEXT, ...) resolve relative to this library and find the fixture itself.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

typedef void *(*lookup_fn)(void *, const char *);
typedef void *(*proc_fn)(const char *);
typedef void *(*current_fn)(void);

static lookup_fn real_dlsym;
static current_fn egl_current, glx_current;
static int active, log_fd = -1, renderer_logged;
static uintptr_t main_lo, main_hi;

static void resolve_dlsym(void) {
    if (real_dlsym) return;
    real_dlsym = (lookup_fn)dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
    if (!real_dlsym) real_dlsym = (lookup_fn)dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
}

// RTLD_LOCAL dlopens by epoxy and glad hide GL from RTLD_NEXT, hence the handles.
static void *find_symbol(const char *name) {
    static const char *const libraries[] = {"libGL.so.1", "libEGL.so.1", "libGLX.so.0", "libOpenGL.so.0"};
    resolve_dlsym();
    void *found = real_dlsym(RTLD_NEXT, name);
    for (size_t i = 0; !found && i < sizeof libraries / sizeof *libraries; i++) {
        void *handle = dlopen(libraries[i], RTLD_LAZY | RTLD_NOLOAD);
        if (handle) found = real_dlsym(handle, name);
    }
    return found;
}

static void *current_native(void) {
    if (!egl_current) egl_current = (current_fn)find_symbol("eglGetCurrentContext");
    if (!glx_current) glx_current = (current_fn)find_symbol("glXGetCurrentContext");
    void *current = egl_current ? egl_current() : NULL;
    if (!current && glx_current) current = glx_current();
    return current;
}

static const char *hex(const void *value) {
    static __thread char ring[8][20];
    static __thread unsigned next;
    char *text = ring[next++ % 8];
    if (value) snprintf(text, sizeof ring[0], "%p", value);
    else strcpy(text, "0");
    return text;
}

static const char *caller_name(const void *address) {
    if ((uintptr_t)address >= main_lo && (uintptr_t)address < main_hi) return "main";
    Dl_info info;
    if (!address || !dladdr(address, &info) || !info.dli_fname) return "unknown";
    const char *slash = strrchr(info.dli_fname, '/');
    return slash ? slash + 1 : info.dli_fname;
}

__attribute__((format(printf, 2, 3))) static void emit(const void *caller, const char *format, ...) {
    if (log_fd < 0) return;
    char line[640];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(line, sizeof line - 96, format, arguments);
    va_end(arguments);
    if (length < 0 || length >= (int)sizeof line - 96) return;
    length += snprintf(line + length, 96, " tid=%ld ctx=%s caller=%s\n", (long)syscall(SYS_gettid), hex(current_native()),
                       caller ? caller_name(caller) : "shim");
    (void)!write(log_fd, line, (size_t)length);
}

#define RETURN_ADDRESS __builtin_return_address(0)
#define REAL(slot, name)                                       \
    do {                                                       \
        if (!(slot)) *(void **)&(slot) = find_symbol(name);    \
    } while (0)

// MARK: GL objects

typedef void (*gen_fn)(int, uint32_t *);
typedef void (*gen_target_fn)(uint32_t, int, uint32_t *);
typedef void (*delete_fn)(int, const uint32_t *);
typedef uint32_t (*create_fn)(void);
typedef uint32_t (*create_shader_fn)(uint32_t);
typedef void (*delete_one_fn)(uint32_t);
typedef void *(*fence_fn)(uint32_t, uint32_t);
typedef void (*delete_sync_fn)(void *);
typedef void (*bind_texture_fn)(uint32_t, uint32_t);
typedef void (*tex_image_fn)(uint32_t, int, int, int, int, int, uint32_t, uint32_t, const void *);
typedef uint32_t (*get_error_fn)(void);
typedef const unsigned char *(*get_string_fn)(uint32_t);

static get_error_fn real_glGetError;
static __thread uint32_t stashed_error;

static void log_created(const char *kind, int count, const uint32_t *names, const void *caller) {
    for (int i = 0; i < count; i++) emit(caller, "GL_CREATE kind=%s name=%u", kind, names[i]);
}

// The error a Ghostty delete raised is logged here, then handed to whoever asks next.
static void log_deleted(const char *kind, uint32_t name, const void *caller) {
    if (log_fd < 0) return;
    char error_text[12] = "none";
    if (strstr(caller_name(caller), "libghostty") && current_native()) {
        REAL(real_glGetError, "glGetError");
        uint32_t error = real_glGetError ? real_glGetError() : 0;
        if (error && !stashed_error) stashed_error = error;
        snprintf(error_text, sizeof error_text, "0x%x", error);
    }
    emit(caller, "GL_DELETE kind=%s name=%u err=%s", kind, name, error_text);
}

#define GEN(function, kind)                                    \
    static gen_fn real_##function;                             \
    void function(int count, uint32_t *names) {                \
        REAL(real_##function, #function);                      \
        real_##function(count, names);                         \
        log_created(kind, count, names, RETURN_ADDRESS);       \
    }
#define GEN_TARGET(function, kind)                             \
    static gen_target_fn real_##function;                      \
    void function(uint32_t target, int count, uint32_t *names) { \
        REAL(real_##function, #function);                      \
        real_##function(target, count, names);                 \
        log_created(kind, count, names, RETURN_ADDRESS);       \
    }
#define DELETE(function, kind)                                 \
    static delete_fn real_##function;                          \
    void function(int count, const uint32_t *names) {          \
        REAL(real_##function, #function);                      \
        real_##function(count, names);                         \
        for (int i = 0; i < count; i++) log_deleted(kind, names[i], RETURN_ADDRESS); \
    }
#define DELETE_ONE(function, kind)                             \
    static delete_one_fn real_##function;                      \
    void function(uint32_t name) {                             \
        REAL(real_##function, #function);                      \
        real_##function(name);                                 \
        log_deleted(kind, name, RETURN_ADDRESS);               \
    }

#define OBJECT_FUNCTIONS(X)                                                                                       \
    X(GEN, glGenTextures, "texture") X(GEN, glGenBuffers, "buffer") X(GEN, glGenFramebuffers, "framebuffer")      \
    X(GEN, glGenRenderbuffers, "renderbuffer") X(GEN, glGenVertexArrays, "vertex_array")                          \
    X(GEN, glGenSamplers, "sampler") X(GEN, glGenQueries, "query") X(GEN, glGenTransformFeedbacks, "transform_feedback") \
    X(GEN, glGenProgramPipelines, "program_pipeline") X(GEN, glCreateBuffers, "buffer")                           \
    X(GEN, glCreateFramebuffers, "framebuffer") X(GEN, glCreateRenderbuffers, "renderbuffer")                     \
    X(GEN, glCreateVertexArrays, "vertex_array") X(GEN, glCreateSamplers, "sampler")                              \
    X(GEN, glCreateTransformFeedbacks, "transform_feedback") X(GEN, glCreateProgramPipelines, "program_pipeline") \
    X(GEN_TARGET, glCreateTextures, "texture") X(GEN_TARGET, glCreateQueries, "query")                            \
    X(DELETE, glDeleteTextures, "texture") X(DELETE, glDeleteBuffers, "buffer")                                   \
    X(DELETE, glDeleteFramebuffers, "framebuffer") X(DELETE, glDeleteRenderbuffers, "renderbuffer")               \
    X(DELETE, glDeleteVertexArrays, "vertex_array") X(DELETE, glDeleteSamplers, "sampler")                        \
    X(DELETE, glDeleteQueries, "query") X(DELETE, glDeleteTransformFeedbacks, "transform_feedback")               \
    X(DELETE, glDeleteProgramPipelines, "program_pipeline")                                                       \
    X(DELETE_ONE, glDeleteProgram, "program") X(DELETE_ONE, glDeleteShader, "shader")

#define DEFINE(shape, function, kind) shape(function, kind)
OBJECT_FUNCTIONS(DEFINE)

static create_fn real_glCreateProgram;
uint32_t glCreateProgram(void) {
    REAL(real_glCreateProgram, "glCreateProgram");
    uint32_t name = real_glCreateProgram();
    log_created("program", 1, &name, RETURN_ADDRESS);
    return name;
}

static create_shader_fn real_glCreateShader;
uint32_t glCreateShader(uint32_t type) {
    REAL(real_glCreateShader, "glCreateShader");
    uint32_t name = real_glCreateShader(type);
    log_created("shader", 1, &name, RETURN_ADDRESS);
    return name;
}

static fence_fn real_glFenceSync;
void *glFenceSync(uint32_t condition, uint32_t flags) {
    REAL(real_glFenceSync, "glFenceSync");
    void *sync = real_glFenceSync(condition, flags);
    emit(RETURN_ADDRESS, "GL_CREATE kind=sync name=%s", hex(sync));
    return sync;
}

static delete_sync_fn real_glDeleteSync;
void glDeleteSync(void *sync) {
    REAL(real_glDeleteSync, "glDeleteSync");
    real_glDeleteSync(sync);
    emit(RETURN_ADDRESS, "GL_DELETE kind=sync name=%s err=none", hex(sync));
}

static __thread struct { uint32_t target, name; } bound[8];

static bind_texture_fn real_glBindTexture;
void glBindTexture(uint32_t target, uint32_t name) {
    REAL(real_glBindTexture, "glBindTexture");
    real_glBindTexture(target, name);
    bound[target % 8].target = target;
    bound[target % 8].name = name;
}

static tex_image_fn real_glTexImage2D;
void glTexImage2D(uint32_t target, int level, int internal, int width, int height, int border, uint32_t format,
                  uint32_t type, const void *pixels) {
    REAL(real_glTexImage2D, "glTexImage2D");
    real_glTexImage2D(target, level, internal, width, height, border, format, type, pixels);
    uint32_t name = bound[target % 8].target == target ? bound[target % 8].name : 0;
    emit(RETURN_ADDRESS, "TEX_IMAGE width=%d height=%d name=%u", width, height, name);
}

uint32_t glGetError(void) {
    REAL(real_glGetError, "glGetError");
    uint32_t error = stashed_error ? stashed_error : (real_glGetError ? real_glGetError() : 0);
    stashed_error = 0;
    if (error) emit(RETURN_ADDRESS, "GL_ERROR value=0x%x", error);
    return error;
}

// MARK: EGL and GLX contexts

typedef void *(*egl_create_fn)(void *, void *, void *, const int *);
typedef unsigned (*egl_destroy_fn)(void *, void *);
typedef void *(*glx_create_fn)(void *, void *, void *, int);
typedef void *(*glx_create_new_fn)(void *, void *, int, void *, int);
typedef void *(*glx_create_attribs_fn)(void *, void *, void *, int, const int *);
typedef void (*glx_destroy_fn)(void *, void *);

static void log_context(const char *api, const void *handle, const void *share, const void *caller) {
    emit(caller, "CONTEXT_CREATE api=%s handle=%s share=%s ok=%d", api, hex(handle), hex(share), handle != NULL);
}

static egl_create_fn real_eglCreateContext;
void *eglCreateContext(void *display, void *config, void *share, const int *attributes) {
    REAL(real_eglCreateContext, "eglCreateContext");
    void *context = real_eglCreateContext(display, config, share, attributes);
    log_context("egl", context, share, RETURN_ADDRESS);
    return context;
}

static egl_destroy_fn real_eglDestroyContext;
unsigned eglDestroyContext(void *display, void *context) {
    REAL(real_eglDestroyContext, "eglDestroyContext");
    unsigned ok = real_eglDestroyContext(display, context);
    emit(RETURN_ADDRESS, "CONTEXT_DESTROY api=egl handle=%s ok=%u", hex(context), ok);
    return ok;
}

static glx_create_fn real_glXCreateContext;
void *glXCreateContext(void *display, void *visual, void *share, int direct) {
    REAL(real_glXCreateContext, "glXCreateContext");
    void *context = real_glXCreateContext(display, visual, share, direct);
    log_context("glx", context, share, RETURN_ADDRESS);
    return context;
}

static glx_create_new_fn real_glXCreateNewContext;
void *glXCreateNewContext(void *display, void *config, int type, void *share, int direct) {
    REAL(real_glXCreateNewContext, "glXCreateNewContext");
    void *context = real_glXCreateNewContext(display, config, type, share, direct);
    log_context("glx", context, share, RETURN_ADDRESS);
    return context;
}

static glx_create_attribs_fn real_glXCreateContextAttribsARB;
void *glXCreateContextAttribsARB(void *display, void *config, void *share, int direct, const int *attributes) {
    REAL(real_glXCreateContextAttribsARB, "glXCreateContextAttribsARB");
    void *context = real_glXCreateContextAttribsARB(display, config, share, direct, attributes);
    log_context("glx", context, share, RETURN_ADDRESS);
    return context;
}

static glx_destroy_fn real_glXDestroyContext;
void glXDestroyContext(void *display, void *context) {
    REAL(real_glXDestroyContext, "glXDestroyContext");
    real_glXDestroyContext(display, context);
    emit(RETURN_ADDRESS, "CONTEXT_DESTROY api=glx handle=%s ok=1", hex(context));
}

// MARK: Symbol resolution

struct hook {
    const char *name;
    void **real;
    void *wrapper;
};

#define HOOK(shape, function, kind) {#function, (void **)&real_##function, (void *)function},
#define PLAIN_HOOK(function) {#function, (void **)&real_##function, (void *)function},
static const struct hook hooks[] = {
    OBJECT_FUNCTIONS(HOOK)
    PLAIN_HOOK(glCreateProgram) PLAIN_HOOK(glCreateShader) PLAIN_HOOK(glFenceSync) PLAIN_HOOK(glDeleteSync)
    PLAIN_HOOK(glBindTexture) PLAIN_HOOK(glTexImage2D) PLAIN_HOOK(glGetError)
    PLAIN_HOOK(eglCreateContext) PLAIN_HOOK(eglDestroyContext) PLAIN_HOOK(glXCreateContext)
    PLAIN_HOOK(glXCreateNewContext) PLAIN_HOOK(glXCreateContextAttribsARB) PLAIN_HOOK(glXDestroyContext)
};

static void *hook_result(const char *name, void *resolved);

static proc_fn real_eglGetProcAddress, real_glXGetProcAddress, real_glXGetProcAddressARB;

void *eglGetProcAddress(const char *name) {
    REAL(real_eglGetProcAddress, "eglGetProcAddress");
    return hook_result(name, real_eglGetProcAddress(name));
}

void *glXGetProcAddress(const char *name) {
    REAL(real_glXGetProcAddress, "glXGetProcAddress");
    return hook_result(name, real_glXGetProcAddress(name));
}

void *glXGetProcAddressARB(const char *name) {
    REAL(real_glXGetProcAddressARB, "glXGetProcAddressARB");
    return hook_result(name, real_glXGetProcAddressARB(name));
}

// RTLD_DEFAULT can answer with this library's own export, which must never land in a real slot.
static void *keep_real(void **slot, void *resolved, void *wrapper) {
    if (!*slot && resolved != wrapper) *slot = resolved;
    return wrapper;
}

static void *hook_result(const char *name, void *resolved) {
    if (!active || !resolved) return resolved;
    if (!strcmp(name, "eglGetProcAddress"))
        return keep_real((void **)&real_eglGetProcAddress, resolved, (void *)eglGetProcAddress);
    if (!strcmp(name, "glXGetProcAddress"))
        return keep_real((void **)&real_glXGetProcAddress, resolved, (void *)glXGetProcAddress);
    if (!strcmp(name, "glXGetProcAddressARB"))
        return keep_real((void **)&real_glXGetProcAddressARB, resolved, (void *)glXGetProcAddressARB);
    for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++)
        if (!strcmp(name, hooks[i].name)) return keep_real(hooks[i].real, resolved, hooks[i].wrapper);
    return resolved;
}

void *dlsym(void *handle, const char *name) {
    resolve_dlsym();
    if (!active || handle == RTLD_NEXT || (strncmp(name, "gl", 2) && strncmp(name, "egl", 3)))
        return real_dlsym(handle, name);
    return hook_result(name, real_dlsym(handle, name));
}

// MARK: Host markers

typedef void *(*surface_new_fn)(void *, const void *);
typedef void (*surface_fn)(void *);
typedef void *(*ref_fn)(void *);
typedef void (*unref_fn)(void *);
typedef void *(*area_context_fn)(void *);
typedef void *(*get_current_fn)(void);
typedef void (*make_current_fn)(void *);
typedef void (*clear_current_fn)(void);

static surface_new_fn real_ghostty_surface_new;
static surface_fn real_ghostty_surface_draw, real_ghostty_surface_free;
static ref_fn real_g_object_ref;
static unref_fn real_g_object_unref;
static area_context_fn real_gtk_gl_area_get_context;
static get_current_fn real_gdk_gl_context_get_current;
static make_current_fn real_gdk_gl_context_make_current;
static clear_current_fn real_gdk_gl_context_clear_current;

static const void *tracked[4096];
static size_t tracked_count;

static int from_main(const void *caller) {
    return active && (uintptr_t)caller >= main_lo && (uintptr_t)caller < main_hi;
}

static int is_tracked(const void *context) {
    for (size_t i = 0; i < tracked_count; i++)
        if (tracked[i] == context) return 1;
    return 0;
}

static void track(const void *context) {
    if (context && !is_tracked(context) && tracked_count < sizeof tracked / sizeof *tracked)
        tracked[tracked_count++] = context;
}

static void log_host(const void *caller, const char *call, const void *argument, const void *result) {
    emit(caller, "HOST call=%s arg=%s ret=%s", call, hex(argument), hex(result));
}

void *ghostty_surface_new(void *app, const void *config) {
    REAL(real_ghostty_surface_new, "ghostty_surface_new");
    emit(NULL, "NEW_BEGIN");
    void *surface = real_ghostty_surface_new(app, config);
    emit(NULL, "NEW_END surface=%s", hex(surface));
    return surface;
}

static void log_renderer(void) {
    if (renderer_logged || !current_native()) return;
    get_string_fn get_string = (get_string_fn)find_symbol("glGetString");
    const unsigned char *renderer = get_string ? get_string(0x1F01) : NULL;
    if (!renderer) return;
    renderer_logged = 1;
    char line[256];
    int length = snprintf(line, sizeof line, "GL_RENDERER text=%s\n", (const char *)renderer);
    if (log_fd >= 0 && length > 0) (void)!write(log_fd, line, (size_t)length);
}

void ghostty_surface_draw(void *surface) {
    REAL(real_ghostty_surface_draw, "ghostty_surface_draw");
    log_renderer();
    emit(NULL, "DRAW_BEGIN surface=%s", hex(surface));
    real_ghostty_surface_draw(surface);
    emit(NULL, "DRAW_END surface=%s", hex(surface));
}

void ghostty_surface_free(void *surface) {
    REAL(real_ghostty_surface_free, "ghostty_surface_free");
    emit(NULL, "FREE_BEGIN surface=%s", hex(surface));
    real_ghostty_surface_free(surface);
    emit(NULL, "FREE_END surface=%s", hex(surface));
}

void *gtk_gl_area_get_context(void *area) {
    REAL(real_gtk_gl_area_get_context, "gtk_gl_area_get_context");
    void *context = real_gtk_gl_area_get_context(area);
    const void *caller = RETURN_ADDRESS;
    if (from_main(caller)) {
        track(context);
        log_host(caller, "area_context", NULL, context);
    }
    return context;
}

void *gdk_gl_context_get_current(void) {
    REAL(real_gdk_gl_context_get_current, "gdk_gl_context_get_current");
    void *context = real_gdk_gl_context_get_current();
    const void *caller = RETURN_ADDRESS;
    if (from_main(caller)) {
        track(context);
        log_host(caller, "get_current", NULL, context);
    }
    return context;
}

void gdk_gl_context_make_current(void *context) {
    REAL(real_gdk_gl_context_make_current, "gdk_gl_context_make_current");
    real_gdk_gl_context_make_current(context);
    const void *caller = RETURN_ADDRESS;
    if (from_main(caller)) {
        track(context);
        log_host(caller, "make_current", context, NULL);
    }
}

void gdk_gl_context_clear_current(void) {
    REAL(real_gdk_gl_context_clear_current, "gdk_gl_context_clear_current");
    real_gdk_gl_context_clear_current();
    const void *caller = RETURN_ADDRESS;
    if (from_main(caller)) log_host(caller, "clear_current", NULL, NULL);
}

void *g_object_ref(void *object) {
    REAL(real_g_object_ref, "g_object_ref");
    const void *caller = RETURN_ADDRESS;
    if (from_main(caller) && is_tracked(object)) log_host(caller, "ref", object, NULL);
    return real_g_object_ref(object);
}

void g_object_unref(void *object) {
    REAL(real_g_object_unref, "g_object_unref");
    const void *caller = RETURN_ADDRESS;
    if (from_main(caller) && is_tracked(object)) log_host(caller, "unref", object, NULL);
    real_g_object_unref(object);
}

// MARK: Lifetime

static int main_range(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    (void)data;
    uintptr_t lo = UINTPTR_MAX, hi = 0;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type != PT_LOAD) continue;
        uintptr_t start = info->dlpi_addr + info->dlpi_phdr[i].p_vaddr;
        if (start < lo) lo = start;
        if (start + info->dlpi_phdr[i].p_memsz > hi) hi = start + info->dlpi_phdr[i].p_memsz;
    }
    main_lo = lo;
    main_hi = hi;
    return 1;
}

static int target_process(void) {
    char path[4096];
    ssize_t length = readlink("/proc/self/exe", path, sizeof path - 1);
    if (length <= 0) return 0;
    path[length] = 0;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return !strcmp(base, "AgtermLinux") || !strcmp(base, "agterm-linux.bin");
}

// Children must not be traced, but the login-shell fixture has to reach them.
static void remove_own_preload(void) {
    const char *preload = getenv("LD_PRELOAD");
    Dl_info self;
    if (!preload || !dladdr((void *)remove_own_preload, &self) || !self.dli_fname) return;
    char *copy = strdup(preload), *rest = NULL;
    char kept[4096] = "";
    for (char *entry = strtok_r(copy, ": ", &rest); entry; entry = strtok_r(NULL, ": ", &rest)) {
        if (!strcmp(entry, self.dli_fname)) continue;
        if (kept[0]) strncat(kept, ":", sizeof kept - strlen(kept) - 1);
        strncat(kept, entry, sizeof kept - strlen(kept) - 1);
    }
    free(copy);
    if (kept[0]) setenv("LD_PRELOAD", kept, 1);
    else unsetenv("LD_PRELOAD");
}

__attribute__((constructor)) static void shim_start(void) {
    if (!target_process()) return;
    const char *path = getenv("GL_TEARDOWN_LOG");
    if (path) log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (log_fd < 0) return;
    dl_iterate_phdr(main_range, NULL);
    remove_own_preload();
    active = 1;
    static const char *const required[] = {
        "ghostty_surface_new", "ghostty_surface_draw", "ghostty_surface_free", "gtk_gl_area_get_context",
        "gdk_gl_context_get_current", "gdk_gl_context_make_current", "gdk_gl_context_clear_current", "g_object_ref",
        "g_object_unref"};
    for (size_t i = 0; i < sizeof required / sizeof *required; i++)
        if (!find_symbol(required[i])) emit(NULL, "SYMBOL_MISSING name=%s", required[i]);
}

__attribute__((destructor)) static void shim_end(void) {
    if (!active || log_fd < 0) return;
    if (!real_glGenTextures || !real_glDeleteTextures || !real_glDeleteFramebuffers || !real_glTexImage2D)
        emit(NULL, "SYMBOL_MISSING name=gl-core");
    if (!egl_current && !glx_current) emit(NULL, "SYMBOL_MISSING name=current-context");
    static const char end[] = "END\n";
    (void)!write(log_fd, end, sizeof end - 1);
    log_fd = -1;
}
