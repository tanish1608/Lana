import SwiftUI
import UniformTypeIdentifiers
import Observation
import FinanceAI
import FWMCore

@Observable @MainActor
final class ChatController {
    var archive: ConversationArchive?
    var savedChats: [ConversationArchive] = []
    var busy = false
    var status: String?
    private var assistant: ConversationalAssistant?
    private var scope: CoreScope?
    private var restored = false
    private let store: ConversationStore
    var messages: [ConversationMessage] { archive?.messages ?? [] }
    init() {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("FinanceChats", isDirectory: true)
        store = ConversationStore(directory: folder)
        do {
            let environment = try DemoEnvironment.assistant()
            assistant = environment.0; scope = environment.1
            archive = ConversationArchive(userID: environment.1.userID, datasetVersion: environment.1.datasetVersion)
        } catch { status = error.localizedDescription }
    }
    func restore() async {
        guard let scope, !restored else { return }
        restored = true; busy = true
        defer { busy = false }
        do {
            savedChats = try await store.load(userID: scope.userID)
            if let latest = savedChats.first { archive = latest }
        } catch { status = "Couldn't restore saved chats: \(error.localizedDescription)" }
    }
    func newChat() async {
        guard let scope, !busy else { return }
        archive = ConversationArchive(userID: scope.userID, datasetVersion: scope.datasetVersion)
        status = nil
        await persist()
    }
    func select(_ chat: ConversationArchive) {
        guard !busy else { return }
        archive = chat; status = nil
    }
    func send(_ text: String) async {
        guard !busy, let assistant, var current = archive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; status = nil
        defer { busy = false }
        let context = current
        current.messages.append(.init(role: .user, text: text)); archive = current
        await persist()
        do {
            let response = try await assistant.respond(to: text, archive: context)
            archive?.messages.append(.init(role: .assistant, text: response.text,
                source: response.source.rawValue, evidence: response.evidence))
            status = response.notice
        } catch {
            archive?.messages.append(.init(role: .assistant,
                text: (error as? ToolError)?.userMessage ?? error.localizedDescription))
        }
        await persist()
    }
    func importPDF(_ url: URL) async {
        guard !busy else { return }
        busy = true; status = "Reading PDF on this device…"
        defer { busy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard byteCount <= 50_000_000 else { throw FinanceAIError.unavailable("Choose a PDF smaller than 50 MB.") }
            let document = try await PDFTextImporter().extract(data: Data(contentsOf: url), name: url.lastPathComponent)
            archive?.documents.append(document)
            archive?.messages.append(.init(role: .assistant,
                text: "I've added \(document.name) (\(document.pages.count) pages). What would you like to know about it?"))
            status = document.notice
            await persist()
        } catch { status = error.localizedDescription }
    }
    func removeDocument(_ id: UUID) async {
        guard !busy else { return }
        archive?.documents.removeAll { $0.id == id }
        await persist()
    }
    private func persist() async {
        guard var current = archive else { return }
        current.updatedAt = Date(); archive = current
        do {
            try await store.save(current)
            savedChats = try await store.load(userID: current.userID)
        } catch { status = "Chat is available in this session but couldn't be saved: \(error.localizedDescription)" }
    }
}

struct ChatLab: View {
    @State private var controller = ChatController()
    @State private var text = ""
    @State private var importing = false
    @State private var showingChats = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(OnDeviceRouter.status.description, systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Chats and PDF text are saved on this device • financial data is a demo fixture")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let status = controller.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    ForEach(controller.archive?.documents ?? []) { document in
                        HStack {
                            Label("\(document.name) · \(document.pages.count) pages", systemImage: "doc.richtext")
                                .font(.caption).lineLimit(1)
                            Spacer()
                            Button { Task { await controller.removeDocument(document.id) } } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel("Remove \(document.name) from chat context").disabled(controller.busy)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if controller.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Hi! What’s on your mind?").font(.title2.weight(.semibold))
                                    Text("Talk naturally, ask about your finances, or attach a PDF and ask me about it.")
                                        .foregroundStyle(.secondary)
                                }.padding(.vertical, 30)
                            }
                            ForEach(controller.messages) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(message.role == .user ? "YOU" : "FINANCE AI").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(message.text).textSelection(.enabled)
                                    if let source = message.source { Text(source).font(.caption2).foregroundStyle(.secondary) }
                                    ForEach(message.evidence) { evidence in
                                        DisclosureGroup("Financial data available to this reply") {
                                            Text(evidence.text).font(.caption).textSelection(.enabled)
                                            Text(evidence.provenance.resultId).font(.caption2).foregroundStyle(.secondary)
                                        }.font(.caption).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(message.role == .user ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                                    .id(message.id)
                            }
                            if controller.busy { ProgressView("Thinking on device…") }
                        }.padding()
                    }.onChange(of: controller.messages.count) {
                        if let id = controller.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
                HStack {
                    Button { importing = true } label: { Image(systemName: "paperclip").font(.title3) }
                        .accessibilityLabel("Attach PDF").disabled(controller.busy)
                    TextField("Message", text: $text, axis: .vertical).lineLimit(1...5)
                        .textFieldStyle(.roundedBorder).onSubmit { submit() }
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Send message").disabled(controller.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding()
            }
            .navigationTitle("Finance AI")
            .toolbar {
                Button { showingChats = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("Saved conversations").disabled(controller.busy)
                Button { Task { await controller.newChat() } } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation").disabled(controller.busy)
            }
            .task { await controller.restore() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): Task { await controller.importPDF(url) }
                case .failure(let error): controller.status = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingChats) {
                NavigationStack {
                    List(controller.savedChats) { chat in
                        Button {
                            controller.select(chat); showingChats = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(chat.title).foregroundStyle(.primary)
                                Text(chat.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.navigationTitle("Saved conversations")
                        .toolbar { Button("Done") { showingChats = false } }
                }
            }
        }
    }
    private func submit() {
        let request = text; text = ""
        Task { await controller.send(request) }
    }
}
