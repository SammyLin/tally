import SwiftUI

/// Big record button, timer, level meter, pause/resume; stop → title + folder → queued for upload.
struct RecordView: View {
    let folders: [Folder]
    let defaultFolder: Int?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var finished: URL?
    @State private var title = ""
    @State private var folder: Int?
    @State private var error: String?
    @State private var confirmDiscard = false

    private var rec: Recorder { app.recorder }

    var body: some View {
        NavigationStack {
            Group {
                if finished != nil { saveForm } else { recording }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .onAppear { folder = defaultFolder }
    }

    private var recording: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(Prompt.fmtDur(rec.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("已錄 \(Prompt.fmtDur(rec.elapsed))")
                .accessibilityIdentifier("record.timer")
            LevelMeter(level: rec.level)
                .frame(height: 48)
                .padding(.horizontal, 32)
                .accessibilityHidden(true)
            Text(statusText).foregroundStyle(.secondary).font(.callout)
            if let error { Text(error).accessibilityIdentifier("record.error").foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal) }
            Spacer()
            HStack(spacing: 48) {
                if rec.isActive {
                    Button {
                        rec.state == .paused ? rec.resume() : rec.pause()
                    } label: {
                        Image(systemName: rec.state == .paused ? "play.fill" : "pause.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(.quaternary, in: .circle)
                    }
                    .accessibilityLabel(rec.state == .paused ? "繼續錄音" : "暫停")
                    .accessibilityIdentifier("record.pause")
                }
                Button(action: mainAction) {
                    ZStack {
                        Circle().stroke(.red, lineWidth: 4).frame(width: 88, height: 88)
                        if rec.isActive {
                            RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 34, height: 34)
                        } else {
                            Circle().fill(.red).frame(width: 72, height: 72)
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
            Section {
                Button("儲存並上傳", action: save).bold().accessibilityIdentifier("save.submit")
            } footer: {
                Text("錄音會先存在手機上，上傳完成後才刪除本機檔案。")
            }
            Section {
                Button("捨棄這段錄音", role: .destructive) { confirmDiscard = true }
            }
        }
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
        app.uploads.enqueue(file: finished, filename: (t.isEmpty ? Self.defaultTitle() : t) + ".m4a", folderId: folder)
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
                    Capsule()
                        .fill(on ? Color.red : Color.secondary.opacity(0.25))
                        .frame(height: geo.size.height * (0.3 + 0.7 * CGFloat(on ? 1 : 0.4)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.1), value: level)
        }
    }
}
