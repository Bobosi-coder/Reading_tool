import SwiftUI

/// Side panel: quoted passage + streaming chat with follow-ups.
struct AskAIView: View {
    let bookTitle: String
    let author: String
    let payload: SelectionPayload?

    @State private var messages: [ChatMessage] = []
    @State private var quote: String = ""
    @State private var input = ""
    @State private var streaming = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var handledPayload: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !quote.isEmpty {
                            Text(quote)
                                .font(.callout)
                                .foregroundStyle(.primary.opacity(0.75))
                                .lineLimit(8)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if messages.isEmpty && quote.isEmpty {
                            Text("在书中选中一段文字，点「问 AI」就能问它讲的是什么。也可以直接在下面提问。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleMessages) { msg in
                            bubble(msg)
                        }
                        if let errorText {
                            Text(errorText).font(.callout).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: messages.last?.content) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            inputBar
        }
        .onAppear(perform: handlePayload)
        .onChange(of: payload?.id) { handlePayload() }
    }

    private var header: some View {
        HStack {
            Label("AI 阅读助手", systemImage: "sparkles").font(.headline)
            Spacer()
            if !messages.isEmpty {
                Button("新对话") { reset() }.font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("继续追问…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit(sendInput)
            if streaming {
                Button { task?.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
            } else {
                Button(action: sendInput) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(input.trimmed.isEmpty)
            }
        }
        .padding(12)
    }

    private var visibleMessages: [ChatMessage] {
        messages.filter { $0.role != "system" }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == "user" {
            Text(msg.displayText)
                .font(.callout)
                .padding(10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Group {
                if msg.content.isEmpty && streaming {
                    ProgressView()
                } else {
                    Text(markdown(msg.content))
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    // MARK: - Logic

    private func handlePayload() {
        guard let payload, payload.id != handledPayload else { return }
        handledPayload = payload.id
        reset()
        quote = payload.text
        var sys = AIConfig.systemPrompt
        sys += "\n\n书名：《\(bookTitle)》"
        if !author.isEmpty { sys += "\n作者：\(author)" }
        if !payload.chapterTitle.isEmpty { sys += "\n当前章节：\(payload.chapterTitle)" }
        if !payload.context.isEmpty && payload.context != payload.text {
            sys += "\n\n选中文字所在的上下文（供参考）：\n\(payload.context)"
        }
        messages = [ChatMessage(role: "system", content: sys)]
        let first = "选中的文字：\n「\(payload.text)」\n\n\(payload.action.prompt)"
        send(first, display: payload.action.prompt)
    }

    private func reset() {
        task?.cancel()
        messages = []
        quote = ""
        errorText = nil
        streaming = false
    }

    private func sendInput() {
        let text = input.trimmed
        guard !text.isEmpty, !streaming else { return }
        input = ""
        if messages.isEmpty {
            messages = [ChatMessage(role: "system", content: AIConfig.systemPrompt + "\n\n书名：《\(bookTitle)》")]
        }
        send(text, display: nil)
    }

    private func send(_ content: String, display: String?) {
        errorText = nil
        var userMsg = ChatMessage(role: "user", content: content)
        userMsg.display = display
        messages.append(userMsg)
        let history = messages
        messages.append(ChatMessage(role: "assistant", content: ""))
        let index = messages.count - 1
        streaming = true
        task = Task { @MainActor in
            do {
                for try await piece in AIClient().stream(history) {
                    guard messages.indices.contains(index) else { break }
                    messages[index].content += piece
                }
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
                if messages.indices.contains(index), messages[index].content.isEmpty {
                    messages.remove(at: index)
                }
            }
            streaming = false
        }
    }
}
