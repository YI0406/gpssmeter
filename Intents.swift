import AppIntents
import UIKit

struct OpenGpsAppIntent: AppIntent {
    static var title: LocalizedStringResource = "快速進入地圖模式請選：maptrack"

    func perform() async throws -> some IntentResult {
        // ⚠️ 僅限前景觸發時有效，背景執行會失敗
        if let url = URL(string: "gpssmeter://maptrack") {
            await MainActor.run {
                UIApplication.shared.open(url)
            }
        }
        return .result()
    }
}

struct OpenAccelModeIntent: AppIntent {
    static var title: LocalizedStringResource = "快速進入加速模式請選：accel"

    func perform() async throws -> some IntentResult {
        if let url = URL(string: "gpssmeter://accel") {
            await MainActor.run {
                UIApplication.shared.open(url)
            }
        }
        return .result()
    }
}
