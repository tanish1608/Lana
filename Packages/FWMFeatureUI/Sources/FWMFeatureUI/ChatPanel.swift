import SwiftUI
import UniformTypeIdentifiers
import FinanceAI

struct ChatPanel: View {
    @Bindable var controller: LanaChatController
    var onJump: (LanaChatJump) -> Void
    var onClose: () -> Void
    @State private var draft = ""
    @State private var importing = false
    @State private var history = false
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var voice = LocalVoiceInput()
    #endif
    private static let suggestions = ["Where did my money go?", "What’s my net worth?", "How do I save $150?", "Which accounts are connected?"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LanaOrb(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lana").font(.headline)
                    Text(OnDeviceRouter.status == .ready ? "On-device AI · demo financial data" : "Local model unavailable · basic answers")
                        .font(.caption).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer()
                Button { history = true } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 32, height: 44) }
                    .accessibilityLabel("Conversation history").disabled(controller.busy)
                Button { Task { await controller.newChat() } } label: { Image(systemName: "square.and.pencil").frame(width: 32, height: 44) }
                    .accessibilityLabel("New conversation").disabled(controller.busy)
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 32, height: 44) }.accessibilityLabel("Close chat")
            }.padding(.horizontal, 14).padding(.top, 8)
            Divider().opacity(0.5)
            if let status = controller.status { Text(status).font(.caption).foregroundStyle(Theme.warn).padding(.horizontal, 14).padding(.top, 4) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(controller.archive?.documents ?? []) { document in
                        HStack {
                            Label(document.name, systemImage: "doc.richtext").lineLimit(1)
                            Button { Task { await controller.removeDocument(document.id) } } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel("Remove \(document.name)").disabled(controller.busy)
                        }.font(.caption).padding(8).background(Theme.accentSoft, in: Capsule())
                    }
                }.padding(.horizontal, 14)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if controller.messages.isEmpty {
                            Text("Hi! What’s on your mind? Talk naturally, or attach a PDF.")
                                .foregroundStyle(Theme.ink2).padding(.vertical, 24)
                        }
                        ForEach(controller.messages) { m in
                            HStack(alignment: .bottom) {
                                if m.role == .user { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(LocalizedStringKey(m.text)).font(.subheadline).textSelection(.enabled)
                                    if let source = m.source { Text(source == "onDevice" ? "On-device AI" : "Basic local answer").font(.caption2).opacity(0.65) }
                                    if !m.evidence.isEmpty {
                                        DisclosureGroup("Financial sources") {
                                            ForEach(m.evidence) { e in
                                                Text(e.text).font(.caption).textSelection(.enabled)
                                                Text("\(e.provenance.dataMode.rawValue) · \(e.provenance.resultId)").font(.caption2)
                                            }
                                        }.font(.caption)
                                    }
                                }.padding(.horizontal, 13).padding(.vertical, 9)
                                    .foregroundStyle(m.role == .user ? .white : Theme.ink)
                                    .background(m.role == .user ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.bubbleIn), in: RoundedRectangle(cornerRadius: 18))
                                if m.role != .user { Spacer(minLength: 30) }
                            }.id(m.id)
                        }
                        if controller.busy { HStack { TypingDots(); Spacer() } }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.horizontal, 14).padding(.top, 12)
                }.scrollIndicators(.hidden)
                    .onChange(of: controller.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: controller.busy) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { send(s) }.font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36)
                            .foregroundStyle(Theme.accent).background(Theme.accentSoft, in: Capsule()).disabled(controller.busy)
                    }
                    Button("Review budget") { onJump(.budget) }.font(.footnote)
                    Button("Review split") { onJump(.split) }.font(.footnote)
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            HStack(spacing: 6) {
                Button { importing = true } label: { Image(systemName: "paperclip").frame(width: 32, height: 44) }.accessibilityLabel("Attach PDF").disabled(controller.busy)
                #if os(iOS)
                Button {
                    Task {
                        if voice.recording {
                            if let text = await voice.finish() { draft = text }
                        } else { await voice.start() }
                        controller.status = voice.status
                    }
                } label: { Image(systemName: voice.recording ? "stop.circle.fill" : "mic").foregroundStyle(voice.recording ? Theme.bad : Theme.accent).frame(width: 32, height: 44) }
                    .accessibilityLabel(voice.recording ? "Stop and transcribe" : "Record message")
                    .disabled(controller.busy || voice.busy)
                #endif
                TextField("Message Lana", text: $draft, axis: .vertical).lineLimit(1...3).focused($focused).submitLabel(.send).onSubmit { send(draft) }
                    .padding(.horizontal, 12).frame(minHeight: 44).background(Theme.bg, in: RoundedRectangle(cornerRadius: 22))
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Theme.lanaGradient, in: Circle())
                }.disabled(controller.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send")
            }.padding(.horizontal, 10).padding(.bottom, 14)
        }
        // Chat stays solid so replies read clearly over any screen.
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.glassEdge))
        .compositingGroup()
        .shadow(color: .black.opacity(0.10), radius: 3, y: 2)
        .shadow(color: .black.opacity(0.28), radius: 36, y: 18)
        .buttonStyle(.plain)
        .task { await controller.restore() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): Task { await controller.importPDF(url) }
            case .failure(let error): controller.status = error.localizedDescription
            }
        }
        .sheet(isPresented: $history) {
            NavigationStack {
                List(controller.savedChats) { chat in
                    Button { controller.select(chat); history = false } label: {
                        VStack(alignment: .leading) { Text(chat.title); Text(chat.updatedAt, style: .date).font(.caption) }
                    }
                }.navigationTitle("Conversations").toolbar { Button("Done") { history = false } }
            }
        }
        #if os(iOS)
        .onDisappear { voice.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { voice.cancel() } }
        #endif
    }
    private func send(_ raw: String) {
        guard !controller.busy, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await controller.send(raw) }
    }
}

enum LanaChatJump { case money, budget, split, accounts }

/// Lana's mark: the one gradient in the app, on the dock orb and the chat header.
struct LanaOrb: View {
    var size: CGFloat = 56
    var symbol = "sparkles"
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background {
                Circle().fill(Theme.lanaGradient)
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: size * 0.55)))
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }
}

private struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.ink3).frame(width: 7, height: 7).opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { on = true }
        .accessibilityLabel("Lana is typing")
    }
}
