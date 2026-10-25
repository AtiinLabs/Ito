import SwiftUI

struct MangaContinuousPageGeometry: Equatable {
    var contentFrame: CGRect?
    var viewportFrame: CGRect?
}

struct MangaContinuousGeometry: Equatable {
    var viewport: CGRect?
    var contentBounds: CGRect?
    var pages: [String: MangaContinuousPageGeometry] = [:]
}

struct MangaContinuousGeometryPreferenceKey: PreferenceKey {
    static var defaultValue = MangaContinuousGeometry()

    static func reduce(value: inout MangaContinuousGeometry, nextValue: () -> MangaContinuousGeometry) {
        let next = nextValue()
        if let viewport = next.viewport { value.viewport = viewport }
        if let contentBounds = next.contentBounds { value.contentBounds = contentBounds }
        value.pages.merge(next.pages) { old, new in
            MangaContinuousPageGeometry(
                contentFrame: new.contentFrame ?? old.contentFrame,
                viewportFrame: new.viewportFrame ?? old.viewportFrame
            )
        }
    }
}

struct MangaContinuousPageGeometryReporter: View {
    let pageID: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MangaContinuousGeometryPreferenceKey.self,
                value: MangaContinuousGeometry(
                    pages: [pageID: MangaContinuousPageGeometry(
                        contentFrame: proxy.frame(in: .named("manga.continuous.content")),
                        viewportFrame: proxy.frame(in: .named("manga.continuous.viewport"))
                    )]
                )
            )
        }
        .allowsHitTesting(false)
    }
}

struct MangaContinuousViewportReporter: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MangaContinuousGeometryPreferenceKey.self,
                value: MangaContinuousGeometry(
                    viewport: proxy.frame(in: .named("manga.continuous.viewport"))
                )
            )
        }
        .allowsHitTesting(false)
    }
}

struct MangaContinuousContentBoundsReporter: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MangaContinuousGeometryPreferenceKey.self,
                value: MangaContinuousGeometry(
                    contentBounds: proxy.frame(in: .named("manga.continuous.viewport"))
                )
            )
        }
        .allowsHitTesting(false)
    }
}

/// Tracks the geometric top page and corrects layout drift without mutating UIKit scroll state.
@MainActor
final class MangaContinuousScrollPositionCoordinator {
    private struct Sample {
        let geometry: MangaContinuousGeometry
        let visiblePageIDs: [String]
        let viewportSize: CGSize
    }

    private struct Restoration {
        let pageID: String
        /// The page's on-screen top to restore. Nil until the page is first observed when no
        /// pre-mutation sample showed it; the request's alignment then gives it.
        var viewportTop: CGFloat?
        let viewportSize: CGSize
        let mutation: MangaScrollRequest?
        let referenceContentFrame: CGRect?
        var direction: CGFloat?
        var closest: CGFloat?
        var retries = 0
        var acknowledged = false
        var request: MangaScrollRequest
    }

    /// How the target the view is driving has progressed.
    private struct TargetProgress {
        let id: UUID
        var closest: CGFloat?
        var sign: CGFloat?
        var retries = 0
    }

    /// Bounds corrections when native layout cannot reach the requested position.
    static let maximumTargetRetries = 8

    private var previousSample: Sample?
    private var latestGeometry: MangaContinuousGeometry?
    private var restoration: Restoration?
    private var targetProgress: TargetProgress?
    /// Signed on-screen motion of the leading page between the last two accepted samples whose
    /// layout did not change: the direction the reader is scrolling, or 0 when it is not.
    private var userMotion: CGFloat = 0

    /// What the view does when the view model publishes `target`: the scroll to perform, or nil
    /// when a content mutation must first let native layout settle. Never consumes an animated
    /// target: it stays authoritative until it arrives (see `handle`).
    func issue(_ target: MangaScrollRequest, viewModel: MangaReaderViewModel) -> MangaScrollRequest? {
        guard !target.waitsForLayout else { return nil }
        cancelRestoration()
        targetProgress = nil
        if !target.animated, isSettled(target) {
            viewModel.consumeScrollTarget(target)
            return nil
        }
        return target
    }

