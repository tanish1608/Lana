#if os(macOS)
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Testing
import FinanceAI

@Test(.enabled(if: ProcessInfo.processInfo.environment["FWM_RUN_NATIVE_OCR"] == "1"))
@MainActor func visionReadsReceiptImageLocally() async throws {
    let context = try #require(CGContext(data: nil, width: 1_000, height: 500,
        bitsPerComponent: 8, bytesPerRow: 4_000, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 500))
    let style: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 48, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ]
    for (index, line) in ["LOCAL MARKET", "Milk 3.49", "TOTAL 3.49"].enumerated() {
        context.textPosition = CGPoint(x: 40, y: 380 - index * 100)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: style)), context)
    }
    let image = try #require(context.makeImage())
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let data = encoded as Data
    let document = try await ReceiptOCR().recognize(imageData: data)
    #expect(document.text.contains("LOCAL MARKET"))
    #expect(document.text.contains("3.49"))
    #expect(document.lines.allSatisfy { (0...1).contains($0.confidence) })
}
#endif
