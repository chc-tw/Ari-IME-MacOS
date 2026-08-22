# Ari IME — macOS (Tahoe / macOS 26) 移植規格與計畫

狀態：v2 草案，待確認。
流程依據 `agent-skills` 流程圖：本文件為 **spec-driven-development** 產出的規格，
後續每個里程碑以 **incremental-implementation + test-driven-development** 執行，
合併前走 **code-review-and-quality**。

---

## 0. 假設（ASSUMPTIONS）—— 錯的話現在糾正我

1. **核心程式碼零修改**。`src/{buffer,zhuyin,layout,unicode}.{cpp,h}` 一行都不動。
   這是「功能保持一致」的唯一可驗證保證：相同的核心 + 相同的測試套件。
   任何需要動核心的需求都必須先討論。
2. **macOS 版與 Linux 版共用同一份 repo 與同一套核心測試**，只是多一個前端。
   不 fork、不複製核心。
3. **這是移植，不是重新設計**。輸入行為（狀態機、注音、候選、學習）完全照搬；
   只有「平台介面」（快捷鍵、設定 UI、候選視窗外觀、安裝方式）會 macOS 化。
4. **最低支援 macOS 14.0，於 macOS 26 (Tahoe) 驗證**。低於 14 不測。
5. **不做 App Sandbox**。輸入法需要讀寫 `~/Library/Application Support` 與
   全域鍵盤事件，沙盒化會大幅增加複雜度且非必要（Squirrel/RIME 等皆未沙盒）。
6. **簽章/公證留到 M5**，開發期用本機自簽 + `codesign --force --deep`。

---

## 1. 現況分析

### 1.1 這個專案已經是「核心 + 前端」結構

| 檔案 | 行數 | 平台相依性 |
|------|------|-----------|
| `src/buffer.cpp/h` | 2622 | **無**（只用到 `fcitx::Key::sym()` / `states()`） |
| `src/zhuyin.cpp/h` | 834 | 只依賴 libchewing C API |
| `src/layout.cpp/h` | 478 | 只依賴 `FCITX_CONFIG_ENUM_NAME` 巨集與 `_()` |
| `src/unicode.h` | 257 | 無 |
| `src/dict_tool.cpp` | 429 | 無（只 include `user_data.h` / `zhuyin.h`） |
| `src/user_data.cpp/h` | 101 | **平台相依**（XDG 路徑）— 已設計成可抽換 |
| `src/inputer.cpp/h` | 586 | **Fcitx5 前端，整個重寫** |

`wasm/` 已證明此切法可行：147 行的 fcitx stub header + 一份平台專屬
`user_data.cpp`，核心即可在無 Fcitx5 環境編譯。

**macOS 移植 = 沿用 100% 核心 + 新寫 InputMethodKit 前端 + 新寫 `user_data.mm`。**

### 1.2 測試套件：已從 git 歷史回復 ✅

原本以為要從零重建。實際上 `/test/` 只是被 `.gitignore` 排除、在 commit
`317ecb2`（release: prepare 2.5.1）被刪除，但**完整存在於 git 歷史**。
已用 `git checkout 317ecb2^ -- test wasm/test` 回復：

| 檔案 | 行數 | 內容 |
|------|------|------|
| `test/test_buffer.cpp` | 2533 | **53 個測試函式**，涵蓋狀態機全部行為 |
| `test/test_user_data.cpp` | 424 | 12 個測試，聚焦「學習行為」（非路徑解析） |
| `test/test_layout.cpp` | 198 | 2 個測試，11 種配列分類 |
| `test/test_common.h` | 116 | 沙盒化環境的測試 harness |
| `test/test_dict_tool.sh` | 62 | CLI export/import/info/candidates |
| `test/test_enable_input_method.sh` | 131 | **Fcitx5 專屬，macOS 需重寫** |
| `test/fuzz_buffer.cpp` + corpus | 249+4 | libFuzzer 狀態機模糊測試 |
| `wasm/test/{native_api.cpp,node_api.mjs}` | 80 | headless API |

這徹底改變了計畫：**M1 從「寫 95 個測試」變成「讓既有 3793 行測試在 macOS 通過」**，
而且它成為功能一致性的**迴歸基準**——同一份測試，Linux 過、macOS 也要過。

這些檔案維持 **untracked**（沿用上游 `.gitignore` 的 `/test/` 排除），
與上游慣例一致。回復方式已記錄於此，重新 clone 後執行即可。

### 1.3 缺少的東西

- Homebrew **沒有** libchewing formula → 必須自行 vendor 建置。
- 測試套件**沒有**涵蓋：`user_data` 路徑解析、`Zhuyin` 直接單元測試、
  以及全部 macOS 前端邏輯。這些是本次真正要新寫的部分（見 §4.2）。

---

## 2. 目標架構