    /// What the view does after a geometry pass: the scroll to perform, if any. Consumes the
    /// pending target once it is settled, an animated one once the reader drives it away, and a
    /// jump that stops getting closer.
    func handle(_ geometry: MangaContinuousGeometry, viewModel: MangaReaderViewModel) -> MangaScrollRequest? {
        let correction = update(geometry, viewModel: viewModel)
        guard let target = viewModel.scrollTarget else {
            targetProgress = nil
            return correction
        }
        if isSettled(target) {
            viewModel.consumeScrollTarget(target)
            targetProgress = nil
            return nil
        }
        if target.waitsForLayout { return correction }
        var progress = targetProgress?.id == target.id ? targetProgress! : TargetProgress(id: target.id)
        let distance = Self.displacement(of: target, in: geometry)
        if target.animated {
            // The animation owns the scroll. It ends on arrival, on passing the target, or when
            // the reader moves it away from the target.
            if let distance {
                let sign: CGFloat = distance > 0 ? 1 : -1
                if let previousSign = progress.sign, previousSign != sign {
                    return finish(target, viewModel: viewModel)
                }
                if let closest = progress.closest, abs(distance) > closest + 1 {
                    return finish(target, viewModel: viewModel)
                }
                progress.sign = sign
                progress.closest = min(progress.closest ?? .infinity, abs(distance))
            }
            targetProgress = progress
            return nil
        }
        // A jump that has not settled is retried only while each retry gets it closer.
        if let distance, let closest = progress.closest, abs(distance) >= closest - 1 {
            return finish(target, viewModel: viewModel)
        }
        progress.retries += 1
        guard progress.retries <= Self.maximumTargetRetries else {
            return finish(target, viewModel: viewModel)
        }
        if let distance { progress.closest = abs(distance) }
        targetProgress = progress
        return correction ?? target
    }

    /// Ends a target the view is driving; the reader's own position decides the current page
    /// from the next geometry pass on.
    private func finish(_ target: MangaScrollRequest, viewModel: MangaReaderViewModel) -> MangaScrollRequest? {
        targetProgress = nil
        viewModel.consumeScrollTarget(target)
        return nil
    }

    func update(
        _ geometry: MangaContinuousGeometry,
        viewModel: MangaReaderViewModel
    ) -> MangaScrollRequest? {
        latestGeometry = geometry
        guard let viewport = geometry.viewport else { return nil }
        let visiblePages = geometry.pages.compactMap { id, page -> (String, CGRect)? in
            guard let frame = page.viewportFrame, Self.isVisible(frame, in: viewport) else { return nil }
            return (id, frame)
        }
        .sorted { $0.1.minY < $1.1.minY }
        let visiblePageIDs = visiblePages.map(\.0)
        let pendingTarget = viewModel.scrollTarget
        if let target = pendingTarget, target.waitsForLayout, restoration?.mutation != target {
            // Only an accepted sample from before the mutation is a baseline: this pass may
            // already show the changed layout.
            let reference = previousSample?.geometry.pages[target.pageID]
            let referenceViewport = previousSample?.geometry.viewport ?? viewport
            restoration = Restoration(
                pageID: target.pageID,
                viewportTop: reference?.viewportFrame.map { $0.minY - referenceViewport.minY },
                viewportSize: viewport.size,
                mutation: target,
                referenceContentFrame: reference?.contentFrame,
                request: target
            )
        }

        let sample = Sample(
            geometry: geometry,
            visiblePageIDs: visiblePageIDs,
            viewportSize: viewport.size
        )

        let ongoing = continueRestoration(in: geometry, viewport: viewport, viewModel: viewModel)
        let targetIsSettled = pendingTarget.map { isSettled($0) } ?? false
        let maySelectViewportPage = (pendingTarget == nil || targetIsSettled) && !ongoing.blocked
        let correction: MangaScrollRequest?
        if ongoing.completed || ongoing.blocked {
            correction = ongoing.request
        } else {
            correction = layoutDriftRequest(
                previous: previousSample,
                current: sample,
                viewport: viewport,
                hasPendingTarget: pendingTarget != nil
            )
        }
        if let correction, restoration == nil,
           let oldViewport = previousSample?.geometry.viewport,
           let oldFrame = previousSample?.geometry.pages[correction.pageID]?.viewportFrame,
           let currentFrame = geometry.pages[correction.pageID]?.viewportFrame {
            let desiredTop = oldFrame.minY - oldViewport.minY
            restoration = Restoration(
                pageID: correction.pageID,
                viewportTop: desiredTop,
                viewportSize: viewport.size,
                mutation: nil,
                referenceContentFrame: nil,
                direction: desiredTop > currentFrame.minY - viewport.minY ? 1 : -1,
                closest: abs(currentFrame.minY - viewport.minY - desiredTop),
                retries: 1,
                request: correction
            )
        }
        guard correction == nil, maySelectViewportPage else { return correction }
        // Corrected or suppressed observations are estimates, not a new restoration baseline.
        // Keep the last accepted viewport until the requested position is actually observed.
        defer {
            if !visiblePageIDs.isEmpty {
                recordUserMotion(from: previousSample, to: sample, viewport: viewport)
                previousSample = sample
            }
        }

        if previousSample?.visiblePageIDs != visiblePageIDs || targetIsSettled || ongoing.completed {
            viewModel.continuousViewportChanged(
                visiblePageIDs,
                preferredPageID: targetIsSettled ? pendingTarget?.pageID : nil
            )
        }
        // The alignment describes the logical current page, which mutations restore.
        let currentPageID = viewModel.flatPages.indices.contains(viewModel.continuousPageIndex)
            ? viewModel.flatPages[viewModel.continuousPageIndex].id
            : nil
        if let alignmentPage = visiblePages.first(where: { $0.0 == currentPageID }) {
            viewModel.updateContinuousScrollAlignment(
                Self.alignmentY(
                    viewportTop: alignmentPage.1.minY - viewport.minY,
                    pageHeight: alignmentPage.1.height,
                    viewportHeight: viewport.height
                )
            )
        }
        return nil
    }

