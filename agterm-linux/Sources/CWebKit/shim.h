#include <webkit/webkit.h>
#include <gio/gio.h>

// Keep the variadic GObject construction at the C boundary: Swift cannot import g_object_new.
static inline GtkWidget *agterm_web_view_new_ephemeral(WebKitUserContentManager *content_manager,
                                                       WebKitSettings *settings)
{
    WebKitNetworkSession *session = webkit_network_session_new_ephemeral();
    GtkWidget *view = g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                   "network-session", session,
                                   "user-content-manager", content_manager,
                                   "settings", settings,
                                   NULL);
    g_object_unref(session);
    return view;
}

static inline void agterm_uri_scheme_finish_file(WebKitURISchemeRequest *request,
                                                  const char *path, const char *content_type)
{
    GFile *file = g_file_new_for_path(path);
    GError *error = NULL;
    GFileInputStream *stream = g_file_read(file, NULL, &error);
    g_object_unref(file);
    if (!stream) {
        webkit_uri_scheme_request_finish_error(request, error);
        g_error_free(error);
        return;
    }
    webkit_uri_scheme_request_finish(request, G_INPUT_STREAM(stream), -1, content_type);
    g_object_unref(stream);
}

static inline void agterm_uri_scheme_deny(WebKitURISchemeRequest *request)
{
    GError *error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                                       "page resource is outside the granted directory");
    webkit_uri_scheme_request_finish_error(request, error);
    g_error_free(error);
}

static inline void agterm_disconnect_signals(gpointer object, gpointer data)
{
    g_signal_handlers_disconnect_by_data(object, data);
}

static inline GtkWidget *agterm_web_view_new_with_session(WebKitUserContentManager *manager,
                                                         WebKitSettings *settings,
                                                         WebKitNetworkSession *session)
{
    return g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", session,
                        "user-content-manager", manager, "settings", settings, NULL);
}
