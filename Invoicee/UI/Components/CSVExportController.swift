internal import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Lightweight document wrapper used by every CSV export flow.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: Data(text.utf8))
        var attributes = wrapper.fileAttributes
        attributes[FileAttributeKey.posixPermissions.rawValue] = NSNumber(value: Int16(0o644))
        wrapper.fileAttributes = attributes
        return wrapper
    }
}

/// Drives the "build CSV → offer a save sheet → mirror to Drive" flow shared by the
/// invoice, expense, revenue, and profit tabs.
@MainActor
final class CSVExportController: ObservableObject {
    @Published var isPresentingExporter = false
    @Published private(set) var document = CSVDocument(text: "")
    @Published private(set) var filename = "export.csv"
    @Published private(set) var errorMessage: String?

    private var uploadTask: Task<Void, Never>?

    deinit {
        uploadTask?.cancel()
    }

    /// Renders `rows` as CSV, presents the system exporter, and mirrors the file to Drive
    /// when an account is linked.
    func export(rows: [[String]], filename: String, mirroringTo connector: GoogleDriveConnector?) {
        // Row 0 is the header, so a single row means there is no data to export.
        guard rows.count > 1 else { return }

        let content = CSVExporting.makeCSV(from: rows)
        document = CSVDocument(text: content)
        self.filename = filename
        errorMessage = nil
        isPresentingExporter = true

        guard let connector, connector.state == .linked else { return }
        let transferService = connector.transferService

        // Cancelled if a second export starts: the first upload's failure would otherwise
        // overwrite the new export's state.
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            do {
                try await CSVExporting.uploadToDrive(content: content,
                                                    filename: filename,
                                                    transferService: transferService)
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.userFacingDescription
            }
        }
    }

    func handleExporterResult(_ result: Result<URL, Error>) {
        if case let .failure(error) = result {
            errorMessage = error.userFacingDescription
        }
    }
}

extension View {
    /// Attaches the system CSV exporter driven by `controller`.
    func csvExporter(_ controller: CSVExportController) -> some View {
        fileExporter(isPresented: Binding(get: { controller.isPresentingExporter },
                                          set: { controller.isPresentingExporter = $0 }),
                     document: controller.document,
                     contentType: .commaSeparatedText,
                     defaultFilename: controller.filename) { result in
            controller.handleExporterResult(result)
        }
    }
}
