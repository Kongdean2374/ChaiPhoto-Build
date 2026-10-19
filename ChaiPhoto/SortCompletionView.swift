import SwiftUI

struct SortCompletion: Identifiable {
    let id = UUID()
    let title: String
    let time: String
    let total: Int
    let kept: Int
    let marked: Int
    let deleted: Int
}
struct SortCompletionView: View {
    let result: SortCompletion
    let nextMonth: Date?
    let onNext: (Date) -> Void
    let onOther: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 42)).foregroundStyle(.green)
                        .frame(width: 80, height: 80).background(Color.green.opacity(0.10), in: Circle())
                    Text(L("這個範圍整理完成", "Selection complete")).font(.title2.bold())
                    Text(result.title + "\n" + result.time).multilineTextAlignment(.center)
                    VStack(spacing: 12) {
                        LabeledContent(L("範圍內項目", "Items in selection"), value: String(result.total))
                        LabeledContent(L("已保留", "Kept"), value: String(result.kept))
                        LabeledContent(L("已標記待刪", "Marked for deletion"), value: String(result.marked))
                        LabeledContent(L("已由系統刪除", "Deleted by iOS"), value: String(result.deleted))
                    }.padding(18).modifier(ChaiPanel(tint: .green))
                    Text(L("以上為此範圍累計結果，包含先前整理的項目。待刪標記不代表已刪除，也不代表已釋放空間；請到待刪頁複查。", "These are cumulative results for this selection, including earlier decisions. Marked items are not yet deleted and no space recovery is implied. Review them in the Review tab.")).font(.caption).foregroundStyle(.secondary)
                    if let nextMonth {
                        Button(L("繼續整理 ", "Continue with ") + monthLabel(nextMonth)) { onNext(nextMonth) }.buttonStyle(.borderedProminent)
                    }
                    Button(L("其他範圍", "Choose another selection"), action: onOther).buttonStyle(.bordered)
                    Button(L("完成", "Done")) { dismiss() }
                }.padding(24).frame(maxWidth: .infinity)
            }.navigationTitle(L("整理小結", "Summary")).navigationBarTitleDisplayMode(.inline)
        }
    }
}
struct GestureReferenceView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L("照片", "Photos")).font(.title2.bold())
                Text(settings.deleteOnRight ? L("左滑保留、右滑待刪。", "Swipe left to keep, right to mark.") : L("左滑待刪、右滑保留。", "Swipe left to mark, right to keep."))
                Text(L("上滑開啟相簿；中央雙擊切換喜好項目；點一下或長按完整預覽；預覽可雙指縮放、雙擊放大。", "Swipe up for albums; double-tap the center for Favorite; tap or hold for a full preview; pinch or double-tap to zoom."))
                Text(L("影片", "Videos")).font(.title2.bold())
                Text(L("上滑保留並看下一部，下滑復原上一部；點一下播放／暫停；左／右側雙擊倒退／快進 10 秒；中央雙擊喜好項目。載入中也可以跳過。", "Swipe up to keep and advance, down to undo the previous video. Tap to play/pause, double-tap left/right to seek 10 seconds, center for Favorite. Loading videos can be skipped."))
                Text(L("複查與紀錄", "Review & history")).font(.title2.bold())
                Text(L("待刪頁點縮圖取消／恢復勾選，長按看完整內容。操作紀錄點縮圖或文字預覽，右側箭頭直接復原標記；已系統刪除的項目不能由 App 復原。", "Tap Review thumbnails to exclude/include, hold to preview. Tap a history thumbnail or text to preview; its arrow directly undoes the decision. The app cannot restore completed system deletions."))
            }.padding(24)
        }.navigationTitle(L("手勢教學", "Gesture guide"))
    }
}
