#include <adwaita.h>
#include <gtk/gtk.h>
#include <pango/pangocairo.h>
#include <glib-unix.h>
#include <epoxy/gl.h>
#include "ghostty.h"

static inline gboolean
agterm_object_get_boolean_property(GObject *object, const char *name, gboolean *value)
{
    GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(object), name);
    if (spec == NULL || !G_IS_PARAM_SPEC_BOOLEAN(spec)) {
        return FALSE;
    }

    GValue property = G_VALUE_INIT;
    g_value_init(&property, G_PARAM_SPEC_VALUE_TYPE(spec));
    g_object_get_property(object, name, &property);
    *value = g_value_get_boolean(&property);
    g_value_unset(&property);
    return TRUE;
}

static inline gboolean
agterm_object_get_enum_property(GObject *object, const char *name, gint *value)
{
    GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(object), name);
    if (spec == NULL || !G_IS_PARAM_SPEC_ENUM(spec)) {
        return FALSE;
    }

    GValue property = G_VALUE_INIT;
    g_value_init(&property, G_PARAM_SPEC_VALUE_TYPE(spec));
    g_object_get_property(object, name, &property);
    *value = g_value_get_enum(&property);
    g_value_unset(&property);
    return TRUE;
}
