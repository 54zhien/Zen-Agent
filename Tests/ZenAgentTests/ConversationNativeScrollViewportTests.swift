import Testing
import UIKit
@testable import ZenAgent

@Suite("Divider commands use their measured native viewport", .serialized)
@MainActor
struct ConversationNativeScrollViewportTests {
    @Test(arguments: [CGFloat(0), CGFloat(62)])
    func finalResizeTargetWaitsForMatchingNativeBounds(topInset: CGFloat) {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 414))
        scroll.contentInsetAdjustmentBehavior = .never
        root.view.addSubview(scroll)
        scroll.contentSize = CGSize(width: 402, height: 2042)
        scroll.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 108, right: 0)
        scroll.contentOffset.y = 1736 - topInset
        let viewport = ConversationNativeScrollViewport()
        let owner = UIView()
        viewport.bind(scroll, owner: owner)
        let final = ScrollGeometry(viewportHeight: 283 - Double(topInset), contentHeight: 2042, offset: 1736)
        let target = 1759 + Double(topInset)
        #expect(!viewport.applyDividerOffset(target, geometry: final))
        #expect(scroll.contentOffset.y == 1736 - topInset)
        scroll.frame.size.height = 391
        #expect(viewport.applyDividerOffset(target, geometry: final))
        #expect(scroll.contentOffset.y == 1759)
        // The same logical target must still work after UIKit clamped an earlier
        // command; declarative value equality cannot stand in for native arrival.
        scroll.contentOffset.y = 1736 - topInset
        #expect(viewport.applyDividerOffset(target, geometry: final))
        #expect(scroll.contentOffset.y == 1759)
    }

    @Test func staleAnchorCannotDetachTheNewNativeOwner() {
        let viewport = ConversationNativeScrollViewport()
        let oldAnchor = UIView(), newAnchor = UIView()
        let oldScroll = UIScrollView(), newScroll = UIScrollView()
        viewport.bind(oldScroll, owner: oldAnchor)
        viewport.bind(newScroll, owner: newAnchor)
        viewport.unbind(owner: oldAnchor)
        #expect(viewport.scrollView === newScroll)
        viewport.unbind(owner: newAnchor)
        #expect(viewport.scrollView == nil)
    }

    @Test func detachedOrStaleContentCannotReceiveTheCommand() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 391))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.bottom = 108
        scroll.contentSize = CGSize(width: 402, height: 2042)
        scroll.contentOffset.y = 100
        let viewport = ConversationNativeScrollViewport()
        let owner = UIView()
        viewport.bind(scroll, owner: owner)
        let measured = ScrollGeometry(viewportHeight: 283, contentHeight: 2042, offset: 100)
        #expect(!viewport.applyDividerOffset(1759, geometry: measured))
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        root.view.addSubview(scroll)
        scroll.contentSize.height = 2000
        #expect(!viewport.applyDividerOffset(1759, geometry: measured))
        #expect(scroll.contentOffset.y == 100)
        scroll.contentSize.height = 2042
        let inconsistent = ScrollGeometry(viewportHeight: 282.6, contentHeight: 2042.4, offset: 100)
        #expect(!viewport.applyDividerOffset(1759.8, geometry: inconsistent))
        #expect(scroll.contentOffset.y == 100)
    }

    @Test(arguments: [false, true])
    func lateNativeLayoutRetriesOnlyTheCurrentLease(cancelled: Bool) async throws {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 414))
        scroll.contentInsetAdjustmentBehavior = .never
        root.view.addSubview(scroll)
        scroll.contentInset.bottom = 108
        scroll.contentSize = CGSize(width: 402, height: 2042)
        scroll.contentOffset.y = 1736
        let viewport = ConversationNativeScrollViewport()
        let owner = UIView()
        viewport.bind(scroll, owner: owner)
        var leaseIsCurrent = true
        var validations = 0
        viewport.restoreDividerOffset(1759,
            geometry: ScrollGeometry(viewportHeight: 283, contentHeight: 2042, offset: 1736),
            whileCurrent: { validations += 1; return leaseIsCurrent })
        #expect(scroll.contentOffset.y == 1736)
        let beforeTick = validations
        if cancelled { leaseIsCurrent = false }
        scroll.frame.size.height = 391
        // This test makes no second helper call: a real display tick must deliver
        // the command when UIKit catches up, or discard the cancelled lease.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (validations == beforeTick || (!cancelled && scroll.contentOffset.y != 1759)),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(validations > beforeTick, "The stimulus must include a real display tick")
        #expect(scroll.contentOffset.y == (cancelled ? 1736 : 1759))
        viewport.unbind(owner: owner)
    }
}
