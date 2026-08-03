enum LinuxQuickCardPolicy {
    /// The chrome of the floating quick-terminal card — and, by construction, of the floating session
    /// overlay, which carries the same `agterm-quick` class on the same GtkFrame shape.
    /// Installed at the application priority (600) in `installAppCSS()`, so it wins over libadwaita's
    /// theme rules (200) for the same `frame`/`.card` nodes.
    ///
    /// Two of the four declarations mirror what macOS draws explicitly (`WindowContentView.swift`):
    /// the 12px radius and the 1px stroke at 18% white. The rounded clip of the terminal content is the
    /// third macOS equivalence but is NOT a declaration here — it is the `GTK_OVERFLOW_HIDDEN` set in
    /// Swift at both frame-construction sites.
    /// The shadow deliberately DIVERGES from SwiftUI's centered, ~⅓-alpha `.shadow(radius: 24)`: it is
    /// offset and stronger, because a subtle centered shadow is exactly what proved invisible when the
    /// card floats over a dark full-bleed session.
    ///
    /// Three invariants are load-bearing and are pinned by `LinuxQuickCardPolicyTests`:
    /// - The `#1e2228` backing stays OPAQUE. It is what keeps the card from going see-through when the
    ///   ghostty surface below draws transparent under `background-opacity < 1`.
    /// - The border color is LIGHT polarity, not a themed `currentColor` derivation. libadwaita's `frame`
    ///   node already draws a 1px border, but it is mixed from `currentColor` and is therefore invisible
    ///   dark-on-dark — the missing contrast, not a missing border, is what made the card read as
    ///   boundary-less. `.agterm-switcher` sets the same light-contour precedent.
    /// - The border WIDTH stays exactly 1px — the same width the theme already drew. A color swap at an
    ///   unchanged width leaves the frame's MEASURED chrome untouched, which is what keeps the
    ///   surface-sizing math that subtracts the frame chrome from the requested size valid.
    ///
    /// No `padding` may be added here: the GL child must keep filling the content box.
    ///
    /// `box-shadow` is layout-neutral (never measured) and draws OUTWARD, so how much of the halo
    /// survives is the CONSUMER's geometry, not this constant's — the two cards do not share a budget:
    /// - The QUICK card has fixed 44/56px margins (`setQuick`). Its bottom edge binds at 8px offset +
    ///   32px blur = 40px against the 44px margin, so a stronger shadow cannot push the blur past ~36px
    ///   without clipping at the window edge.
    /// - The floating OVERLAY card has NO margins at all: `syncOverlay` centers it at an explicit size
    ///   request of `sizePercent`% of the window content, leaving `(100 - sizePercent)/2` % per side.
    ///   Its halo is therefore EXPECTED to truncate as the percentage climbs — at 95 (what `editKeymap`
    ///   uses) only ~2.5% of the window height sits below the card, less than the shadow's 40px reach,
    ///   and at 100 the card is full-bleed: the shadow falls entirely outside the window while the
    ///   border and the rounded clip hug the window content edge. That is ACCEPTED, not a bug — the
    ///   window's own clip cuts the halo, nothing bleeds onto the sidebar or header, and the alternative
    ///   (dropping the chrome above some threshold) would make the two cards diverge for one caller.
    ///   Do NOT validate a shadow change against the 44px arithmetic alone; it bounds the quick card only.
    static let cardCSS = """
        .agterm-quick { background-color: #1e2228; border: 1px solid alpha(#ffffff, 0.18); border-radius: 12px; box-shadow: 0 8px 32px alpha(#000000, 0.8); }
        """
}
