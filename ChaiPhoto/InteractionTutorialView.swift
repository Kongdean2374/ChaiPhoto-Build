import SwiftUI

enum MediaTutorialKind: Equatable {
    case photo
    case video
}

struct InteractionTutorialView: View {
    let kind: MediaTutorialKind
    let deleteOnRight: Bool
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            ScrollView {
            VStack(spacing: 20) {
                Image(systemName: kind == .photo ? "photo.fill" : "play.rectangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)

                Text(kind == .photo ? L("照片操作", "Photo controls") : L("影片操作", "Video controls"))
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                VStack(spacing: 14) {
                    if kind == .photo {
                        tutorialRow(
                            "arrow.left.and.right",
                            deleteOnRight
                                ? L("左右滑：左滑保留、右滑待刪", "Swipe left/right: left keeps, right marks for deletion")
                                : L("左右滑：左滑待刪、右滑保留", "Swipe left/right: left marks for deletion, right keeps")
                        )
                        tutorialRow(
                            "arrow.up",
                            L("上滑：選擇一個或多個相簿", "Swipe up: choose one or more albums")
                        )
                        tutorialRow(
                            "heart.fill",
                            L("照片中央雙擊：加入／取消 iOS 喜好項目", "Double-tap the photo center: toggle iOS Favorite")
                        )
                        tutorialRow(
                            "hand.tap",
                            L("點一下或長按：開啟完整預覽", "Tap or hold: open the full preview")
                        )
                    } else {
                        tutorialRow(
                            "arrow.up.arrow.down",
                            L("上下滑：像短影音一樣切換上一部／下一部", "Swipe up/down: move through videos like a short-video feed")
                        )
                        tutorialRow(
                            "pause.fill",
                            L("單點：播放／暫停", "Single tap: play/pause")
                        )
                        tutorialRow(
                            "gobackward.10",
                            L("左側雙擊：倒退 10 秒", "Double-tap left: back 10 seconds")
                        )
                        tutorialRow(
                            "heart.fill",
                            L("中間雙擊：加入／取消 iOS 喜好項目", "Double-tap center: toggle iOS Favorite")
                        )
                        tutorialRow(
                            "goforward.10",
                            L("右側雙擊：快進 10 秒", "Double-tap right: forward 10 seconds")
                        )
                        tutorialRow(
                            "rectangle.stack.badge.plus",
                            L("右側「相簿」：加入一個或多個相簿", "Album button: add to one or more albums")
                        )
                    }
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))

                Button(L("知道了", "Got it")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
            .padding(24)
            }
        }
        .transition(.opacity)
    }

    private func tutorialRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.white)

            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
