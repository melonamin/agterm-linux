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
    /// survives is the CONSUMER's geometry, not this constant's — and no fixed margin bounds it any more:
    /// - The QUICK card has no margins: its rectangle comes from `cardAllocation` below, which
    ///   leaves `(100 - cardSizePercent)/2` % of the FULL overlay width per side horizontally, and the same
    ///   fraction of the area BELOW the header above and beneath it. Both bands shrink with the window
    ///   rather than holding at 44px, so the old "8px offset + 32px blur = 40px fits inside 44px"
    ///   arithmetic no longer bounds anything — and the replacement is a THRESHOLD, not a constant: a 5%
    ///   band clears the shadow's 40px reach only above ~800px of overlay width and ~800px of
    ///   below-header height. Under that the halo truncates at the window edge, exactly as the overlay
    ///   card below already accepts.
    /// - The floating OVERLAY card also has no margins, but it is NOT purely proportional: `syncOverlay`
    ///   centers it at a size request of the session's `overlaySizePercent`% of the overlay, FLOORED at
    ///   240x160px, and computes that once when the overlay opens rather than per layout pass. Its halo
    ///   is therefore EXPECTED to truncate as the percentage climbs — at 95 (what `editKeymap` uses) only
    ///   ~2.5% of the window height sits below the card, less than the shadow's 40px reach, and at 100
    ///   the card is full-bleed: the shadow falls entirely outside the window while the border and the
    ///   rounded clip hug the window content edge. On a window small enough for the pixel floor to bind
    ///   it reaches the edge at any percentage. That is ACCEPTED, not a bug — the window's own clip cuts
    ///   the halo, nothing bleeds onto the sidebar or header, and the alternative (dropping the chrome
    ///   above some threshold) would make the two cards diverge for one caller.
    /// So validate a shadow change against the SMALLEST window either card must survive — the percentage
    /// band for the quick card, the 240x160 floor for the overlay card — not against a margin constant;
    /// there is none left to check it against.
    static let cardCSS = """
        .agterm-quick { background-color: #1e2228; border: 1px solid alpha(#ffffff, 0.18); border-radius: 12px; box-shadow: 0 8px 32px alpha(#000000, 0.8); }
        """

    /// How much of the available area the quick card occupies, as a percentage.
    /// macOS is the reference and the parity target: `WindowContentView` sizes the same card at
    /// `geo.size.width * 0.9` by `geo.size.height * 0.9` of the window content below the titlebar,
    /// centered.
    /// Named for the CARD deliberately: the unqualified `sizePercent` already means the SESSION overlay's
    /// own percentage elsewhere in the port (`session.overlay.resize`, `overlaySizePercent`), and the two
    /// are unrelated numbers.
    static let cardSizePercent: Int32 = 90

    /// Where the quick-terminal card sits inside the deck overlay, in overlay coordinates.
    /// A struct rather than a 4-member tuple, per the `large_tuple` budget.
    struct CardAllocation: Equatable {
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32
    }

    /// The quick card's rectangle for one overlay layout pass: `cardSizePercent`% of the overlay area
    /// BELOW the header strip, centered horizontally in the whole overlay and vertically in that
    /// available area — so the top edge lands at `headerHeight` plus half of the leftover band, and the
    /// header stays fully visible and clickable above the card.
    ///
    /// This governs the QUICK card ONLY. The floating session-overlay card is a sibling on the same
    /// `deckOverlay` wearing the same `agterm-quick` chrome, but `syncOverlay` keeps its own inline
    /// percent arithmetic with 240x160 pixel floors, applied once at open time — see the `cardCSS`
    /// comment above. The two are deliberately NOT shared here; folding the floored variant in is a
    /// follow-up, not something this function silently already does.
    ///
    /// There are deliberately NO pixel floors. macOS has none, and a floor here could not raise the
    /// window's own minimum size anyway — it could only clip the card; the window minimum is what keeps
    /// a degenerate card unreachable in practice.
    ///
    /// The function is TOTAL over its `Int32` inputs: every degenerate value (zero, negative, near
    /// `Int32.max`) clamps to a non-negative result instead of trapping. The multiply widens to 64 bits
    /// and comes back through `Int32(clamping:)`, the idiom `GhosttySurfaceGeometry.initialBackingSize`
    /// already uses — a naive `width * cardSizePercent / 100` TRAPS near `Int32.max`, while
    /// `width / 100 * cardSizePercent` would silently change the rounding the tests pin. A `headerHeight`
    /// at or beyond `overlayHeight` (a window shorter than its own header) collapses the available
    /// height to 0 and pins `y` at `min(headerHeight, overlayHeight)`.
    ///
    /// The caller passes `headerHeight: 0` when the header is hidden; that visibility gate belongs to it
    /// (`onDeckOverlayChildPosition` explains why), not here.
    static func cardAllocation(overlayWidth: Int32, overlayHeight: Int32,
                               headerHeight: Int32) -> CardAllocation {
        let width = max(0, overlayWidth)
        let height = max(0, overlayHeight)
        let header = min(max(0, headerHeight), height)
        let availableHeight = height - header
        let cardWidth = scaledToPercent(width)
        let cardHeight = scaledToPercent(availableHeight)
        return CardAllocation(x: (width - cardWidth) / 2,
                              y: header + (availableHeight - cardHeight) / 2,
                              width: cardWidth,
                              height: cardHeight)
    }

    private static func scaledToPercent(_ value: Int32) -> Int32 {
        Int32(clamping: Int64(value) * Int64(cardSizePercent) / 100)
    }
}
