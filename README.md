# Morrow RAW for macOS

這是 Morrow RAW 的原生 macOS SwiftUI RAW 相片編輯器，專為 Apple Silicon
Mac 與 Apple GPU Metal pipeline 優化。

## 用 Xcode 開啟

1. 用 Xcode 開啟 `Package.swift`。
2. 選擇 `MorrowRAW` scheme。
3. 選擇一個 macOS My Mac destination。
4. 按 Run 執行。

若要產生 Apple Silicon ARM64 專用 `.app`：

```sh
./build-app.sh
open dist/MorrowRAW.app
```

也可以使用明確命名的 ARM64 建置腳本：

```sh
./build-arm64-app.sh
open dist/MorrowRAW-arm64.app
```

若仍需要同時支援 Apple Silicon 與 Intel Mac 的 Universal 2 App（舊版相容性路徑）：

```sh
./build-universal-app.sh
open dist/MorrowRAW-universal.app
```

若要產生可直接分發的 Apple Silicon ARM64 DMG：

```sh
./package-dmg.sh
open dist/MorrowRAW-0.1.0-arm64.dmg
```

`build-universal-app.sh` 仍保留作為舊版 Intel/Apple Silicon 相容性建置，但不再是預設發布路徑。

DMG 內含 `Applications` 捷徑；正式發布時可用 `SIGNING_IDENTITY` 指定 Developer ID
Application 身份，並另行完成 Apple notarization。

建置腳本預設使用 adhoc signing；若已安裝 Apple Developer 憑證，可指定正式簽署身份：

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
```

需求：macOS 13 或更新版本、Xcode 15 或更新版本。

## 目前支援

- RAW：ARW、SR2、SRF、CR2、CR3、CRW、NEF、NRW、RAF、RW2、ORF、PEF、DNG
- 一般影像：JPEG、PNG、TIFF、BMP、HEIC
- 支援從 Finder 拖曳照片或資料夾到視窗開啟
- 最近開啟資料夾記錄（最多 20 筆）
- 支援從 Finder 一次開啟多張照片並建立縮圖列
- 資料夾照片可隱藏／恢復，狀態保存於 `RAW_TEMP/preview_list.macos.json`
- 隱藏照片即使在「顯示隱藏」模式下也不會進入批次匯出
- Core Image RAW 解碼與既有 `RAW_TEMP/*.rawpipe.png` proxy fallback
- 無 XML 快取時直接從 ImageIO 讀取 EXIF 與影像尺寸 metadata
- 即時 64-bin 亮度直方圖
- 曝光、對比、亮部、暗部、白色、黑色、色溫、色調、鮮豔度、飽和度
- 預覽取樣白平衡滴管（自動設定色溫與色調）
- 銳化、降噪、暗角、變形修正、90° 旋轉、精細旋轉、裁切
- 裁切比例支援自訂寬:高格式
- 線性漸層：讀取、保存、預覽渲染，以及基本調整控制
- 修補點：clone/inpaint 近似渲染、位置/半徑控制，以及預覽區拖曳筆刷
- JPEG、PNG、TIFF、BMP 匯出
- 已開啟資料夾的全部照片批次匯出（JPEG / PNG / TIFF / BMP；每張照片讀取自己的調整 XML）
- 批次編輯：將目前調整或內建 preset 套用到資料夾全部照片，保留各照片 EXIF
- 縮圖多選與批次套用目前調整或內建 preset 到選取照片
- 照片調整複製／貼上（Shift-Command-C / Shift-Command-V；貼上保留目標照片 EXIF）
- 匯出浮水印：文字、字型、大小、透明度、邊距、顏色與四角位置
- JPEG 品質控制
- 匯出長邊尺寸上限：原尺寸、1200、2400、4000 或 6000 px
- 匯出 DPI（72 / 150 / 300 / 600）與 EXIF metadata 保留選項
- 批次匯出命名規則：原檔名、日期時間、流水號
- 批次匯出檔案衝突策略：自動編號或覆寫
- 匯出偏好持久化：品質、尺寸、DPI、EXIF、命名、衝突策略與浮水印
- 內建風景、人像、鮮豔、黑白、柔和等預設風格
- 自訂 preset 持久化：保留自訂1～3相容槽位，也可建立任意名稱
- 自訂 preset JSON 備份與還原
- System / Dark / Light 介面外觀選擇並持久化
- 原生「關於 Morrow RAW」視窗，顯示版本、授權、來源與 RAW 解碼說明
- 預覽縮放、Fit 與 trackpad magnification
- ARM64-only 建置；NLM、CIE Lab 色彩調整與 Brown–Conrady 變形修正使用 Apple GPU Metal kernel
- 對照原圖預覽：保留裁切／旋轉幾何，不改寫實際調整值
- Before/After 對照：左側原圖、右側已編輯，分割線可拖曳；快捷鍵 `⌘⇧B`
- Undo / Redo（最多保留 50 個調整狀態）
- 讀取與保存 `RAW_TEMP/<檔名>.rawpipe.xml`
- 虛擬副本：新增與切換 `RAW_TEMP/<檔名>.copyN.rawpipe.xml`

## 命令列驗證

在專案根目錄執行：

```sh
swift test
swift build -c release
```

實際相機 RAW 是否能由 Apple RAW 解碼器直接開啟，仍需使用對應相機的樣本檔案驗證；若同資料夾存在 `RAW_TEMP` proxy，macOS 版本會優先使用該 proxy 作為 fallback。

修補點目前以圓形 feather mask 搭配 clone 或局部 blur 近似原 Windows 的修補演算法；拖曳筆刷目前建立連續 inpaint 點。
