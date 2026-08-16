import Testing
@testable import AgtermLinux

@Suite("embedded libghostty surface geometry")
struct GhosttySurfaceGeometryTests {
    @Test("GTK viewport dimensions convert to backing pixels")
    func viewportUsesContentScale() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 1, storedFallback: nil
        ) == .init(width: 960, height: 540))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 2, storedFallback: nil
        ) == .init(width: 1_920, height: 1_080))
    }

    @Test("GtkGLArea resize dimensions are already backing pixels")
    func resizeViewportPassesThrough() {
        #expect(GhosttySurfaceGeometry.resizedViewport(
            widthPixels: 1_920, heightPixels: 1_080
        ) == .init(width: 1_920, height: 1_080))
    }

    @Test("GTK pointer coordinates remain unscaled at the embedded API boundary")
    func pointerStaysInWidgetCoordinates() {
        #expect(GhosttySurfaceGeometry.pointerPosition(
            gtkX: 320.5, gtkY: 180.25
        ) == .init(x: 320.5, y: 180.25))
    }

    @Test("non-positive viewport inputs clamp to one")
    func clampsNonPositiveDimensionsAndScale() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: -12, scaleFactor: 0, storedFallback: nil
        ) == .init(width: 1, height: 1))
        #expect(GhosttySurfaceGeometry.resizedViewport(
            widthPixels: 0, heightPixels: -12
        ) == .init(width: 1, height: 1))
    }

    @Test("creation falls back when the widget has no allocation of its own")
    func initialSizeUsesFallbackWhenUnallocated() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 1, storedFallback: (width: 849, height: 644)
        ) == .init(width: 849, height: 644))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 2, storedFallback: (width: 849, height: 644)
        ) == .init(width: 1_698, height: 1_288))
    }

    @Test("surface creation pushes the fallback through the libghostty size boundary")
    func creationPushesFallbackSize() {
        var calls: [(UInt32, UInt32)] = []
        let inputs = GhosttySurfaceGeometry.InitialSizeInputs(
            gtkWidth: 0,
            gtkHeight: 0,
            scaleFactor: 2,
            storedFallback: (width: 849, height: 644),
            deckFallback: (width: 700, height: 500))
        GhosttySurfaceGeometry.pushInitialSize(inputs, setSurfaceSize: { calls.append(($0, $1)) })

        #expect(calls.count == 1)
        #expect(calls.first?.0 == 1_698)
        #expect(calls.first?.1 == 1_288)
    }

    @Test("surface creation checks own, stored, deck, and clamp sources in order")
    func creationSizeSourcePrecedence() {
        let stored = (width: Int32(849), height: Int32(644))
        let deck = (width: Int32(700), height: Int32(500))

        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 1,
            storedFallback: stored, deckFallback: deck
        ) == .init(width: 960, height: 540))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 1,
            storedFallback: stored, deckFallback: deck
        ) == .init(width: 849, height: 644))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 2,
            storedFallback: (width: 849, height: 0), deckFallback: deck
        ) == .init(width: 1_400, height: 1_000))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 2,
            storedFallback: nil, deckFallback: (width: 0, height: 500)
        ) == .init(width: 2, height: 2))
    }

    @Test("creation prefers the widget's own allocation over the fallback")
    func initialSizePrefersOwnAllocation() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 1, storedFallback: (width: 100, height: 200)
        ) == .init(width: 960, height: 540))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 960, gtkHeight: 540, scaleFactor: 2, storedFallback: (width: 100, height: 200)
        ) == .init(width: 1_920, height: 1_080))
    }

    @Test("creation treats a half-allocated source as not credible")
    func initialSizeRejectsPartialSources() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 849, gtkHeight: 0, scaleFactor: 1, storedFallback: (width: 100, height: 200)
        ) == .init(width: 100, height: 200))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 644, scaleFactor: 1, storedFallback: (width: 100, height: 200)
        ) == .init(width: 100, height: 200))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: -20, gtkHeight: -12, scaleFactor: 1, storedFallback: (width: 100, height: 200)
        ) == .init(width: 100, height: 200))
    }

    @Test("creation still clamps to one when neither source is credible")
    func initialSizeClampsWithoutACredibleSource() {
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 1, storedFallback: (width: 0, height: 0)
        ) == .init(width: 1, height: 1))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: -4, gtkHeight: -12, scaleFactor: 1, storedFallback: (width: -8, height: -9)
        ) == .init(width: 1, height: 1))
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 1, storedFallback: (width: 100, height: 0)
        ) == .init(width: 1, height: 1))
        // The clamp is deliberately scale x scale, not a literal 1x1 — byte-identical to the historic
        // `max(1, gtkWidth) * scale`. Scale 1 cannot observe that choice, so pin it at 2.
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: 0, gtkHeight: 0, scaleFactor: 2, storedFallback: nil
        ) == .init(width: 2, height: 2))
    }

    @Test("a stored frame estimate subtracts the frame's measured chrome")
    func contentSizeSubtractsChrome() {
        // Harness-measured: a 60% floating overlay requests 654x414, and its `.card` chrome is 2px per axis.
        let content = GhosttySurfaceGeometry.contentSize(
            request: (width: 654, height: 414), chrome: (width: 2, height: 2))
        #expect(content == (width: 652, height: 412))
    }

    @Test("an unresolved chrome measurement degrades to the raw request")
    func contentSizeKeepsRequestWithoutChrome() {
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 849, height: 644), chrome: (width: 0, height: 0)
        ) == (width: 849, height: 644))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 849, height: 644), chrome: (width: -4, height: -4)
        ) == (width: 849, height: 644))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 849, height: 644), chrome: (width: 0, height: 2)
        ) == (width: 849, height: 642))
    }

    @Test("a chrome that is not a minority of its box keeps the request, never a credible 1x1")
    func contentSizeRefusesToCollapse() {
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 240, height: 160), chrome: (width: 239, height: 159)
        ) == (width: 240, height: 160))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 240, height: 160), chrome: (width: 240, height: 160)
        ) == (width: 240, height: 160))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 240, height: 160), chrome: (width: 900, height: 900)
        ) == (width: 240, height: 160))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 240, height: 160), chrome: (width: 120, height: 80)
        ) == (width: 240, height: 160))
        // One pixel inside the accepting side still subtracts — pins `>` rather than `>=`, so the
        // 120x80 case above is a real boundary and not the whole upper half of the range.
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 240, height: 160), chrome: (width: 119, height: 79)
        ) == (width: 121, height: 81))
    }

    @Test("a chrome whose subtraction would overflow keeps the request instead of trapping")
    func contentSizeSurvivesOverflowingChrome() {
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 240, height: 160), chrome: (width: .min, height: .min)
        ) == (width: 240, height: 160))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: .max, height: .max), chrome: (width: -1, height: .min)
        ) == (width: .max, height: .max))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: 849, height: 644), chrome: (width: .min, height: 2)
        ) == (width: 849, height: 642))
        #expect(GhosttySurfaceGeometry.contentSize(
            request: (width: .min, height: .min), chrome: (width: .max, height: 2)
        ) == (width: .min, height: .min))
    }

    @Test("an absurd allocation saturates instead of wrapping")
    func initialSizeSaturatesOnOverflow() {
        // UInt32(clamping:) on the UInt64 product is what keeps a bogus allocation from wrapping to a
        // small positive size, which would look like a plausible grid rather than an obvious failure.
        #expect(GhosttySurfaceGeometry.initialBackingSize(
            gtkWidth: .max, gtkHeight: .max, scaleFactor: 8, storedFallback: nil
        ) == .init(width: .max, height: .max))
    }
}
