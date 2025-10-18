import SwiftUI

/// Hosts account preferences and Google Drive linking flows.
struct ProfileTabView: View {
    @StateObject private var driveLinkViewModel: GoogleDriveLinkViewModel

    init(viewModel: @autoclosure @escaping () -> GoogleDriveLinkViewModel) {
        _driveLinkViewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                settingsSection
            }
            .navigationTitle("Profile")
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Invoicee Account")
                    .font(.headline)
                Text("User details and preferences will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            NavigationLink {
                GoogleDriveSettingsView(viewModel: driveLinkViewModel)
            } label: {
                HStack {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(.blue)
                    Text("Link Google Drive")
                    Spacer()
                    driveStatusView
                }
            }
        }
    }

    private var driveStatusView: some View {
        Group {
            switch driveLinkViewModel.authorizationState {
            case .signedOut:
                Text("Not linked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .authorizing:
                ProgressView()
            case .linked:
                Text("Linked")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failed:
                Text("Error")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Detailed controls for linking and managing Google Drive sync.
struct GoogleDriveSettingsView: View {
    @ObservedObject var viewModel: GoogleDriveLinkViewModel
    @State private var showingUnlinkConfirmation = false
    @State private var requiresForceUnlink = false

    var body: some View {
        Form {
            connectionSection
            qualitySection
        }
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .alert(unlinkAlertTitle,
               isPresented: $showingUnlinkConfirmation,
               actions: unlinkAlertActions,
               message: { Text(unlinkAlertMessageText) })
    }

    private var connectionSection: some View {
        Section("Google Drive") {
            HStack {
                Text("Status")
                Spacer()
                Text(viewModel.authorizationState.label)
                    .foregroundStyle(viewModel.authorizationState.color)
            }

            if let accountName = viewModel.accountDisplayName, viewModel.authorizationState == .linked {
                HStack {
                    Text("Account")
                    Spacer()
                    Text(accountName)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.authorizationState == .linked {
                if viewModel.hasUnsyncedInvoices {
                    Label("You have invoices waiting to sync. Please sync before unlinking.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button(role: .destructive) {
                    requiresForceUnlink = viewModel.hasUnsyncedInvoices
                    showingUnlinkConfirmation = true
                } label: {
                    Label("Unlink Google Drive", systemImage: "link.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSyncing)
                .tint(.red)
            } else {
                Button(action: viewModel.linkAccount) {
                    Label("Link Google Drive", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.authorizationState == .authorizing)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let syncMessage = viewModel.syncStatusMessage {
                Text(syncMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualitySection: some View {
        Section("Image Quality") {
            Picker("Upload Size", selection: $viewModel.imageQuality) {
                ForEach(InvoiceImageQuality.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)

            Text(viewModel.imageQuality.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var unlinkAlertTitle: String {
        requiresForceUnlink ? "Unsynced Invoices Detected" : "Unlink Google Drive?"
    }

    private var unlinkAlertMessageText: String {
        if requiresForceUnlink {
            return "There are invoices that have not been synced yet. Sync them now to avoid losing changes. You can also unlink anyway to remove the unsynced invoices from this device."
        } else {
            return "Invoices will no longer sync with Google Drive until you link the account again."
        }
    }

    @ViewBuilder
    private func unlinkAlertActions() -> some View {
        if requiresForceUnlink {
            Button("Sync Now") {
                showingUnlinkConfirmation = false
                viewModel.syncInvoices()
            }
            Button("Unlink Anyway", role: .destructive) {
                viewModel.unlinkAccount(force: true)
            }
        } else {
            Button("Unlink", role: .destructive) {
                viewModel.unlinkAccount(force: false)
            }
        }

        Button("Cancel", role: .cancel) {}
    }
}

private extension GoogleDriveAuthorizationState {
    var label: String {
        switch self {
        case .signedOut: "Not linked"
        case .authorizing: "Authorizing…"
        case .linked: "Linked"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .signedOut: .secondary
        case .authorizing: .secondary
        case .linked: .green
        case .failed: .red
        }
    }
}
