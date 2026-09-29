import Foundation
import Testing
@testable import AgtermLinux

/// `GHOSTTY_ACTION_MOUSE_OVER_LINK` arrives as a length-delimited C struct
/// (`ghostty_action_mouse_over_link_s { const char* url; size_t len; }`).
/// libghostty signals "pointer left the link" with an EMPTY url (`len == 0`) —
/// the `url` pointer itself is never NULL, so hover state must be decided by `len`.
@Suite("Link hover decision (GHOSTTY_ACTION_MOUSE_OVER_LINK)")
struct LinkHoverDecisionTests {
    @Test("non-null URL pointer with len 0 clears hover (the libghostty clear signal)")
    func nonNullEmptyURLClearsHover() {
        "https://example.com".withCString { ptr in
            #expect(LinkHoverDecision.isActive(url: ptr, len: 0) == false)
        }
    }

    @Test("non-empty URL with positive len sets hover")
    func nonEmptyURLSetsHover() {
        "https://example.com".withCString { ptr in
            #expect(LinkHoverDecision.isActive(url: ptr, len: 18) == true)
        }
    }

    @Test("nil URL pointer never sets hover")
    func nilURLNeverSetsHover() {
        #expect(LinkHoverDecision.isActive(url: nil, len: 0) == false)
        #expect(LinkHoverDecision.isActive(url: nil, len: 18) == false)
    }
}
