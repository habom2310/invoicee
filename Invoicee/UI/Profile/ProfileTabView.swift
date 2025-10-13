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

    var body: some View {
        Form {
            Section("Cloud Storage") {
                Text("Connect Invoicee to a Google Drive folder to upload invoice photos and data exports.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(viewModel.authorizationState.label)
                            .foregroundStyle(viewModel.authorizationState.color)
                    }

                    if viewModel.authorizationState == .linked {
                        Button(role: .destructive) {
                            showingUnlinkConfirmation = true
                        } label: {
                            Label("Unlink Google Drive", systemImage: "link.slash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Invoices sync automatically whenever you add or edit them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: viewModel.linkAccount) {
                            Label("Link Google Drive", systemImage: "link")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.authorizationState == .authorizing)
                    }

                    if let folderName = viewModel.linkedFolderName {
                        HStack {
                            Text("Target Folder")
                            Spacer()
                            Text(folderName)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if viewModel.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Syncing…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let syncMessage = viewModel.syncStatusMessage {
                        Text(syncMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Unlink Google Drive?", isPresented: $showingUnlinkConfirmation) {
            Button("Unlink", role: .destructive) {
                viewModel.unlinkAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Invoices will no longer sync with Google Drive until you link the account again.")
        }
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