```
compat/include/            ← wasm/include/ 升格成共用 fcitx 相容層
    fcitx-utils/{key.h,keysym.h,i18n.h}
    fcitx-config/{enum.h,rawconfig.h}

src/                       ← 不動（核心）

macos/
    CMakeLists.txt
    user_data.mm           ← ~/Library/Application Support/AriIME/
    KeyMap.mm/.h           ← NSEvent → fcitx::Key + 快捷鍵映射（純函式）
    AriInputController.mm  ← IMKInputController
    AriCandidateWindow.mm  ← 自繪 NSPanel（IMKCandidates 無法顯示輔助行）
    AriHUD.mm              ← 中/英 提示
    AriPreferences.mm      ← 設定視窗 + NSUserDefaults
    AriApp.mm              ← IMKServer main
    AriIME.app/Info.plist

third_party/libchewing/    ← submodule，靜態連結，字典打包進 .app
test/                      ← 回復的既有套件 + 新增（見 §4）
test/macos/                ← 新增前端測試
```

### 2.1 Fcitx5 → macOS 對應

| Fcitx5 | macOS / InputMethodKit |
|--------|------------------------|
| `InputMethodEngineV2::keyEvent` | `-handleEvent:client:` |
| `setClientPreedit()` | `-setMarkedText:selectionRange:replacementRange:` |
| `commitString()` | `-insertText:replacementRange:` |
| `CommonCandidateList` + AuxUp/AuxDown | 自繪 `NSPanel` |
| `showCustomInputMethodInformation` | 短暫 HUD `NSPanel` |
| clipboard addon | `NSPasteboard.generalPasteboard` |
| `CapabilityFlag::SurroundingText` | `-attributedSubstringFromRange:` + `-selectedRange` |
| `CapabilityFlag::PasswordOrSensitive` | `IsSecureEventInputEnabled()` |
| fcitx5-configtool | .app 內建設定視窗 + `NSUserDefaults` |
| `ari-ime-enable` | `TISRegisterInputSource` + 安裝 script |

### 2.2 已知的功能落差（誠實揭露）

| 項目 | 落差 |
|------|------|
| 反轉換刪除原文 | Fcitx5 有 `deleteSurroundingText`；macOS 靠 `replacementRange`，在不支援的 app（多數 Electron）會失效 → 需偵測並降級為不啟用 |
| 輔助行 | IMK 原生候選視窗沒有；自繪視窗解決，但多螢幕/全螢幕定位需額外處理 |
| Secure Input | macOS 只給「全系統是否啟用」的布林值，粒度比 Fcitx5 的 per-context capability 粗 → 偏保守（啟用時一律不學習） |

### 2.3 快捷鍵：macOS 安全預設 + 可設定（回應你的第 2 點）

**問題**：核心 `buffer.cpp` 把 `Ctrl+Space`（中英切換）和 `Alt+[` / `Alt+]`
（角落引號）**寫死**了（`buffer.cpp:825`、`buffer.cpp:885`）。要讓它們可設定，
表面上得改核心——但那會破壞假設 1。

**解法：把映射併進 `macos/KeyMap.mm`**（已決定，2026-08-21）。
`NSEvent → fcitx::Key` 的對照表本來就必須存在，快捷鍵映射只是表中多幾個條目，
不是新增一層。使用者按 `⌃⌥E`，對照表直接產出 `Key(space, Ctrl)` 餵給 `Buffer`。

評估過的替代方案是「改核心讓快捷鍵可設定」，已否決：那會動到 `handleKey`/
`handleAuto` 的分派路徑（2622 行、53 個測試護著）、要改既有測試的預期值、
並讓這個 fork 的核心與上游永久分歧，破壞「同一份核心 + 同一份測試」的迴歸基準。
對照表方案的成本是 5 行純函式，風險為零。

**macOS 預設值**（原則：避開 macOS 保留鍵，且不產生文字）：

| 功能 | Linux 預設 | macOS 衝突 | **macOS 新預設** |
|------|-----------|-----------|-----------------|
| 中/英 切換 | `Ctrl+Space` | ⌃Space = 系統切換輸入源 | **`⌃⌥E`** |
| 角落引號 「」 | `Alt+[` / `Alt+]` | ⌥[ / ⌥] 產生 `“` `‘` | **`⌃⌥[` / `⌃⌥]`** |
| 中文標點 | `Ctrl+Shift`+符號 | 無衝突 | 維持 `⌃⇧`（可改 ⌃⌥） |
| 反轉換 | `Ctrl+Alt+R` | 無系統衝突 | 維持 **`⌃⌥R`** |
| 還原選字 | `Ctrl+Z` | macOS 用 ⌘Z，⌃Z 空著 | 維持 `⌃Z` |
| 忘記候選 | `Shift+Delete` | 無衝突（⌫） | 維持 `⇧⌫` |

⌃⌥（Control+Option）作為 Ari 的專屬命名空間：macOS 在此組合只保留了
`⌃⌥Space`（切換輸入源），我們完全避開 Space。全部項目在設定頁可改。

