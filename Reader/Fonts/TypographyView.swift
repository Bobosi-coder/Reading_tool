import SwiftUI
import UniformTypeIdentifiers

/// The "Aa" popover in the reader: theme, fonts, size, spacing.
struct TypographyView: View {
    @Environment(ReaderSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Button { s.theme = theme } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(theme.bgColor)
                                        .overlay(Text("文").font(.callout).foregroundStyle(theme.fgColor))
                                        .overlay(Circle().stroke(s.theme == theme ? Color.accentColor : .gray.opacity(0.3), lineWidth: s.theme == theme ? 3 : 1))
                                        .frame(width: 44, height: 44)
                                    Text(theme.name).font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Section("字体") {
                    NavigationLink {
                        FontPickerList(title: "中文字体", selection: $s.cjkFont, sample: "永和九年，岁在癸丑")
                    } label: {
                        LabeledContent("中文字体") { fontLabel(s.cjkFont) }
                    }
                    NavigationLink {
                        FontPickerList(title: "西文字体", selection: $s.latinFont, sample: "The quick brown fox")
                    } label: {
                        LabeledContent("西文字体") { fontLabel(s.latinFont) }
                    }
                }

                Section("排版") {
                    sliderRow("字号", value: $s.fontSize, range: 12...40, step: 1, format: { "\(Int($0))" })
                    sliderRow("行距", value: $s.lineHeight, range: 1.2...2.6, step: 0.05, format: { String(format: "%.2f", $0) })
                    sliderRow("字间距", value: $s.letterSpacing, range: 0...0.2, step: 0.01, format: { String(format: "%.2f", $0) })
                    sliderRow("段间距", value: $s.paragraphSpacing, range: 0...2, step: 0.1, format: { String(format: "%.1f", $0) })
                    sliderRow("页边距", value: $s.horizontalMargin, range: 12...96, step: 2, format: { "\(Int($0))" })
                    Toggle("首行缩进", isOn: $s.textIndent)
                    Toggle("两端对齐", isOn: $s.justify)
                }

                Section("预览") {
                    FontPreview()
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func fontLabel(_ family: String) -> some View {
        Text(family.isEmpty ? "跟随书籍" : family)
            .font(family.isEmpty ? .body : .custom(family, size: 17))
            .lineLimit(1)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                           format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

struct FontPreview: View {
    @Environment(ReaderSettings.self) private var settings

    var body: some View {
        let s = settings
        VStack(alignment: .leading, spacing: s.paragraphSpacing * s.fontSize * 0.6) {
            previewText("    落霞与孤鹜齐飞，秋水共长天一色。", family: s.cjkFont)
            previewText("It was the best of times, it was the worst of times.", family: s.latinFont.isEmpty ? s.cjkFont : s.latinFont)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(s.theme.bgColor, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(s.theme.fgColor)
    }

    private func previewText(_ text: String, family: String) -> some View {
        let size = settings.fontSize
        return Text(text)
            .font(family.isEmpty ? .system(size: size) : .custom(family, size: size))
            .tracking(settings.letterSpacing * size)
            .lineSpacing((settings.lineHeight - 1) * size * 0.8)
    }
}

/// Pick a font family: imported fonts, recommended system fonts, everything else.
struct FontPickerList: View {
    let title: String
    @Binding var selection: String
    let sample: String

    @State private var fonts = FontManager.shared
    @State private var importing = false
    @State private var showSystemPicker = false
    @State private var message: String?
    @State private var search = ""

    var body: some View {
        List {
            Section {
                row("", display: "跟随书籍（不覆盖）")
            }
            Section {
                ForEach(filtered(fonts.importedFamilies), id: \.self) { row($0) }
                Button { importing = true } label: { Label("导入字体文件（.ttf / .otf / .ttc）", systemImage: "square.and.arrow.down") }
                Button { showSystemPicker = true } label: { Label("从已安装到 iPad 的字体中选择", systemImage: "textformat") }
            } header: {
                Text("我的字体")
            } footer: {
                Text("推荐导入字体文件：例如霞鹜文楷 LXGWWenKai-Regular.ttf，可放在「文件」App 或通过隔空投送传到 iPad。通过其他 App 安装到系统的字体，阅读页不一定能显示，若无效请改为导入文件。")
            }
            if search.isEmpty {
                Section("推荐系统字体") {
                    ForEach(fonts.recommendedSystemFamilies, id: \.self) { row($0) }
                }
            }
            Section("全部系统字体") {
                ForEach(filtered(fonts.systemFamilies), id: \.self) { row($0) }
            }
        }
        .searchable(text: $search, prompt: "搜索字体")
        .navigationTitle(title)
        .fileImporter(isPresented: $importing, allowedContentTypes: FontPickerList.fontTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var added: [String] = []
            for url in urls {
                do { added += try fonts.importFont(from: url) } catch { message = error.localizedDescription }
            }
            if let first = added.first { selection = first; message = "已导入：" + added.joined(separator: "、") }
        }
        .sheet(isPresented: $showSystemPicker) {
            SystemFontPicker { family in
                selection = family
                showSystemPicker = false
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        }
    }

    static let fontTypes: [UTType] = {
        var t: [UTType] = [.font]
        for ext in ["ttf", "otf", "ttc", "otc"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }()

    private func filtered(_ list: [String]) -> [String] {
        search.isEmpty ? list : list.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func row(_ family: String, display: String? = nil) -> some View {
        Button { selection = family } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(display ?? family)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if !family.isEmpty {
                        Text(sample)
                            .font(.custom(family, size: 20))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if selection == family {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

/// Wraps UIFontPickerViewController, which also lists fonts installed by font apps / profiles.
struct SystemFontPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let config = UIFontPickerViewController.Configuration()
        config.includeFaces = false
        config.displayUsingSystemFont = false
        let vc = UIFontPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIFontPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }

        func fontPickerViewControllerDidPickFont(_ vc: UIFontPickerViewController) {
            guard let desc = vc.selectedFontDescriptor else { return }
            let family = (desc.object(forKey: .family) as? String)
                ?? UIFont(descriptor: desc, size: 17).familyName
            onPick(family)
        }
    }
}
