import Testing
@testable import StageCue

@Suite(.serialized)
struct ModelTests {
    private let temporaryFiles = TemporaryFiles()
    @Test func testGainConversionAndBounds() {
        expectEqual(amplitude(0), 1)
        expectEqual(amplitude(-6), 0.5011872, accuracy: 0.000001)
        expectEqual(amplitude(-60), 0.001, accuracy: 0.000001)
        expectEqual(amplitude(6), 1.9952623, accuracy: 0.000001)
        expectEqual(amplitude(.nan), 1)
        expectEqual(amplitude(200), amplitude(6))
    }
    @Test func testNormalizationRepairsMalformedSettingsAndIDs() {
        var cue = Cue(gainDB: .nan, bus: 99, mode: .hold, fadeInSeconds: -2, fadeOutSeconds: .infinity)
        var project = SoundProject(cues: [cue, cue], busDB: [.nan, -200, 200], masterDB: .infinity, manualFadeSeconds: -5)
        let notes = project.normalize()
        expectFalse(notes.isEmpty)
        expectEqual(project.cues.count, 32)
        expectEqual(project.busDB, [0, -60, 6, 0, 0, 0])
        expectEqual(project.masterDB, 0)
        expectEqual(project.manualFadeSeconds, 0)
        cue.normalize()
        expectEqual(cue.bus, 5)
        expectEqual(cue.gainDB, -6)
        expectEqual(cue.mode, .oneShot)
        expectEqual(cue.fadeInSeconds, 0)
        expectEqual(cue.fadeOutSeconds, 2)
        expectNotEqual(project.cues[0]?.id, project.cues[1]?.id)
        let once = project
        expectTrue(project.normalize().isEmpty)
        expectEqual(project, once)
    }
    @Test func testOversizedProjectIsTruncated() {
        var project = SoundProject(cues: Array(repeating: nil, count: 40), busDB: Array(repeating: 1, count: 12))
        project.normalize()
        expectEqual(project.cues.count, 32)
        expectEqual(project.busDB.count, 6)
    }
    @Test func testFadeEndpointsMonotonicityAndBounds() {
        for curve in FadeCurve.allCases {
            for (initial, target): (Float, Float) in [(0, 1), (1, 0), (0.2, 0.8), (0.8, 0.2)] {
                let fade = FadeEnvelope(initial: initial, target: target, started: 10, duration: 2, curve: curve, stopWhenDone: false)
                expectEqual(fade.level(at: 9), initial)
                expectEqual(fade.level(at: 12), target)
                expectEqual(fade.level(at: 13), target)
                var previous = initial
                for step in 0...100 {
                    let level = fade.level(at: 10 + Double(step) / 50)
                    expectTrue(level >= min(initial, target) && level <= max(initial, target))
                    expectTrue(target >= initial ? level >= previous : level <= previous)
                    previous = level
                }
            }
        }
    }
    @Test func testEqualPowerComplementaryCurves() {
        let up = FadeEnvelope(initial: 0, target: 1, started: 0, duration: 1, curve: .equalPower, stopWhenDone: false)
        let down = FadeEnvelope(initial: 1, target: 0, started: 0, duration: 1, curve: .equalPower, stopWhenDone: false)
        for step in 0...100 {
            let t = Double(step) / 100
            let a = up.level(at: t), b = down.level(at: t)
            expectEqual(a * a + b * b, 1, accuracy: 0.000001)
        }
    }
    @Test func testInterruptedFadeIsContinuousAndZeroDurationIsImmediate() {
        let old = FadeEnvelope(initial: 1, target: 0, started: 0, duration: 2, curve: .smooth, stopWhenDone: false)
        let current = old.level(at: 0.7)
        let replacement = FadeEnvelope(initial: current, target: 1, started: 0.7, duration: 1, curve: .linear, stopWhenDone: false)
        expectEqual(replacement.level(at: 0.7), current)
        expectEqual(replacement.level(at: 1.7), 1)
        let zero = FadeEnvelope(initial: 1, target: 0, started: 0, duration: 0, curve: .smooth, stopWhenDone: true)
        expectEqual(zero.level(at: 0), 0)
        expectEqual(zero.fraction(at: 0), 1)
    }
    @Test func testShortClipFadesFitDurationAndLoopsHaveNoTail() {
        var cue = Cue(loop: false, autoFadeIn: true, fadeInSeconds: 2, autoFadeOut: true, fadeOutSeconds: 2)
        var plan = AutomaticFades(cue: cue, duration: 1)
        expectEqual(plan.fadeIn, 0.5)
        expectEqual(plan.fadeOut, 0.5)
        cue.loop = true
        plan = AutomaticFades(cue: cue, duration: 1)
        expectEqual(plan.fadeIn, 2)
        expectEqual(plan.fadeOut, 0)
    }
}
