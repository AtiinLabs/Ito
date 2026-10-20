import Combine
import SwiftUI

public struct ToastMessage: Identifiable, Equatable {
    public let id: UUID
    public enum Style: Equatable {
        case success
        case error
        case info
    }
    public var style: Style
    public var title: String
    public var message: String?

    // For specific actions like 'Move' after saving
    public var actionId: String?
    public var actionTitle: String?

    public init(
        id: UUID = UUID(),
        style: Style,
        title: String,
        message: String? = nil,
        actionId: String? = nil,
        actionTitle: String? = nil
    ) {
        self.id = id
        self.style = style
        self.title = title
        self.message = message
        self.actionId = actionId
        self.actionTitle = actionTitle
    }
}

struct SnackBarOverlay: View {
    @ObservedObject private var messageCenter: AppMessageCenter
    private let categoryHistoryViewFactory: CategoryHistoryViewFactory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingSheetForId: String?
    @State private var messageDismissTask: Task<Void, Never>?

    init(
        messageCenter: AppMessageCenter,
        categoryHistoryViewFactory: CategoryHistoryViewFactory
    ) {
        self.messageCenter = messageCenter
        self.categoryHistoryViewFactory = categoryHistoryViewFactory
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear // Transparent root covering safe area
                .ignoresSafeArea()

            if let toast = currentToast {
                HStack(spacing: 12) {
                    icon(for: toast.style)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if let msg = toast.message {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    if let actionTitle = toast.actionTitle, let actionId = toast.actionId {
                        Button {
                            showingSheetForId = messageCenter.mediaDetailItemID(
                                forActionID: actionId
                            ) ?? actionId
                            withAnimation {
                                messageCenter.dismiss(messageID: toast.id)
                            }
                        } label: {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                        }
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 16)
                .padding(.trailing, toast.actionTitle != nil ? 8 : 16)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                .padding(.horizontal, 16)
                .transition(
                    reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
                )
                .id(toast.id) // Ensure transition triggers on change
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentToast?.id)
        .onReceive(messageCenter.$currentMessage) { message in
            scheduleDismissal(for: message)
        }
        .onDisappear {
            messageDismissTask?.cancel()
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 10) // Floats above home indicator
        }
        .sheet(item: Binding(
            get: { showingSheetForId.map { SheetIdentifiable(id: $0) } },
            set: { showingSheetForId = $0?.id }
        )) { wrapper in
            categoryHistoryViewFactory.makeCategoryAssignmentSheet(itemID: wrapper.id)
        }
    }

    private var currentToast: ToastMessage? {
        guard let message = messageCenter.currentMessage else { return nil }
        let presentation = message.kind.presentation
        return ToastMessage(
            id: message.id,
            style: presentation.style,
            title: presentation.title,
            message: presentation.detail,
            actionId: presentation.actionID,
            actionTitle: presentation.actionTitle
        )
    }

    private func scheduleDismissal(for message: AppMessage?) {
        messageDismissTask?.cancel()
        guard let message else { return }

        let duration: UInt64 = message.kind.presentation.style == .error
            ? 4_500_000_000
            : 3_000_000_000
        messageDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            messageCenter.dismiss(messageID: message.id)
        }
    }

    @ViewBuilder
    private func icon(for style: ToastMessage.Style) -> some View {
        switch style {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.accentColor)
        }
    }
}

private struct SheetIdentifiable: Identifiable {
    let id: String
}
