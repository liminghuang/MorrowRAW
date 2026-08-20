# Morrow RAW for macOS

Morrow RAW 是使用 SwiftUI、Core Image 與 Metal 開發的原生 macOS RAW 相片
編輯器，針對 Apple Silicon 設計，提供流暢的瀏覽、非破壞式編輯與匯出工作流。

[English README](README.md)

## 特色

- 原生 RAW 工作流：Core Image RAW 解碼、照片資訊檢視，以及持久化的 sidecar
  調整檔。
- 非破壞式編輯：曝光與色調控制、白平衡取樣、裁切／旋轉、漸層遮罩、修補點、
  preset，以及可拖曳分割線的 Before/After 對照。
- Morrow Natural Color Assistant：可解釋的裝置端色彩建議、waveform／vectorscope／
  clipping scopes、Vision 語意遮罩、ColorChecker 相機校正，以及參考照片匹配。
- 大型資料夾批次處理：可取消、逐步顯示進度、每張照片獨立套用調整、保留
  metadata，並支援 JPEG／PNG／TIFF／BMP 匯出。
- Apple Silicon 渲染路徑：非同步 Metal 處理、共用 texture pool、限制 GPU
  併發量，以及依畫布大小調整預覽解析度。

## 效能設計

macOS 版本將影像處理研究中常見的多尺度、非同步與資源管理概念，應用在實際
編輯流程：

- 多尺度預覽降低 RAW 影像進入渲染圖形的資料量，同時保留完整解析度來源供匯出。
- 可取消的非同步 pipeline 避免資料夾掃描、縮圖解碼、RAW 讀取與預覽渲染阻塞 UI。
- 重用 Metal texture、限制工作佇列與快取成本，控制大量高解析度 RAW 瀏覽時的 GPU
  與記憶體壓力。
- 直方圖、metadata 讀取與批次匯出分開排程，避免昂貴分析工作搶占使用者目前的操作。

目前已使用最高 8192×5464 的 Canon CR3 樣本進行驗證。實際 RAW 相容性仍取決於
相機型號與主機 macOS 版本提供的 Apple RAW 解碼器。

## App 截圖

![Morrow RAW 編輯畫面](Assets/Screenshots/morrow-raw-editor.png)

![Morrow RAW Before/After 對照](Assets/Screenshots/morrow-raw-before-after.png)

## 使用 Xcode 建置

1. 用 Xcode 開啟 `Package.swift`。
2. 選擇 `MorrowRAW` scheme。
3. 選擇 macOS My Mac destination。
4. 按 Run 執行。

產生 Apple Silicon ARM64 App：

```sh
./build-app.sh
open dist/MorrowRAW.app
```

產生 Apple Silicon DMG：

```sh
./package-dmg.sh
open dist/MorrowRAW-0.1.0-arm64.dmg
```

若需要 Intel 相容性，仍可使用舊版 Universal 2 建置：

```sh
./build-universal-app.sh
open dist/MorrowRAW-universal.app
```

建置腳本預設使用 adhoc signing；正式發布時可指定 Developer ID：

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
```

需求：macOS 13 或更新版本、Xcode 15 或更新版本。

## 驗證

```sh
swift test
swift build -c release
```

本專案預設產出的 App 沒有完成簽署或 notarization。macOS 本機測試時可能需要
在 Finder 選擇「打開」，或移除 quarantine 屬性：

```sh
xattr -dr com.apple.quarantine dist/MorrowRAW.app
open dist/MorrowRAW.app
```
