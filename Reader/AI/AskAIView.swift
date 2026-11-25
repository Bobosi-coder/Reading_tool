import SwiftUI

/// Side panel: quoted passage + streaming chat with follow-ups.
struct AskAIView: View {
    let bookTitle: String
    let author: String
    let payload: SelectionPayload?
    var onClose: () -> Void = {}

    @State private var messages: [ChatMessage] = []
    @State private var quote: String = ""
    @State private var input = ""
    @State private var streaming = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var handledPayload: UUID?
    @FocusState private var inputFocused: Bool

    private let followUps = ["用更简单的话说", "讲讲背景", "举个例子", "翻译并解释"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !quote.isEmpty { quoteCard }
                        if messages.isEmpty && quote.isEmpty { intro }
                        ForEach(visibleMessages) { msg in bubble(msg) }
                        if let errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        if !streaming && visibleMessages.last?.role == "assistant" {
                            chips
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.content) {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            inputBar
        }
        .foregroundStyle(DS.ink)
        .onAppear(perform: handlePayload)
        .onChange(of: payload?.id) { handlePayload() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(rgb: 0x5CC8F2), Color(rgb: 0x1E6BA8)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("阅读助手").font(DS.serif(18, .semibold))
                Text("《\(bookTitle)》").font(.caption).foregroundStyle(DS.inkSoft).lineLimit(1)
            }
            Spacer()
            if !messages.isEmpty {
                Button { reset() } label: { Image(systemName: "square.and.pencil") }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.inkSoft)
                    .padding(.trailing, 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(DS.hairline.opacity(0.7), in: Circle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 54)
        .padding(.bottom, 14)
    }

    private var quoteCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: 3)
            Text(quote)
                .font(DS.serif(16))
                .lineSpacing(4)
                .foregroundStyle(DS.ink.opacity(0.85))
                .lineLimit(10)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选中一段文字，点「问 AI」或「译 · 释」。")
                .font(DS.serif(17))
            Text("也可以直接在下面输入问题，比如这本书的背景、人物或某个概念。")
                .font(.callout)
                .foregroundStyle(DS.inkSoft)
        }
        .padding(.top, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(followUps, id: \.self) { q in
                    Button { sendFollowUp(q) } label: {
                        Text(q)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(DS.card, in: Capsule())
                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("继续追问…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(sendInput)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(DS.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DS.hairline, lineWidth: 0.5))
            Button {
                if streaming { task?.cancel() } else { sendInput() }
            } label: {
                Image(systemName: streaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(streaming || !input.trimmed.isEmpty ? Color.accentColor : DS.hairline))
            }
            .disabled(!streaming && input.trimmed.isEmpty)
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 30)
    }

    private var visibleMessages: [ChatMessage] {
        messages.filter { $0.role != "system" }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == "user" {
            HStack {
                Spacer(minLength: 40)
                Text(msg.displayText)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            Group {
                if msg.content.isEmpty && streaming {
                    TypingDots()
                } else {
                    Text(markdown(msg.content))
                        .font(.system(size: 16))
                        .lineSpacing(5)
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
        messages = [ChatMessage(role: "system", content: systemPrompt(chapter: payload.chapterTitle, context: payload.context, selection: payload.text))]
        let first = "选中的文字：\n「\(payload.text)」\n\n\(payload.action.prompt)"
        send(first, display: payload.action.label)
    }

    private func systemPrompt(chapter: String, context: String, selection: String) -> String {
        var sys = AIConfig.systemPrompt
        sys += "\n\n书名：《\(bookTitle)》"
        if !author.isEmpty { sys += "\n作者：\(author)" }
        if !chapter.isEmpty { sys += "\n当前章节：\(chapter)" }
        if !context.isEmpty && context != selection {
            sys += "\n\n选中文字所在的上下文（供参考）：\n\(context)"
        }
        return sys
    }

    private func reset() {
        task?.cancel()
        messages = []
        quote = ""
        errorText = nil
        streaming = false
    }

    private func sendFollowUp(_ q: String) {
        guard !streaming else { return }
        if q == "翻译并解释", !quote.isEmpty {
            send("针对上面选中的文字：\n" + AIQuickAction.translateExplain.prompt, display: q)
        } else {
            send(q, display: nil)
        }
    }

    private func sendInput() {
        let text = input.trimmed
        guard !text.isEmpty, !streaming else { return }
        input = ""
        if messages.isEmpty {
            messages = [ChatMessage(role: "system", content: systemPrompt(chapter: "", context: "", selection: ""))]
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

/// Three pulsing dots while waiting for the first token.
struct TypingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(DS.inkSoft)
                    .frame(width: 7, height: 7)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: on)
            }
        }
        .padding(.vertical, 6)
        .onAppear { on = true }
    }
}
