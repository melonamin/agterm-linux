import Testing
@testable import AgtermLinux

private final class GLStandIn {
    var events: [String] = []
    var logs: [String] = []
    var refs: [String: Int] = [:]
    var slot: String?
    var displayOpen = true
    var makeCurrentFails: Set<String> = []
    var clearFails = false

    var steps: LinuxRetainedGLTeardownSteps<String> {
        LinuxRetainedGLTeardownSteps(
            displayIsOpen: { [self] in
                events.append("display")
                return displayOpen
            },
            current: { [self] in slot },
            retain: { [self] in
                events.append("retain \($0)")
                refs[$0, default: 0] += 1
            },
            release: { [self] in
                events.append("release \($0)")
                refs[$0, default: 0] -= 1
            },
            makeCurrent: { [self] context in
                events.append("make \(context)")
                guard !makeCurrentFails.contains(context) else { return false }
                slot = context
                return true
            },
            clear: { [self] in
                events.append("clear")
                guard !clearFails else { return slot == nil }
                slot = nil
                return true
            },
            free: { [self] in events.append("free") },
            log: { [self] in logs.append($0) })
    }

    func run() -> LinuxRetainedGLTeardownResult {
        LinuxRetainedGLTeardown.run(owner: "owner", steps: steps)
    }

    var priorRefsBalance: Bool { refs["prior", default: 0] == 0 }
}

@MainActor
private final class EngineOwnerStandIn: LinuxEngineSurfaceOwner {
    var isRealized: Bool
    var awaitingSpawnPermit = false
    var events: [String] = []
    var frees = 0
    var onDischarge: (EngineOwnerStandIn) -> Void = { _ in }

    init(realized: Bool) {
        isRealized = realized
    }

    func dischargeEngineSurface() {
        events.append("discharge")
        frees += 1
        isRealized = false
        onDischarge(self)
    }

    func teardown() {
        if isRealized { dischargeEngineSurface() }
    }
}