    /// More than a sub-point sliver of the page is inside the viewport.
    static func isVisible(_ frame: CGRect, in viewport: CGRect) -> Bool {
        min(frame.maxY, viewport.maxY) - max(frame.minY, viewport.minY) > 1
    }

    private func recordUserMotion(from previous: Sample?, to current: Sample, viewport: CGRect) {
        guard let previous, previous.viewportSize == current.viewportSize,
              let previousViewport = previous.geometry.viewport,
              let leadID = current.visiblePageIDs.first(where: previous.visiblePageIDs.contains),
              let before = previous.geometry.pages[leadID], let after = current.geometry.pages[leadID],
              let beforeContent = before.contentFrame, let afterContent = after.contentFrame,
              let beforeFrame = before.viewportFrame, let afterFrame = after.viewportFrame else { return }
        // A layout change moves pages too; only a layout-stable pair shows the reader's scroll.
        guard abs(afterContent.minY - beforeContent.minY) <= 1 else { return }
        let delta = (afterFrame.minY - viewport.minY) - (beforeFrame.minY - previousViewport.minY)
        userMotion = abs(delta) > 1 ? delta : 0
    }

    private func continueRestoration(
        in geometry: MangaContinuousGeometry,
        viewport: CGRect,
        viewModel: MangaReaderViewModel
    ) -> (request: MangaScrollRequest?, completed: Bool, blocked: Bool) {
        guard var active = restoration else { return (nil, false, false) }
        if active.acknowledged {
            if viewModel.scrollTarget == active.mutation { return (nil, true, false) }
            restoration = nil
            return (nil, false, false)
        }
        guard viewModel.scrollTarget == active.mutation,
              viewport.size == active.viewportSize,
              viewModel.flatPages.contains(where: { $0.id == active.pageID }) else {
            abandonRestoration(active, viewModel: viewModel)
            return (nil, false, false)
        }
        guard let page = geometry.pages[active.pageID], let frame = page.viewportFrame else {
            guard active.retries < Self.maximumTargetRetries else {
                abandonRestoration(active, viewModel: viewModel)
                return (nil, false, false)
            }
            active.retries += 1
            restoration = active
            return (active.request, false, true)
        }
        // A mutation's first preference can still contain the entire pre-mutation layout.
        // Do not acknowledge it, or force a scroll before the changed layout is observed.
        if active.direction == nil, let reference = active.referenceContentFrame,
           page.contentFrame == reference {
            return (nil, false, true)
        }
        let desiredTop = active.viewportTop
            ?? active.request.alignmentY * (viewport.height - frame.height)
        active.viewportTop = desiredTop
        let displacement = frame.minY - viewport.minY - desiredTop
        active.request.alignmentY = Self.alignmentY(
            viewportTop: desiredTop,
            pageHeight: frame.height,
            viewportHeight: viewport.height
        )
        var crossed = active.direction.map { displacement * $0 >= -1 } ?? (abs(displacement) <= 1)
        if !crossed, active.direction == nil, userMotion * displacement > 0,
           abs(displacement) < viewport.height {
            // The first changed frame is already past the saved position in the direction the
            // reader was scrolling: momentum carried it there. Pulling it back would recoil.
            crossed = true
        }
        if crossed || Self.isSettled(active.request, in: geometry) {
            active.acknowledged = true
            restoration = active.mutation == nil ? nil : active
            return (nil, true, false)
        }
        // Once a correction starts, movement away is the reader's to keep, not a reason to
        // repeatedly pull back. Native estimates that never settle get a bounded attempt too.
        if let closest = active.closest, abs(displacement) > closest + 1 {
            abandonRestoration(active, viewModel: viewModel)
            return (nil, false, false)
        }
        guard active.retries < Self.maximumTargetRetries else {
            abandonRestoration(active, viewModel: viewModel)
            return (nil, false, false)
        }
        active.closest = min(active.closest ?? .infinity, abs(displacement))
        active.retries += 1
        if active.direction == nil { active.direction = displacement > 0 ? -1 : 1 }
        restoration = active
        return (active.request, false, true)
    }

