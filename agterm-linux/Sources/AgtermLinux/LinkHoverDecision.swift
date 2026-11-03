/// Decides whether a `GHOSTTY_ACTION_MOUSE_OVER_LINK` action means the pointer is over a hyperlink.
///
/// libghostty reports the state length-delimited (`ghostty_action_mouse_over_link_s { url, len }`) and
/// signals "pointer left the link" with an EMPTY url (`len == 0`): the `url` pointer itself is never
/// NULL (see `apprt/action.zig` `MouseOverLink`), so nullability alone cannot distinguish set from clear.
enum LinkHoverDecision {
    static func isActive(url: UnsafePointer<CChar>?, len: Int) -> Bool {
        url != nil && len > 0
    }
}
