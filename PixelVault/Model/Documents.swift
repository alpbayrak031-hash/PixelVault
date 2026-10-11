import PixelVaultKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// PixelVault's own image format, declared in the app's Info.plist.
    static let pixv = UTType(exportedAs: PixelVault.typeIdentifier)
}

/// A finished file handed to the system's save panel.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pixv, .png]
    static let writableContentTypes: [UTType] = [.pixv, .png]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// What the save panel is about to write.
struct ExportRequest: Identifiable {
    let id = UUID()
    let document: ExportDocument
    let contentType: UTType
    let filename: String
}
