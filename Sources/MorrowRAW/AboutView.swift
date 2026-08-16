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
            Text(StudioText.localized("原生 macOS RAW 相片編輯器", "Native macOS RAW photo editor"))
                .foregroundStyle(.secondary)
            Text(StudioText.localized("版本 \(version)", "Version \(version)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Copyright © 2026 Morrow RAW")
            Text(StudioText.localized("本程式以 BSD 3-Clause 授權發布。\n來源：Morrow RAW",
                                     "Released under the BSD 3-Clause License.\nSource: Morrow RAW"))
                .multilineTextAlignment(.center)
                .font(.callout)
            Text(StudioText.localized(
                "RAW 解碼使用 macOS Core Image；若系統無法解碼，會嘗試使用 RAW_TEMP proxy。",
                "RAW decoding uses macOS Core Image; RAW_TEMP proxy is used if the system decoder fails."
            ))
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Link(StudioText.localized("專案網站", "Project website"),
                     destination: URL(string: "https://github.com/liminghuang/MorrowRAW")!)
                Button(StudioText.localized("關閉", "Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 430)
    }
}
