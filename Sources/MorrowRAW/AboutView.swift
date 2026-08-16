import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("Morrow RAW")
                .font(.title2.weight(.semibold))
            Text("原生 macOS RAW 相片編輯器")
                .foregroundStyle(.secondary)
            Text("版本 \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Copyright © 2026 Awaysu")
            Text("本程式以 BSD 3-Clause 授權發布。\n來源：Morrow RAW / Awaysu")
                .multilineTextAlignment(.center)
                .font(.callout)
            Text("RAW 解碼使用 macOS Core Image；若系統無法解碼，會嘗試使用 RAW_TEMP proxy。")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Link("專案網站", destination: URL(string: "https://github.com/liminghuang/MorrowRAW")!)
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 430)
    }
}
