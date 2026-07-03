import XCTest
@testable import CemuEmulator

final class JITEngineTests: XCTestCase {
    func testCachedLoopIsNilBeforeThresholdReached() {
        let engine = JITEngine(enabled: true, hotThreshold: 3)
        let bodyStart: UInt32 = 0x1000
        let branchPC: UInt32 = 0x1008
        let fallthroughPC: UInt32 = 0x100C

        XCTAssertNil(engine.cachedLoop(at: bodyStart))

        engine.recordBackEdge(bodyStart: bodyStart, branchPC: branchPC, fallthroughPC: fallthroughPC) { PPCInstruction(opcode: $0) }
        XCTAssertNil(engine.cachedLoop(at: bodyStart), "one hit shouldn't compile with hotThreshold 3")

        engine.recordBackEdge(bodyStart: bodyStart, branchPC: branchPC, fallthroughPC: fallthroughPC) { PPCInstruction(opcode: $0) }
        XCTAssertNil(engine.cachedLoop(at: bodyStart), "two hits shouldn't compile with hotThreshold 3")
    }

    func testCompilesAfterHotThresholdReached() {
        let engine = JITEngine(enabled: true, hotThreshold: 3)
        let bodyStart: UInt32 = 0x1000
        let branchPC: UInt32 = 0x1008
        let fallthroughPC: UInt32 = 0x100C

        for _ in 0..<3 {
            engine.recordBackEdge(bodyStart: bodyStart, branchPC: branchPC, fallthroughPC: fallthroughPC) { PPCInstruction(opcode: $0) }
        }

        guard let loop = engine.cachedLoop(at: bodyStart) else {
            return XCTFail("expected a compiled loop after hitting hotThreshold")
        }

        XCTAssertEqual(loop.instructions.count, 2, "body spans [bodyStart, branchPC) in 4-byte steps")
        XCTAssertEqual(loop.instructions[0].opcode, bodyStart)
        XCTAssertEqual(loop.instructions[1].opcode, bodyStart &+ 4)
        XCTAssertEqual(loop.branch.opcode, branchPC)
        XCTAssertEqual(loop.fallthroughPC, fallthroughPC)
        XCTAssertEqual(engine.stats.compiledLoops, 1)
    }

    func testDisabledEngineNeverCompiles() {
        let engine = JITEngine(enabled: false, hotThreshold: 1)

        for _ in 0..<5 {
            engine.recordBackEdge(bodyStart: 0x1000, branchPC: 0x1004, fallthroughPC: 0x1008) { PPCInstruction(opcode: $0) }
        }

        XCTAssertNil(engine.cachedLoop(at: 0x1000))
        XCTAssertEqual(engine.stats.compiledLoops, 0)
    }

    func testForwardBranchIsNeverTreatedAsALoop() {
        // bodyStart > branchPC means the branch target is *ahead* of the
        // branch instruction - not a backward edge, so this must never
        // compile regardless of hit count.
        let engine = JITEngine(enabled: true, hotThreshold: 1)

        engine.recordBackEdge(bodyStart: 0x2000, branchPC: 0x1000, fallthroughPC: 0x1004) { PPCInstruction(opcode: $0) }

        XCTAssertNil(engine.cachedLoop(at: 0x2000))
        XCTAssertEqual(engine.stats.compiledLoops, 0)
    }

    func testOversizedLoopBodyIsNeverCompiled() {
        let engine = JITEngine(enabled: true, hotThreshold: 1)
        // maxLoopBodyInstructions is capped internally at 4096; a body of
        // 4097 instructions must be rejected as a safety guard against a
        // mis-detected "loop" ballooning into a huge cached array.
        let branchPC: UInt32 = 4097 * 4

        engine.recordBackEdge(bodyStart: 0, branchPC: branchPC, fallthroughPC: branchPC &+ 4) { PPCInstruction(opcode: $0) }

        XCTAssertNil(engine.cachedLoop(at: 0))
        XCTAssertEqual(engine.stats.compiledLoops, 0)
    }

    func testResetClearsCompiledLoopsAndCounters() {
        let engine = JITEngine(enabled: true, hotThreshold: 1)
        engine.recordBackEdge(bodyStart: 0x1000, branchPC: 0x1004, fallthroughPC: 0x1008) { PPCInstruction(opcode: $0) }
        XCTAssertNotNil(engine.cachedLoop(at: 0x1000))

        engine.reset()

        XCTAssertNil(engine.cachedLoop(at: 0x1000))
        XCTAssertEqual(engine.stats.compiledLoops, 0)
    }

    func testSetEnabledFalseDisablesAndClearsExistingCompiledLoops() {
        let engine = JITEngine(enabled: true, hotThreshold: 1)
        engine.recordBackEdge(bodyStart: 0x1000, branchPC: 0x1004, fallthroughPC: 0x1008) { PPCInstruction(opcode: $0) }
        XCTAssertNotNil(engine.cachedLoop(at: 0x1000))

        engine.setEnabled(false)

        XCTAssertNil(engine.cachedLoop(at: 0x1000))
        XCTAssertEqual(engine.stats.compiledLoops, 0, "setEnabled(false) resets state, it doesn't just gate lookups")
    }
}
