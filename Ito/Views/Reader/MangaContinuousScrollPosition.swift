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

    private var previousSample: Sample?
    private var latestGeometry: MangaContinuousGeometry?

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
        let targetIsSettled = pendingTarget.map { Self.isSettled($0, in: geometry) } ?? false
        let maySelectViewportPage = pendingTarget == nil || targetIsSettled

        let sample = Sample(
            geometry: geometry,
            visiblePageIDs: visiblePageIDs,
            viewportSize: viewport.size
        )
        defer { previousSample = sample }

        let correction = layoutDriftRequest(
            previous: previousSample,
            current: sample,
            viewport: viewport,
            hasPendingTarget: pendingTarget != nil
        )
        guard correction == nil, maySelectViewportPage else { return correction }

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
        if previousSample?.visiblePageIDs != visiblePageIDs || targetIsSettled {
            viewModel.continuousViewportChanged(
                visiblePageIDs,
                preferredPageID: targetIsSettled ? pendingTarget?.pageID : nil
            )
        }
        return nil
    }

    func isSettled(_ target: MangaScrollRequest) -> Bool {
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

        return MangaScrollRequest(
            pageID: anchorID,
            animated: false,
            alignmentY: Self.alignmentY(
                viewportTop: previousViewportFrame.minY - previousViewport.minY,
                pageHeight: currentViewportFrame.height,
                viewportHeight: viewport.height
            )
        )
    }

    /// Returns the normalized anchor that places the target's top at `viewportTop`.
    static func alignmentY(viewportTop: CGFloat, pageHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let availableTravel = viewportHeight - pageHeight
        guard abs(availableTravel) > 1 else { return 0 }
        return min(max(viewportTop / availableTravel, 0), 1)
    }
}
