#if DEBUG
import Foundation
import SwiftUI
import UIKit
import ito_runner

/// A two-page chapter with printed English text, opened from the main screen under
/// `--ui-test-manga-reader` so UI tests can exercise the reader without a plugin.
enum UITestMangaReaderFixture {
    nonisolated static let pageTexts = ["HELLO WORLD", "GOODBYE MOON"]

    static func makeViewModel(dependencies: PreparedMangaReaderDependencies) throws -> MangaReaderViewModel {
        let directory = try UITestLaunchConfiguration.fixtureRootURL()
            .appendingPathComponent("MangaReaderPages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var pages: [Page] = []
        for (index, text) in pageTexts.enumerated() {
            let url = directory.appendingPathComponent("page-\(index + 1).png")
            guard let data = renderPage(text: text).pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            pages.append(Page(index: Int32(index), content: .url(url.absoluteString)))
        }

        let chapter = Manga.Chapter(key: "ui-test-chapter", chapter: 1)
        let manga = Manga(key: "ui-test-manga", title: "Lookup Fixture", viewer: .Ltr, chapters: [chapter])
        return MangaReaderViewModel(
            pageLoader: FixturePageLoader(pages: pages),
            pluginID: "ui-test-plugin",
            entry: .manga(manga),
            initialChapter: chapter,
            dependencies: dependencies
        )
    }

    /// A white page with `text` in large black capitals across its upper third.
    private static func renderPage(text: String) -> UIImage {
        let size = CGSize(width: 800, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 80, weight: .heavy),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 60, y: 300), withAttributes: attributes)
        }
    }

    @MainActor
    private final class FixturePageLoader: MangaPageLoading {
        let pages: [Page]

        init(pages: [Page]) {
            self.pages = pages
        }

        func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
            _ = entry
            _ = chapter
            return pages
        }
    }
}

/// Opens the fixture reader full screen.
struct UITestMangaReaderFixtureButton: View {
    let dependencies: PreparedMangaReaderDependencies
    @State private var viewModel: MangaReaderViewModel?
    @State private var failure: String?

    var body: some View {
        VStack {
            Button("Open Manga Reader Fixture") {
                do {
                    viewModel = try UITestMangaReaderFixture.makeViewModel(dependencies: dependencies)
                } catch {
                    failure = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("open-manga-reader-fixture")
            if let failure {
                Text(failure)
            }
            Spacer()
        }
        .padding(.top, 8)
        .fullScreenCover(
            isPresented: Binding(
                get: { viewModel != nil },
                set: { if !$0 { viewModel = nil } }
            )
        ) {
            if let viewModel {
                ReaderView(viewModel: viewModel)
            }
        }
    }
}
#endif
