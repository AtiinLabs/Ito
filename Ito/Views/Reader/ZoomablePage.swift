import SwiftUI
import UIKit

/// A page-local transform. The surrounding reader keeps its original page layout.
nonisolated struct ReaderPageZoom: Equatable {
    static let maximumScale: CGFloat = 4
    static let doubleTapScale: CGFloat = 2.5

    var scale: CGFloat = 1
    var offset: CGSize = .zero

    func doubleTapped(at point: CGPoint, in size: CGSize) -> Self {
        guard scale == 1 else { return Self() }
        return Self(scale: Self.doubleTapScale, offset: Self.zoomOffset(around: point, scale: Self.doubleTapScale, in: size))
    }

    func pinched(
        from startPoint: CGPoint,
        to point: CGPoint,
        magnification: CGFloat,
        in size: CGSize
    ) -> Self {
        let nextScale = min(max(scale * magnification, 1), Self.maximumScale)
        let ratio = nextScale / scale
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return Self(
            scale: nextScale,
            offset: Self.clamped(
                CGSize(
                    width: point.x - center.x - ratio * (startPoint.x - center.x - offset.width),
                    height: point.y - center.y - ratio * (startPoint.y - center.y - offset.height)
                ),
                scale: nextScale,
                in: size
            )
        )
    }

    /// Counteracts center-based scaling so a double tap stays at its visible position.
    static func zoomOffset(around point: CGPoint, scale: CGFloat, in size: CGSize) -> CGSize {
        clamped(
            CGSize(
                width: (size.width / 2 - point.x) * (scale - 1),
                height: (size.height / 2 - point.y) * (scale - 1)
            ),
            scale: scale,
            in: size
        )
    }

    /// Keeps the page covering its original frame, without revealing space outside it.
    static func clamped(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max(size.width * (scale - 1) / 2, 0)
        let maxY = max(size.height * (scale - 1) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}

/// Pinch and double-tap zoom for one page. At normal size, drags belong to the reader.
struct ZoomablePage<Content: View>: View {
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var zoom = ReaderPageZoom()
    @State private var size: CGSize = .zero

    var body: some View {
        content()
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) {
                            size = $0
                            zoom = ReaderPageZoom()
                        }
                }
            )
            .clipped()
            .contentShape(Rectangle())
            .overlay(PageGestureSurface(zoom: $zoom, size: size, onTap: onTap))
            .accessibilityAction { onTap() }
            // Gesture locations and offsets are physical page coordinates, also in RTL readers.
            .environment(\.layoutDirection, .leftToRight)
            .onDisappear { zoom = ReaderPageZoom() }
    }
}

/// A pinch may span adjacent page surfaces; only the last owner restores a parent pan.
@MainActor
final class ReaderParentPanSuspension {
    private struct Entry {
        let recognizer: UIPanGestureRecognizer
        let wasEnabled: Bool
        var count: Int
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private var keys: [ObjectIdentifier] = []

    init(_ recognizers: [UIPanGestureRecognizer]) {
        for recognizer in recognizers {
            let key = ObjectIdentifier(recognizer)
            guard !keys.contains(key) else { continue }
            keys.append(key)
            if var entry = Self.entries[key] {
                entry.count += 1
                Self.entries[key] = entry
            } else {
                Self.entries[key] = Entry(recognizer: recognizer, wasEnabled: recognizer.isEnabled, count: 1)
                recognizer.isEnabled = false
            }
        }
    }

