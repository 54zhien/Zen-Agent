import Testing
import UIKit

@testable import ZenAgent

@Suite("Composer local morph")
struct ComposerMorphGeometryTests {
    @Test("localLayoutMatchesEndpointsAndInterpolatesTogether")
    func localLayoutMatchesEndpointsAndInterpolatesTogether() {
        let rest = endpoint(.resting)
        let edit = endpoint(.editing)
        #expect(rest.size.width == 336)
        #expect(edit.size.width == 358)
        #expect(rest.size.height >= 50)
        #expect(edit.size.height >= 108)
        var previousWidth = rest.size.width
        var previousHeight = rest.size.height
        for index in 0...100 {
            let p = CGFloat(index) / 100
            let sample = ComposerMorphGeometry.interpolate(rest, edit, progress: p)
            #expect(sample.size.width >= previousWidth - 0.001)
            #expect(sample.size.height >= previousHeight - 0.001)
            #expect(sample.textViewport.minX >= 0)
            #expect(sample.textViewport.maxX <= sample.size.width + 0.001)
            #expect(sample.plus.minX >= 0)
            #expect(sample.plus.maxX <= sample.size.width + 0.001)
            #expect(sample.primary.minX >= 0)
            #expect(sample.primary.maxX <= sample.size.width + 0.001)
            previousWidth = sample.size.width
            previousHeight = sample.size.height
        }
        #expect(ComposerMorphGeometry.interpolate(rest, edit, progress: 0).textOrigin == rest.textOrigin)
        #expect(ComposerMorphGeometry.interpolate(rest, edit, progress: 1).textOrigin == edit.textOrigin)
    }

    private func endpoint(_ state: ComposerPresentationState) -> ComposerMorphGeometry {
        ComposerMorphGeometry.endpoint(
            state, containerWidth: 390, availableHeight: 600,
            measuredTextHeight: 25, lineHeight: 24,
            collapseProgress: .expanded
        )
    }
}

@MainActor
@Suite("Composer transition order")
struct ComposerMotionControllerTests {
    @Test("staleCompletionCannotSettleNewTransition")
    func staleCompletionCannotSettleNewTransition() {
        let controller = ComposerMotionController()
        let first = controller.begin(.editing)
        let second = controller.begin(.resting)
        #expect(!controller.settle(first, target: .editing, finished: true))
        #expect(controller.phase == .collapsing)
        #expect(controller.settle(second, target: .resting, finished: true))
        #expect(controller.phase == .resting)
        controller.reset(to: .editing)
        #expect(controller.phase == .editing)
    }
}
