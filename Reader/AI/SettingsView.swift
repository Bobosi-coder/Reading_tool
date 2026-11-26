import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ReaderSettings.self) private var settings

    @State private var store = AIProfiles.shared
    @State private var systemPrompt = AIConfig.systemPrompt
    @State private var path: [AIProfile] = []
    @State private var fonts = FontManager.shared
    @State private var importingFont = false
    @State private var fontMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    ForEach(store.profiles) { p in
                        HStack(spacing: 12) {
                            Button { store.activeID = p.id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: store.active?.id == p.id ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(store.active?.id == p.id ? Color.accentColor : DS.inkSoft.opacity(0.5))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundStyle(DS.ink)
                                        Text(p.model + (p.isConfigured ? "" : " · 未填 Key"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { path = [p] } label: {
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                    .frame(width: 32, height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.delete(p) } label: { Label("删除", systemImage: "trash") }
                            Button { path = [store.duplicate(p)] } label: { Label("复制", systemImage: "plus.square.on.square") }
                                .tint(.gray)
                        }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                    Menu {
                        ForEach(AIProfile.templates) { t in
                            Button("\(t.name)（\(t.model)）") { add(t) }
                        }
                        Divider()
                        Button("自定义") { add(AIProfile(name: "新接口", baseURL: "", model: "")) }
                    } label: {
                        Label("添加接口", systemImage: "plus")
                    }
                } header: {
                    Text("AI 模型")
                } footer: {
                    Text("点选一个作为当前使用的模型，点右侧箭头编辑。左滑可复制或删除——复制会带上同一个 Key，适合同一账号配不同模型。阅读时也可以在 AI 面板顶部切换。")
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
            .navigationDestination(for: AIProfile.self) { p in
                AIProfileEditor(profile: p)
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
        AIConfig.systemPrompt = systemPrompt
    }

    private func add(_ template: AIProfile) {
        var p = template
        p.id = UUID()
        store.upsert(p)
        path = [p]
    }
}


/// Edit one saved endpoint: name, address, model, key, test.
struct AIProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIProfile
    @State private var apiKey: String
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmDelete = false
    private let store = AIProfiles.shared

    init(profile: AIProfile) {
        _draft = State(initialValue: profile)
        _apiKey = State(initialValue: profile.apiKey)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称，例如 DeepSeek", text: $draft.name)
            } header: { Text("名称") }

            Section {
                TextField("接口地址", text: $draft.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                    .textContentType(.oneTimeCode) // keep iOS from offering to save it as a password
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
                Text("OpenAI 兼容接口")
            } footer: {
                Text(verbatim: "接口地址填到 /v1 即可（DeepSeek 填 https://api.deepseek.com）。API Key 只保存在本机钥匙串中。")
            }

            Section {
                Button("设为当前使用") { save(); store.activeID = draft.id }
                    .disabled(store.active?.id == draft.id)
                Button("删除这个接口", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "接口" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .confirmationDialog("删除「\(draft.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.delete(draft)
                deleted = true
                dismiss()
            }
        }
    }

    @State private var deleted = false

    private func save() {
        guard !deleted else { return }
        draft.name = draft.name.trimmed.isEmpty ? "未命名" : draft.name.trimmed
        draft.baseURL = draft.baseURL.trimmed
        draft.model = draft.model.trimmed
        store.upsert(draft)
        draft.apiKey = apiKey.trimmed
    }

    private func test() {
        save()
        testing = true
        testResult = nil
        let client = AIClient(profile: draft, apiKey: apiKey.trimmed)
        Task {
            do {
                let reply = try await client.complete([ChatMessage(role: "user", content: "用一句话回复：连接成功")])
                testResult = "连接成功：" + reply.trimmed
            } catch {
                testResult = "连接失败：" + error.localizedDescription
            }
            testing = false
        }
    }
}