    func release() {
        let acquired = keys
        keys.removeAll()
        for key in acquired {
            guard var entry = Self.entries[key] else { continue }
            entry.count -= 1
            if entry.count == 0 {
                Self.entries.removeValue(forKey: key)
                entry.recognizer.isEnabled = entry.wasEnabled
            } else {
                Self.entries[key] = entry
            }
        }
    }
}

@MainActor
private struct PageGestureSurface: UIViewRepresentable {
    @Binding var zoom: ReaderPageZoom
    let size: CGSize
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom, size: size, onTap: onTap)
    }

    func makeUIView(context: Context) -> GestureView {
        let view = GestureView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = true
        view.accessibilityElementsHidden = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: GestureView, context: Context) {
        context.coordinator.update(zoom: $zoom, size: size, onTap: onTap)
    }

    static func dismantleUIView(_ view: GestureView, coordinator: Coordinator) {
        coordinator.invalidate()
        view.onDetach = nil
    }

    final class GestureView: UIView {
        var onDetach: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { onDetach?() }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private struct PanStart {
            let zoom: ReaderPageZoom
            let size: CGSize
        }

        private struct PinchStart {
            let zoom: ReaderPageZoom
            let point: CGPoint
            let magnification: CGFloat
            let size: CGSize
        }

        private enum Session {
            case idle
            case panning(PanStart)
            case takingPinch
            case pinching(PinchStart)
        }

        private var zoom: Binding<ReaderPageZoom>
        private var size: CGSize
        private var onTap: () -> Void
        private weak var view: GestureView?
        private var session: Session = .idle
        private var parentSuspension: ReaderParentPanSuspension?
        private let singleTap = UITapGestureRecognizer()
        private let doubleTap = UITapGestureRecognizer()
        private let pan = UIPanGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()

        init(zoom: Binding<ReaderPageZoom>, size: CGSize, onTap: @escaping () -> Void) {
            self.zoom = zoom
            self.size = size
            self.onTap = onTap
            super.init()
            singleTap.addTarget(self, action: #selector(singleTapped))
            doubleTap.addTarget(self, action: #selector(doubleTapped))
            doubleTap.numberOfTapsRequired = 2
            singleTap.require(toFail: doubleTap)
            singleTap.cancelsTouchesInView = false
            doubleTap.cancelsTouchesInView = false
            pan.maximumNumberOfTouches = 1
            pan.addTarget(self, action: #selector(panned))
            pinch.addTarget(self, action: #selector(pinched))
            pan.delegate = self
            pinch.delegate = self
        }

        func install(on view: GestureView) {
            self.view = view
            view.addGestureRecognizer(singleTap)
            view.addGestureRecognizer(doubleTap)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            view.onDetach = { [weak self] in self?.invalidate() }
        }

        func update(zoom: Binding<ReaderPageZoom>, size: CGSize, onTap: @escaping () -> Void) {
            self.zoom = zoom
            self.onTap = onTap
            if self.size != size {
                invalidate()
                self.size = size
            }
        }

        func invalidate() {
            // Invalidate ownership first: disabling a recognizer can synchronously cancel it.
            session = .idle
            parentSuspension?.release()
            parentSuspension = nil
            pan.isEnabled = false
            pinch.isEnabled = false
            pan.isEnabled = true
            pinch.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer === pan {
                guard case .idle = session else { return false }
                return zoom.wrappedValue.scale > 1
            }
            return true
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            recognizer === pan && isAncestorPan(other)
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            recognizer === pinch && (other === pan || isAncestorPan(other))
        }

        private func isAncestorPan(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let view, let scroll = recognizer.view as? UIScrollView else { return false }
            return recognizer === scroll.panGestureRecognizer && view.isDescendant(of: scroll)
        }

        private func ancestorPans() -> [UIPanGestureRecognizer] {
            var result: [UIPanGestureRecognizer] = []
            var parent = view?.superview
            while let current = parent {
                if let scroll = current as? UIScrollView { result.append(scroll.panGestureRecognizer) }
                parent = current.superview
            }
            return result
        }

        @objc private func singleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, case .idle = session else { return }
            onTap()
        }

        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, case .idle = session, let view else { return }
            // Immediate transforms can be safely snapshotted by a pinch on the next touch.
            zoom.wrappedValue = zoom.wrappedValue.doubleTapped(at: recognizer.location(in: view), in: view.bounds.size)
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            switch recognizer.state {
            case .began:
                guard case .idle = session else { return }
                session = .panning(PanStart(zoom: zoom.wrappedValue, size: view.bounds.size))
                updatePan(recognizer)
            case .changed:
                updatePan(recognizer)
            case .ended:
                updatePan(recognizer)
                if case .panning = session { session = .idle }
            case .cancelled, .failed:
                if case .panning = session { session = .idle }
            default:
                break
            }
        }

        private func updatePan(_ recognizer: UIPanGestureRecognizer) {
            guard case .panning(let start) = session, let view else { return }
            guard start.size == view.bounds.size else { invalidate(); return }
            let translation = recognizer.translation(in: view)
            zoom.wrappedValue = ReaderPageZoom(
                scale: start.zoom.scale,
                offset: ReaderPageZoom.clamped(
                    CGSize(width: start.zoom.offset.width + translation.x, height: start.zoom.offset.height + translation.y),
                    scale: start.zoom.scale,
                    in: start.size
                )
            )
        }

        @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch recognizer.state {
            case .began:
                session = .takingPinch
                pan.isEnabled = false
                parentSuspension = ReaderParentPanSuspension(ancestorPans())
                guard case .takingPinch = session, view.window != nil else {
                    parentSuspension?.release()
                    parentSuspension = nil
                    return
                }
                session = .pinching(PinchStart(
                    zoom: zoom.wrappedValue,
                    point: recognizer.location(in: view),
                    magnification: recognizer.scale,
                    size: view.bounds.size
                ))
            case .changed:
                guard case .pinching(let start) = session, recognizer.numberOfTouches >= 2 else { return }
                guard start.size == view.bounds.size else { invalidate(); return }
                zoom.wrappedValue = start.zoom.pinched(
                    from: start.point,
                    to: recognizer.location(in: view),
                    magnification: recognizer.scale / start.magnification,
                    in: start.size
                )
            case .ended, .cancelled, .failed:
                // A lifted finger changes the centroid; retain the last valid two-touch state.
                if case .panning = session { return }
                session = .idle
                parentSuspension?.release()
                parentSuspension = nil
                pan.isEnabled = true
            default:
                break
            }
        }
    }
}
