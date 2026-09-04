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

/// The allocation math the `GtkOverlay::get-child-position` handler answers with. The handler itself is
/// not unit-testable (a live GTK layout pass drives it), so everything but the widget plumbing —
/// percentage, centering, the header inset, and totality over degenerate `Int32` input — is pinned here.
@Suite("Linux quick-terminal card allocation")
struct LinuxQuickCardAllocationTests {
    @Test("card is 90% of the area below the header, centered in it")
    func percentAndCentering() {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 1000, overlayHeight: 800,
                                                       headerHeight: 50)
        // available area is 1000 x 750; 90% of it is 900 x 675.
        #expect(card.width == 900)
        #expect(card.height == 675)
        #expect(card.x == 50)                    // (1000 - 900) / 2, centered in the FULL overlay width
        #expect(card.y == 50 + 37)               // header + (750 - 675) / 2
    }

    @Test("a configured percentage replaces the default and is clamped")
    func configuredPercent() {
        let compact = LinuxQuickCardPolicy.cardAllocation(
            overlayWidth: 1000, overlayHeight: 800, headerHeight: 50, sizePercent: 40
        )
        #expect(compact == LinuxQuickCardPolicy.CardAllocation(x: 300, y: 275, width: 400, height: 300))

        let oversized = LinuxQuickCardPolicy.cardAllocation(
            overlayWidth: 1000, overlayHeight: 800, headerHeight: 50, sizePercent: 500
        )
        #expect(oversized == LinuxQuickCardPolicy.cardAllocation(
            overlayWidth: 1000, overlayHeight: 800, headerHeight: 50, sizePercent: 90
        ))
    }

    /// The band the card leaves is 5% of the AVAILABLE area on every side — the header is inset on top
    /// of that, not counted against it, which is what keeps the header bar clickable above the card.
    @Test("header inset lands 5% bands around the card, below the header")
    func headerInsetBands() {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 2000, overlayHeight: 1200,
                                                       headerHeight: 200)
        #expect(card.width == 1800)              // 90% of 2000
        #expect(card.height == 900)              // 90% of the 1000 available below the header
        #expect(card.x == 100)                   // 5% of 2000
        #expect(2000 - (card.x + card.width) == 100)
        #expect(card.y == 250)                   // header 200 + 5% of 1000
        #expect(1200 - (card.y + card.height) == 50)
    }

    /// Pins the MATH for a zero header, not a UI mode: with no strip to clear, the available area is the
    /// whole overlay and the card centers in it. The caller decides when to pass 0, so that gate is not
    /// this function's business.
    @Test("zero header height centers the card in the whole overlay")
    func zeroHeaderCentersInOverlay() {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 1000, overlayHeight: 1000,
                                                       headerHeight: 0)
        #expect(card == LinuxQuickCardPolicy.CardAllocation(x: 50, y: 50, width: 900, height: 900))
    }

    @Test("an empty overlay yields an empty card at the origin")
    func emptyOverlay() {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 0, overlayHeight: 0,
                                                       headerHeight: 0)
        #expect(card == LinuxQuickCardPolicy.CardAllocation(x: 0, y: 0, width: 0, height: 0))
    }

    @Test("negative inputs clamp to an empty card instead of trapping")
    func negativeInputs() {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: -1000, overlayHeight: -800,
                                                       headerHeight: -50)
        #expect(card == LinuxQuickCardPolicy.CardAllocation(x: 0, y: 0, width: 0, height: 0))
    }

    /// The three clamps are independent, so they need MIXED-sign input too: an all-degenerate case passes
    /// even if two of the three were dropped. A negative width may not disturb the vertical math, and a
    /// negative header must behave exactly like no header at all.
    @Test("a single negative input clamps only its own dimension")
    func mixedSignInputs() {
        let narrow = LinuxQuickCardPolicy.cardAllocation(overlayWidth: -10, overlayHeight: 800,
                                                         headerHeight: 50)
        #expect(narrow == LinuxQuickCardPolicy.CardAllocation(x: 0, y: 87, width: 0, height: 675))

        let negativeHeader = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 1000, overlayHeight: 800,
                                                                 headerHeight: -50)
        #expect(negativeHeader == LinuxQuickCardPolicy.cardAllocation(overlayWidth: 1000,
                                                                      overlayHeight: 800,
                                                                      headerHeight: 0))
    }

    /// The 64-bit-widened multiply is what makes this survive: `Int32.max * 90` overflows `Int32`, so a
    /// naive `width * 90 / 100` would trap here.
    @Test("near-Int32.max input stays non-negative without trapping")
    func nearOverflowInput() {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: .max, overlayHeight: .max,
                                                       headerHeight: 0)
        #expect(card.width == 1_932_735_282)     // Int32.max * 90 / 100
        #expect(card.height == 1_932_735_282)
        #expect(card.x == 107_374_182)
        #expect(card.y == 107_374_182)
        // Widened deliberately: an `Int32 + Int32` here would TRAP on the very overflow it claims to rule
        // out, reporting a crash instead of a named failure.
        #expect(Int64(card.x) + Int64(card.width) <= Int64(Int32.max))
        #expect(Int64(card.y) + Int64(card.height) <= Int64(Int32.max))
    }

    /// The physically reachable short-window case: the header alone fills (or over-fills) the overlay.
    /// Available height collapses to 0 and the card's top edge pins at `min(header, overlayHeight)`,
    /// so it never escapes the overlay.
    @Test("header at or beyond the overlay height collapses the card to zero height")
    func headerFillsOverlay() {
        let exact = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 1000, overlayHeight: 800,
                                                        headerHeight: 800)
        #expect(exact == LinuxQuickCardPolicy.CardAllocation(x: 50, y: 800, width: 900, height: 0))

        let beyond = LinuxQuickCardPolicy.cardAllocation(overlayWidth: 1000, overlayHeight: 800,
                                                         headerHeight: 5000)
        #expect(beyond == exact)                 // header clamps to the overlay height
    }

    /// A sweep over containment and centering, parameterized so a failure names the `(size, header)` case
    /// instead of aborting the whole cross product at the first one. The PERCENTAGE is deliberately not
    /// re-derived here — restating `width * cardSizePercent / 100` would move the assertion in lockstep
    /// with the implementation and prove nothing; the exact-value tests above are what pin it. What this
    /// adds is the two properties they cannot cover across many shapes: the card never escapes the overlay
    /// or rides up over the header, and both bands stay equal to within the odd-size rounding remainder.
    @Test("the card stays centered inside the overlay, below the header",
          arguments: [(1, 1), (7, 9), (320, 240), (1440, 900), (3840, 2160)] as [(Int32, Int32)],
          [0, 1, 46, 200] as [Int32])
    func cardStaysCenteredBelowHeader(size: (width: Int32, height: Int32), header: Int32) {
        let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: size.width,
                                                       overlayHeight: size.height,
                                                       headerHeight: header)
        let top = min(header, size.height)
        #expect(card.width >= 0)
        #expect(card.height >= 0)
        #expect(card.x >= 0)
        #expect(card.y >= top)
        #expect(card.x + card.width <= size.width)
        #expect(card.y + card.height <= size.height)
        // Centered: the leading and trailing bands may differ only by the odd-size rounding remainder.
        #expect(abs(size.width - (card.x + card.width) - card.x) <= 1)
        #expect(abs(size.height - (card.y + card.height) - (card.y - top)) <= 1)
    }
}
