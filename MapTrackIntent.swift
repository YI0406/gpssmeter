import AppIntents
import UIKit

struct MapTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "地圖軌跡"
    static var description = IntentDescription("開啟地圖模式")

    static var parameterSummary: some ParameterSummary {
        Summary("Open map track mode")
    }

    func perform() async throws -> some IntentResult {
        // 呼叫 URL Scheme，讓 Flutter 端處理
        if let url = URL(string: "gpssmeter://maptrack") {
            await UIApplication.shared.open(url)
        }
        return .result()
    }
}//
//  MapTrackIntent.swift
//  Runner
//
//  Created by 詹子逸 on 2025/9/2.
//

