// Proves the premise of the retained GL teardown: a separate ref keeps a GtkGLArea's context usable, objects
// included, after the area is finalized and its native surface destroyed, with the display still open.
//
//   cc -o check agterm-linux/tests/gl_retained_context_check.c $(pkg-config --cflags --libs gtk4 epoxy)
//   GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 GDK_DEBUG=gl-egl xvfb-run -a ./check GdkX11GLContextEGL
//   GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 GDK_DEBUG=gl-glx xvfb-run -a ./check GdkX11GLContextGLX
//
// The optional argument is the context class the run must have tested.
#include <epoxy/gl.h>
#include <gtk/gtk.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { TIMEOUT_SECONDS = 20 };

static const unsigned char buffer_seed[4] = {0x11, 0x22, 0x33, 0x44};
static const unsigned char texture_seed[4] = {0xA1, 0xB2, 0xC3, 0xD4};

static GtkWidget *window;
static GdkSurface *native_surface;
static GdkGLContext *retained;
static GLuint buffer, texture, framebuffer;
static gboolean created, rendered, destroy_queued, area_finalized, context_finalized;
static int failures;

static void check(gboolean ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

static void on_timeout(int signal_number) {
    (void)signal_number;
    static const char message[] = "FAIL: timed out\n";
    (void)!write(STDOUT_FILENO, message, sizeof message - 1);
    _exit(3);
}

static void on_area_finalized(gpointer data, GObject *gone) {
    (void)data;
    (void)gone;
    area_finalized = TRUE;
}

static void on_context_finalized(gpointer data, GObject *gone) {
    (void)data;
    (void)gone;
    context_finalized = TRUE;
}

static void on_realize(GtkGLArea *area, gpointer data) {
    (void)data;
    gtk_gl_area_make_current(area);
    if (gtk_gl_area_get_error(area)) {
        printf("FAIL: GLArea error: %s\n", gtk_gl_area_get_error(area)->message);
        _exit(1);
    }
    retained = g_object_ref(gtk_gl_area_get_context(area));
    g_object_weak_ref(G_OBJECT(retained), on_context_finalized, NULL);
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof buffer_seed, buffer_seed, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, texture_seed);
    glBindTexture(GL_TEXTURE_2D, 0);
    GLint prior_framebuffer = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prior_framebuffer);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prior_framebuffer);
    check(glGetError() == GL_NO_ERROR, "objects created without a GL error");
    created = TRUE;
}

static gboolean destroy_window(gpointer data) {
    (void)data;
    native_surface = g_object_ref(gtk_native_get_surface(GTK_NATIVE(window)));
    gtk_window_destroy(GTK_WINDOW(window));
    return G_SOURCE_REMOVE;
}

static gboolean on_render(GtkGLArea *area, GdkGLContext *context, gpointer data) {
    (void)area;
    (void)context;
    (void)data;
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    rendered = TRUE;
    if (!destroy_queued) {
        destroy_queued = TRUE;
        g_idle_add(destroy_window, NULL);
    }
    return TRUE;
}

static void exercise_retained_context(void) {
    gdk_gl_context_make_current(retained);
    check(gdk_gl_context_get_current() == retained, "retained context current after native destruction");
    unsigned char bytes[4] = {0};
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glGetBufferSubData(GL_ARRAY_BUFFER, 0, sizeof bytes, bytes);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    check(memcmp(bytes, buffer_seed, sizeof bytes) == 0, "buffer read-back equal");
    unsigned char pixels[4] = {0};
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    check(memcmp(pixels, texture_seed, sizeof pixels) == 0, "texture read-back through the FBO equal");
    check(glIsBuffer(buffer), "glIsBuffer before delete");
    check(glIsTexture(texture), "glIsTexture before delete");
    check(glIsFramebuffer(framebuffer), "glIsFramebuffer before delete");
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    glDeleteBuffers(1, &buffer);
    check(!glIsBuffer(buffer), "glIsBuffer false after delete");
    check(!glIsTexture(texture), "glIsTexture false after delete");
    check(!glIsFramebuffer(framebuffer), "glIsFramebuffer false after delete");
    check(glGetError() == GL_NO_ERROR, "glGetError zero");
    gdk_gl_context_clear_current();
    check(gdk_gl_context_get_current() == NULL, "none current after clear");
}

int main(int argc, char **argv) {
    signal(SIGALRM, on_timeout);
    alarm(TIMEOUT_SECONDS);
    gtk_init();
    window = gtk_window_new();
    GtkWidget *area = gtk_gl_area_new();
    gtk_gl_area_set_allowed_apis(GTK_GL_AREA(area), GDK_GL_API_GL);
    g_object_weak_ref(G_OBJECT(area), on_area_finalized, NULL);
    g_signal_connect(area, "realize", G_CALLBACK(on_realize), NULL);
    g_signal_connect(area, "render", G_CALLBACK(on_render), NULL);
    gtk_window_set_default_size(GTK_WINDOW(window), 64, 64);
    gtk_window_set_child(GTK_WINDOW(window), area);
    gtk_window_present(GTK_WINDOW(window));

    while (!(area_finalized && native_surface && gdk_surface_is_destroyed(native_surface)))
        g_main_context_iteration(NULL, TRUE);
    check(created && rendered, "created and rendered before destruction");
    check(!gdk_display_is_closed(gdk_display_get_default()), "display open");

    const char *context_type = G_OBJECT_TYPE_NAME(retained);
    printf("context type: %s\n", context_type);
    printf("gtk: %d.%d.%d\n", gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
    if (argc > 1) check(strcmp(context_type, argv[1]) == 0, "context type is the requested API");

    exercise_retained_context();

    g_object_unref(retained);
    check(context_finalized, "last ref released the context");
    g_object_unref(native_surface);
    printf("%s\n", failures == 0 ? "PASS" : "FAILED");
    return failures == 0 ? 0 : 1;
}
