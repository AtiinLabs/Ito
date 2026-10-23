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
        let viewportTop: CGFloat
        let viewportSize: CGSize
        let mutation: MangaScrollRequest?
        let referenceContentFrame: CGRect?
        var direction: CGFloat?
        var acknowledged = false
        var request: MangaScrollRequest
    }

    private var previousSample: Sample?
    private var latestGeometry: MangaContinuousGeometry?
    private var restoration: Restoration?

    func update(
        _ geometry: MangaContinuousGeometry,
        viewModel: MangaReaderViewModel
    ) -> MangaScrollRequest? {
        latestGeometry = geometry
        guard let viewport = geometry.viewport else { return nil }
        let visiblePages = geometry.pages.compactMap { id, page -> (String, CGRect)? in
            guard let frame = page.viewportFrame, frame.intersects(viewport) else { return nil }
            return (id, frame)
        }
        .sorted { $0.1.minY < $1.1.minY }
        let visiblePageIDs = visiblePages.map(\.0)
        let pendingTarget = viewModel.scrollTarget
        if let target = pendingTarget, target.waitsForLayout, restoration?.mutation != target {
            let reference = previousSample?.geometry.pages[target.pageID] ?? geometry.pages[target.pageID]
            let top = reference?.viewportFrame.map { $0.minY - viewport.minY }
                ?? target.alignmentY * (viewport.height - (reference?.contentFrame?.height ?? 0))
            restoration = Restoration(
                pageID: target.pageID, viewportTop: top, viewportSize: viewport.size,
                mutation: target, referenceContentFrame: reference?.contentFrame, request: target
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
                request: correction
            )
        }
        guard correction == nil, maySelectViewportPage else { return correction }
        // Corrected or suppressed observations are estimates, not a new restoration baseline.
        // Keep the last accepted viewport until the requested position is actually observed.
        defer { if !visiblePageIDs.isEmpty { previousSample = sample } }

        let alignmentPage = targetIsSettled
            ? visiblePages.first { $0.0 == pendingTarget?.pageID } ?? visiblePages.first
            : visiblePages.first
        if let alignmentPage {
            viewModel.updateContinuousScrollAlignment(
                Self.alignmentY(
                    viewportTop: alignmentPage.1.minY - viewport.minY,
                    pageHeight: alignmentPage.1.height,
                    viewportHeight: viewport.height
                )
            )
        }
        if previousSample?.visiblePageIDs != visiblePageIDs || targetIsSettled || ongoing.completed {
            viewModel.continuousViewportChanged(
                visiblePageIDs,
                preferredPageID: targetIsSettled ? pendingTarget?.pageID : nil
            )
        }
        return nil
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
            if viewport.size != active.viewportSize, let mutation = active.mutation {
                viewModel.consumeScrollTarget(mutation)
            }
            restoration = nil
            previousSample = nil
            return (nil, false, false)
        }
        guard let page = geometry.pages[active.pageID], let frame = page.viewportFrame else {
            return (active.request, false, true)
        }
        // A mutation's first preference can still contain the entire pre-mutation layout.
        // Do not acknowledge it, or force a scroll before the changed layout is observed.
        if active.direction == nil, let reference = active.referenceContentFrame,
           page.contentFrame == reference {
            return (nil, false, true)
        }
        let displacement = frame.minY - viewport.minY - active.viewportTop
        active.request.alignmentY = Self.alignmentY(
            viewportTop: active.viewportTop,
            pageHeight: frame.height,
            viewportHeight: viewport.height
        )
        let crossed = active.direction.map { displacement * $0 >= -1 } ?? (abs(displacement) <= 1)
        if crossed || Self.isSettled(active.request, in: geometry) {
            active.acknowledged = true
            restoration = active.mutation == nil ? nil : active
            return (nil, true, false)
        }
        if active.direction == nil { active.direction = displacement > 0 ? -1 : 1 }
        restoration = active
        return (active.request, false, true)
    }

    func cancelRestoration() {
        restoration = nil
        previousSample = nil
    }

    func isSettled(_ target: MangaScrollRequest) -> Bool {
        if target.waitsForLayout {
            return restoration?.mutation == target && restoration?.acknowledged == true
        }
        guard let latestGeometry else { return false }
        return Self.isSettled(target, in: latestGeometry)
    }

    static func isSettled(_ target: MangaScrollRequest, in geometry: MangaContinuousGeometry) -> Bool {
        guard let viewport = geometry.viewport,
              let pageFrame = geometry.pages[target.pageID]?.viewportFrame else { return false }
        let expectedTop = viewport.minY + target.alignmentY * (viewport.height - pageFrame.height)
        let displacement = pageFrame.minY - expectedTop
        if abs(displacement) <= 1 { return true }
        guard pageFrame.intersects(viewport),
              let contentBounds = geometry.contentBounds else { return false }
        if contentBounds.height <= viewport.height + 1 { return true }

        let atTopBoundary = abs(contentBounds.minY - viewport.minY) <= 1
        let atBottomBoundary = abs(contentBounds.maxY - viewport.maxY) <= 1
        return (atTopBoundary && displacement < 0) || (atBottomBoundary && displacement > 0)
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
              let anchorID = previous.visiblePageIDs.first(where: { id in
                  current.geometry.pages[id]?.viewportFrame != nil
              }),
              let previousContentFrame = previous.geometry.pages[anchorID]?.contentFrame,
              let currentPage = current.geometry.pages[anchorID],
              let currentContentFrame = currentPage.contentFrame,
              let previousViewportFrame = previous.geometry.pages[anchorID]?.viewportFrame,
              abs(currentContentFrame.minY - previousContentFrame.minY) > 1,
              let currentViewportFrame = currentPage.viewportFrame,
              let previousViewport = previous.geometry.viewport else { return nil }
        let previousTop = previousViewportFrame.minY - previousViewport.minY
        let currentTop = currentViewportFrame.minY - viewport.minY
        guard abs(currentTop - previousTop) > 1 else { return nil }

        let request = MangaScrollRequest(
            pageID: anchorID,
            animated: false,
            alignmentY: Self.alignmentY(
                viewportTop: previousViewportFrame.minY - previousViewport.minY,
                pageHeight: currentViewportFrame.height,
                viewportHeight: viewport.height
            )
        )
        // LazyVStack can preserve the anchor itself. Reissuing scrollTo in that case
        // interrupts the reader's momentum without correcting any visible displacement.
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
