import Testing
@testable import AgtermLinux

@Suite("Linux quick-terminal card chrome")
struct LinuxQuickCardPolicyTests {
    /// A deliberate change-detector over a bare constant, pinned by EQUALITY rather than by a pile of
    /// substring checks. The contract itself lives in `LinuxQuickCardPolicy.cardCSS`'s doc comment —
    /// opaque backing, light-polarity border at an unchanged 1px width, explicit 12px radius, no
    /// padding, and ONE rule so the quick terminal and the floating session overlay stay visually
    /// identical. A string assertion cannot enforce any of that; what it can do is make every edit trip
    /// here, including the ones substring pins miss (splitting the chrome across a second selector,
    /// re-opening `border-width`, adding a `padding` shorthand), so the edit has to be a conscious one
    /// that re-reads the comment.
    ///
    /// It says NOTHING about GTK ACCEPTING the CSS: GTK drops an unparseable declaration silently and
    /// only a running app reports it (`Theme parser error` on stderr, which `scripts/test-linux-ui.sh`
    /// fails the UI smoke on).
    @Test("quick-card CSS pins the floating chrome contract")
    func cardCSS() {
        #expect(LinuxQuickCardPolicy.cardCSS == """
            .agterm-quick { background-color: #1e2228; border: 1px solid alpha(#ffffff, 0.18); border-radius: 12px; box-shadow: 0 8px 32px alpha(#000000, 0.8); }
            """)
    }
}