**這是 macOS 版與 Linux 版唯一的行為差異，且是刻意的。** 已在假設 3 的
「平台介面 macOS 化」範圍內。

### 2.4 libchewing

**已解決（M0）：採用 v0.12.0**，與 Linux 版目標版本相同，無需任何 legacy
相容路徑。建置方式見 `macos/build-libchewing.sh` 與 §6。

---

## 3. 里程碑（每個都有可驗證的驗收條件）

| M | 內容 | 驗收條件（Definition of Done） |
|---|------|-------------------------------|
| **M0** ✅ | libchewing on macOS + `compat/` 相容層 + 核心靜態庫 | ~~`ari-ime-dict info` 在 macOS 印出資料目錄與 libchewing 版本~~ **完成，見 §6** |
| **M1** | 既有測試套件在 macOS 通過 | `ctest` 全綠：`test_buffer`(53) / `test_layout` / `test_user_data` / `test_dict_tool`；產生覆蓋率基線數字 |
| **M2** | **可 demo 的 IMK 前端** | 在 TextEdit 打出 `acer螢幕`、Enter 送出、Down 開候選、數字選字。外觀陽春 |
| **M3** | 功能對齊 | 剪貼簿、反轉換、數字鍵盤、標點、學習、Secure Input；`test/macos/` 全綠 |
| **M4** | 設定視窗 / 候選視窗外觀 / 快捷鍵 UI | **先討論設計再實作**；§2.3 的預設值先寫死，此階段才做設定 UI |
| **M5** | 打包 | `.app` + 安裝器 + 簽章公證說明；`docs/manual-qa-macos.md` 走完 |

M0 → M2 是「證明可行」，我建議一路做到 M2 再停下來討論。
M0 若卡在 libchewing，我會立刻回報，不會悶頭硬幹。

---

## 4. 測試策略

### 4.1 L1 核心測試 —— 既有套件（回復，不重寫）

53 個 `test_buffer` 函式已涵蓋 README 幾乎所有聲明：
typing / tone-1 由轉換結果決定 / 五種以上配列 / 數字鍵盤字面與導覽 / commit /
強制英文 / backspace / 片語優先 / 尾端片語推薦 / live preview / 反轉換核心 /
片語選取 / 直接點選 / 過期點選忽略 / pin 先前選擇 / 候選排序 / Ctrl+Z undo /
符號密集情境 / 中插 / 貼上與 grapheme / 中插刪除 / Up 導覽 / 原始鍵還原 /
分頁 / Tab 導覽 / reinterpret / 選字中打字 / 選字後 commit / 游標編輯 /
片語游標導覽 / 長候選對齊 / Escape / 全形標點 / 模糊符號邊界 / 決定性壓力測試。

`test_user_data`(12) 涵蓋學習權重、sensitive 欄位、sidecar、忘記候選、字典遷移。

**這些一行都不改**（改了就不叫迴歸基準）。macOS 上唯一要處理的是
`test_common.h` 的沙盒環境變數需加上 macOS 路徑（見 G1）。

### 4.2 新增測試（這才是本次真正要寫的）

