import Testing

@testable import ZenAgent

@Suite("Bottom anchor resize")
struct BottomAnchorResizeTests {
    private let machine = ReadingPositionStateMachine(tolerance: 12)
    private let epsilon = 1e-7

    @Test("resizeFollowingBottomNeverRequestsScrollToBottom")
    func resizeFollowingBottomNeverRequestsScrollToBottom() {
        let contentHeight = 1_000.0
        var offset = 850.0
        var mode: ReadingMode = .followingBottom

        for viewportHeight in [150.0, 220.0, 90.0, 180.0] {
            let geometry = ScrollGeometry(
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                offset: offset
            )
            let output = machine.reduce(
                mode,
                .paneHeightChanged(geometry: geometry, anchor: nil, turnTop: nil)
            )
            let expectedOffset = max(0, contentHeight - viewportHeight)

            #expect(output.mode == .followingBottom)
            #expect(output.action != .scrollToBottom)
            #expect(output.action == .maintainBottomEdge(targetOffset: expectedOffset))

            offset = apply(output.action, to: geometry)
            mode = output.mode
            #expect(abs(offset - expectedOffset) <= epsilon)
        }
    }

    @Test("resizeReadingKeepsContentBottomEdgeAcrossBothDirections")
    func resizeReadingKeepsContentBottomEdgeAcrossBothDirections() {
        let runID = "run-bottom-edge"
        let contentHeight = 1_200.0
        let turnTop = 500.0
        let initialGeometry = ScrollGeometry(viewportHeight: 200, contentHeight: contentHeight, offset: 400)
        let originalBottomEdge = initialGeometry.offset + initialGeometry.viewportHeight
        let bottomAnchorValue = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: turnTop,
            geometry: initialGeometry
        )
        #expect(bottomAnchorValue != nil)
        guard let bottomAnchor = bottomAnchorValue else { return }

        var mode: ReadingMode = .reading(
            anchor: TurnAnchor(
                runID: runID,
                relativeViewportOffset: (turnTop - initialGeometry.offset) / initialGeometry.viewportHeight
            ),
            pendingTurns: []
        )
        var offset = initialGeometry.offset

