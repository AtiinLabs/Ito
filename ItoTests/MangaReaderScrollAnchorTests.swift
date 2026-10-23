import SwiftUI
import UIKit
import XCTest
@testable import Ito

@MainActor
final class MangaReaderScrollAnchorTests: XCTestCase {
    func testDeepPagePositionIsRepresentableByScrollViewReader() async {
        let aligned = expectation(description: "Deep page position reached on screen")
        var requested = false
        var completed = false
        let host = UIHostingController(rootView: AnchorProbe { frame, proxy in
            if abs(frame.minY + 700) <= 1 {
                if !completed {
                    completed = true
                    aligned.fulfill()
                }
            } else if !requested, frame.height > 0 {
                requested = true
                let anchor = MangaContinuousScrollPositionCoordinator.alignmentY(
                    viewportTop: -700, pageHeight: 1_400, viewportHeight: 844
                )
                proxy.scrollTo("page", anchor: UnitPoint(x: 0.5, y: anchor))
            }
        })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [aligned], timeout: 5)
    }
}

private struct AnchorFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct AnchorProbe: View {
    let observe: (CGRect, ScrollViewProxy) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1_000)
                    Color.blue.frame(height: 1_400)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: AnchorFrameKey.self,
                                    value: geometry.frame(in: .named("anchor.viewport"))
                                )
                            }
                        }
                        .id("page")
                    Color.clear.frame(height: 1_000)
                }
            }
            .coordinateSpace(name: "anchor.viewport")
            .frame(width: 390, height: 844)
            .onPreferenceChange(AnchorFrameKey.self) { observe($0, proxy) }
        }
        .ignoresSafeArea()
    }
}
