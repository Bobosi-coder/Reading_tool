import SwiftUI
import UniformTypeIdentifiers

/// The "Aa" popover in the reader: theme, fonts, size, spacing, page turn.
struct TypographyView: View {
    @Environment(ReaderSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    themeRow(s)

                    card {
                        sizeRow(s)
                    }

                    card {
                        NavigationLink {
                            FontPickerList(title: "中文字体", script: .cjk, selection: $s.cjkFont, sample: "落霞与孤鹜齐飞")
                        } label: {
                            fontRow(label: "中文", family: s.cjkFont, sample: "永和九年，岁在癸丑")
                        }
                        Divider().padding(.leading, 16)
                        NavigationLink {
                            FontPickerList(title: "西文字体", script: .latin, selection: $s.latinFont, sample: "The quick brown fox")
                        } label: {
                            fontRow(label: "西文", family: s.latinFont, sample: "Call me Ishmael.")
                        }
                    }

                    card {
                        sliderRow("行距", value: $s.lineHeight, range: 1.2...2.6, step: 0.05, format: { String(format: "%.2f", $0) })
                        Divider().padding(.leading, 16)
                        sliderRow("字间距", value: $s.letterSpacing, range: 0...0.2, step: 0.01, format: { String(format: "%.2f", $0) })
                        Divider().padding(.leading, 16)
                        sliderRow("段间距", value: $s.paragraphSpacing, range: 0...2, step: 0.1, format: { String(format: "%.1f", $0) })
                        Divider().padding(.leading, 16)
                        sliderRow("页边距", value: $s.horizontalMargin, range: 12...96, step: 2, format: { "\(Int($0))" })
                    }

                    card {
                        Toggle("首行缩进", isOn: $s.textIndent).padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().padding(.leading, 16)
                        Toggle("两端对齐", isOn: $s.justify).padding(.horizontal, 16).padding(.vertical, 10)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("翻页效果").font(.footnote.weight(.semibold)).foregroundStyle(DS.inkSoft).padding(.leading, 4)
                        Picker("翻页效果", selection: $s.pageTurn) {
                            ForEach(PageTurnStyle.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    FontPreview()
                }
                .padding(18)
            }
            .background(DS.paper)
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.accentColor)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(DS.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline.opacity(0.6), lineWidth: 0.5))
    }

    private func themeRow(_ s: ReaderSettings) -> some View {
        HStack(spacing: 12) {
            ForEach(ReaderTheme.allCases) { theme in
                let selected = s.theme == theme
                Button { withAnimation(.easeInOut(duration: 0.2)) { s.theme = theme } } label: {
                    VStack(spacing: 6) {
                        Text("Aa")
                            .font(DS.serif(20, .medium))
                            .foregroundStyle(theme.fgColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(theme.bgColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(selected ? Color.accentColor : DS.hairline, lineWidth: selected ? 2.5 : 1)
                            )
                        Text(theme.name)
                            .font(.caption2.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : DS.inkSoft)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func sizeRow(_ s: ReaderSettings) -> some View {
        HStack(spacing: 0) {
            Button { s.fontSize = max(12, s.fontSize - 1) } label: {
                Text("A").font(DS.serif(15)).frame(maxWidth: .infinity, minHeight: 48)
            }
            Divider().frame(height: 28)
            Text("\(Int(s.fontSize))")
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(DS.inkSoft)
                .frame(width: 56)
            Divider().frame(height: 28)
            Button { s.fontSize = min(40, s.fontSize + 1) } label: {
                Text("A").font(DS.serif(24)).frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .foregroundStyle(DS.ink)
    }

    private func fontRow(label: String, family: String, sample: String) -> some View {
        HStack(spacing: 14) {
            Text(label).font(.subheadline).foregroundStyle(DS.inkSoft).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(FontManager.displayName(for: family))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.ink)
                Text(sample)
                    .font(FontManager.previewFont(family, size: 18))
                    .foregroundStyle(DS.ink.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(DS.inkSoft.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                           format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value.wrappedValue)).font(.subheadline.monospacedDigit()).foregroundStyle(DS.inkSoft)
            }
            Slider(value: value, in: range, step: step)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct FontPreview: View {
    @Environment(ReaderSettings.self) private var settings

    var body: some View {
        let s = settings
        VStack(alignment: .leading, spacing: s.paragraphSpacing * s.fontSize * 0.6) {
            previewText("　　落霞与孤鹜齐飞，秋水共长天一色。", family: s.cjkFont)
            previewText("It was the best of times, it was the worst of times.", family: s.latinFont.isEmpty ? s.cjkFont : s.latinFont)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(s.theme.bgColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline.opacity(0.6), lineWidth: 0.5))
        .foregroundStyle(s.theme.fgColor)
    }

    private func previewText(_ text: String, family: String) -> some View {
        let size = settings.fontSize
        return Text(text)
            .font(FontManager.previewFont(family, size: size))
            .tracking(settings.letterSpacing * size)
            .lineSpacing((settings.lineHeight - 1) * size * 0.8)
    }
}

/// Pick a font family: curated fonts first, then the user's imports and all system fonts.
struct FontPickerList: View {
    let title: String
    let script: FontScript
    @Binding var selection: String
    let sample: String

    @State private var fonts = FontManager.shared
    @State private var importing = false
    @State private var showSystemPicker = false
    @State private var message: String?
    @State private var search = ""

    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    ForEach(fonts.featured(for: script)) { f in
                        featuredRow(f)
                    }
                } header: {
                    Text("精选")
                }
            }

            Section {
                ForEach(filtered(fonts.importedFamilies), id: \.self) { row($0) }
                Button { importing = true } label: { Label("导入字体文件（.ttf / .otf / .ttc）", systemImage: "square.and.arrow.down") }
                Button { showSystemPicker = true } label: { Label("从已安装到 iPad 的字体中选择", systemImage: "textformat") }
            } header: {
                Text("我的字体")
            } footer: {
                Text("有 Bookerly 等字体文件的话，可以在这里导入。通过其他 App 安装到系统的字体，阅读页不一定能显示，如无效请改为导入文件。")
            }

            if search.isEmpty {
                Section { row("", display: "跟随书籍（不覆盖）") }
            }

            Section("全部系统字体") {
                ForEach(filtered(fonts.systemFamilies), id: \.self) { row($0) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.paper)
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

    private func featuredRow(_ f: FeaturedFont) -> some View {
        Button { selection = f.family } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sample)
                        .font(FontManager.previewFont(f.family, size: 24))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(f.displayName).font(.footnote.weight(.semibold)).foregroundStyle(DS.ink)
                        Text(f.note).font(.footnote).foregroundStyle(DS.inkSoft).lineLimit(1)
                    }
                }
                Spacer()
                if selection == f.family {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ family: String, display: String? = nil) -> some View {
        Button { selection = family } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(display ?? family)
                        .font(.subheadline)
                        .foregroundStyle(DS.ink)
                    if !family.isEmpty {
                        Text(sample)
                            .font(FontManager.previewFont(family, size: 20))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if selection == family {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
