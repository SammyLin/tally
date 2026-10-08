import SwiftUI

/// Big record button, timer, level meter, pause/resume; stop → title + folder → queued for upload.
struct RecordView: View {
    let folders: [Folder]
    let defaultFolder: Int?
    let defaultLanguage: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var finished: URL?
    @State private var title = ""
    @State private var folder: Int?
    @State private var language = "zh"
    @State private var error: String?
    @State private var confirmDiscard = false

    private var rec: Recorder { app.recorder }

    var body: some View {
        NavigationStack {
            Group {
                if finished != nil { saveForm } else { recording }
            }
            .navigationBarTitleDisplayMode(.inline)
            .kirokuChrome()
            .kirokuNavyScreen() // the record screen is the logo: navy, ivory, seafoam
        }
        .interactiveDismissDisabled()
        .onAppear { folder = defaultFolder; language = defaultLanguage }
    }

    private var recording: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(Prompt.fmtDur(rec.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(.brandIvory))
                .accessibilityLabel("已錄 \(Prompt.fmtDur(rec.elapsed))")
                .accessibilityIdentifier("record.timer")
            LevelMeter(level: rec.level)
                .frame(height: 48)
                .padding(.horizontal, 32)
                .accessibilityHidden(true)
            Text(statusText).foregroundStyle(Color(.onChromeMuted)).font(.callout)
            if let error { Text(error).accessibilityIdentifier("record.error").foregroundStyle(Color(.danger)).multilineTextAlignment(.center).padding(.horizontal) }
            Spacer()
            HStack(spacing: 48) {
                if rec.isActive {
                    Button {
                        rec.state == .paused ? rec.resume() : rec.pause()
                    } label: {
                        Image(systemName: rec.state == .paused ? "play.fill" : "pause.fill")
                            .font(.title)
                            .foregroundStyle(Color(.brandIvory))
                            .frame(width: 64, height: 64)
                            .background(Color(.chromeRaised), in: .circle)
                    }
                    .accessibilityLabel(rec.state == .paused ? "繼續錄音" : "暫停")
                    .accessibilityIdentifier("record.pause")
                }
                Button(action: mainAction) {
                    ZStack {
                        Circle().stroke(Color(.rec), lineWidth: 4).frame(width: 88, height: 88)
                        Circle().fill(Color(.rec)).frame(width: 72, height: 72)
                        if rec.isActive { // navy glyph: ivory on the coral Rec is only 1.9:1
                            RoundedRectangle(cornerRadius: 8).fill(Color(.brandNavy)).frame(width: 30, height: 30)
                        }
                    }
                }
                .accessibilityLabel(rec.isActive ? "停止並儲存" : "開始錄音")
                .accessibilityIdentifier(rec.isActive ? "record.stop" : "record.start")
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if !rec.isActive { Button("關閉") { dismiss() } }
            }
        }
    }

    private var statusText: String {
        if rec.interrupted { return "已被中斷（例如來電），結束後會自動繼續" }
        switch rec.state {
        case .idle: return "按下開始錄音。鎖定螢幕也會繼續錄。"
        case .recording: return "錄音中"
        case .paused: return "已暫停"
        }
    }

    private func mainAction() {
        if rec.isActive {
            guard let url = rec.stop() else { return }
            title = Self.defaultTitle()
            finished = url
        } else {
            error = nil
            Task {
                do { try await rec.start() } catch { self.error = error.localizedDescription }
            }
        }
    }

    private var saveForm: some View {
        Form {
            Group {
                Section("標題") {
                    TextField("標題", text: $title).accessibilityIdentifier("save.title")
                }
                Section("資料夾") {
                    Picker("資料夾", selection: $folder) {
                        Text("未分類").tag(Int?.none)
                        ForEach(FolderTree.flatten(folders), id: \.folder.id) { item in
                            Text(String(repeating: "　", count: item.depth) + item.folder.name).tag(Int?.some(item.folder.id))
                        }
                    }
                }
                Section("語言") {
                    Picker("語言", selection: $language) {
                        ForEach(STTLang.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("save.language")
                }
                Section {
                    Button("儲存並上傳", action: save).bold().accessibilityIdentifier("save.submit")
                } footer: {
                    Text("錄音會先存在手機上，上傳完成後才刪除本機檔案。")
                }
                Section {
                    Button("捨棄這段錄音", role: .destructive) { confirmDiscard = true }
                }
            }
            .kirokuRows()
        }
        .kirokuList()
        .navigationTitle("儲存錄音")
        .confirmationDialog("確定要捨棄？錄音將無法復原。", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("捨棄", role: .destructive) {
                if let finished { try? FileManager.default.removeItem(at: finished) }
                dismiss()
            }
        }
    }

    private func save() {
        guard let finished else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        app.uploads.enqueue(file: finished, filename: (t.isEmpty ? Self.defaultTitle() : t) + ".m4a", folderId: folder, language: language)
        dismiss()
    }

    static func defaultTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: .now)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let bars = 24
            HStack(spacing: 4) {
                ForEach(0..<bars, id: \.self) { i in
                    let on = Float(i) / Float(bars) < level
                    // lit bars fade in left to right, like the logo's wave
                    Capsule()
                        .fill(on ? Color(.brandSeafoam).opacity(0.45 + 0.55 * Double(i) / Double(bars - 1)) : Color(.onChromeMuted).opacity(0.3))
                        .frame(height: geo.size.height * (0.3 + 0.7 * CGFloat(on ? 1 : 0.4)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.1), value: level)
        }
    }
}
