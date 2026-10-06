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

// Page script messages cross as JSON text; `gpointer` keeps JSC and reply types out of Swift's view.
static inline char *agterm_script_message_json(gpointer value)
{
    return jsc_value_to_json(JSC_VALUE(value), 0);
}

static inline gpointer agterm_script_message_reply_ref(gpointer reply)
{
    return webkit_script_message_reply_ref((WebKitScriptMessageReply *)reply);
}

static inline void agterm_script_message_reply_unref(gpointer reply)
{
    webkit_script_message_reply_unref((WebKitScriptMessageReply *)reply);
}

// One context serves every reply: the reply serializes the value out of it at once.
static inline void agterm_script_message_reply_json(gpointer reply, const char *json)
{
    static JSCContext *context = NULL;
    if (!context) context = jsc_context_new();
    JSCValue *value = jsc_value_new_from_json(context, json);
    webkit_script_message_reply_return_value((WebKitScriptMessageReply *)reply, value);
    g_object_unref(value);
}

static inline void agterm_script_message_reply_error(gpointer reply, const char *message)
{
    webkit_script_message_reply_return_error_message((WebKitScriptMessageReply *)reply, message);
}
