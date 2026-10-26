import ImageIO
import SwiftUI
import UIKit

/// Word lookup for one page shown by `MangaImage`.
struct MangaPageWordLookup {
    let pageID: String
    let model: MangaWordLookupViewModel
}

/// A zoomable page where a long press outlines the words on it and a tapped word opens the
/// dictionary. The outlines sit inside the zoomed content, so they follow pinch and pan.
struct MangaWordLookupPage: View {
    let image: Image
    let platformImage: UIImage?
    let imageLabel: String
    let pageID: String
    let onTap: () -> Void
    @ObservedObject var lookup: MangaWordLookupViewModel

    var body: some View {
        let phase = lookup.phase(on: pageID)
        // The long press stays attached while words are outlined (changing it mid-touch would
        // free the tap the press already claimed); the word buttons take precedence over it.
        ZoomablePage(onTap: onTap, onLongPress: beginLookup) {
            image
                .resizable()
                .scaledToFit()
                .accessibilityLabel(imageLabel)
                .accessibilityHint(phase == nil ? "Long-press to look up its words." : "")
                .overlay {
                    if let phase {
                        MangaPageWordOverlay(
                            phase: phase,
                            lookUp: { lookup.lookUp($0) },
                            end: { lookup.end() }
                        )
                    }
                }
        }
    }

    /// Starts reading the page; a press while the page is already in lookup does nothing.
    private var beginLookup: (() -> Void)? {
        guard let platformImage, let cgImage = platformImage.cgImage else { return nil }
        let orientation = CGImagePropertyOrientation(platformImage.imageOrientation)
        return { [lookup, pageID] in
            guard lookup.phase(on: pageID) == nil else { return }
            lookup.begin(pageID: pageID, image: cgImage, orientation: orientation)
        }
    }
}

/// Lookup drawn over a page: outlines on its words, or what reading the page found.
private struct MangaPageWordOverlay: View {
    let phase: MangaWordLookupViewModel.Phase
    let lookUp: (RecognizedWord) -> Void
    let end: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // A tap beside the words leaves lookup instead of toggling the reader controls.
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: end)
                    .accessibilityHidden(true)

                switch phase {
                case .reading:
                    status("Reading page…", showsProgress: true, in: proxy.size)
                case .words(let words):
                    ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                        wordButton(word, in: proxy.size)
                    }
                case .noWords:
                    status("No English text found on this page", showsProgress: false, in: proxy.size)
                case .failed:
                    status("Couldn't read this page", showsProgress: false, in: proxy.size)
                }
            }
        }
    }

    private func wordButton(_ word: RecognizedWord, in size: CGSize) -> some View {
        let frame = CGRect(
            x: word.bounds.minX * size.width,
            y: word.bounds.minY * size.height,
            width: word.bounds.width * size.width,
            height: word.bounds.height * size.height
        )
        return Button { lookUp(word) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1.5))
                // Comic lettering is small; give each word a little more room to hit.
                .padding(-3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel(word.text)
        .accessibilityHint("Looks up the word in the dictionary.")
        .accessibilityIdentifier("manga-lookup-word")
    }

    private func status(_ text: String, showsProgress: Bool, in size: CGSize) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().tint(.white)
            }
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("manga-lookup-status")
        .position(x: size.width / 2, y: size.height / 2)
        .allowsHitTesting(false)
    }
}

/// Presents the system dictionary as a UIKit modal, reporting its Close action or interactive
/// dismissal back to the lookup model so another word can be selected.
struct MangaWordLookupDictionaryPresenter: View {
    @ObservedObject var lookup: MangaWordLookupViewModel

    var body: some View {
        DictionaryPresentationAnchor(lookup: lookup.lookup) { [lookup] in
            lookup.finishLookup()
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct DictionaryPresentationAnchor: UIViewControllerRepresentable {
    let lookup: MangaWordLookupViewModel.Lookup?
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AnchorViewController {
        AnchorViewController()
    }

    func updateUIViewController(_ anchor: AnchorViewController, context: Context) {
        anchor.onDismiss = onDismiss
        anchor.show(lookup)
    }

    final class AnchorViewController: UIViewController {
        var onDismiss: () -> Void = {}
        private weak var shown: DictionaryViewController?
        private var shownID: UUID?

        /// Shows `lookup`'s entry, or closes the one shown when lookup has ended.
        func show(_ lookup: MangaWordLookupViewModel.Lookup?) {
            guard let lookup else {
                if let shown, !shown.isBeingDismissed {
                    shown.dismiss(animated: true)
                }
                return
            }
            guard lookup.id != shownID, view.window != nil else { return }
            shownID = lookup.id
            let dictionary = DictionaryViewController(term: lookup.term)
            dictionary.onDismiss = { [weak self] in
                self?.shownID = nil
                self?.onDismiss()
            }
            shown = dictionary
            present(dictionary, animated: true)
        }
    }

    /// The dictionaries installed on the device, open at a term; with none installed it says
    /// so and offers to manage them.
    final class DictionaryViewController: UIReferenceLibraryViewController {
        var onDismiss: (() -> Void)?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed { onDismiss?() }
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