@Suite("retained GL teardown")
struct LinuxRetainedGLTeardownTests {
    @Test("the free runs under the owner, then the prior comes back and both refs drop once")
    func successOrder() {
        let gl = GLStandIn()
        gl.slot = "prior"

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .ownerCurrent, restore: .restored))
        #expect(gl.events == ["display", "retain prior", "make owner", "free", "make prior", "release prior", "release owner"])
        #expect(gl.logs.isEmpty)
        #expect(gl.slot == "prior")
    }

    @Test("no prior context ends with none current")
    func nilPrior() {
        let gl = GLStandIn()

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .ownerCurrent, restore: .restored))
        #expect(gl.events == ["display", "make owner", "free", "clear", "release owner"])
        #expect(gl.slot == nil)
    }

    @Test("a prior that is the owner keeps its own ref apart from the consumed one")
    func priorIsOwner() {
        let gl = GLStandIn()
        gl.slot = "owner"
        gl.refs["owner"] = 1

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .ownerCurrent, restore: .restored))
        #expect(gl.events == ["display", "retain owner", "make owner", "free", "make owner", "release owner", "release owner"])
        #expect(gl.refs["owner"] == 0)
    }

    @Test("a closed display reaches no context step and no free")
    func closedDisplay() {
        let gl = GLStandIn()
        gl.slot = "prior"
        gl.displayOpen = false

        let result = gl.run()

        #expect(result.free == .leaked)
        #expect(gl.events == ["display"])
        #expect(gl.logs.count == 1)
        #expect(gl.logs[0].hasPrefix("agterm: retained GL context:"))
    }

    @Test("a failed make-current clears, frees with no context, and warns of a leak")
    func makeCurrentFailure() {
        let gl = GLStandIn()
        gl.slot = "prior"
        gl.makeCurrentFails = ["owner"]

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .noContext, restore: .restored))
        #expect(gl.events == ["display", "retain prior", "make owner", "clear", "free", "make prior", "release prior", "release owner"])
        #expect(gl.logs == ["agterm: retained GL context: owner not current; freed with no context, possible GPU leak"])
        #expect(gl.priorRefsBalance)
    }

    @Test("a clear that cannot be established skips the free and keeps the owner ref")
    func clearFailure() {
        let gl = GLStandIn()
        gl.slot = "prior"
        gl.makeCurrentFails = ["owner"]
        gl.clearFails = true

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .leaked, restore: .restored))
        #expect(!gl.events.contains("free"))
        #expect(!gl.events.contains("release owner"))
        #expect(gl.priorRefsBalance)
        #expect(gl.logs == ["agterm: retained GL context: owner not current and the clear failed; surface left running"])
    }

    @Test("a restore failure is separate from the free and clears")
    func restoreFailure() {
        let gl = GLStandIn()
        gl.slot = "prior"
        gl.makeCurrentFails = ["prior"]

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .ownerCurrent, restore: .cleared))
        #expect(result.free.calledFree)
        #expect(gl.logs == ["agterm: retained GL context: restore failed; cleared"])
        #expect(gl.events.contains("release owner"))
        #expect(gl.priorRefsBalance)
    }

    @Test("a restore failure with no clear still reports a free that ran")
    func restoreAndClearFailure() {
        let gl = GLStandIn()
        gl.slot = "prior"
        gl.makeCurrentFails = ["prior"]
        gl.clearFails = true

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .ownerCurrent, restore: .failed))
        #expect(result.free.calledFree)
        #expect(gl.logs == ["agterm: retained GL context: restore failed; current context unknown"])
        #expect(gl.events.contains("release owner"))
    }

    @Test("only the skipped free leaves a handle for later", arguments: [
        (LinuxGLFreeOutcome.ownerCurrent, true), (.noContext, true), (.leaked, false),
    ])
    func discharge(outcome: LinuxGLFreeOutcome, calledFree: Bool) {
        #expect(outcome.calledFree == calledFree)
    }

    @Test("a disposed prior still in the slot reads as restored through the steps")
    func stalePriorInSlot() {
        let gl = GLStandIn()
        gl.slot = "stale"
        gl.makeCurrentFails = ["owner"]
        gl.clearFails = true

        let result = gl.run()

        #expect(result.free == .leaked)
        #expect(gl.slot == "stale")
        #expect(result.restore == .restored)
        #expect(gl.refs["stale"] == 0)
    }

    @Test("a stale prior the valid owner replaced fails its restore and the clear clears the owner")
    func stalePriorReplacedByOwner() {
        let gl = GLStandIn()
        gl.slot = "stale"
        gl.makeCurrentFails = ["stale"]

        let result = gl.run()

        #expect(result == LinuxRetainedGLTeardownResult(free: .ownerCurrent, restore: .cleared))
        #expect(gl.slot == nil)
    }

    @MainActor
    @Test("destroy discharges before GTK's reference drops, and teardown after it frees nothing")
    func destroyDischarges() {
        let owner = EngineOwnerStandIn(realized: true)

        LinuxSurfaceWidgetLifecycle.destroyed(owner) { owner.events.append("release") }
        owner.teardown()

        #expect(owner.events == ["discharge", "release"])
        #expect(owner.frees == 1)
    }

    @MainActor
    @Test("an explicit teardown leaves destroy no engine to discharge")
    func teardownFirst() {
        let owner = EngineOwnerStandIn(realized: true)

        owner.teardown()
        LinuxSurfaceWidgetLifecycle.destroyed(owner) { owner.events.append("release") }

        #expect(owner.frees == 1)
        #expect(owner.events == ["discharge", "release"])
    }

    @MainActor
    @Test("a skipped free pins the wrapper before GTK's reference drops")
    func skipFreePins() {
        let quarantine = LinuxSurfaceQuarantine<EngineOwnerStandIn>(log: { _ in })
        let gtkReference = Unmanaged.passRetained(EngineOwnerStandIn(realized: true))
        weak var survivor = gtkReference.takeUnretainedValue()
        gtkReference.takeUnretainedValue().onDischarge = { quarantine.insert($0, key: 1) }

        LinuxSurfaceWidgetLifecycle.destroyed(gtkReference.takeUnretainedValue()) { gtkReference.release() }

        #expect(survivor != nil)
        #expect(quarantine.contains(1))
    }

    @MainActor
    @Test("a paced grant arriving after destroy finds nothing to create")
    func pacedGrantAfterDestroy() {
        let owner = EngineOwnerStandIn(realized: false)
        owner.awaitingSpawnPermit = true

        LinuxSurfaceWidgetLifecycle.destroyed(owner) {}

        #expect(owner.frees == 0)
        #expect(!owner.awaitingSpawnPermit)
    }

    @Test("the skip-free injection needs the scenario and names one role")
    func skipFreeInjection() {
        let active = ["AGTERM_ATSPI_SCENARIO": "gl-teardown-quarantine", LinuxSurfaceFailureInjection.environmentKey: "gl-skip-free:overlay"]
        #expect(LinuxSurfaceFailureInjection.skipsGLFree(for: .overlay, environment: active))
        #expect(!LinuxSurfaceFailureInjection.skipsGLFree(for: .main, environment: active))
        #expect(!LinuxSurfaceFailureInjection.skipsGLFree(
            for: .overlay, environment: [LinuxSurfaceFailureInjection.environmentKey: "gl-skip-free:overlay"]))
        #expect(LinuxSurfaceFailureInjection.failure(for: .overlay, environment: active) == nil)
    }
}
