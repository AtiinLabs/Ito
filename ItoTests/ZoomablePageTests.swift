import UIKit
import XCTest
@testable import Ito

@MainActor
final class ZoomablePageTests: XCTestCase {
    func testPortraitImageFitsAndCentersWithoutStretching() {
        let (window, controller) = mount(image: image(size: CGSize(width: 200, height: 800)))
        defer { window.isHidden = true }

        XCTAssertEqual(controller.imageView.bounds.size, CGSize(width: 100, height: 400))
        XCTAssertEqual(controller.imageView.frame, CGRect(x: 100, y: 0, width: 100, height: 400))
        XCTAssertEqual(controller.scrollView.minimumZoomScale, 1)
        XCTAssertEqual(controller.scrollView.maximumZoomScale, 4)
    }

    func testLandscapeImageRemainsCenteredOnItsShortAxisWhenZoomed() {
        let (window, controller) = mount(image: image(size: CGSize(width: 600, height: 200)))
        defer { window.isHidden = true }
        XCTAssertEqual(controller.imageView.frame, CGRect(x: 0, y: 150, width: 300, height: 100))

        controller.scrollView.setZoomScale(2.5, animated: false)

        XCTAssertEqual(controller.imageView.frame.midY, 200, accuracy: 0.001)
        XCTAssertEqual(controller.imageView.frame.width, 750, accuracy: 0.001)
        XCTAssertEqual(controller.imageView.frame.height, 250, accuracy: 0.001)
    }

