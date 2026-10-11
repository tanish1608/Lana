import Foundation
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public struct PDFTextImporter {
    public init() {}
    /// PDFKit stays on the main actor; scanned page recognition runs through local Vision.
    @MainActor public func extract(data: Data, name: String) async throws -> ChatDocument {
        guard !data.isEmpty, data.count <= 50_000_000, let pdf = PDFDocument(data: data) else {
            throw FinanceAIError.unavailable("Choose a readable PDF smaller than 50 MB.")
        }
        guard !pdf.isLocked else { throw FinanceAIError.unavailable("Unlock the PDF before importing it.") }
        var pages: [String] = [], characters = 0, scanned = 0
        for index in 0..<min(pdf.pageCount, 100) {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { pages.append(""); continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 10 {
                let thumbnail = page.thumbnail(of: CGSize(width: 1_200, height: 1_600), for: .mediaBox)
                #if os(iOS)
                let imageData = thumbnail.pngData()
                #else
                let imageData = thumbnail.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                #endif
                if let imageData { text = try await ReceiptOCR().recognize(imageData: imageData).text; scanned += 1 }
            }
            let remaining = 300_000 - characters
            guard remaining > 0 else { break }
            pages.append(String(text.prefix(remaining))); characters += pages.last!.count
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw FinanceAIError.unavailable("No readable text was found in this PDF.") }
        var notes: [String] = []
        if pages.count < pdf.pageCount || characters >= 300_000 { notes.append("Imported up to 100 pages / 300,000 characters; some text may be omitted.") }
        if scanned > 0 { notes.append("\(scanned) scanned pages were read with local OCR. Verify extracted text against the PDF.") }
        return .init(name: String(name.prefix(180)), pages: pages, notice: notes.isEmpty ? nil : notes.joined(separator: " "))
    }
}
