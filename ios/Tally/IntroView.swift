import SwiftUI

/// First launch, before the welcome screen: what Kiroku does, how a recording flows, where the data lives
/// (web: the landing's 「運作方式」 and 「兩種用法」). Shown once; 設定 → 「再看一次介紹」 shows it again.
struct IntroView: View {
    /// UserDefaults key: the intro has been finished or skipped.
    static let seenKey = "introSeen"

    let onFinish: () -> Void
    @State private var page = 0
    private let lastPage = 2

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("略過", action: onFinish)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(.onChromeMuted))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("intro.skip")
                    .opacity(page == lastPage ? 0 : 1)
                    .disabled(page == lastPage)
            }
            .padding(.horizontal, 12)

            TabView(selection: $page) {
                IntroPage(lockup: true, title: "把對話記下來", text: "錄下會議、訪談或語音備忘錄，Kiroku 會轉成標好講者的逐字稿，再整理成摘要。") {
                    WhatIllustration()
                }
                .tag(0)
                IntroPage(title: "一段錄音怎麼變成筆記", text: nil) {
                    FlowSteps()
                }
                .tag(1)
                IntroPage(title: "資料放在哪裡，由你決定", text: nil) {
                    PlacesIllustration()
                }
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < lastPage { withAnimation { page += 1 } } else { onFinish() }
            } label: {
                Text(page < lastPage ? "下一步" : "開始使用")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color(.brandNavy))
            .accessibilityIdentifier(page < lastPage ? "intro.next" : "intro.start")
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .kirokuNavyScreen() // same navy frame as the welcome screen that follows
    }
}

/// One intro page: title, optional line, then the illustration, centred; scrolls when Dynamic Type makes it taller than the screen.
private struct IntroPage<Art: View>: View {
    var lockup = false
    let title: String
    let text: String?
    @ViewBuilder let art: Art

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 28) {
                    if lockup { KirokuLockup(size: 40) }
                    VStack(spacing: 10) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color(.brandIvory))
                            .accessibilityAddTraits(.isHeader)
                        if let text {
                            Text(text)
                                .font(.body)
                                .foregroundStyle(Color(.onChromeMuted))
                        }
                    }
                    .multilineTextAlignment(.center)
                    art
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 56) // clear of the page dots
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: Page 1 — what Kiroku does

/// A seafoam → ivory sound wave flowing into transcript rows, one per speaker.
private struct WhatIllustration: View {
    private let bars: [CGFloat] = [0.35, 0.6, 0.9, 0.55, 1, 0.7, 0.4, 0.8, 0.5, 0.95, 0.6, 0.3, 0.7, 0.45]
    private let speakers: [(ColorResource, CGFloat)] = [(.speaker1, 0.85), (.speaker2, 0.6), (.speaker3, 0.75)]

    var body: some View {
        VStack(spacing: 22) {
            LinearGradient(colors: [Color(.brandSeafoam), Color(.brandIvory)], startPoint: .leading, endPoint: .trailing)
                .frame(width: CGFloat(bars.count) * 10 - 4, height: 44)
                .mask {
                    HStack(spacing: 4) {
                        ForEach(bars.indices, id: \.self) { i in Capsule().frame(width: 6, height: 44 * bars[i]) }
                    }
                }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(speakers.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Circle().fill(Color(speakers[i].0)).frame(width: 12, height: 12)
                        Text("講者 \(i + 1)").font(.caption.weight(.semibold)).foregroundStyle(Color(.brandIvory))
                        Capsule().fill(Color(.onChromeMuted).opacity(0.45))
                            .frame(width: 170 * speakers[i].1, height: 6)
                    }
                }
            }
            .padding(16)
            .background(Color(.surface), in: .rect(cornerRadius: 14))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // decorative; fixed-width lines
            .accessibilityHidden(true)
        }
    }
}

// MARK: Page 2 — the flow

private struct FlowSteps: View {
    private let steps: [(icon: String, title: String, text: String)] = [
        ("mic.fill", "錄音或匯入", "用 iPhone 錄，或從其他 App 分享音檔到 Kiroku。"),
        ("person.2.fill", "逐字稿與講者", "轉成文字並分出講者；命名一次，之後依聲紋自動認出。"),
        ("doc.text.fill", "摘要", "選範本和語言，整理成一份摘要。"),
        ("questionmark.bubble.fill", "問問看", "對所有錄音一起提問，回答附上出處，點一下就從那句開始播。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Image(systemName: steps[i].icon)
                            .font(.title3)
                            .foregroundStyle(Color(.brandNavy))
                            .frame(width: 48, height: 48)
                            .background(Color(.brandSeafoam), in: .circle)
                        if i < steps.count - 1 {
                            Rectangle().fill(Color(.brandSeafoam).opacity(0.5)).frame(width: 2).frame(minHeight: 16, maxHeight: .infinity)
                        }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // the glyph lives in a fixed circle
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(i + 1). \(steps[i].title)").font(.headline).foregroundStyle(Color(.brandIvory))
                        Text(steps[i].text).font(.subheadline).foregroundStyle(Color(.onChromeMuted))
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Page 3 — where the data lives

private struct PlacesIllustration: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 44))
                .foregroundStyle(Color(.brandIvory))
                .accessibilityHidden(true)
            Image(systemName: "arrow.down")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.brandSeafoam))
                .accessibilityHidden(true)
            place(icon: "cloud.fill", title: "Kiroku Cloud", text: "註冊帳號就能開始；資料存在 Kiroku Cloud，轉錄和 AI 由我們處理。")
            place(icon: "server.rack", title: "自己的伺服器", text: "架在你的 Cloudflare 帳號，轉錄在你自己的 Mac 上跑；開源免費。")
            Text("同一個 App 兩種都能用，之後可在設定切換。兩邊資料各自獨立，不會互相搬移。")
                .font(.footnote)
                .foregroundStyle(Color(.onChromeMuted))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private func place(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color(.brandSeafoam))
                .frame(width: 32)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Color(.brandIvory))
                Text(text).font(.subheadline).foregroundStyle(Color(.onChromeMuted))
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.surface), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.onChromeMuted).opacity(0.4)) }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    IntroView {}
}