    func testOrdinaryUpdatePreservesImageIdentityZoomAndPanButRefreshesActivation() {
        let original = image(size: CGSize(width: 300, height: 400))
        let (window, controller) = mount(image: original)
        defer { window.isHidden = true }
        controller.scrollView.setZoomScale(2.5, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 90, y: 120)
        var activations = 0

        controller.update(image: original, onTap: { activations += 1 }, imageLabel: "Updated page")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.scrollView.zoomScale, 2.5, accuracy: 0.001)
        XCTAssertEqual(controller.scrollView.contentOffset, CGPoint(x: 90, y: 120))
        XCTAssertEqual(controller.imageView.accessibilityLabel, "Updated page")
        XCTAssertTrue(controller.imageView.accessibilityActivate())
        XCTAssertEqual(activations, 1)
    }

    func testDifferentImageIdentityResetsZoomAndOffsetEvenForEqualDimensions() {
        let (window, controller) = mount(image: image(size: CGSize(width: 300, height: 400)))
        defer { window.isHidden = true }
        controller.scrollView.setZoomScale(3, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 100, y: 150)
        let replacement = image(size: CGSize(width: 300, height: 400))

        controller.update(image: replacement, onTap: {}, imageLabel: "Next page")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.scrollView.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(controller.scrollView.contentOffset, .zero)
        XCTAssertEqual(controller.imageView.frame, CGRect(x: 0, y: 0, width: 300, height: 400))
    }

    func testNativeDoubleTapKeepsPhysicalOffCenterPointAndResetsOnSecondTap() {
        let (window, controller) = mount(image: image(size: CGSize(width: 300, height: 400)))
        defer { window.isHidden = true }
        controller.scrollView.semanticContentAttribute = .forceRightToLeft
        let point = CGPoint(x: 90, y: 260)
        let contentPoint = controller.imageView.convert(point, from: controller.scrollView)

        controller.zoom(at: point, animated: false)

        XCTAssertEqual(controller.scrollView.zoomScale, 2.5, accuracy: 0.001)
        let projected = controller.imageView.convert(contentPoint, to: controller.scrollView)
        XCTAssertEqual(projected.x - controller.scrollView.bounds.minX, point.x, accuracy: 0.001)
        XCTAssertEqual(projected.y - controller.scrollView.bounds.minY, point.y, accuracy: 0.001)
        controller.zoom(at: projected, animated: false)
        XCTAssertEqual(controller.scrollView.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(controller.scrollView.contentOffset, .zero)
    }

    func testDoubleTapInLetterboxUsesNativeClampingAndCentering() {
        let (window, controller) = mount(image: image(size: CGSize(width: 600, height: 200)))
        defer { window.isHidden = true }

        controller.zoom(at: CGPoint(x: 150, y: 20), animated: false)

        XCTAssertEqual(controller.scrollView.zoomScale, 2.5, accuracy: 0.001)
        XCTAssertEqual(controller.imageView.frame.midY, 200, accuracy: 0.001)
        XCTAssertEqual(controller.scrollView.contentOffset.y, 0, accuracy: 0.001)
    }

    func testViewportResizePreservesMagnificationAndImageCenterAnchor() {
        let (window, controller) = mount(image: image(size: CGSize(width: 300, height: 400)))
        defer { window.isHidden = true }
        controller.scrollView.setZoomScale(2.5, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 150, y: 200)
        let before = centerFraction(controller)

        controller.view.frame.size = CGSize(width: 400, height: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let after = centerFraction(controller)
        XCTAssertEqual(controller.scrollView.zoomScale, 2.5, accuracy: 0.001)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    func testPagePanIsRejectedAtMinimumZoomAndAcceptedWhenZoomed() {
        let (window, controller) = mount(image: image(size: CGSize(width: 300, height: 400)))
        defer { window.isHidden = true }

        XCTAssertFalse(controller.scrollView.gestureRecognizerShouldBegin(controller.scrollView.panGestureRecognizer))
        controller.scrollView.setZoomScale(2.5, animated: false)
        XCTAssertTrue(controller.scrollView.gestureRecognizerShouldBegin(controller.scrollView.panGestureRecognizer))
        controller.scrollView.setZoomScale(1, animated: false)
        XCTAssertFalse(controller.scrollView.gestureRecognizerShouldBegin(controller.scrollView.panGestureRecognizer))
    }

    func testRetargetingAnInFlightNativeZoomToResetSettlesTheModelAtMinimum() throws {
        let (window, controller) = try mountInKeyWindow(image: image(size: CGSize(width: 300, height: 400)))
        defer { window.isHidden = true }

        controller.zoom(at: CGPoint(x: 100, y: 160), animated: true)
        // The zoom-in is in flight: its animation is attached and the model already reports the target scale.
        XCTAssertFalse(controller.imageView.layer.animationKeys()?.isEmpty ?? true)
        XCTAssertGreaterThan(controller.scrollView.zoomScale, 1.001)
        controller.zoom(
            at: CGPoint(x: controller.scrollView.bounds.midX, y: controller.scrollView.bounds.midY),
            animated: true
        )
        // The retarget decision is synchronous: the model is at the minimum before any frame renders.
        XCTAssertEqual(controller.scrollView.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(controller.scrollView.contentOffset, .zero)
        XCTAssertEqual(controller.imageView.frame, CGRect(x: 0, y: 0, width: 300, height: 400))
        // A delegate report after the retarget centres the page on that minimum, not on the replaced scale.
        controller.scrollViewDidZoom(controller.scrollView)
        XCTAssertEqual(controller.imageView.center, CGPoint(x: 150, y: 200))
    }

    private func centerFraction(_ controller: NativeReaderImageZoomController) -> CGPoint {
        let bounds = controller.scrollView.bounds
        let point = controller.imageView.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: controller.scrollView)
        return CGPoint(
            x: point.x / controller.imageView.bounds.width,
            y: point.y / controller.imageView.bounds.height
        )
    }

    private func image(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func mount(image: UIImage) -> (UIWindow, NativeReaderImageZoomController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let controller = NativeReaderImageZoomController()
        controller.update(image: image, onTap: {}, imageLabel: "Page")
        root.addChild(controller)
        root.view.addSubview(controller.view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        controller.didMove(toParent: root)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    /// Hosts the page in a key window of the app's scene, the environment the native zoom runs in.
    private func mountInKeyWindow(image: UIImage) throws -> (UIWindow, NativeReaderImageZoomController) {
        let (unrenderedWindow, controller) = mount(image: image)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = unrenderedWindow.frame
        let root = unrenderedWindow.rootViewController
        unrenderedWindow.rootViewController = nil
        unrenderedWindow.isHidden = true
        window.rootViewController = root
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }
}
