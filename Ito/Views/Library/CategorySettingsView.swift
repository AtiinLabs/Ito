import SwiftUI

struct CategorySettingsView: View {
    @StateObject private var viewModel: CategorySettingsViewModel

    init(viewModel: @autoclosure @escaping () -> CategorySettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        List {
            Section {
                if let systemCategory = viewModel.systemCategory {
                    Text(systemCategory.name)
                        .foregroundColor(.secondary)
                        .deleteDisabled(true)
                        .moveDisabled(true)
                }

                ForEach(viewModel.userCategories) { category in
                    NavigationLink(
                        destination: EditCategoryView(
                            viewModel: viewModel,
                            categoryID: category.id
                        )
                    ) {
                        Text(category.name)
                    }
                }
                .onDelete { indexSet in
                    guard let index = indexSet.first,
                          viewModel.userCategories.indices.contains(index) else { return }
                    triggerWarningHaptic()
                    viewModel.requestDelete(categoryID: viewModel.userCategories[index].id)
                }
                .onMove(perform: viewModel.moveUserCategories)
            } header: {
                Text("Your Lists")
            }
        }
        .navigationTitle("Manage Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    viewModel.presentAddCategory()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.isCreating)
            }
        }
        .confirmationDialog(
            "Delete \(viewModel.categoryPendingDeletion?.name ?? "List")?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete List", role: .destructive) {
                viewModel.confirmDelete()
            }
            .disabled(viewModel.isDeleting)
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: addCategoryBinding) {
            addCategorySheet
        }
        .alert(
            viewModel.failure?.alertTitle ?? "List Change Failed",
            isPresented: settingsFailureBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissFailure()
            }
        } message: {
            Text(viewModel.failure?.alertMessage ?? "Please try again.")
        }
    }

    private var deleteMessage: String {
        let fallbackName = viewModel.systemCategory?.name ?? "Uncategorized"
        return "Items only in this list move to \(fallbackName). "
            + "Nothing is removed from your library."
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.categoryPendingDeletionID != nil },
            set: { isPresented in
                if !isPresented { viewModel.cancelDelete() }
            }
        )
    }

    private var addCategoryBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isAddCategoryPresented },
            set: { isPresented in
                if !isPresented { viewModel.cancelAddCategory() }
            }
        )
    }

    private var settingsFailureBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.failure == .categoryDeleteFailed
                    || viewModel.failure == .categoryReorderFailed
            },
            set: { if !$0 { viewModel.dismissFailure() } }
        )
    }

    private var addCategorySheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("List Name", text: $viewModel.newCategoryName)
                        .font(.body)
                } footer: {
                    Text("Enter a name for your new list.")
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        viewModel.cancelAddCategory()
                    }
                    .disabled(viewModel.isCreating)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        Task { await viewModel.createCategory() }
                    }
                    .disabled(!viewModel.canCreateCategory)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isCreating)
        .alert(
            viewModel.failure?.alertTitle ?? "List Not Created",
            isPresented: createFailureBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissFailure()
            }
        } message: {
            Text(viewModel.failure?.alertMessage ?? "Please try again.")
        }
    }

    private var createFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.failure == .categoryCreateFailed },
            set: { if !$0 { viewModel.dismissFailure() } }
        )
    }

    private func triggerWarningHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
}

struct EditCategoryView: View {
    @ObservedObject var viewModel: CategorySettingsViewModel
    let categoryID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("List Name", text: $viewModel.editedCategoryName)
                    .font(.body)
            } footer: {
                Text("Tap Done to save. Going back discards your changes.")
            }
        }
        .navigationTitle("Edit List")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.beginRename(categoryID: categoryID)
        }
        .onDisappear {
            viewModel.endRename(categoryID: categoryID)
        }
        .onChange(of: viewModel.renameDismissalID) { dismissalID in
            guard dismissalID == categoryID else { return }
            viewModel.consumeRenameDismissal(categoryID: categoryID)
            dismiss()
        }
        .onChange(of: viewModel.editingCategoryID) { editingCategoryID in
            guard editingCategoryID == nil else { return }
            dismiss()
        }
        .alert(
            viewModel.failure?.alertTitle ?? "List Not Renamed",
            isPresented: renameFailureBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissFailure()
            }
        } message: {
            Text(viewModel.failure?.alertMessage ?? "Please try again.")
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    Task { await viewModel.saveRename() }
                }
                .disabled(!viewModel.canSaveRename)
            }
        }
    }

    private var renameFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.failure == .categoryRenameFailed },
            set: { if !$0 { viewModel.dismissFailure() } }
        )
    }
}
