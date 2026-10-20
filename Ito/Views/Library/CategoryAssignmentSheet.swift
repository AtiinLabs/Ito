import SwiftUI

struct CategoryAssignmentSheet: View {
    @StateObject private var viewModel: CategoryAssignmentViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: CategoryAssignmentViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    if viewModel.userCategories.isEmpty {
                        Section {
                            VStack(spacing: 12) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 32, weight: .thin))
                                    .foregroundStyle(.secondary)
                                Text("No custom lists yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Create a list below to organize your library.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    } else {
                        Section {
                            ForEach(viewModel.userCategories) { category in
                                categoryRow(for: category)
                                    .id(category.id)
                            }
                        } header: {
                            Text("Your Lists")
                        } footer: {
                            Text("Tap a list to add or remove this series. Series always remain in your library even if removed from all lists.")
                        }
                    }

                    Section {
                        Button {
                            viewModel.presentAddCategory()
                        } label: {
                            Label("New List", systemImage: "plus")
                                .font(.body.weight(.medium))
                        }
                        .disabled(viewModel.isCreatingAndAssigning)
                    }
                }
                .navigationTitle("Add to List")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            viewModel.dismissPresentation()
                            dismiss()
                        }
                        .font(.body.weight(.semibold))
                    }
                }
                .onChange(of: viewModel.newlyCreatedCategoryID) { categoryID in
                    guard let categoryID else { return }
                    withAnimation {
                        proxy.scrollTo(categoryID, anchor: .bottom)
                    }
                    viewModel.consumeNewlyCreatedCategoryID(categoryID)
                }
            }
        }
        .sheet(isPresented: addCategoryBinding) {
            addCategorySheet
        }
        .alert(
            viewModel.failure?.alertTitle ?? "List Change Failed",
            isPresented: assignmentFailureBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissFailure()
            }
        } message: {
            Text(viewModel.failure?.alertMessage ?? "Please try again.")
        }
        .onDisappear {
            viewModel.dismissPresentation()
        }
    }

    private var addCategoryBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isAddCategoryPresented },
            set: { isPresented in
                if !isPresented { viewModel.cancelAddCategory() }
            }
        )
    }

    private var assignmentFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.failure == .categoryAssignmentFailed },
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
                    .disabled(viewModel.isCreatingAndAssigning)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        Task { await viewModel.createAndAssignCategory() }
                    }
                    .disabled(!viewModel.canCreateAndAssign)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isCreatingAndAssigning)
        .alert(
            viewModel.failure?.alertTitle ?? "List Not Created",
            isPresented: createAndAssignFailureBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissFailure()
            }
        } message: {
            Text(viewModel.failure?.alertMessage ?? "Please try again.")
        }
    }

    private var createAndAssignFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.failure == .categoryCreateAndAssignFailed },
            set: { if !$0 { viewModel.dismissFailure() } }
        )
    }

    @ViewBuilder
    private func categoryRow(for category: LibraryCategory) -> some View {
        let isLinked = viewModel.isAssigned(to: category.id)
        let isAssigning = viewModel.assigningCategoryIDs.contains(category.id)

        Button {
            triggerHaptic()
            Task { await viewModel.toggleCategory(categoryID: category.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundColor(.primary)

                    if isLinked {
                        Text("Added")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isAssigning {
                    ProgressView()
                        .accessibilityLabel("Saving")
                } else if isLinked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundColor(Color(.tertiaryLabel))
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isLinked)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.name)
        .accessibilityValue(isAssigning ? "Saving" : "")
        .accessibilityAddTraits(isLinked ? .isSelected : [])
        .accessibilityHint(
            isLinked ? "Removes this series from the list" : "Adds this series to the list"
        )
        .disabled(isAssigning)
    }

    private func triggerHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
