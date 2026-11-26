import Foundation
import Security

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String   // "system" | "user" | "assistant"
    var content: String
    /// Optional short label shown in the bubble instead of the full prompt.
    var display: String? = nil

    var displayText: String { display ?? content }
}

/// One saved OpenAI-compatible endpoint. Its API key lives in the Keychain under `keychainKey`.
struct AIProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var model: String

    var keychainKey: String { "ai.apiKey.\(id.uuidString)" }
    var apiKey: String {
        get { Keychain.read(keychainKey) ?? "" }
        nonmutating set { Keychain.write(keychainKey, newValue) }
    }
    var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty }

    /// Starting points offered by "添加".
    static let templates: [AIProfile] = [
        AIProfile(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
        AIProfile(name: "DeepSeek 推理", baseURL: "https://api.deepseek.com", model: "deepseek-reasoner"),
        AIProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    ]
}

/// The saved endpoints and which one is in use.
@Observable
final class AIProfiles {
    static let shared = AIProfiles()
    private let d = UserDefaults.standard

    private(set) var profiles: [AIProfile] = []
    var activeID: UUID? {
        didSet { d.set(activeID?.uuidString, forKey: "ai.activeProfile") }
    }

    var active: AIProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    private init() {
        if let data = d.data(forKey: "ai.profiles"), let list = try? JSONDecoder().decode([AIProfile].self, from: data) {
            profiles = list
        } else {
            migrateSingleConfig()
        }
        let saved = d.string(forKey: "ai.activeProfile").flatMap(UUID.init)
        activeID = profiles.contains { $0.id == saved } ? saved : profiles.first?.id
    }

    /// Earlier versions stored a single endpoint; turn it into the first profile.
    private func migrateSingleConfig() {
        let oldKey = Keychain.read("ai.apiKey") ?? ""
        guard let url = d.string(forKey: "ai.baseURL") ?? (oldKey.isEmpty ? nil : "https://api.openai.com/v1") else { return }
        let model = d.string(forKey: "ai.model") ?? "gpt-4o-mini"
        let host = URL(string: url)?.host ?? url
        let name = host.contains("deepseek") ? "DeepSeek" : host.contains("openai") ? "OpenAI" : host
        let p = AIProfile(name: name, baseURL: url, model: model)
        p.apiKey = oldKey
        profiles = [p]
        persist()
        Keychain.write("ai.apiKey", "")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: "ai.profiles") }
    }

    func upsert(_ p: AIProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        if activeID == nil || !profiles.contains(where: { $0.id == activeID }) { activeID = p.id }
        persist()
    }

    func delete(_ p: AIProfile) {
        p.apiKey = ""
        profiles.removeAll { $0.id == p.id }
        if activeID == p.id { activeID = profiles.first?.id }
        persist()
    }

    /// Copy with the same address and key (e.g. same account, different model).
    @discardableResult
    func duplicate(_ p: AIProfile) -> AIProfile {
        var copy = p
        copy.id = UUID()
        copy.name = p.name + " 副本"
        copy.apiKey = p.apiKey
        if let i = profiles.firstIndex(of: p) { profiles.insert(copy, at: i + 1) } else { profiles.append(copy) }
        persist()
        return copy
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        persist()
    }
}

/// Settings used by requests: the active profile plus the shared role prompt.
enum AIConfig {
    private static let d = UserDefaults.standard

    static var baseURL: String { AIProfiles.shared.active?.baseURL ?? "" }
    static var model: String { AIProfiles.shared.active?.model ?? "" }
    static var apiKey: String { AIProfiles.shared.active?.apiKey ?? "" }

    static var systemPrompt: String {
        get { d.string(forKey: "ai.systemPrompt") ?? defaultSystemPrompt }
        set { d.set(newValue, forKey: "ai.systemPrompt") }
    }

    static let defaultSystemPrompt = """
    你是一位耐心、博学的阅读伙伴。用户正在读一本书，会选中书中的一段文字向你提问。
    请结合书名、章节和上下文，用简洁清晰的中文回答；必要时解释词语、典故、背景和作者意图。
    不要复述原文太多，回答尽量控制在 300 字以内，除非用户要求详细展开。
    """

    static var isConfigured: Bool { AIProfiles.shared.active?.isConfigured ?? false }
}

enum AIError: LocalizedError {
    case notConfigured, badURL, http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先在「设置 → AI 模型」里添加一个接口，填好地址、模型和 API Key。"
        case .badURL: "接口地址不正确。"
        case .http(let code, let body): "请求失败（\(code)）：\(body.prefix(300))"
        }
    }
}

struct AIClient {
    var baseURL = AIConfig.baseURL
    var model = AIConfig.model
    var apiKey = AIConfig.apiKey

    init() {}
    init(profile: AIProfile, apiKey: String) {
        baseURL = profile.baseURL
        model = profile.model
        self.apiKey = apiKey
    }

    private var endpoint: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") { return URL(string: s) }
        return URL(string: s + "/chat/completions")
    }

    /// Streams assistant text deltas.
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty, !model.isEmpty else { throw AIError.notConfigured }
                    guard let url = endpoint else { throw AIError.badURL }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        throw AIError.http(status, text)
                    }

                    var gotStream = false
                    var raw = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else {
                            raw += line
                            continue
                        }
                        gotStream = true
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let delta = Self.deltaText(payload) { continuation.yield(delta) }
                    }
                    // Some servers ignore stream=true and return a single JSON object.
                    if !gotStream, let full = Self.fullText(raw) {
                        continuation.yield(full)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience used by "test connection".
    func complete(_ messages: [ChatMessage]) async throws -> String {
        var out = ""
        for try await piece in stream(messages) { out += piece }
        return out
    }

    private static func deltaText(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any] {
            return delta["content"] as? String
        }
        if let msg = first["message"] as? [String: Any] {
            return msg["content"] as? String
        }
        return nil
    }

    private static func fullText(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return nil }
        return msg["content"] as? String
    }
}

enum Keychain {
    private static let service = "com.personal.reader"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
