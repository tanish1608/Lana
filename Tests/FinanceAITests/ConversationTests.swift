import Foundation
import PDFKit
import CoreGraphics
import CoreText
import Testing
import FWMCore
@testable import FinanceAI

@Test func savedConversationRestoresMessagesDocumentsAndOwnerIsolation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ConversationStore(directory: folder)
    var chat = ConversationArchive(userID: "owner", datasetVersion: "v1")
    chat.messages.append(.init(role: .user, text: "My name is Sam"))
    chat.messages.append(.init(role: .assistant, text: "Hi Sam"))
    chat.documents.append(.init(name: "statement.pdf", pages: ["September statement", "Closing balance 123.45"]))
    try await store.save(chat)
    let restored = try #require(try await ConversationStore(directory: folder).load(userID: "owner").first)
    #expect(restored.id == chat.id)
    #expect(restored.messages.map(\.text) == ["My name is Sam", "Hi Sam"])
    #expect(restored.documents.first?.pages.count == 2)
    #expect(try await store.load(userID: "another-owner").isEmpty)
    var second = ConversationArchive(userID: "owner", datasetVersion: "v1")
    second.messages.append(.init(role: .user, text: "Another conversation"))
    try await store.save(second)
    #expect(try await store.load(userID: "owner").count == 2)
}
@Test func contextIsBoundedAndOmitsStaleFinancialEvidence() {
    var chat = ConversationArchive(userID: "owner", datasetVersion: "old")
    for index in 0..<50 { chat.messages.append(.init(role: .user, text: "Message \(index): " + String(repeating: "x", count: 2_000))) }
    chat.messages.append(.init(role: .assistant, text: "STALE MONEY VALUE", evidence: [.init(text: "STALE MONEY VALUE",
        provenance: .init(resultId: "old-r", datasetVersion: "old", dataMode: .fixture, asOf: "2026-09", sourceIds: [], engineVersion: "test"))]))
    let scope = CoreScope(userID: "owner", conversationID: "c", period: "2026-09", datasetVersion: "new", preferencesVersion: 1)
    let prompt = ConversationContext.prompt(request: "What was my latest question?", archive: chat, scope: scope)
    #expect(!prompt.contains("Message 0:"))
    #expect(prompt.contains("Message 49:"))
    #expect(!prompt.contains("STALE MONEY VALUE"))
    #expect(prompt.count < 6_000)
}
@Test func pdfRetrievalFindsLaterPagesAndPreservesPageLabels() {
    let document = ChatDocument(name: "report.pdf", pages: ["Introduction", String(repeating: "text ", count: 400) + "Insurance premium renewal due October"])
    let result = document.excerpts(query: "insurance renewal")
    #expect(result.contains("page 2"))
    #expect(result.contains("Insurance premium"))
    #expect(document.excerpts(query: "intro", page: 1).contains("Introduction"))
    #expect(!document.excerpts(query: "intro", page: 1).contains("Insurance"))
}
@Test @MainActor func importsActualPDFTextAndRejectsInvalidBytes() async throws {
    let encoded = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: encoded))
    var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &rect, nil))
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 40, y: 600)
    let style = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Demo statement closing balance 123.45", attributes: style)), context)
    context.endPDFPage(); context.closePDF()
    let document = try await PDFTextImporter().extract(data: encoded as Data, name: "statement.pdf")
    #expect(document.pages.count == 1)
    #expect(document.pages[0].contains("123.45"))
    do { _ = try await PDFTextImporter().extract(data: Data("not a pdf".utf8), name: "bad.pdf"); Issue.record("Invalid PDF accepted") }
    catch is FinanceAIError {}
}
private actor ChatTestTools: CoreToolExecuting {
    var count = 0
    func query(_ call: ToolCall, scope: CoreScope) async throws -> CoreToolOutput {
        count += 1
        return .init(replyText: "Income $4,800.00", provenance: .init(resultId: "r", datasetVersion: scope.datasetVersion,
            dataMode: .fixture, asOf: "2026-09", sourceIds: [], engineVersion: "test"))
    }
    func calls() -> Int { count }
}
@Test func conversationalToolRejectsInvalidArgumentsWithoutCallingAdapter() async throws {
    let scope = CoreScope(userID: "owner", conversationID: "c", period: "2026-09", datasetVersion: "v1", preferencesVersion: 1)
    let tools = ChatTestTools()
    let session = ChatToolSession(context: .init(scope: scope), tools: tools)
    let output = try await session.query(.init(operation: .money, period: "2026-99", savings: nil))
    #expect(output.contains("Tool unavailable"))
    #expect(await tools.calls() == 0)
    let valid = try await session.query(.init(operation: .money, period: nil, savings: nil))
    #expect(valid.contains("$4,800.00"))
    #expect(await session.results().first?.provenance.resultId == "r")
}