| # | 測試 | 為何既有套件沒有 |
|---|------|-----------------|
| G1 | `user_data` 路徑解析：Application Support 預設、`INPUTER_USER_DATA_DIR` 覆寫、無 HOME、目錄不可寫、`resetUserDictionary` | 既有 `test_user_data` 只測學習行為 |
| G2 | `Zhuyin` 直接單元測試（候選 API、片語區間、反查、sidecar 原子寫入） | 既有只透過 `Buffer` 間接測 |
| G3 | `KeyMap`：字母/數字/符號/方向鍵/Home/End/Page/Delete/Esc/Tab/Shift+Tab/數字鍵盤全套/修飾鍵位元 | macOS 全新 |
| G4 | `KeyMap` 快捷鍵映射：⌃⌥E → `Ctrl+Space`、⌃⌥[ → `Alt+[`、自訂值往返、衝突偵測 | macOS 全新 |
| G5 | Controller（fake IMK client）：marked text 內容/底線/游標、`insertText` 只呼叫一次、`handled==false` 交還 app | macOS 全新 |
| G6 | 候選視窗資料模型：頁碼、highlight、輔助行文字與 `Buffer` 一致；點擊走 `selectCandidate(i, expectedText)` | macOS 全新 |
| G7 | Secure Input → `setLearningAllowed(false)` | macOS 全新 |
| G8 | macOS 反轉換：取 selected range → `beginReconversion`；失敗不刪原文；Esc 還原 | macOS 全新 |
| G9 | `NSUserDefaults` 變更即時套用到 `Buffer` | macOS 全新 |
| G10 | 安裝/註冊腳本（`TISRegisterInputSource`）—— 取代 `test_enable_input_method.sh` | Fcitx5 專屬需重寫 |
| G11 | HUD 提示出現與自動消失 | macOS 全新 |

### 4.3 L3 人工驗收

新增 `docs/manual-qa-macos.md`：環境矩陣改為 TextEdit / Safari / VS Code
(Electron) / Terminal / 全螢幕 app；新增 Secure Input、輸入源切換、
多螢幕候選定位、深色模式。

### 4.4 覆蓋率

- 工具：`llvm-cov`（`-fprofile-instr-generate -fcoverage-mapping`）。
- **先在 M1 量出既有套件的基線數字**，再談要補到哪。憑空承諾百分比沒有意義。
- 立場不變：**行為覆蓋 100%**（README 每條聲明都有測試）可以做到；
  **行覆蓋 100%** 需要對檔案 I/O 失敗做錯誤注入，那要動 `src/`，
  與假設 1 衝突。建議目標 **≥95% + 逐條列出未覆蓋原因**。
  若你要硬性 100%，我們得先討論注入層怎麼加才不破壞核心。


---

## 6. M0 完成紀錄（2026-08-21）

### 結果

**核心在 macOS 上零修改編譯通過並實際運作。**

```
$ ari-ime-dict candidates su3
keys      su3
preedit   你
total     32
page      1/4
candidate 你 妳 擬 抳 馜 鑈 苨 隬 儗
```

### 產出

| 檔案 | 說明 |
|------|------|
| `macos/build-libchewing.sh` | 建置 libchewing v0.12.0 靜態庫 + 字典資料 |
| `macos/CMakeLists.txt` | macOS 專案根（`ari-core` 靜態庫 + `ari-ime-dict`） |
| `macos/user_data.mm` | macOS 資料路徑實作 |
| `compat/include/` | 由 `wasm/include/` 升格的共用 fcitx 相容層 |

`src/` **一行未改**。

### 建置路上踩到的坑（都已解決並寫進腳本）

1. **Rust 版本**：libchewing 0.12 要求 Rust ≥ 1.88，Homebrew 的 rust 是
   1.85.1 且在 PATH 前面。腳本改為優先使用 `~/.cargo/bin`（rustup stable 1.91.1）。
2. **CMake 版本**：`data/` 子模組要求 CMake ≥ 3.31.6，本機是 3.31.5 →
   已升級到 4.4.2。
3. **`data/` 是 git submodule**，需 `git submodule update --init --depth 1 data`。
4. **SQLite3 誤判**：CMake 在 `/Library/Frameworks/Mono.framework` 找到 3.26.0。
   已改用 `WITH_SQLITE3=false` —— 這也與 Ari 的目標一致（0.12 的 trie 後端
   使用 `chewing.dat` / `chewing-deleted.dat`，正是 `user_data.cpp` 處理的檔案）。
5. **libchewing 靜態建置無法用 CMake install**：`install(EXPORT)` 會因為
   Rust staticlib target 不在 export set 而失敗。腳本改為直接用
   `cargo build -p chewing_capi -p chewing-cli` 產出，再用 `chewing-cli init`
   編譯字典。（`capi/src/chewing.c` 是空檔案，靜態庫本體就是 Rust staticlib。）
6. **系統字典搜尋路徑**：macOS 沒有編譯進去的 `/usr/share/libchewing`。
   改用 libchewing 文件化的 `CHEWING_PATH` 環境變數，在
   `macos/user_data.mm` 的 `ensureUserDataDir()` 裡設定 ——
   平台路徑檔案本來就是負責這件事的地方，`src/zhuyin.cpp` 因此不需要 macOS 分支。

### 驗證過的附帶事項

- `compat/include/` 搬移後，wasm 的 headless 建置仍可編譯通過
  （用 `ARI_WASM_BUILD_NATIVE_TEST=ON` 在 macOS 驗證）。
  該測試執行時失敗屬預期：`INPUTER_WASM` 分支把系統路徑寫死為
  `/usr/share/libchewing`，那是 Emscripten 專用路徑，與本次變更無關。

### 待處理（記錄，M3 處理）

- 首次啟動時 libchewing 會在 stderr 印出
  `ERROR chewing::dictionary::loader] Dictionary file not found: chewing.dat`。
  0.12 改用 Rust 的 log crate，`src/zhuyin.cpp` 傳給 `chewing_new2` 的
  `quietChewingLogger` 攔不到。IME 前端需要處理（例如首次啟動建立空字典檔）。

---

## 7. M1 完成紀錄（2026-08-21）

### 測試結果

| 測試 | 結果 |
|------|------|
| `test_buffer`（53 個測試函式） | **19885 checks, 0 failures** ✅ |
| `test_layout` | ✅ |
| `dict_tool`（CLI export/import/info/candidates） | ✅ |
| `test_user_data` | 76 checks, **1 failure** ⚠️（見下） |

`src/` 仍然一行未改。

### libchewing 版本更正：0.12.0 → **0.13.1（Codeberg）**

第一次用了 GitHub 上的 v0.12.0，`test_buffer` 有一個排序斷言失敗
（`你應該試試` 得到 `你應該是是`）。追查後發現：

**libchewing 上游已從 GitHub 搬到 Codeberg**，GitHub 那份是停更鏡像
（最新 tag 只到 v0.12.0）。Arch 實際打包的是
`codeberg.org/chewing/libchewing` 的 **0.13.1**，而 Ari 的 CI 跑在 Arch 上，
所以既有測試是對著 0.13.1 驗證的。換成 0.13.1 後該斷言直接通過。

`macos/build-libchewing.sh` 已改為預設 `LIBCHEWING_VERSION=0.13.1` 並指向 Codeberg。

### 唯一失敗：libchewing 使用者字典的寫回時機

`test_explicit_preference_can_be_forgotten` 最後一步失敗：
Shift+Delete 忘記 `妳` 之後，新開的 context 仍然把 `妳` 排第一。

已用隔離實驗定位（非 macOS 專屬、非 Ari 核心問題）：

| 情境 | 結果 |
|------|------|
| A：忘記後，**舊 context 仍存活**時開新 context（＝測試現在的寫法） | ❌ 仍是 `妳` |
| B：忘記後**先關閉舊 context**再開新的 | ✅ 變回 `你` |

原因：libchewing 0.13 的 `chewing_userphrase_remove()` 只改記憶體中的字典，
實際寫檔發生在 `chewing_delete()`（context 解構）。`chewing.h` 裡**沒有任何
save/flush API** 可以強制寫回。實驗中也直接觀察到 libchewing 的原子寫入暫存檔
（`chewing-<random>.dat`）只在 context 關閉時出現。

另外驗證過：這與 `WITH_SQLITE3` 無關（開啟 sqlite feature 重建後結果相同），
libchewing 的 sqlite 後端只在字典副檔名為 `.sqlite3` 時才生效，
而 Ari 傳入的是 `userdict.dat`。

**真實影響（M3 要處理）**：macOS 前端每個 input context 各有一個
`Buffer`→`Zhuyin`→chewing context。使用者在 A app 忘記某個候選後，
若 B app 的 context 已經開著，該變更要等 A 的 context 解構才會生效。
前端可行的解法：忘記候選後主動重建 chewing context，或全域共用單一 context。
**這個限制在 Linux/Fcitx5 搭配 libchewing 0.13 上同樣存在**，不是移植造成的。

### 覆蓋率基線（`llvm-cov`，M1 實測）

| 檔案 | Region | Line | Branch |
|------|--------|------|--------|
| `src/buffer.cpp` | 90.02% | **87.59%** | 78.23% |
| `src/layout.cpp` | 89.17% | **89.55%** | 85.82% |
| `src/zhuyin.cpp` | 75.20% | **73.79%** | 53.04% |
| `src/unicode.h` | 99.44% | 93.06% | 53.42% |
| `macos/user_data.mm` | 59.38% | **53.77%** | 43.18% |
| **TOTAL** | 88.87% | **84.67%** | 70.71% |

重現方式：
```sh
cmake -S macos -B build-macos/cov -DARI_ENABLE_COVERAGE=ON -DBUILD_TESTING=ON ...
# 逐一以 LLVM_PROFILE_FILE 執行 test_buffer / test_layout / test_user_data
xcrun llvm-profdata merge -sparse ... && xcrun llvm-cov report ...
```

基線證實了 §4.2 事先預測的兩個缺口：
- **`zhuyin.cpp` 73.79%** —— 既有測試只透過 `Buffer` 間接觸及（缺口 G2）。
- **`macos/user_data.mm` 53.77%** —— 全新的 macOS 路徑解析程式碼（缺口 G1）。

`src/dict_tool.cpp` 不在這份報告中：它由 shell 測試覆蓋，該執行檔未加上
覆蓋率插樁。

---

## 8. M2 完成紀錄（2026-08-21）

### 結果

`AriIME.app` 已建置、簽章並註冊為系統輸入源：

```
FOUND id=io.github.chctw.inputmethod.AriIME        enabled=0
FOUND id=io.github.chctw.inputmethod.AriIME.Zhuyin enabled=1
```

輸入路徑以無頭測試驗證（不需切換使用者目前的輸入源）：

| 測試 | 結果 |
|------|------|
| `test_keymap`（34 checks） | ✅ |
| `test_controller`（17 checks） | ✅ |
| `test_buffer` / `test_layout` / `dict_tool` | ✅ |
| `test_user_data` | 1 failure（§7 已定位的 libchewing 寫回時機） |

`test_controller` 用假的 IMK client 驅動真實的 `AriInputController`，證明：
`aceru/6aj4` → marked text `acer螢幕` 且 Enter 前不送出、Enter 送出、
`README.md` 保持字面、`su3` → `你`、Down 開候選 + 數字選字、
`⌃⌥E` 強制英文、`⌃⌥[` `⌃⌥]` → `「」`、`⌘C` 交還應用程式、
失焦時 `commitComposition` 不遺失文字。

### 產出

| 檔案 | 說明 |
|------|------|
| `macos/KeyMap.h/.mm` | NSEvent → `fcitx::Key`，含 macOS 快捷鍵映射 |
| `macos/AriInputController.h/.mm` | IMKInputController：marked text / commit / 候選 |
| `macos/AriCandidateWindow.h/.mm` | 自繪候選面板（NSPanel，M2 陽春版） |
| `macos/AriApp.mm` | IMKServer 進入點，`--register` 註冊輸入源 |
| `macos/Info.plist.in` | 輸入法 bundle 描述 |
| `macos/install-local.sh` | 安裝到 `~/Library/Input Methods` 並註冊 |
| `macos/test/` | macOS 前端測試（**納入版控**，與 upstream 的 `test/` 不同） |
| `macos/ari.tiff` | 選單列圖示（由 `data/inputer.svg` 轉出） |

### 踩到的坑

1. **Info.plist 內容不足會靜默失敗**：TIS 接受了 `TISRegisterInputSource`
   （回傳 `noErr`）但輸入源完全不出現。對照使用者機器上既有的 McBopomofo
   後補齊：`TISInputSourceID`、`TISIntendedLanguage`、`tsInputMethodIconFileKey`、
   `CFBundleSignature`、各 mode 的圖示鍵，並把 `tsInputModeScriptKey` 從
   `smUnicodeScript` 改為 `smTradChinese`；`LSBackgroundOnly` 換成 `LSUIElement`。
2. **CMake cache 變數不會因重新 configure 而更新**：`ARI_BUNDLE_ID` 改了值
   卻仍沿用舊的，導致安裝的 bundle 帶著舊識別碼。需顯式 `-DARI_BUNDLE_ID=`。
3. **ObjC++ 需要 ARC**：以
   `$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>` 只對 `.mm` 開啟。
4. **測試污染真實使用者資料**：第一版 `test_controller` 沒有沙盒化，
   在 `~/Library/Application Support/AriIME` 寫入了學習資料
   （並導致後續斷言得到 `妳`）。已改為在建立任何 `Buffer` 前設定
   `INPUTER_USER_DATA_DIR` / `CHEWING_USER_PATH` / `INPUTER_DISABLE_AUTOLEARN`，
   並在結束時清除；那次誤建的目錄已刪除。

### M2 尚未做（列入 M3 / M4）

- 剪貼簿（`NSPasteboard`）、反轉換（`attributedSubstringFromRange:`）
- 輔助行（編輯預覽 / 游標位置 / 狀態列）目前只顯示候選頁碼
- 中/英提示暫時借用候選面板顯示，尚無獨立 HUD
- 設定視窗與快捷鍵自訂（M4，先討論）
- 忘記候選後重建 chewing context（§7 的寫回時機問題）

---

## 9. 實機測試回報與修正（2026-08-21，M2 之後）

第一次實機使用暴露了三個 M2 沒抓到的問題，其中兩個是自動化測試**本來就抓不到**
的類型，值得記錄。

### 9.1 輸入法不會自動啟動（未解決，最高優先）

輸入源切換成功（log 可見 `Keyboard input source did change`），但 macOS
**從未嘗試啟動 `AriIME.app`** —— 沒有 LaunchServices 啟動紀錄、沒有崩潰、
沒有錯誤。按鍵被送往一個不存在的伺服器，使用者看到「完全打不出字」。

手動 `open -b io.github.chctw.inputmethod.AriIME` 後一切正常。

已補上與 McBopomofo 對照後缺少的 `CFBundleInfoDictionaryVersion` 與 `PkgInfo`，
但尚未驗證。下一步：確認是否為「輸入法伺服器僅在登入時被拉起」。

**診斷過程的教訓**：使用者的 zsh 定義了名為 `log` 的函式，蓋掉 `/usr/bin/log`。
所有 `log show` 查詢都以 `too many arguments` 靜默失敗，而我把「查不到紀錄」
當成「沒有發生」的證據，據此做出錯誤結論。**工具無聲失敗時，缺少證據不是證據。**
診斷指令一律使用絕對路徑。

### 9.2 Shift 標點失效（已修）

`NSEvent.charactersIgnoringModifiers` **連 Shift 也一併忽略**（Shift+1 回報
`"1"`、Shift+comma 回報 `","`），與我假設的「除 Shift 外忽略所有修飾鍵」相反。
於是每一個需要 Shift 的標點都變成未加 Shift 的字元。

修法：改用 `UCKeyTranslate` 對照使用者的鍵盤佈局解析，只套用 Shift/Caps Lock。

**測試為何沒抓到**：`test_keymap` 自己把 `"<"` 餵給 `translateKey` 再斷言
結果是 `<`，等於自問自答；38 個檢查全綠卻完全沒有覆蓋「字元從哪裡來」。
`test_controller` 也用 `keyCode=0xFF` 這種不存在的鍵碼繞過了真實解析路徑。

已修正：新增 `shiftedCharacterForKeyCode()` 對實際佈局的斷言，並讓
`test_controller` 反查佈局建出「字元 → (keyCode, shift)」對照表，
**強制所有合成事件帶真實鍵碼**，無法再繞過解析路徑。

### 9.3 Caps Lock 開啟時打不出大寫（已修）

log 顯示每個按鍵都是 `mods=0x10000`（Caps Lock），而非 `0x20000`（Shift）。
字元解析只看 Shift、忽略 Caps Lock，因此 Caps Lock 鎖定時仍輸出小寫。

修法：`UCKeyTranslate` 的修飾鍵狀態加入 `alphaLock`；同時確保
Caps Lock 不會阻擋 `⌃⌥` 快捷鍵比對，也絕不作為修飾鍵傳給核心。

### 9.4 Caps Lock 切換中英（進行中）

已加入 `TICapsLockLanguageSwitchCapable` 並實作 `-setValue:forTag:client:`，
把系統的輸入模式切換映射到核心既有的強制英文狀態（透過核心本來就有的
Ctrl+Space 路徑，核心零修改）。TIS 會快取輸入源屬性，可能需要重新登入才生效。

### 9.5 使用者體驗發現：中文模式下無法輸入英文空格

`I` + Space → `喔`。這是 README 記載的 result-based tone-one 行為
（`i` 在大千是 ㄛ，一聲確實產生漢字），**不是 bug**。
混合輸入的設計情境是 `acer螢幕` 這種單字間無空格的用法；整句英文應切換
強制英文模式（`⌃⌥E` 或 Caps Lock）。

這一點在 M4 討論設定時值得重新檢視：macOS 使用者對「空格」的預期
可能與 Linux 使用者不同。

### 9.6 §9.1 與 §9.4 的解答：登入時才建立的狀態（已解決）

重新開機後，**三件事同時自動修好**：

1. macOS 自行啟動 `AriIME.app`（開機 15:44，程序於 15:47:53 由系統啟動，
   無任何手動介入）。
2. Caps Lock 正確切換中/英，不再只是鎖定大寫。
3. 標點與大寫維持正常。

根因：**Text Input Services 在登入時建立輸入法清單與其屬性快取**。
新安裝的輸入法在該次登入階段內：

- 可以被選取，但它的伺服器不會被系統拉起 → 按鍵靜默消失（§9.1）；
- Info.plist 的新鍵（例如 `TICapsLockLanguageSwitchCapable`）不會生效（§9.4）。

`TISRegisterInputSource` 與 `lsregister -f` 都不足以刷新這份快取。

**因此「安裝後必須登出再登入」是這個平台的硬性步驟**，不是可有可無的提示。
`macos/install-local.sh` 已改為明確說明這一點，並附上開發期間免登出的
重啟指令（`pkill -x AriIME && open -b <bundle id>`）。

M5 打包時，安裝器必須把這一步講清楚。

### 9.7 標點鍵疑問的結論：非 bug

使用者回報「打 `,` 之後接 `su3` 不會變成 `,你`」。查證後確認是大千配列語意：

```
','  zhuyinSlot=2  → ㄝ        '.'  zhuyinSlot=2  → ㄡ
';'  zhuyinSlot=2  → ㄤ        '/'  zhuyinSlot=2  → ㄥ
'-'  zhuyinSlot=2  → ㄦ
```

這五個鍵本來就是注音韻母鍵。`.` + `su3` → `紐`（ㄋㄧㄡˇ）最能說明它們被
併入音節。非注音鍵的標點完全正常（`!su3` → `!你`、`(su3` → `(你`）。

影響範圍很窄——只有「標點位於預編輯區開頭且緊接注音」才會遇到：

| 輸入 | 結果 |
|------|------|
| `su3 , cl3` | `你,好` ✅ |
| `a , su3` | `a,你` ✅ |
| `, su3` | `,su3` ❌ |

四種正解（皆已驗證）：`⌃⇧`+逗號鍵 → `，你`（設計上的正解）、
`,` 後按 Space → `, 你`、`,` 後按 ↓ 選 `,` `，` `、`、或先打中文再補標點。

---

## 10. M3 完成紀錄（2026-08-21）

| 項目 | 狀態 |
|------|------|
| 輔助行（編輯預覽 + 游標/選字位置 + 狀態列） | ✅ |
| 獨立 HUD（中/英、動作提示） | ✅ |
| 剪貼簿貼入預編輯區 | ✅（`⌘V`，見下方差異說明） |
| 反轉換 `⌃⌥R` | ✅ |
| 忘記候選後的字典寫回 | ✅（延後到組字結束時重建 context） |
| Secure Input 學習封鎖 | ✅（M2 已完成） |

`test_controller` 從 17 → **29 checks**，全數通過。`src/` 仍然一行未改。

### 與 Linux 版的刻意差異：`⌘V`

Fcitx5 版**永遠**攔截 `Ctrl+V` 並貼進預編輯區。在 macOS 照做會讓 `⌘V`
對所有應用程式失效，也會擋掉圖片、檔案等非文字剪貼內容。

因此 macOS 版**只在有組字進行中時**攔截 `⌘V`；沒有預編輯內容時直接交還
應用程式。剪貼簿沒有文字內容時同樣交還。

### 反轉換的 macOS 實作

Fcitx5 用 `deleteSurroundingText` 刪掉原文再開預編輯。macOS 沒有等價 API，
改用 `setMarkedText:...replacementRange:` 一步替換選取範圍。
取消（Esc 或失焦）時把原文 `insertText` 回去。

任何一項不確定就直接放棄、完全不動文件：Secure Input 啟用中、已有組字、
沒有選取範圍、client 不支援 `selectedRange`/`attributedSubstringFromRange:`、
或核心無法為每個字找到讀音。

### 忘記候選的寫回（§7 問題的實際解法）

libchewing 只在 `chewing_delete()`（context 解構）時寫檔，`chewing.h`
沒有任何 flush API。因此前端在偵測到「已忘記」通知後設一個旗標，
等**組字結束**（commit 或失焦）時銷毀並重建 `Buffer`——
此時沒有進行中的組字，重建是安全的，而重建正好觸發 libchewing 寫檔。

`Buffer` 因此改為以 `std::unique_ptr` 持有（`Buffer` 不可複製）。
強制英文狀態會在重建後還原（透過核心既有的 Ctrl+Space 路徑）。

---

## 11. 非文字輸入 client 偵測：調查結論（不做）

**問題**：Finder 的檔案清單裡打字會開始組字，type-select（打字跳到檔案）失效。

### 調查方法

在 controller 加上暫時的探針，於每次焦點切換時 dump client 回報的所有值，
實測 22 筆，涵蓋 Finder、TextEdit、Zed、iTerm2、Safari/Dia、Raycast、
開啟/儲存面板、Claude Desktop。

### 結果：沒有可用訊號

```
com.apple.finder   length=0 selected=0,0 marked=0,0 unicode=1 level=19
dev.zed.Zed        length=0 selected=0,0 marked=0,0 unicode=1 level=19
```

Finder 的檔案清單與 Zed 編輯器**每一個純量欄位都相同**。
Finder 的 `validAttributesForMarkedText` 亦包含 `NSMarkedClauseSegment`，
主動宣告完整支援組字。

此外 TextEdit 自身前後兩次回報並不一致
（`length` 0 vs 2147483647、`selected` 0,0 vs NSNotFound），
這些值即使在單一 app 內也不足以作為分支依據。

旁證：使用者機器上的 McBopomofo 二進位檔中，除 `com.apple.keylayout.US`
外沒有任何 app bundle id，代表這個成熟專案並未採用白名單。

### 決定

**不實作**。維持與 macOS 內建注音一致的行為（在 Finder 亦會組字）。
誤判的代價是「某個 app 完全無法輸入中文」，遠大於 type-select 失效。

若日後要重啟這個議題，需要的是**新的訊號**，而非更多 app 特例。

### 副產品

1. **候選視窗定位修正**：TextEdit 會間歇性回報 `rect={{0,0},{0,0}}`，
   原本的 fallback 會把面板丟到螢幕正中央。改為沿用上一次有效的插入點矩形。

2. **§7 的解釋修正**：`test_user_data` 的失敗**是環境相依的**——
   `ctest -j4`（機器忙）通過，單獨執行（快）連續五次失敗。
   追進 libchewing 原始碼：

   ```rust
   // src/dictionary/trie_buf.rs:322
   self.join_handle = Some(thread::spawn(move || { /* write snapshot */ }));
   // src/dictionary/trie_buf.rs:427
   impl Drop for TrieBuf {
       fn drop(&mut self) { self.wait(); self.sync(); self.flush(); self.wait(); }
   }
   ```

   寫檔是**背景執行緒非同步**進行，且新的 checkpoint 若發現前一個尚未完成
   就直接放棄。測試的失敗是「新 context 讀檔」與「背景執行緒寫檔」的競速。

   **先前「libchewing 只在 context 解構時寫檔」的說法並不正確**：
   它會非同步寫，`Drop` 只是保證 join 等待完成。
   M3 的修法（忘記候選後、組字結束時重建 `Buffer`）依然正確——
   它觸發 `Drop` 的 `wait/flush/wait`，保證寫入落地。
