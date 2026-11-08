import SwiftUI
import UIKit

/// A page keeps its native scroll and zoom state across ordinary SwiftUI updates.
struct NativeReaderImageZoom: UIViewControllerRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let imageLabel: String

    func makeUIViewController(context: Context) -> NativeReaderImageZoomController {
        let controller = NativeReaderImageZoomController()
        controller.update(image: image, onTap: onTap, imageLabel: imageLabel)
        return controller
    }

    func updateUIViewController(_ controller: NativeReaderImageZoomController, context: Context) {
        controller.update(image: image, onTap: onTap, imageLabel: imageLabel)
    }
}

/// Lets UIKit arbitrate nested reader pans without permanent recognizer dependencies.
/// At minimum zoom the page's pan does not begin, so ordinary swipes remain available
/// to an enclosing pager; once zoomed, the page handles its own pan normally.
final class ReaderImageScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           panGestureRecognizer.numberOfTouches < 2,
           zoomScale <= minimumZoomScale,
           !isZooming {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

final class NativeReaderImageZoomController: UIViewController, UIScrollViewDelegate {
    let scrollView = ReaderImageScrollView()
    let imageView = ReaderImageAccessibilityView()
    let singleTap = UITapGestureRecognizer()
    let doubleTap = UITapGestureRecognizer()
    private var viewportSize: CGSize = .zero
    private var onTap: () -> Void = {}
    private var layingOutImage = false

    override func loadView() {
        view = scrollView
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = ReaderZoomGeometry.maximumScale
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        // UIKit gesture locations remain physical coordinates in either reading direction.
        scrollView.semanticContentAttribute = .forceLeftToRight
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        singleTap.addTarget(self, action: #selector(singleTapped))
        doubleTap.addTarget(self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        scrollView.addGestureRecognizer(doubleTap)
        imageView.onActivate = { [weak self] in self?.onTap() }
    }

    func update(image: UIImage, onTap: @escaping () -> Void, imageLabel: String) {
        loadViewIfNeeded()
        self.onTap = onTap
        imageView.accessibilityLabel = imageLabel
        guard imageView.image !== image else { return }
        // A different decoded image is a different page, not a continuation of a zoom.
        scrollView.setZoomScale(1, animated: false)
        imageView.image = image
        viewportSize = .zero
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0, imageView.image != nil else { return }
        guard viewportSize != size else {
            centerImage()
            return
        }
        layoutImage(in: size)
    }

    private func layoutImage(in size: CGSize) {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let oldSize = imageView.bounds.size
        let oldCenter = imageView.convert(
            CGPoint(
                x: scrollView.bounds.minX + viewportSize.width / 2,
                y: scrollView.bounds.minY + viewportSize.height / 2
            ),
            from: scrollView
        )
        let fraction = CGPoint(
            x: oldSize.width > 0 ? oldCenter.x / oldSize.width : 0.5,
            y: oldSize.height > 0 ? oldCenter.y / oldSize.height : 0.5
        )
        let scale = viewportSize == .zero ? 1 : scrollView.zoomScale
        layingOutImage = true
        scrollView.setZoomScale(1, animated: false)
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        let fittedSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.bounds = CGRect(origin: .zero, size: fittedSize)
        imageView.center = CGPoint(x: fittedSize.width / 2, y: fittedSize.height / 2)
        scrollView.contentSize = fittedSize
        viewportSize = size
        scrollView.setZoomScale(scale, animated: false)
        layingOutImage = false
        centerImage()
        let focus = CGPoint(x: fraction.x * fittedSize.width, y: fraction.y * fittedSize.height)
        let converted = imageView.convert(focus, to: scrollView)
        let maximum = CGPoint(
            x: max(0, scrollView.contentSize.width - size.width),
            y: max(0, scrollView.contentSize.height - size.height)
        )
        scrollView.contentOffset = CGPoint(
            x: min(max(0, converted.x - size.width / 2), maximum.x),
            y: min(max(0, converted.y - size.height / 2), maximum.y)
        )
    }

    private func centerImage() {
        guard !layingOutImage else { return }
        imageView.center = CGPoint(
            x: max(scrollView.bounds.width, imageView.bounds.width * scrollView.zoomScale) / 2,
            y: max(scrollView.bounds.height, imageView.bounds.height * scrollView.zoomScale) / 2
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    @objc private func singleTapped() { onTap() }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        zoom(at: recognizer.location(in: scrollView), animated: true)
    }

    /// The input is in scroll-view bounds coordinates, including its current bounds origin.
    func zoom(at point: CGPoint, animated: Bool) {
        guard viewportSize != .zero else { return }
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        } else {
            let contentPoint = imageView.convert(point, from: scrollView)
            let viewportPoint = CGPoint(
                x: point.x - scrollView.bounds.minX,
                y: point.y - scrollView.bounds.minY
            )
            scrollView.zoom(
                to: ReaderZoomGeometry.targetRect(
                    contentPoint: contentPoint,
                    viewportPoint: viewportPoint,
                    viewportSize: scrollView.bounds.size,
                    scale: ReaderZoomGeometry.doubleTapScale
                ),
                animated: animated
            )
        }
    }
}

final class ReaderImageAccessibilityView: UIImageView {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}
