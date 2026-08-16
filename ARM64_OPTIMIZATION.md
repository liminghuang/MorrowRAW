# ARM64 / Apple GPU 最佳化

macOS 發布路徑現在只產出 Apple Silicon ARM64，不再為預設建置付出 Intel slice 的大小與建置時間成本。

## 建置與驗證

```sh
cd macos
./build-app.sh
./package-dmg.sh

file dist/MorrowRAW.app/Contents/MacOS/MorrowRAW
lipo -info dist/MorrowRAW.app/Contents/MacOS/MorrowRAW
```

預期執行檔結果是 `architecture: arm64`，而不是 fat/universal binary。產物位於：

- `dist/MorrowRAW.app`
- `dist/MorrowRAW-<version>-arm64.dmg`

## 目前已導入的路徑

- Metal：`Resources/ImageKernels.metal` 提供非區域平均降噪、CIE Lab chroma 調整、Brown–Conrady radial distortion；`MetalImageProcessor` 負責 pipeline、texture 與 command buffer。
- Metal 迭代式修補：`teleaIterative` 以平行 radial frontier 逐層推進，`poissonIterative` 以多次 Jacobi dispatch 進行 gradient-domain clone；每一輪使用 ping-pong textures。
- 非同步 Metal：預覽使用 `addCompletedHandler` 與 Swift concurrency continuation，GPU 完成前不阻塞 preview worker；新調整會取消過期的 preview task。
- Texture pool：重用 input 與非輸出 scratch textures；仍由 CIImage 持有的 final texture 不會提前回收，避免資料競爭。
- 預覽品質分級：互動中限制 900px、修補迭代約 35%；停止調整 180ms 後再產生 1800px 高品質預覽。
- simd：變形參數與 Metal uniforms 使用 `SIMD2<Float>`，避免手動拆解向量並讓 Apple Silicon 使用原生向量型別。
- Accelerate：直方圖正規化使用 vDSP，將最大值搜尋與除法交給 Apple 的向量化實作。
- half：NLM、Telea 與 Poisson 的鄰域累加使用 `half3`，座標、權重與迭代控制保留 `float`。
- Threadgroup memory：Poisson kernel 將每個 threadgroup 的 4-neighbour tile 暫存於 shared tile，減少對 `previous` texture 的重複讀取。
- 多修補點：不重疊的修補點使用 Swift task group 並行送入 GPU；重疊區域維持序列處理以保留結果語義。
- CPU fallback：Metal 初始化失敗或影像超過 4 megapixels 時，降噪與 Lab 調整回到既有 Core Image/CPU 安全路徑；這確保匯出與測試不因 GPU 資源狀態而中斷。

Telea-style inpainting 與 Poisson-style clone 現在以 Metal 迭代 kernel 作為 ARM 預覽主路徑；原本 CPU 實作仍保留作 shader 初始化失敗時的 correctness fallback。GPU 迭代路徑仍限制單次修補半徑 180 px、影像 4 megapixels，避免在 UI 預覽中配置過大的 ping-pong texture。

## 可重現驗證

```sh
swift test
```

`CompatibilityTests.testAppleGPUKernelsCanProcessPreviewTextures` 會實際建立 Apple GPU 的 Metal library、五個 compute pipeline，並檢查兩個迭代修補 kernel 的輸出確實不同於輸入。`testAsyncMetalPreviewPipelineCompletesRepairWithoutBlockingWait` 驗證 async repair preview；`testMetalRepairPerformanceAndMemoryBudget` 使用 XCTest clock/memory metrics 記錄基準。建置後再以 `codesign --verify --deep --strict` 與 `hdiutil imageinfo` 驗證 app/DMG。
