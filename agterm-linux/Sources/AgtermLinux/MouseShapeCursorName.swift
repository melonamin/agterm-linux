/// Maps a libghostty mouse shape (`ghostty_action_mouse_shape_e`) to the CSS cursor name that GTK
/// accepts for `gtk_widget_set_cursor_from_name` (ghostty's shapes are named after CSS cursors).
///
/// `GHOSTTY_MOUSE_SHAPE_DEFAULT` must map to `"default"` (the arrow): ghostty requests it in
/// mouse-tracking mode (vim, htop, opencode — see `surface_mouse.zig`: "default state when in a
/// mouse tracking mode … displays an arrow pointer"), while `"text"` is the plain-terminal state.
/// Without an explicit case the enum's zero value fell through to the `"text"` fallback, so TUIs
/// showed an I-beam where upstream Ghostty shows an arrow.
import CGtk

enum MouseShapeCursorName {
    static func cssName(for shape: ghostty_action_mouse_shape_e) -> String {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return "default"
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return "context-menu"
        case GHOSTTY_MOUSE_SHAPE_HELP: return "help"
        case GHOSTTY_MOUSE_SHAPE_POINTER: return "pointer"
        case GHOSTTY_MOUSE_SHAPE_PROGRESS: return "progress"
        case GHOSTTY_MOUSE_SHAPE_WAIT: return "wait"
        case GHOSTTY_MOUSE_SHAPE_CELL: return "cell"
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return "crosshair"
        case GHOSTTY_MOUSE_SHAPE_TEXT: return "text"
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return "vertical-text"
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return "alias"
        case GHOSTTY_MOUSE_SHAPE_COPY: return "copy"
        case GHOSTTY_MOUSE_SHAPE_MOVE: return "move"
        case GHOSTTY_MOUSE_SHAPE_NO_DROP: return "no-drop"
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return "not-allowed"
        case GHOSTTY_MOUSE_SHAPE_GRAB: return "grab"
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return "grabbing"
        case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return "all-scroll"
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return "col-resize"
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return "row-resize"
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return "n-resize"
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return "e-resize"
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return "s-resize"
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return "w-resize"
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE: return "ne-resize"
        case GHOSTTY_MOUSE_SHAPE_NW_RESIZE: return "nw-resize"
        case GHOSTTY_MOUSE_SHAPE_SE_RESIZE: return "se-resize"
        case GHOSTTY_MOUSE_SHAPE_SW_RESIZE: return "sw-resize"
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return "ew-resize"
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return "ns-resize"
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return "nesw-resize"
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return "nwse-resize"
        case GHOSTTY_MOUSE_SHAPE_ZOOM_IN: return "zoom-in"
        case GHOSTTY_MOUSE_SHAPE_ZOOM_OUT: return "zoom-out"
        default: return "text"
        }
    }
}
