import AppKit
import Combine
import SwiftUI

/// 生词本窗口的数据：从 VocabStore 拷一份成行，生词本一变就整份重载。
final class VocabListModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let word: String
        let gloss: String
        let level: String
        let example: String
        let source: String
        let seen: Int
        let dueAt: Date?
        let lastSeen: Date
    }

    @Published var learning: [Row] = []
    @Published var mastered: [Row] = []
    /// 不高于我的水平、不再提示的词数。
    @Published var belowLevel = 0
    @Published var level = "B1"
    @Published var languageName = ""

    var speak: (String) -> Void = { _ in }
    var setKnown: (String, Bool) -> Void = { _, _ in }
    var delete: ([String]) -> Void = { _ in }
    var export: () -> Void = {}

    func load(_ store: VocabStore, language: Language) {
        let all = store.entries.sorted { $0.value.lastSeen > $1.value.lastSeen }.map { key, entry in
            (entry, Row(id: key, word: entry.word, gloss: entry.zh, level: entry.level, example: entry.example,
                        source: entry.exampleZh, seen: entry.seen, dueAt: entry.dueAt, lastSeen: entry.lastSeen))
        }
        learning = all.filter { !$0.0.known && !store.isBelowLevel($0.0.level) }.map(\.1)
        mastered = all.filter { $0.0.known }.map(\.1)
        belowLevel = all.filter { !$0.0.known && store.isBelowLevel($0.0.level) }.count
        level = store.learnerLevel
        languageName = language.displayName
    }
}

final class VocabWindowController: NSWindowController {
    private var titleWatch: AnyCancellable?

    init(model: VocabListModel) {
        let host = NSHostingController(rootView: VocabView().environmentObject(model))
        // 不让 SwiftUI 按列表内容定窗口大小（会撑到几千点高），窗口大小由下面和用户拖动决定。
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 560))
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("Vocabulary") { window.center() }
        window.setFrameAutosaveName("Vocabulary")
        super.init(window: window)
        titleWatch = model.$languageName.sink { [weak window] name in
            window?.title = name.isEmpty ? tr("生词本") : tr("生词本 · %@", name)
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct VocabView: View {
    @EnvironmentObject var model: VocabListModel
    @State private var showMastered = false
    @State private var query = ""
    @State private var selection = Set<String>()

    private var rows: [VocabListModel.Row] {
        let rows = showMastered ? model.mastered : model.learning
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            [row.word, row.gloss, row.example, row.source].contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $showMastered) {
                    Text(tr("学习中（%@）", "\(model.learning.count)")).tag(false)
                    Text(tr("已掌握（%@）", "\(model.mastered.count)")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField(tr("搜索"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Button(tr("导出到 Anki…")) { model.export() }
                    .disabled(model.learning.isEmpty)
            }
            .padding(12)
            Divider()
            if rows.isEmpty {
                Text(query.isEmpty ? (showMastered ? tr("还没有掌握的词") : tr("还没有生词")) : tr("没有匹配的词"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(rows) { row in
                        VocabRow(row: row, mastered: showMastered).tag(row.id)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button(showMastered ? tr("移回学习中") : tr("标为已掌握")) {
                        ids.forEach { model.setKnown($0, !showMastered) }
                    }
                    Button(tr("删除"), role: .destructive) { model.delete(Array(ids)) }
                }
                .onDeleteCommand {
                    model.delete(Array(selection))
                    selection = []
                }
            }
            Divider()
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .onChange(of: showMastered) { _ in selection = [] }
    }

    private var footer: String {
        if showMastered { return tr("已掌握的词不再在浮窗里出现。用外语自己写出来的词会自动算掌握。") }
        var text = tr("生词在浮窗里出现、没点它朗读，就算记得一次，隔 1、3、7、15、30 天再提示，隔完自动算掌握；点了朗读会从头再来。")
        if model.belowLevel > 0 {
            text += "\n" + tr("另有 %@ 个词不高于你的水平（%@），不再提示。", "\(model.belowLevel)", model.level)
        }
        return text
    }
}

private struct VocabRow: View {
    @EnvironmentObject var model: VocabListModel
    let row: VocabListModel.Row
    let mastered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.word).fontWeight(.semibold)
                    if !row.level.isEmpty {
                        Text(row.level)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                    }
                    Text(row.gloss).foregroundStyle(.secondary)
                }
                if !row.example.isEmpty {
                    Text(row.example)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                icon("speaker.wave.2", tr("朗读")) { model.speak(row.word) }
                if mastered {
                    icon("arrow.uturn.backward", tr("移回学习中")) { model.setKnown(row.id, false) }
                } else {
                    icon("checkmark.circle", tr("标为已掌握")) { model.setKnown(row.id, true) }
                }
                icon("trash", tr("删除")) { model.delete([row.id]) }
            }
        }
        .padding(.vertical, 3)
    }

    private var status: String {
        let seen = tr("见过 %@ 次", "\(row.seen)")
        guard !mastered else { return seen }
        guard let due = row.dueAt, due > Date() else { return seen + " · " + tr("下次遇到就提示") }
        let days = max(1, Int((due.timeIntervalSinceNow / 86400).rounded(.up)))
        return seen + " · " + tr("%@ 天后再提示", "\(days)")
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}
