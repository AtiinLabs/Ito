import SwiftUI

/// The Library's saved-chapter filter, offered only where the saved-chapter inventory can be read. It is a
/// submenu of the toolbar's More Options menu, so the toolbar keeps room for its direct controls.
struct LibraryOfflineFilterPicker: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        Picker(selection: facetBinding) {
            ForEach(LibraryOfflineFacet.allCases, id: \.self) { facet in
                Self.title(for: facet).tag(facet)
            }
        } label: {
            Label {
                Text("Filter Library", comment: "More Options menu: submenu that filters the Library by saved chapters.")
            } icon: {
                Image(
                    systemName: viewModel.offlineFacet == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
        }
        .pickerStyle(.menu)
    }

    /// The name of a filter, shown in the picker and announced on More Options while the filter is active.
    static func title(for facet: LibraryOfflineFacet) -> Text {
        switch facet {
        case .all:
            Text("All Series", comment: "Library filter: every series in the Library, whether or not any of its chapters is saved.")
        case .anyVerified:
            Text("Has Saved Chapters", comment: "Library filter: series with at least one chapter saved on this device.")
        case .noneVerified:
            Text("No Saved Chapters", comment: "Library filter: series with no chapter saved on this device. Series whose downloads are only queued, damaged or failed count here.")
        case .entireKnownSeries:
            Text("Entire Series Offline", comment: "Library filter: series whose every chapter is saved on this device, and the source recently confirmed its chapter list is complete.")
        }
    }

    private var facetBinding: Binding<LibraryOfflineFacet> {
        Binding(
            get: { viewModel.offlineFacet },
            set: { viewModel.selectOfflineFacet($0) }
        )
    }
}
