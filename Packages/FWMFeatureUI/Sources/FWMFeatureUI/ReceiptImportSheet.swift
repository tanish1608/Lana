import SwiftUI
import UniformTypeIdentifiers
import FinanceAI
import FWMCore

struct ReceiptImportSheet: View {
    struct Line: Identifiable { let id = UUID(); var name = ""; var amount = "" }
    let template: Receipt
    var onReview: (Receipt) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var busy = false
    @State private var merchant = ""
    @State private var lines: [Line] = []
    @State private var subtotal = ""
    @State private var tax = ""
    @State private var tip = ""
    @State private var total = ""
    @State private var raw = ""
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Local receipt OCR") {
                    Button("Choose receipt image from Files") { importing = true }.disabled(busy)
                    if busy { ProgressView("Reading on this device…") }
                    if let notice { Text(notice).font(.footnote) }
                    if !raw.isEmpty { DisclosureGroup("Original OCR text") { Text(raw).font(.caption).textSelection(.enabled) } }
                }
                Section("Review every field against the image") {
                    TextField("Merchant", text: $merchant)
                    ForEach($lines) { $line in
                        HStack { TextField("Item name", text: $line.name); TextField("Price", text: $line.amount).frame(width: 90) }
                    }.onDelete { lines.remove(atOffsets: $0) }
                    Button("Add item") { lines.append(Line()) }.disabled(lines.count >= 40)
                    amount("Subtotal", $subtotal); amount("Tax", $tax); amount("Tip", $tip); amount("Total", $total)
                }
                Section {
                    Text("Amounts use USD. Items must add to subtotal; subtotal + tax + tip must equal total. Assign people on the next screen.").font(.footnote)
                    Button("Use reviewed receipt") { apply() }.disabled(busy || raw.isEmpty || lines.isEmpty)
                }
            }.navigationTitle("Import receipt")
                .toolbar { Button("Cancel") { dismiss() } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                    switch result {
                    case .success(let url): Task { await read(url) }
                    case .failure(let error): notice = error.localizedDescription
                    }
                }
        }
    }
    private func amount(_ title: String, _ binding: Binding<String>) -> some View {
        HStack { Text(title); Spacer(); TextField("0.00", text: binding).multilineTextAlignment(.trailing).frame(width: 100) }
    }
    private func read(_ url: URL) async {
        busy = true; notice = nil
        defer { busy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 25_000_000 else { throw FinanceAIError.invalidInput }
            let document = try await ReceiptOCR().recognize(imageData: Data(contentsOf: url))
            let draft = try await ReceiptDraftBuilder().build(from: document)
            raw = document.text; merchant = draft.merchant ?? ""
            lines = draft.items.map { Line(name: $0.name, amount: $0.amountText ?? "") }
            if lines.isEmpty { lines = [Line()] }
            subtotal = ""; tax = ""; tip = ""; total = draft.totalText ?? ""
            notice = draft.notice
        } catch { notice = error.localizedDescription }
    }
    private func apply() {
        do {
            var r = template
            r.receiptId = "local-" + UUID().uuidString
            r.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            r.date = nil // Do not carry the sample receipt date into a new import.
            r.items = try lines.enumerated().map { index, line in
                let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ToolError(.invalidArguments, "Name every item.") }
                let fields: [String: Any] = ["item_id": "local-item-\(index)", "description": name,
                    "quantity": 1, "extended_price_cents": try ReceiptReviewAmounts.cents(line.amount)]
                return try FWMJSON.decoder.decode(ReceiptItem.self, from: JSONSerialization.data(withJSONObject: fields))
            }
            r.subtotalCents = try ReceiptReviewAmounts.cents(subtotal)
            r.taxCents = try ReceiptReviewAmounts.cents(tax)
            r.tipCents = try ReceiptReviewAmounts.cents(tip)
            r.totalCents = try ReceiptReviewAmounts.cents(total)
            try ReceiptReviewAmounts.validate(r)
            onReview(r); dismiss()
        } catch { notice = (error as? ToolError)?.userMessage ?? error.localizedDescription }
    }
}

/// Exact decimal input validation shared with tests; never round an extra fraction of a cent.
enum ReceiptReviewAmounts {
    static func cents(_ text: String) throws -> Int {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard clean.range(of: #"^\d{1,7}(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ToolError(.invalidArguments, "Enter a nonnegative USD amount with at most two decimal places.")
        }
        return NSDecimalNumber(decimal: decimal * 100).intValue
    }
    static func validate(_ receipt: Receipt) throws {
        guard !receipt.items.isEmpty,
              receipt.items.reduce(0, { $0 + $1.extendedPriceCents }) == receipt.subtotalCents,
              receipt.subtotalCents + receipt.taxCents + receipt.tipCents == receipt.totalCents else {
            throw ToolError(.receiptMismatch, "Items, subtotal, tax, tip and total must reconcile before continuing.")
        }
    }
}
