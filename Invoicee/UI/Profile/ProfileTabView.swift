internal import SwiftUI

/// Hosts account preferences and Google Drive linking flows.
struct ProfileTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector

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
                GoogleDriveSettingsView()
            } label: {
                HStack {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(.blue)
                    Text("Link Google Drive")
                    Spacer()
                    if driveConnector.state == .authorizing {
                        ProgressView()
                    } else {
                        Text(driveConnector.state.label)
                            .font(.footnote)
                            .foregroundStyle(driveConnector.state.tint)
                    }
                }
            }
        }
    }
}

/// Detailed controls for linking and managing Google Drive sync.
struct GoogleDriveSettingsView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @EnvironmentObject private var archive: InvoiceArchive
    @State private var isConfirmingUnlink = false
    @State private var actionErrorMessage: String?

    var body: some View {
        Form {
            connectionSection
            qualitySection
        }
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .alert(unlinkAlertTitle,
               isPresented: $isConfirmingUnlink,
               actions: unlinkAlertActions,
               message: { Text(unlinkAlertMessage) })
    }

    /// Unlinking discards invoices that were never uploaded, so it needs a sterner
    /// confirmation than an ordinary unlink.
    private var hasUnsyncedWork: Bool {
        driveConnector.hasUnsyncedInvoices
    }

    private var connectionSection: some View {
        Section("Google Drive") {
            HStack {
                Text("Status")
                Spacer()
                Text(driveConnector.state.label)
                    .foregroundStyle(driveConnector.state.tint)
            }

            if driveConnector.state == .linked {
                if let accountName = driveConnector.accountDisplayName {
                    HStack {
                        Text("Account")
                        Spacer()
                        Text(accountName)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasUnsyncedWork {
                    Label("You have invoices waiting to sync. Please sync before unlinking.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button(role: .destructive) {
                    isConfirmingUnlink = true
                } label: {
                    Label("Unlink Google Drive", systemImage: "link.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(driveConnector.isSyncing)
                .tint(.red)
            } else {
                Button {
                    actionErrorMessage = nil
                    Task { await driveConnector.linkAccount() }
                } label: {
                    Label("Link Google Drive", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(driveConnector.state == .authorizing)
            }

            if let message = actionErrorMessage ?? driveConnector.linkIssueMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let syncMessage = driveConnector.lastSyncSummary {
                Text(syncMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualitySection: some View {
        Section("Image Quality") {
            Picker("Upload Size", selection: $driveConnector.imageQuality) {
                ForEach(InvoiceImageQuality.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)

            Text(driveConnector.imageQuality.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var unlinkAlertTitle: String {
        hasUnsyncedWork ? "Unsynced Invoices Detected" : "Unlink Google Drive?"
    }

    private var unlinkAlertMessage: String {
        hasUnsyncedWork
            ? "There are invoices that have not been synced yet. Sync them now to avoid losing changes. You can also unlink anyway to remove the unsynced invoices from this device."
            : "Invoices will no longer sync with Google Drive until you link the account again."
    }

    @ViewBuilder
    private func unlinkAlertActions() -> some View {
        if hasUnsyncedWork {
            Button("Sync Now") { syncNow() }
            Button("Unlink Anyway", role: .destructive) { unlink(force: true) }
        } else {
            Button("Unlink", role: .destructive) { unlink(force: false) }
        }

        Button("Cancel", role: .cancel) {}
    }

    private func syncNow() {
        actionErrorMessage = nil
        guard !archive.invoices.isEmpty else {
            actionErrorMessage = "No invoices available to sync."
            return
        }

        Task {
            do {
                try await driveConnector.syncNow()
            } catch {
                actionErrorMessage = error.userFacingDescription
            }
        }
    }

    private func unlink(force: Bool) {
        actionErrorMessage = nil
        Task { await driveConnector.unlinkAccount(force: force) }
    }
}

extension GoogleDriveAuthorizationState {
    var label: String {
        switch self {
        case .signedOut: "Not linked"
        case .authorizing: "Authorizing…"
        case .linked: "Linked"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .signedOut, .authorizing: .secondary
        case .linked: .green
        case .failed: .red
        }
    }
}
