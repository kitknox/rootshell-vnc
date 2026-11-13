import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import rootshellVNC

final class FileTransferDropTypeTests: XCTestCase {
    private func provider(_ types: [String], name: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        for type in types {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        provider.suggestedName = name
        return provider
    }

    /// Finder items have no name until the drop.
    func testFinderTextFilesBeforeTheDrop() {
        for type in ["public.plain-text", "net.daringfireball.markdown", "public.python-script"] {
            let item = provider([type, VNCFileTransferController.finderNodeType])
            XCTAssertEqual(VNCFileTransferController.fileType(for: item), type)
        }
    }

    func testNamedTextFile() {
        let item = provider([UTType.plainText.identifier], name: "notes.txt")
        XCTAssertEqual(VNCFileTransferController.fileType(for: item), UTType.plainText.identifier)
    }

    func testUnnamedTextSnippetIsSkipped() {
        let item = provider([UTType.utf8PlainText.identifier, UTType.html.identifier])
        XCTAssertNil(VNCFileTransferController.fileType(for: item))
    }

    func testFinderPDF() {
        let item = provider([UTType.pdf.identifier, VNCFileTransferController.finderNodeType])
        XCTAssertEqual(VNCFileTransferController.fileType(for: item), UTType.pdf.identifier)
    }
}