    private func abandonRestoration(_ active: Restoration, viewModel: MangaReaderViewModel) {
        if let mutation = active.mutation { viewModel.consumeScrollTarget(mutation) }
        cancelRestoration()
    }

    func cancelRestoration() {
        restoration = nil
        previousSample = nil
        userMotion = 0
    }

    func isSettled(_ target: MangaScrollRequest) -> Bool {
        if target.waitsForLayout {
            return restoration?.mutation == target && restoration?.acknowledged == true
        }
        guard let latestGeometry else { return false }
        return Self.isSettled(target, in: latestGeometry)
    }

    /// How far the target page's top is from where the request puts it, or nil when the page is
    /// not laid out.
    static func displacement(of target: MangaScrollRequest, in geometry: MangaContinuousGeometry) -> CGFloat? {
        guard let viewport = geometry.viewport,
              let pageFrame = geometry.pages[target.pageID]?.viewportFrame else { return nil }
        return pageFrame.minY - (viewport.minY + target.alignmentY * (viewport.height - pageFrame.height))
    }

    static func isSettled(_ target: MangaScrollRequest, in geometry: MangaContinuousGeometry) -> Bool {
        guard let viewport = geometry.viewport,
              let pageFrame = geometry.pages[target.pageID]?.viewportFrame,
              let displacement = displacement(of: target, in: geometry) else { return false }
        if abs(displacement) <= 1 { return true }
        guard pageFrame.intersects(viewport),
              let contentBounds = geometry.contentBounds else { return false }
        if contentBounds.height <= viewport.height + 1 { return true }

        let atTopBoundary = abs(contentBounds.minY - viewport.minY) <= 1
        let atBottomBoundary = abs(contentBounds.maxY - viewport.maxY) <= 1
        return (atTopBoundary && displacement < 0) || (atBottomBoundary && displacement > 0)
    }

    /// How a page moved between two samples: in content space (layout above it) and on screen.
    private struct AnchorShift {
        let pageID: String
        let content: CGFloat
        let screen: CGFloat
        let previousTop: CGFloat
        let height: CGFloat

        /// The screen moved exactly as the layout did: no scrolling happened in between.
        var isLayoutOnly: Bool { abs(content) > 1 && abs(screen - content) <= 1 }
    }

    private func layoutDriftRequest(
        previous: Sample?,
        current: Sample,
        viewport: CGRect,
        hasPendingTarget: Bool
    ) -> MangaScrollRequest? {
        guard !hasPendingTarget,
              let previous,
              previous.viewportSize == current.viewportSize,
              let previousViewport = previous.geometry.viewport else { return nil }
        func shift(of id: String) -> AnchorShift? {
            guard let before = previous.geometry.pages[id], let after = current.geometry.pages[id],
                  let beforeContent = before.contentFrame, let afterContent = after.contentFrame,
                  let beforeFrame = before.viewportFrame, let afterFrame = after.viewportFrame else { return nil }
            let previousTop = beforeFrame.minY - previousViewport.minY
            return AnchorShift(
                pageID: id,
                content: afterContent.minY - beforeContent.minY,
                screen: afterFrame.minY - viewport.minY - previousTop,
                previousTop: previousTop,
                height: afterFrame.height
            )
        }
        // Anchor on a page the reader still sees. A page now off-screen qualifies only when
        // layout alone moved it there; one the reader scrolled away from is not an anchor.
        let anchor = previous.visiblePageIDs.lazy
            .filter(current.visiblePageIDs.contains)
            .compactMap(shift(of:))
            .first
            ?? previous.visiblePageIDs.lazy.compactMap(shift(of:)).first(where: \.isLayoutOnly)
        // Correct only drift the layout caused alone. The screen top is the content top plus the
        // scroll offset, so a frame that also scrolled (the reader's own motion, or native
        // anchoring compensating) is left alone rather than pulled against that motion.
        guard let anchor, anchor.isLayoutOnly else { return nil }

        let request = MangaScrollRequest(
            pageID: anchor.pageID,
            animated: false,
            alignmentY: Self.alignmentY(
                viewportTop: anchor.previousTop,
                pageHeight: anchor.height,
                viewportHeight: viewport.height
            )
        )
        return Self.isSettled(request, in: current.geometry) ? nil : request
    }

    /// Returns the normalized anchor that places the target's top at `viewportTop`.
    static func alignmentY(viewportTop: CGFloat, pageHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let availableTravel = viewportHeight - pageHeight
        guard abs(availableTravel) > 1 else { return 0 }
        // UnitPoint accepts out-of-bounds fractions. Clamping loses deep-page positions.
        return viewportTop / availableTravel
    }
}
