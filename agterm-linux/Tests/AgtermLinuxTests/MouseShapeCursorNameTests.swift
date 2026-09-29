import CGtk
import Foundation
import Testing
@testable import AgtermLinux

/// The mouse-shape switch previously covered every `ghostty_action_mouse_shape_e` value except
/// `GHOSTTY_MOUSE_SHAPE_DEFAULT` (the enum's zero value), which silently fell through to the
/// `"text"` fallback. Ghostty requests DEFAULT in mouse-tracking mode (vim, htop, opencode) where
/// upstream shows the arrow (`surface_mouse.zig`), so TUIs got the wrong I-beam cursor.
@Suite("Mouse shape → GTK cursor name (GHOSTTY_ACTION_MOUSE_SHAPE)")
struct MouseShapeCursorNameTests {
    @Test("DEFAULT maps to the arrow cursor (mouse-tracking mode), not the I-beam fallback")
    func defaultShapeMapsToArrow() {
        #expect(MouseShapeCursorName.cssName(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) == "default")
        #expect(MouseShapeCursorName.cssName(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) != "text")
    }

    @Test("every documented enum value maps to its CSS cursor name")
    func documentedShapesMapToCSSNames() {
        let cases: [(ghostty_action_mouse_shape_e, String)] = [
            (GHOSTTY_MOUSE_SHAPE_DEFAULT, "default"),
            (GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU, "context-menu"),
            (GHOSTTY_MOUSE_SHAPE_HELP, "help"),
            (GHOSTTY_MOUSE_SHAPE_POINTER, "pointer"),
            (GHOSTTY_MOUSE_SHAPE_PROGRESS, "progress"),
            (GHOSTTY_MOUSE_SHAPE_WAIT, "wait"),
            (GHOSTTY_MOUSE_SHAPE_CELL, "cell"),
            (GHOSTTY_MOUSE_SHAPE_CROSSHAIR, "crosshair"),
            (GHOSTTY_MOUSE_SHAPE_TEXT, "text"),
            (GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT, "vertical-text"),
            (GHOSTTY_MOUSE_SHAPE_ALIAS, "alias"),
            (GHOSTTY_MOUSE_SHAPE_COPY, "copy"),
            (GHOSTTY_MOUSE_SHAPE_MOVE, "move"),
            (GHOSTTY_MOUSE_SHAPE_NO_DROP, "no-drop"),
            (GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, "not-allowed"),
            (GHOSTTY_MOUSE_SHAPE_GRAB, "grab"),
            (GHOSTTY_MOUSE_SHAPE_GRABBING, "grabbing"),
            (GHOSTTY_MOUSE_SHAPE_ALL_SCROLL, "all-scroll"),
            (GHOSTTY_MOUSE_SHAPE_COL_RESIZE, "col-resize"),
            (GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, "row-resize"),
            (GHOSTTY_MOUSE_SHAPE_N_RESIZE, "n-resize"),
            (GHOSTTY_MOUSE_SHAPE_E_RESIZE, "e-resize"),
            (GHOSTTY_MOUSE_SHAPE_S_RESIZE, "s-resize"),
            (GHOSTTY_MOUSE_SHAPE_W_RESIZE, "w-resize"),
            (GHOSTTY_MOUSE_SHAPE_NE_RESIZE, "ne-resize"),
            (GHOSTTY_MOUSE_SHAPE_NW_RESIZE, "nw-resize"),
            (GHOSTTY_MOUSE_SHAPE_SE_RESIZE, "se-resize"),
            (GHOSTTY_MOUSE_SHAPE_SW_RESIZE, "sw-resize"),
            (GHOSTTY_MOUSE_SHAPE_EW_RESIZE, "ew-resize"),
            (GHOSTTY_MOUSE_SHAPE_NS_RESIZE, "ns-resize"),
            (GHOSTTY_MOUSE_SHAPE_NESW_RESIZE, "nesw-resize"),
            (GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE, "nwse-resize"),
            (GHOSTTY_MOUSE_SHAPE_ZOOM_IN, "zoom-in"),
            (GHOSTTY_MOUSE_SHAPE_ZOOM_OUT, "zoom-out"),
        ]
        #expect(cases.count == 34)
        for (shape, expected) in cases {
            #expect(MouseShapeCursorName.cssName(for: shape) == expected)
        }
    }

    @Test("an unknown future enum value falls back to text")
    func unknownShapeFallsBackToText() {
        let unknown = ghostty_action_mouse_shape_e(rawValue: 9999)
        #expect(MouseShapeCursorName.cssName(for: unknown) == "text")
    }
}