        for viewportHeight in [250.0, 330.0, 270.0, 200.0] {
            let geometry = ScrollGeometry(
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                offset: offset
            )
            let output = machine.reduce(
                mode,
                .paneHeightChanged(geometry: geometry, anchor: bottomAnchor, turnTop: turnTop)
            )
            let resolverTargetValue = AnchorResolver.restoreTargetFromBottomAnchor(
                anchor: bottomAnchor,
                turnTop: turnTop,
                contentHeight: contentHeight,
                viewportHeight: viewportHeight
            )
            #expect(resolverTargetValue != nil)
            guard let resolverTarget = resolverTargetValue else { return }

            let expectedOffset = min(
                max(0, resolverTarget),
                max(0, contentHeight - viewportHeight)
            )
            #expect(output.action != .scrollToBottom)
            #expect(output.action == .maintainBottomEdge(targetOffset: expectedOffset))

            offset = apply(output.action, to: geometry)
            mode = output.mode
            #expect(abs(offset + viewportHeight - originalBottomEdge) <= epsilon)
        }
    }

    @Test("resizeRoundTripHasNoCumulativeDrift")
    func resizeRoundTripHasNoCumulativeDrift() {
        let runID = "run-round-trip"
        let contentHeight = 2_000.0
        let turnTop = 700.0
        let initialGeometry = ScrollGeometry(viewportHeight: 300, contentHeight: contentHeight, offset: 500)
        let originalOffset = initialGeometry.offset
        let bottomAnchorValue = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: turnTop,
            geometry: initialGeometry
        )
        #expect(bottomAnchorValue != nil)
        guard let originalBottomAnchor = bottomAnchorValue else { return }

        var mode: ReadingMode = .reading(
            anchor: TurnAnchor(runID: runID, relativeViewportOffset: (turnTop - originalOffset) / 300),
            pendingTurns: []
        )
        var offset = originalOffset

        for viewportHeight in [100.0, 350.0, 125.0, 300.0, 175.0, 300.0] {
            let geometry = ScrollGeometry(
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                offset: offset
            )
            let output = machine.reduce(
                mode,
                .paneHeightChanged(geometry: geometry, anchor: originalBottomAnchor, turnTop: turnTop)
            )
            let resolverTargetValue = AnchorResolver.restoreTargetFromBottomAnchor(
                anchor: originalBottomAnchor,
                turnTop: turnTop,
                contentHeight: contentHeight,
                viewportHeight: viewportHeight
            )
            #expect(resolverTargetValue != nil)
            guard let resolverTarget = resolverTargetValue else { return }
            let expectedOffset = min(
                max(0, resolverTarget),
                max(0, contentHeight - viewportHeight)
            )
            #expect(output.action == .maintainBottomEdge(targetOffset: expectedOffset))

            offset = apply(output.action, to: geometry)
            mode = output.mode
        }

        #expect(abs(offset - originalOffset) <= epsilon)
    }

    @Test("resizeReadingPreservesTurnIdentityAndPendingTurns")
    func resizeReadingPreservesTurnIdentityAndPendingTurns() {
        let runID = "run-identity"
        let pendingTurns: Set<String> = ["run-pending-1", "run-pending-2"]
        let contentHeight = 1_000.0
        let originalTurnTop = 350.0
        let initialGeometry = ScrollGeometry(viewportHeight: 200, contentHeight: contentHeight, offset: 300)
        let bottomAnchorValue = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: originalTurnTop,
            geometry: initialGeometry
        )
        #expect(bottomAnchorValue != nil)
        guard let bottomAnchor = bottomAnchorValue else { return }

        let originalTurnAnchor = TurnAnchor(
            runID: runID,
            relativeViewportOffset: (originalTurnTop - initialGeometry.offset) / initialGeometry.viewportHeight
        )
        var mode: ReadingMode = .reading(anchor: originalTurnAnchor, pendingTurns: pendingTurns)
        var offset = initialGeometry.offset

        let resizedHeight = 250.0
        let resizedTurnTop = 360.0
        let resizedGeometry = ScrollGeometry(
            viewportHeight: resizedHeight,
            contentHeight: contentHeight,
            offset: offset
        )
        let resized = machine.reduce(
            mode,
            .paneHeightChanged(geometry: resizedGeometry, anchor: bottomAnchor, turnTop: resizedTurnTop)
        )
        let expectedOffset = resizedTurnTop + bottomAnchor.bottomEdgeFromTurnTop - resizedHeight
        #expect(resized.action == .maintainBottomEdge(targetOffset: expectedOffset))

        offset = apply(resized.action, to: resizedGeometry)
        mode = resized.mode
        guard case let .reading(updatedTurnAnchor, updatedPendingTurns) = mode else {
            #expect(false, "Resize must preserve reading mode")
            return
        }
        #expect(updatedTurnAnchor.runID == runID)
        #expect(updatedPendingTurns == pendingTurns)
        #expect(abs(updatedTurnAnchor.relativeViewportOffset - (resizedTurnTop - offset) / resizedHeight) <= epsilon)

        let missingAnchorGeometry = ScrollGeometry(
            viewportHeight: resizedHeight,
            contentHeight: contentHeight,
            offset: offset
        )
        let missingAnchorOutput = machine.reduce(
            mode,
            .paneHeightChanged(geometry: missingAnchorGeometry, anchor: nil, turnTop: resizedTurnTop)
        )
        #expect(missingAnchorOutput.mode == mode)
        #expect(missingAnchorOutput.action == .restoreAnchor(updatedTurnAnchor))
        offset = apply(missingAnchorOutput.action, to: missingAnchorGeometry, restorationTurnTop: resizedTurnTop)
        mode = missingAnchorOutput.mode

        let missingTurnTopGeometry = ScrollGeometry(
            viewportHeight: 300,
            contentHeight: contentHeight,
            offset: offset
        )
        let missingTurnTopOutput = machine.reduce(
            mode,
            .paneHeightChanged(geometry: missingTurnTopGeometry, anchor: bottomAnchor, turnTop: nil)
        )
        #expect(missingTurnTopOutput.mode == mode)
        #expect(missingTurnTopOutput.action == .restoreAnchor(updatedTurnAnchor))
        offset = apply(missingTurnTopOutput.action, to: missingTurnTopGeometry, restorationTurnTop: 390)
        #expect(abs(offset - (390 - updatedTurnAnchor.relativeViewportOffset * 300)) <= epsilon)
    }

    @Test("resizeClampsAtScrollableBoundariesAndCanReturn")
    func resizeClampsAtScrollableBoundariesAndCanReturn() {
        let runID = "run-clamped"
        let pendingTurns: Set<String> = ["pending-after-clamp"]
        let contentHeight = 1_000.0
        let turnTop = 250.0
        let initialGeometry = ScrollGeometry(viewportHeight: 200, contentHeight: contentHeight, offset: 100)
        let initialOffset = initialGeometry.offset
        let bottomAnchorValue = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: turnTop,
            geometry: initialGeometry
        )
        #expect(bottomAnchorValue != nil)
        guard let originalBottomAnchor = bottomAnchorValue else { return }

        var mode: ReadingMode = .reading(
            anchor: TurnAnchor(runID: runID, relativeViewportOffset: (turnTop - initialOffset) / 200),
            pendingTurns: pendingTurns
        )
        var offset = initialOffset

        let tallViewportHeight = 350.0
        let tallGeometry = ScrollGeometry(
            viewportHeight: tallViewportHeight,
            contentHeight: contentHeight,
            offset: offset
        )
        let unclampedOffset = turnTop + originalBottomAnchor.bottomEdgeFromTurnTop - tallViewportHeight
        let appliedOffset = max(0, min(max(0, contentHeight - tallViewportHeight), unclampedOffset))
        #expect(unclampedOffset < 0)

        let clamped = machine.reduce(
            mode,
            .paneHeightChanged(geometry: tallGeometry, anchor: originalBottomAnchor, turnTop: turnTop)
        )
        #expect(clamped.action == .maintainBottomEdge(targetOffset: appliedOffset))
        offset = apply(clamped.action, to: tallGeometry)
        mode = clamped.mode
        #expect(offset == 0)

        guard case let .reading(clampedTurnAnchor, clampedPendingTurns) = mode else {
            #expect(false, "Clamping must preserve reading mode")
            return
        }
        let ratioFromAppliedOffset = (turnTop - offset) / tallViewportHeight
        let ratioFromUnclampedOffset = (turnTop - unclampedOffset) / tallViewportHeight
        #expect(clampedTurnAnchor.runID == runID)
        #expect(clampedPendingTurns == pendingTurns)
        #expect(abs(clampedTurnAnchor.relativeViewportOffset - ratioFromAppliedOffset) <= epsilon)
        #expect(abs(clampedTurnAnchor.relativeViewportOffset - ratioFromUnclampedOffset) > epsilon)

        let returnedGeometry = ScrollGeometry(viewportHeight: 200, contentHeight: contentHeight, offset: offset)
        let returned = machine.reduce(
            mode,
            .paneHeightChanged(geometry: returnedGeometry, anchor: originalBottomAnchor, turnTop: turnTop)
        )
        #expect(returned.action == .maintainBottomEdge(targetOffset: initialOffset))
        offset = apply(returned.action, to: returnedGeometry)
        #expect(abs(offset - initialOffset) <= epsilon)
    }

    @Test("resizeRejectsZeroNegativeAndNonFiniteGeometry")
    func resizeRejectsZeroNegativeAndNonFiniteGeometry() {
        let runID = "run-invalid-geometry"
        let validGeometry = ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: 100)
        let turnTop = 150.0
        let validBottomAnchor = BottomTurnAnchor(runID: runID, bottomEdgeFromTurnTop: 50)
        let readingMode: ReadingMode = .reading(
            anchor: TurnAnchor(runID: runID, relativeViewportOffset: 0.5),
            pendingTurns: ["pending-invalid"]
        )
        let invalidGeometries = [
            ScrollGeometry(viewportHeight: 0, contentHeight: 1_000, offset: 100),
            ScrollGeometry(viewportHeight: -1, contentHeight: 1_000, offset: 100),
            ScrollGeometry(viewportHeight: .infinity, contentHeight: 1_000, offset: 100),
            ScrollGeometry(viewportHeight: 100, contentHeight: .infinity, offset: 100),
            ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: .nan),
            ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: .infinity)
        ]

        for geometry in invalidGeometries {
            let followingOutput = machine.reduce(
                .followingBottom,
                .paneHeightChanged(geometry: geometry, anchor: nil, turnTop: nil)
            )
            #expect(followingOutput.mode == .followingBottom)
            #expect(followingOutput.action == .none)
            let followingOffset = apply(followingOutput.action, to: geometry)
            #expect(followingOffset.isNaN == geometry.offset.isNaN)
            if !geometry.offset.isNaN {
                #expect(followingOffset == geometry.offset)
            }

            let readingOutput = machine.reduce(
                readingMode,
                .paneHeightChanged(geometry: geometry, anchor: validBottomAnchor, turnTop: turnTop)
            )
            #expect(readingOutput.mode == readingMode)
            #expect(readingOutput.action == .none)
            let readingOffset = apply(readingOutput.action, to: geometry)
            #expect(readingOffset.isNaN == geometry.offset.isNaN)
            if !geometry.offset.isNaN {
                #expect(readingOffset == geometry.offset)
            }
        }

        let nonFiniteTopCapture = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: .infinity,
            geometry: validGeometry
        )
        let nonFiniteOffsetCapture = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: turnTop,
            geometry: ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: .nan)
        )
        let overflowingCapture = AnchorResolver.captureBottomAnchor(
            runID: runID,
            turnTop: -Double.greatestFiniteMagnitude,
            geometry: ScrollGeometry(
                viewportHeight: .greatestFiniteMagnitude,
                contentHeight: .greatestFiniteMagnitude,
                offset: .greatestFiniteMagnitude
            )
        )
        #expect(nonFiniteTopCapture == nil)
        #expect(nonFiniteOffsetCapture == nil)
        #expect(overflowingCapture == nil)

        let overflowingAnchor = BottomTurnAnchor(
            runID: runID,
            bottomEdgeFromTurnTop: .greatestFiniteMagnitude
        )
        let overflowingRestore = AnchorResolver.restoreTargetFromBottomAnchor(
            anchor: overflowingAnchor,
            turnTop: .greatestFiniteMagnitude,
            contentHeight: .greatestFiniteMagnitude,
            viewportHeight: 1
        )
        #expect(overflowingRestore == nil)

        let nonFiniteAnchorOutput = machine.reduce(
            readingMode,
            .paneHeightChanged(
                geometry: validGeometry,
                anchor: BottomTurnAnchor(runID: runID, bottomEdgeFromTurnTop: .infinity),
                turnTop: turnTop
            )
        )
        #expect(nonFiniteAnchorOutput.mode == readingMode)
        #expect(nonFiniteAnchorOutput.action == .none)
        #expect(apply(nonFiniteAnchorOutput.action, to: validGeometry) == validGeometry.offset)

        let overflowingGeometry = ScrollGeometry(
            viewportHeight: 1,
            contentHeight: .greatestFiniteMagnitude,
            offset: 0
        )
        let overflowingOutput = machine.reduce(
            readingMode,
            .paneHeightChanged(geometry: overflowingGeometry, anchor: overflowingAnchor, turnTop: .greatestFiniteMagnitude)
        )
        #expect(overflowingOutput.mode == readingMode)
        #expect(overflowingOutput.action == .none)
        #expect(apply(overflowingOutput.action, to: overflowingGeometry) == overflowingGeometry.offset)
    }

    @Test("contentGrowthWhileFollowingBottomKeepsEndVisible")
    func contentGrowthWhileFollowingBottomKeepsEndVisible() {
        var offset = 420.0
        var mode: ReadingMode = .followingBottom
        let resizeGeometries = [
            (viewportHeight: 220.0, contentHeight: 900.0),
            (viewportHeight: 180.0, contentHeight: 1_300.0),
            (viewportHeight: 300.0, contentHeight: 150.0)
        ]

        for size in resizeGeometries {
            let geometry = ScrollGeometry(
                viewportHeight: size.viewportHeight,
                contentHeight: size.contentHeight,
                offset: offset
            )
            let output = machine.reduce(
                mode,
                .paneHeightChanged(geometry: geometry, anchor: nil, turnTop: nil)
            )
            let expectedOffset = max(0, size.contentHeight - size.viewportHeight)
            #expect(output.mode == .followingBottom)
            #expect(output.action == .maintainBottomEdge(targetOffset: expectedOffset))

            offset = apply(output.action, to: geometry)
            mode = output.mode
            #expect(offset + size.viewportHeight + epsilon >= size.contentHeight)
            if size.contentHeight >= size.viewportHeight {
                #expect(abs(offset + size.viewportHeight - size.contentHeight) <= epsilon)
            } else {
                #expect(offset == 0)
            }
        }
    }

    @Test("nonResizeGeometryChangedRetainsExistingBehavior")
    func nonResizeGeometryChangedRetainsExistingBehavior() {
        let geometry = ScrollGeometry(viewportHeight: 100, contentHeight: 1_000, offset: 200)
        let following = machine.reduce(
            .followingBottom,
            .geometryChanged(geometry: geometry, anchor: nil)
        )
        #expect(following.mode == .followingBottom)
        #expect(following.action == .scrollToBottom)
        let followingOffset = apply(following.action, to: geometry)
        #expect(followingOffset == max(0, geometry.contentHeight - geometry.viewportHeight))

        let readingAnchor = TurnAnchor(runID: "run-reading", relativeViewportOffset: -0.25)
        let eventAnchor = TurnAnchor(runID: "event-anchor-is-ignored", relativeViewportOffset: 0.5)
        let pendingTurns: Set<String> = ["pending-a", "pending-b"]
        let readingMode = ReadingMode.reading(anchor: readingAnchor, pendingTurns: pendingTurns)
        let readingGeometry = ScrollGeometry(viewportHeight: 200, contentHeight: 1_000, offset: 250)
        let reading = machine.reduce(
            readingMode,
            .geometryChanged(geometry: readingGeometry, anchor: eventAnchor)
        )
        #expect(reading.mode == readingMode)
        #expect(reading.action == .restoreAnchor(readingAnchor))
        let readingOffset = apply(reading.action, to: readingGeometry, restorationTurnTop: 400)
        #expect(readingOffset == 450)
    }

    private func apply(
        _ action: ScrollAction,
        to geometry: ScrollGeometry,
        restorationTurnTop: Double? = nil
    ) -> Double {
        switch action {
        case .none:
            return geometry.offset
        case .scrollToBottom:
            return max(0, geometry.contentHeight - geometry.viewportHeight)
        case let .restoreAnchor(anchor):
            guard let restorationTurnTop,
                  let target = AnchorResolver.restoreTarget(
                    anchor: anchor,
                    turnTop: restorationTurnTop,
                    geometry: geometry
                  ) else {
                return geometry.offset
            }
            return target
        case let .maintainBottomEdge(targetOffset: targetOffset):
            return targetOffset
        }
    }
}
