import SwiftUI

/// Pinch and double-tap zoom for one manga page. A single tap calls `onTap`; a long press calls
/// `onLongPress` when there is one.
///
/// Dragging pans only while zoomed in; at normal size the drag is left to the enclosing
/// pager or scroll view so swiping between pages keeps working.
struct ZoomablePage<Content: View>: View {
    static var maximumScale: CGFloat { 4 }
    static var doubleTapScale: CGFloat { 2.5 }
    static var longPressDuration: Double { 0.5 }

    let onTap: () -> Void
    let onLongPress: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var size: CGSize = .zero

    var body: some View {
        content()
            .scaleEffect(scale)
            .offset(offset)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { size = $0 }
                }
            )
            .clipped()
            .contentShape(Rectangle())
            .gesture(taps, including: onLongPress == nil ? .all : .subviews)
            // A long press wins the touch outright, so lifting the finger after it is not also a
            // tap. (It fires while the finger is still down.)
            .gesture(
                LongPressGesture(minimumDuration: Self.longPressDuration)
                    .onEnded { _ in onLongPress?() }
                    .exclusively(before: taps),
                including: onLongPress == nil ? .subviews : .all
            )
            .simultaneousGesture(magnification)
            .gesture(pan, including: scale > 1 ? .all : .subviews)
            // Offsets and drags are in screen terms; keep them so in right-to-left readers.
            .environment(\.layoutDirection, .leftToRight)
            .onDisappear(perform: reset)
    }

    private var taps: some Gesture {
        TapGesture(count: 2)
            .onEnded { toggleZoom() }
            .exclusively(before: TapGesture().onEnded { onTap() })
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(committedScale * value, 1), Self.maximumScale)
                offset = Self.clamped(committedOffset, scale: scale, in: size)
            }
            .onEnded { _ in
                if scale <= 1 {
                    reset()
                } else {
                    committedScale = scale
                    committedOffset = offset
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = Self.clamped(
                    CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    ),
                    scale: scale,
                    in: size
                )
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if scale > 1 {
                reset()
            } else {
                scale = Self.doubleTapScale
                committedScale = scale
            }
        }
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }

    /// Keeps the zoomed page covering its frame: it can move at most as far as it overhangs.
    static func clamped(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max(size.width * (scale - 1) / 2, 0)
        let maxY = max(size.height * (scale - 1) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
