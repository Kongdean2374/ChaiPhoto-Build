import SwiftUI

struct WelcomeGuide: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    let finished: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(
                        systemName: page == 0
                            ? "hand.draw"
                            : "play.rectangle"
                    )
                    .font(.system(size: 44))
                    .foregroundStyle(.indigo)

                    if page == 0 {
                        Text(L("先認識照片操作", "Photo gestures"))
                            .font(.title.bold())

                        Text(
                            settings.deleteOnRight
                                ? L(
                                    "左滑保留，右滑待刪。",
                                    "Swipe left to keep, right to mark for deletion."
                                )
                                : L(
                                    "左滑待刪，右滑保留。",
                                    "Swipe left to mark for deletion, right to keep."
                                )
                        )

                        Text(L(
                            "上滑選相簿；中央雙擊切換系統喜好項目。點一下或長按看完整照片，預覽可雙指縮放。",
                            "Swipe up for albums; double-tap the center to toggle system Favorite. Tap or hold to preview; pinch to zoom in the preview."
                        ))

                        Text(L(
                            "滑動只做標記，真正刪除要到「待刪」頁複查後執行。",
                            "Swipes only mark items. Actual deletion happens after you review the Review tab."
                        ))
                    } else {
                        Text(L("影片操作", "Video gestures"))
                            .font(.title.bold())

                        Text(L(
                            "上滑保留並看下一部，下滑復原上一部。載入中也能跳過。",
                            "Swipe up to keep and advance; swipe down to undo the previous video. You can skip while loading."
                        ))

                        Text(L(
                            "點一下播放／暫停；左側雙擊倒退 10 秒，右側雙擊快進 10 秒；中央雙擊切換系統喜好項目。",
                            "Tap to play/pause; double-tap left to rewind 10 seconds, right to advance 10 seconds, or center to toggle Favorite."
                        ))

                        Text(L(
                            "右側可標記待刪、加入相簿、分享及查看資訊；底下可拖曳播放進度。",
                            "Use the side controls for deletion marks, albums, sharing and information. Drag the bottom slider to seek."
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if page == 0 {
                        Button(L("下一步", "Next")) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                page = 1
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(L("開始使用", "Start")) {
                            finish()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(L("上一步", "Back")) {
                            page = 0
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
            .navigationTitle(L("開始使用", "Welcome"))
            .interactiveDismissDisabled()
        }
    }

    private func finish() {
        UserDefaults.standard.set(
            true,
            forKey: "tutorial.photo.interactions.v2"
        )
        UserDefaults.standard.set(
            true,
            forKey: "tutorial.video.interactions.v2"
        )

        finished()
        dismiss()
    }
}
