import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ReaderSettings.self) private var settings

    @State private var baseURL = AIConfig.baseURL
    @State private var model = AIConfig.model
    @State private var apiKey = AIConfig.apiKey
    @State private var systemPrompt = AIConfig.systemPrompt
    @State private var testing = false
    @State private var testResult: String?
    @State private var fonts = FontManager.shared
    @State private var importingFont = false
    @State private var fontMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("接口地址", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("模型名", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("测试连接") { test() }.disabled(testing)
                        if testing { ProgressView().padding(.leading, 8) }
                    }
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI（OpenAI 兼容接口）")
                } footer: {
                    Text("接口地址填到 /v1 即可，例如 https://api.openai.com/v1、https://api.deepseek.com/v1。API Key 只保存在本机钥匙串中。")
                }

                Section("AI 角色设定") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                    Button("恢复默认") { systemPrompt = AIConfig.defaultSystemPrompt }
                }

                Section {
                    ForEach(fonts.importedFamilies, id: \.self) { family in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(family).font(.subheadline)
                            Text("永和九年 The quick brown fox").font(.custom(family, size: 20)).lineLimit(1)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { fonts.deleteFamily(fonts.importedFamilies[i]) }
                    }
                    Button { importingFont = true } label: { Label("导入字体文件", systemImage: "square.and.arrow.down") }
                } header: {
                    Text("已导入的字体")
                } footer: {
                    Text("在阅读页点「Aa」可分别选择中文和西文字体。左滑可删除字体。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save(); dismiss() }
                }
            }
            .fileImporter(isPresented: $importingFont, allowedContentTypes: FontPickerList.fontTypes, allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                var added: [String] = []
                for url in urls {
                    do { added += try fonts.importFont(from: url) } catch { fontMessage = error.localizedDescription }
                }
                if !added.isEmpty { fontMessage = "已导入：" + added.joined(separator: "、") }
            }
            .alert(fontMessage ?? "", isPresented: Binding(get: { fontMessage != nil }, set: { if !$0 { fontMessage = nil } })) {
                Button("好") { fontMessage = nil }
            }
        }
        .onDisappear(perform: save)
    }

    private func save() {
        AIConfig.baseURL = baseURL.trimmed
        AIConfig.model = model.trimmed
        AIConfig.apiKey = apiKey.trimmed
        AIConfig.systemPrompt = systemPrompt
    }

    private func test() {
        save()
        testing = true
        testResult = nil
        Task {
            do {
                let reply = try await AIClient().complete([ChatMessage(role: "user", content: "用一句话回复：连接成功")])
                testResult = "✅ " + reply.trimmed
            } catch {
                testResult = "❌ " + error.localizedDescription
            }
            testing = false
        }
    }
}
