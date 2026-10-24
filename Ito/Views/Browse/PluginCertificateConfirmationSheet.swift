import SwiftUI

/// Encapsulates the user flow for confirming trust of an untrusted server certificate.
@MainActor
struct TrustCertificateAction: Identifiable {
    let request: PendingTrust
    let sourceName: String
    let confirm: () throws -> Void
    let onSuccess: () -> Void

    var id: String { request.id }
}

/// A confirmation sheet presented when a source's network call encountered an untrusted server certificate.
/// Displays the source name, host, and fingerprint, and allows the user to Trust or Cancel.
struct PluginCertificateConfirmationSheet: View {
    let sourceName: String
    let request: PendingTrust
    let onTrust: () throws -> Void

    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section {
                    HStack {
                        Text("Source")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(sourceName)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Host")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(request.host)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section(header: Text("Certificate Fingerprint (SHA-256)")) {
                    Text(request.displayFingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }

                Section {
                    Text("Trusting this certificate allows connections to this server. Only trust certificates from servers you own or control.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Trust Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") {
                        do {
                            try onTrust()
                            dismiss()
                        } catch {
                            errorMessage = "The certificate couldn't be saved. Try again."
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
