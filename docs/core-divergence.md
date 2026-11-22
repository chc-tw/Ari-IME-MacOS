# 核心分歧記錄

上游：[kaiyasi/Ari-IME](https://github.com/kaiyasi/Ari-IME)

macOS 移植的原則是**核心零修改**——`src/` 與上游相同，是「功能一致」的可驗證
保證。本文件逐條記錄每一處必要的例外：改了什麼、為什麼、上游的行為是什麼、
以及實測衝擊。

檢查上游是否動到這些地方：`bash scripts/check-upstream.sh`

---

## D1 — ~~`Buffer::pendingSyllable()`~~ **已撤銷（2026-08-26）**

合併上游 2.6.1 後撤銷。上游 `f061818` 已提供官方版本
`Buffer::pendingSyllableHint()`，且 API 更好——直接回傳注音符號、剝除聲調、
處理引擎失效。macOS 前端改用官方 API，本項分歧消失。

`scripts/check-upstream.sh` 第一次執行就抓到這件事。以下保留原始記錄。

### （原始記錄）`Buffer::pendingSyllable()`（唯讀存取器）

**檔案**：`src/buffer.h`
**類型**：新增唯讀存取器，**不改變任何行為**
**衝擊**：`test_buffer` 19885 checks 全過，無任何預期值變動

```cpp
std::string pendingSyllable() const {
    return token_ == Token::Chinese ? syl_ : std::string{};
}
```

**為什麼**：Ari 的預編輯區刻意顯示原始按鍵（`cj0`），因為那串鍵有可能最後
是英文。但這也讓「Ari 現在把這串鍵當成什麼」變成不可見的——使用者要打完
好幾個字才會發現邊界判斷錯了（例如 `ui` 被當成 ㄧㄛ）。

macOS 前端在輔助行顯示該音節的讀音（ㄏㄨㄢ），需要知道目前待處理的音節按鍵。
前端無法可靠地從預編輯區反推：`acer` 的尾巴 `r` 是合法聲母，硬猜會誤顯示 ㄐ。

**上游行為**：無此存取器；`syl_` 是私有的。上游的 Fcitx5 前端不顯示讀音。

**合併風險**：極低。純新增，不與既有成員衝突。

---

## D2 — 剝離英文尾端音節時，優先取「以聲母開頭」的切法

**檔案**：`src/buffer.cpp`（`tryPeelEnglish`、`tryPeelEnglishTone1`）
**類型**：**行為變更**
**衝擊**：`test_buffer` 20065 checks 中 **1 個預期值改變**（見下）

> **2026-11-21 合併上游 2.8.0 時重新套用。** 上游 2.6.3 把這兩個函式改寫成
> `commit` / `tryBody` / `tryCandidate` lambda，並新增「打錯字修正」（重複鍵、
> 開頭單一無效鍵）。本分歧改為建立在上游新結構上：
>
> - 原本的私有 `peelInto()` 已刪除——上游的 `commit` lambda 做同一件事，且會
>   重設上游新增的 `invalidPrefixLength_` 等欄位，`runTyped_` 也同樣記錄實際鍵序。
> - 「以聲母開頭」一輪寫成 `zhuyinSlot(buf[k]) == 0 && tryCandidate(k, false)`。
>   有聲調鍵時放在上游的最短規則**之前**；Space（一聲）時放在最後當備援。
> - 順序：上游的打錯字修正 → 以聲母開頭（D2）→ 上游最短 → 上游 symbol-led。
>   打錯字修正排在最前，因此 `avu;4` 的 `a`（ㄇ，與 ㄒ 不相容）會被**當成打錯字
>   刪除**，不再保留成英文；`cc8`+Space 的重複 `c` 也一樣。這是上游刻意的行為，
>   `macos/test/test_mixed_input.mm` 的這兩個預期已改為上游的結果。

### 上游行為

英文串後面接注音時，聲調鍵到達才會從尾端「剝」一個音節下來，且刻意取**最短**
的：

```cpp
// Prefer the shortest trailing syllable (largest k) that actually forms a
// character: steal as few letters as possible from the English word. This
// keeps brand names like "acer" intact ... without relying on a dictionary.
```

一聲（Space）走另一條路徑 `tryPeelEnglishTone1`，該路徑**只有** symbol-led
迴圈，沒有通用迴圈。

### 問題

最短切法會把音節的聲母留在英文串裡：

| 輸入 | 上游結果 | 應為 |
|------|---------|------|
| `ui` + ㄏㄨㄢˊ | `uic完` | `ui環` |
| `agent` + ㄌㄧㄡˊ | `agentx由` | `agent瀏` |
| `?` + ㄒㄧㄤˋ | `?v樣` | `?像` |
| `shift` + ㄐㄧㄚ + Space | `shiftru8 `（完全沒轉） | `shift加` |
| `哈哈c` + ㄏㄚ + Space | `哈哈cc8 ` | `哈哈c哈` |

使用者實測回報「打完標點後一定要按一次空白鍵，否則下一個字會被吃掉」。

### 改動

在既有的最短規則**之前**加一輪：取**最長且以聲母開頭且真的成字**的切法。
一聲路徑補上同樣的一輪（上游該處沒有通用迴圈）。

理由：中文音節通常以聲母起頭，因此從介音或韻母開始的切法幾乎必然是切在音節
中間、把真正的聲母遺留在英文串裡。

### 為何不會破壞上游保護的案例

新規則是**附加**在舊規則之前，不是取代：

- `aceru/6`：`ru/6` 以聲母起頭，但 ㄐㄩㄥˊ 不成字 → 落回最短規則 → `acer` 完整
- `HTTPsu3`：`psu3` 從韻母 ㄣ 起頭 → 不被考慮 → 取 `su3` → `HTTP` 完整

（先試過「單純改成最長優先」，會把 `HTTPsu3` 破壞成 `HTT拰`。聲母條件是關鍵。）

### 唯一改變的上游預期

```
FAIL catsu3 keeps cats and peels one Chinese syllable
```

而上游 README 自己把這個結果標為錯誤：

> `↑` ... recovering "catsu3" -> cat + 你 **when the syllable's 聲母 was
> wrongly absorbed into the English run.**

上游提供 `↑` 手動修正此案例；新規則直接產出修正後的答案。因此這不是「打破一個
測試」，而是「把一個已知錯誤的預期值扶正」。

**上游測試檔維持原樣不動**（它是基準）。本 fork 的預期寫在受版控的
`macos/test/test_mixed_input.mm`，同時涵蓋上述五個修好的案例與 `acer`／`HTTP`
兩個必須保住的案例。

**合併風險**：中。若上游日後改寫 `tryPeelEnglish`，需要人工重新套用。

---

## D3 — `setUppercaseIsEnglish()`：大寫字母恆為英文

**檔案**：`src/buffer.h`（新增設定項與 `bodyIsPeelable()`）、`src/buffer.cpp`
**類型**：新增設定項，**預設關閉＝維持上游行為**
**衝擊**：`test_buffer` 零額外變動（上游測試不會打開此選項）

> **2026-11-21**：上游改寫剝離函式後，`bodyIsPeelable()` 檢查移到兩個
> `tryBody` lambda 內，因此打錯字修正產生的 body 也同樣受大寫規則約束。

### 上游行為

鍵盤配列表折疊大小寫，`zhuyinSlot('S') == zhuyinSlot('s')`，因此 `SU3` 與
`su3` 同樣轉成「你」。

### 改動

新增 `setUppercaseIsEnglish(bool)`（預設 `false`）。開啟時，大寫字母走既有的
`literal` 路徑（原本只有數字鍵盤在用）：結束目前音節、進入英文串。

**同時必須擋住剝離**：只把大寫送進英文串是不夠的——聲調鍵會再把它們剝回來，
因為 `isValidSyllable` 同樣折疊大小寫。`SU` + `3` 於是又變回「你」。
新增 `bodyIsPeelable()`，開啟此選項時拒絕含大寫字母的候選切法，並在四個剝離
迴圈中套用。

### 為什麼

中文之中出現大寫幾乎必然是縮寫或識別字（API、UI、HTTP、SDK），把它讀成注音
正是導致後續音節聲母被吞掉的原因之一。macOS 前端預設開啟
（`UppercaseIsEnglish`）。

**合併風險**：低。新增為主；四個迴圈各多一個條件。

---

## D4 — 還原原始鍵時保留一聲的空白

**檔案**：`src/buffer.cpp`（`revertCellToEnglish()`、`loadCellCandidates()`）
**類型**：**行為變更**（bug 修復）
**衝擊**：`test_buffer` 19904 checks 零額外變動

### 上游行為

```cpp
(void)tone1; // 一聲 has no key of its own; the body alone explodes
```

把中文字還原成原始鍵時，一聲（Space）被丟棄：`c8 `（哈）還原成 `c8`。

### 改動

`revertCellToEnglish()` 在 `tone1` 時補回空白；`loadCellCandidates()` 的
`原始鍵` 候選標籤也一併補上，讓顯示與實際還原結果一致。

### 為什麼

在 Ari 的模型裡，Space **就是**使用者實際按下的一聲鍵。「還原成原始鍵」若吐回
`c8` 而不是 `c8 `，還原出來的就不是使用者打的東西，而且下一個按鍵會跟這個未
結束的音節重新合併。

實測：

| 輸入 | 上游還原 | 本 fork 還原 |
|------|---------|-------------|
| `su3`（三聲）| `su3` | `su3` |
| `c8`+Space（一聲）| `c8` ❌ | `c8 ` ✅ |
| `ru8`+Space（一聲）| `ru8` ❌ | `ru8 ` ✅ |
| `cj06`（二聲）| `cj06` | `cj06` |

### 上游 2.6.3 新增測試的預期衝突（2026-11-21）

上游 2.6.3 加了「原始鍵還原保留大寫」的測試：輸入 Shift+I 再按 Space（一聲）
→ 喔，期望候選為 `原始鍵 I`、還原結果為 `I`。依本分歧，一聲的 Space 會一起
還原，因此實際是 `原始鍵 I ` 與 `I `：

```
FAIL raw-key recovery keeps uppercase input state
FAIL raw-key recovery restores the originally typed uppercase key got="喔" want="I"
```

大寫保留本身是正確的（上游的修正已生效），差別只在結尾的一聲空白。依本文件的
慣例，**上游測試檔維持原樣**，這兩個失敗列為已知差異。

**合併風險**：低。兩處小改動，皆在既有函式內。

---

## D5 — 注音提示在英文尾端也要顯示

**檔案**：`src/buffer.cpp`（`pendingSyllableHint()`）
**類型**：**行為變更**（擴充）
**衝擊**：`test_buffer` 19904 checks 零額外變動

### 上游行為

```cpp
if (syl_.empty() || !zhuyin_.ok()) { return {}; }
```

只在 token 為中文（按鍵累積於 `syl_`）時回報讀音。token 一旦翻成英文，
按鍵改累積於 `englishBuf_`，提示即為空。

### 問題

實測回報：

| 情境 | 上游 | 應為 |
|------|------|------|
| `bug` 之後打 `ru.` | 全程無提示 | `ㄐㄧ` → `ㄐㄧㄡ` |
| `!` 之後打 `cj` | 無提示 | `ㄏㄨ` |
| `t` → `tae` → 退兩格回到 `t` | 無提示 | `ㄔ` |

**提示消失的時機，正是邊界未定、最需要看到讀音的時機。**

### 改動

`syl_` 為空時，回退到 `englishBuf_` 的尾端：取最長、以聲母開頭、可剝離的
子字串，與 `tryPeelEnglish` 的偏好一致，因此提示**預測的是實際會發生的事**，
而非猜測。

單一聲母只在「它就是整個尾端」時回報（例如把打錯的字退格清掉後只剩一個鍵）。
若允許從詞尾取單鍵，每個結尾恰為聲母鍵的英文字下方都會閃出一個符號，
而單一符號還不足以說明有東西要轉換。實測：

```
acer "" | agent "" | bug "" | README "" | fig ""     ← 安靜
t "ㄔ"                                                ← 整個尾端只剩一鍵
```

**合併風險**：低。單一函式內的擴充，早期返回條件放寬。

### ⚠️ 未完全解決：英文尾端的第一個鍵仍然沒有提示

「單一聲母只在它就是整個尾端時才回報」是一個**取捨，不是完整解法**：

| 情境 | 目前 | 理想 |
|------|------|------|
| `bug` 之後打第一個鍵 `r` | 無提示 | `ㄐ` |
| `bug` 之後打第二個鍵 `u` | `ㄐㄧ` ✅ | `ㄐㄧ` |
| 打英文 `acer` | 無提示 ✅ | 無提示 |

兩者無法同時滿足，因為在只看到一個鍵時，「英文字的最後一個字母」與
「新音節的聲母」在資訊上**完全相同**——`bug`+`r` 和 `acer` 的尾端都是一個
聲母鍵，Ari 無從分辨使用者接下來要打中文還是繼續打英文。

目前選擇「安靜」而非「誤報」：讓每個以聲母鍵結尾的英文字下方閃出符號，
比延後一個鍵才顯示更擾人。

**這個歧義正是 M6 要處理的問題**（見 `docs/macos-port-plan.md` §12）。
M6 的偏好記憶一旦存在，這裡就能有更好的答案：記得使用者在這個組合上
選過什麼，就能在第一個鍵時做出有根據的預測，而不是猜。

---

## D6 — `boundaryAlternatives()` / `chooseBoundaryAlternative()`（M6 第一部分）

**檔案**：`src/buffer.h`、`src/buffer.cpp`（**新增**兩個方法與一個結構）
**類型**：新增 API，**不改變任何既有行為**
**衝擊**：`test_buffer` 19904 checks 零額外變動

### 為什麼

有一類邊界**不是規則判斷錯誤，而是輸入本身有歧義**——`fig4` 是圖片標號，
也可以是 `fi` + `是`，只有使用者知道要哪一個。啟發式規則只能挑一邊。

### 改動

```cpp
struct BoundaryAlternative {
    std::string english; // 保持英文的字面前綴
    std::string chinese; // 其餘按鍵轉換成的字（空 = 全部英文）
    std::string keys;    // 這個切法涵蓋的完整按鍵串
};
std::vector<BoundaryAlternative> boundaryAlternatives(int idx) const;
KeyResult chooseBoundaryAlternative(int idx, int choice);
```

`boundaryAlternatives()` 從指定的中文格往左收集連續的英文格，重建原始按鍵串，
再列舉所有「合法音節且真的成字」的切法，英文最多者在前。

實測：

```
fig4    → [0] fig4        [1] fi + 是
su3     → [0] su3         [1] s + 以      [2] 你
catsu3  → [0] catsu3      [1] cats + 以   [2] cat + 你
```

**必須先檢查 `isValidSyllable`**：否則正規化器會默默丟掉放不進去的鍵，
回報一個使用者根本沒打的音節（`catsu3` 會冒出 `ca` + `你`，那個 `t` 憑空消失）。

### 尚未實作（M6 剩餘部分）

偏好記憶（記住這個組合選過什麼）與設定頁的檢視／刪除。
記憶範圍先做純全域，理由見 `docs/macos-port-plan.md` §12。

**合併風險**：低。純新增，不修改既有函式。

---

## D7 — 記住邊界裁決（M6 第二部分）

**檔案**：`src/buffer.h`、`src/buffer.cpp`
**類型**：新增 API + **兩處既有函式的小改動**
**衝擊**：`test_buffer` 19904 checks 零額外變動

### 新增

```cpp
KeyResult chooseAndRememberBoundaryAlternative(int idx, int choice);
struct RememberedBoundary { std::string keys, english, chinese; };
static std::vector<RememberedBoundary> rememberedBoundaries();
static bool forgetBoundary(const std::string &keys);
```

儲存於 `<資料目錄>/boundaries.tsv`，格式與既有的 `preferences.tsv` 一致
（表頭 + TAB 分隔 + 原子 rename）。含 TAB/換行的內容一律拒絕。
`boundaryMemoryAllowed_` 為假（密碼欄位、使用者關閉學習）時不寫入。

> **2026-11-21**：原本以 `learningAllowed_` 判斷。上游 2.7.0 讓
> `setLearningAllowed()` 同時受行程層級的 `ARI_IME_DISABLE_AUTOLEARN` 控制（測試
> 與打包用的開關），這會連帶關掉邊界記憶。邊界裁決是使用者**明確做出的決定**，
> 不是統計式學習，因此改用獨立的 `boundaryMemoryAllowed_`：只看欄位與使用者
> 設定，不看該環境變數。改動僅在 `setLearningAllowed()` 多記一個值。

### 既有函式的兩處改動

**1. `freezeAll()` 末尾呼叫 `applyRememberedBoundary()`。**

這是「token 完成」的時機——另一個 token 開始，或整行即將送出。
在按鍵還在進來時套用，等於替一個下一鍵仍可能改變的邊界做決定。

**2. `handleEnter()` 改為在 `mergeTail()` 之後才讀取要送出的文字。**

上游先取 `preeditText()` 再 `mergeTail()`。凍結尾端正是最後一個 token 完成的
時刻，記憶在那裡套用，因此文字必須在合併之後才讀，否則送出的是套用前的內容。

### 套用時機：轉換當下（原本的「token 完成才套用」已移除）

初版在 `freezeAll()` 才套用，以防「較短的按鍵串記憶影響較長 token 的解析」。
實測後確認**那個風險不存在**：

```
fig4      → fi是      | fig46         → fi是6        前綴不變
su3       → 你        | su3cl3        → 你好        前綴不變
c8+Space  → 哈        | c8+Space+u3   → 哈以        前綴不變
agentxu.6 → agent劉   | agentxu.6cj/4 → agent劉鍙   前綴不變
```

原因是結構性的：**聲調鍵本身就是 token 邊界**。轉換一旦發生，該字即定案，
後續按鍵開始新的 token，沒有任何輸入能把它拉回一個更長的音節。因此記憶的鍵
必然是一個已被聲調鍵封閉的 token，不可能被後續按鍵延長。

延後套用的代價則很實際：已經教過的組合，打字途中仍顯示規則的判斷，直到 token
收尾才跳成記憶的答案。使用者回報「太惱人」，且該保護防的是不存在的問題。

現在改為在音節轉換的當下套用（`handleKey()` 末尾的
`applyRememberedBoundaryToRun()`），文字不再在使用者眼前變動。

剝離路徑因此必須記錄**實際按下的鍵序**（`runTyped_`），記憶是以使用者按了
什麼為鍵，而非正規化後的形式。（原本在 `peelInto()`；合併上游 2.8.0 後由上游的
`commit` lambda 負責，行為相同。）

**合併風險**：中。新增為主，但 `freezeAll()` 與 `handleEnter()` 各有一處小改動。


---

## D8 — 選字記憶改為小麥注音的 UserOverrideModel（取代永久學習）

**檔案**：新增 `src/user_override.h`（header-only，免改各 CMake 清單）；
`src/buffer.{h,cpp}`（`pickCandidate()`、`handleKey()`、`freezeRun()`、
`moveAutoCommit()`、`handleBackspace()`、`learnFromCells()`、
`forgetHighlightedCandidate()`，以及各個重設 live run 的地方）
**類型**：**行為變更**（核心設計）
**衝擊**：`test_buffer` 零額外變動；本機私有 `test_user_data.cpp` 的學習測試改寫為新語意；
新增受版控的 `macos/test/test_user_override.mm`

### 上游行為

libchewing 的自動學習會把「第一次寫進使用者詞庫的詞」設成該讀音的最高頻率 +10
（`editor/estimate.rs`），之後只增不減。Ari 在 Enter 時把整段重播給 libchewing，
手動選過的字再多重播 3 次。結果：偶爾選一次的生僻字，從此永遠排第一。
使用者 2 個多月累積了 269 個單字偏好。

### 改動（對齊 McBopomofo）

- `src/user_override.h` 移植 McBopomofo 的 `UserOverrideModel`：key 是
  「前兩個詞 + 這個讀音的預設字」，分數 = 該選擇的比例 × e^(−Δt·ln2/半衰期)，
  低於 2⁻²⁰ 歸零；500 筆 LRU；半衰期 1.5 小時（皆同 McBopomofo）。只在記憶體、
  整個行程共用、不寫檔。
- **記錄**：`pickCandidate()` 在選字前後各取一次 libchewing 的分詞結果
  （`chewingWalk()`），交給 `observe()`。三種情況（同長替換、合成更長的詞、
  拆成單字）照 McBopomofo 處理。key 的 head 用 `topCandidateAt()` 查詢字典本身的首選。
- **套用**：`handleKey()` 結尾，若 live run 多了一個音節，`applyUserOverrideToRun()`
  對最新的詞查詢建議，並以 `selectRunCandidate()` 在 libchewing 中選上。
  被選上的範圍記在 `runOverrides_`，凍結進 `cells_` 時標為 `locked`，因此之後開
  候選視窗重新組字（`relockRun`）不會被還原。
- **不再永久學習**：libchewing 的 autoLearn 一律關閉（D9）；`learnFromCells()`
  只保留讀音快取（供重新轉換），不再重播、不再寫 `preferences.tsv`。
- `Shift+Delete` 忘記候選時，也會清掉這個記憶裡的對應建議。
- `learningAllowed_`（敏感欄位、使用者設定）與 `ARI_IME_DISABLE_AUTOLEARN`
  都會關閉記錄與套用；後者讓既有測試不受行程共用的記憶影響。
  測試可用 `Buffer::clearUserOverrides()` 清空。

### 與 McBopomofo 的差異

- **選上即固定**：McBopomofo 套用建議時只把該節點的分數提到「與首選同分」，
  之後的組字仍可能選別條路；libchewing 只有「選擇」這種硬性限制，所以 Ari
  套用後就固定，後面的音節不能跨過它組詞。由於 key 已綁定上下文，又會衰減，
  實際影響有限。
- **沒有「罕用字不學」門檻**：McBopomofo 只在選中字的 log₁₀ 分數 > −8 時記錄。
  換算到 libchewing（`ln(freq/58376702)`），門檻是詞頻 0.58；而 libchewing 計分時
  詞頻最低算 1，所以照實移植永遠不會觸發，因此不實作。真正防止生僻字長期霸占的
  是衰減、上下文 key 與 LRU。
- **拆詞的 key（2026-11-22）**：用單字拆開一個詞時（在「選城市」的 市 選 是），
  McBopomofo 用「選字之後」的分詞當 key。但下次打同樣的音，字典仍會先組出 城市，
  查詢時的 key 是「城市」那個節點，永遠對不上，所以這類選字等於白記。使用者回報的
  「是什麼→式什麼」「選成是→選程式」正是這類。Ari 改用「選字之前」的那個詞
  （城市，head 仍查字典首選）當 key，建議值是它所涵蓋音節選字後的整段文字
  （成是）。套用時若整段不是字典詞，就逐字選上。
- **拆詞後再修正（2026-11-22）**：拆詞後 libchewing 會自己重選同一詞裡的其他字
  （是 選下去，ㄔㄥˊ 變成 乘）。同一段 run 裡再修正這些字時，`lastSplit_` 讓
  `revise()` 改寫剛才那筆記憶（乘是 → 成是），而不是另記一筆。
- `forget()` 會一併清掉「包含」該候選的拆詞記憶。

**合併風險**：中。多數是新增函式，但 live run 的每個重設點都多了一行
`runOverrides_.clear()`；上游若新增重設 run 的路徑，需要一併補上。

---

## D9 — libchewing autoLearn 一律關閉；使用者詞庫變動時重開 context

**檔案**：`src/zhuyin.{h,cpp}`（`openContext()`、`reopenContext()`、
`userDictionaryChanged()`、`resetAll()`、`setLearningAllowed()`、`addUserPhrase()`、
`forgetUserPhrase()`）
**類型**：行為變更

- 建構子拆成 `openContext()`，其中 `chewing_set_autoLearn(AUTOLEARN_DISABLED)`。
  `setLearningAllowed()` 只管 Ari 的明確偏好 API。
- libchewing 只在「該 context 自己有改動」的按鍵結束時才（在背景執行緒）寫檔，
  其他已開著的 context 也不會重讀。autoLearn 關掉後，各 App 的 context 永遠不會再
  有改動，於是一個 App 加的自訂詞，其他 App 永遠看不到。現在
  `addUserPhrase()` / `forgetUserPhrase()` 成功後呼叫 `userDictionaryChanged()`：
  重開自己的 context（銷毀時同步寫完檔），並遞增一個行程共用的版本號；其他
  context 在下一次 `resetAll()`（buffer 為空）時發現版本變了就重開。

**合併風險**：低到中。建構子結構改變，上游若改建構子需人工對照。

---

## D10 — 自訂詞：Shift+←/→ 標記、Enter 加入（McBopomofo 的加詞手勢）

**檔案**：`src/buffer.{h,cpp}`（`handleCaret()`、`exitSelection()`，新增
`markedRange()`、`markStatus()`、`markedPhrase()`、`addMarkedPhrase()`、
`bopomofoForReading()`）；macOS 前端 `AriInputController.mm`、`AriPreferencesWindow.mm`
**類型**：新增功能

- caret 模式下 Shift+←/→ 從原游標位置開始標記；Enter 把 2–8 個中文字的標記
  範圍以 `addUserPhrase()` 加入使用者詞庫（libchewing 會把它排在同讀音的第一位），
  不送出組字。Esc 只取消標記。打字中直接按 Shift+← 也會進入 caret 模式並開始標記。
- `markStatus()` 提供面板提示：「Enter 加入自訂詞「…」」、「已有自訂詞「…」」、
  「自訂詞需為 2–8 個中文字」。
- macOS：標記範圍畫粗底線，面板上方顯示提示；設定視窗的列表改稱「自訂詞」。

**合併風險**：低。純新增，`handleCaret()` 開頭多一段分支。


---

## D11 — `ari-ime-dict` 匯入接受輕聲 ˙（U+02D9）

**檔案**：`src/dict_tool.cpp`（`isCanonicalReading()`）
**類型**：bug 修復（值得回報上游）

libchewing 匯出輕聲時寫成 `ㄌㄜ˙`（U+02D9），但匯入的驗證只認得 `·`（U+00B7）等
符號，所以含輕聲的詞（了、的、嗎…）**自己匯出的檔案匯不回去**，而且整份匯入失敗。
2026-11-21 重置使用者資料、重新匯入保留的詞時發現。私有測試 `test_dict_tool.sh`
已補上輕聲的往返測試。

**合併風險**：極低。一行。

---

## D12 — Backspace 一律刪掉整個字（不還原亂序打法的原始鍵）

**檔案**：`src/buffer.cpp`（`handleBackspace()`）
**類型**：**行為變更**
**衝擊**：`test_buffer` 多兩項預期失敗（見下）；`macos/test/test_mixed_input.mm` 加了反向測試

### 上游行為

上游 2.6.3 起，若最後一個字是用「非標準順序」打的（例如 `s3u`：先按聲調再按
韻母；或 `140`），Backspace 不刪字，而是把它還原成當初打的鍵（`s3u`），之後要
一個鍵一個鍵刪。照標準順序打的字則整個刪掉。

### 問題

Ari 會默默接受亂序打法，使用者自己不會察覺哪個字是亂序打的，所以同一個
Backspace 看起來像「有時候字突然變回英文字母」，觸發條件無從捉摸
（2026-11-22 使用者回報）。

### 改動

只要 live run 有字，Backspace 一律走 libchewing 原生路徑，刪掉整個字。
要拿回原始鍵，用候選視窗最後的「原始鍵」即可。

### 上游測試的預期衝突

```
FAIL backspace restores out-of-order keys in their typed order got="" want="140"
FAIL backspace restores tone-before-final keys in typed order got="" want="240"
```

**合併風險**：低。上游若再改 `handleBackspace()` 的 live run 分支，需重新套用。

---

## D13 — 中英裁決：尚未成字的鍵也能問，並提供注音符號

**檔案**：`src/buffer.{h,cpp}`（`boundaryAlternatives()` 拆出 `alternativesForKeys()`；
新增 `pendingAlternatives()`；`chooseBoundaryAlternative()`）
**類型**：新增 API + 行為變更（D6/D7 的延伸）
**衝擊**：`test_buffer` 零變動；`macos/test/test_controller.mm` 加了三個情境

### 問題（2026-11-22 使用者回報）

只打了一個 `1` 或 `su` 這類還沒成字的鍵時按 ↑：前端先按 ← 把尾端凍結成英文格，
但這些鍵沒有任何中文讀法可選，所以不出現選單，鍵卻已經永遠變成英文，接著打
`u4` 得到「1亦」而不是「必」。另外使用者想直接打出注音符號本身。

### 改動

- `alternativesForKeys()`：原本的切法邏輯原封搬出。若沒有任何中文讀法、但整串鍵
  是部分音節（`1`、`su`、`s3`），加一個注音符號讀法（ㄅ、ㄋㄧ、ㄋˇ）。
- `pendingAlternatives()`：對還在打的尾端（`englishBuf_ + syl_`，加上前面相連的
  字母數字格）算同樣的讀法，**不凍結**。尾端含標點時回傳空，由前端走原路徑。
- `chooseBoundaryAlternative()`：選到注音符號（不含漢字）時插入一般文字格，
  不再做成「讀音不完整的中文格」；後者在重新組字（`feedRun`）時會被打回中文。
- macOS 前端：↑ 先問 `pendingAlternatives()`，只有真的選了才按 ← 凍結；Esc 不改
  任何東西；沒得選時 ↑ 什麼都不做。選注音符號不寫進裁決記憶。

**合併風險**：低～中。上游若改 `boundaryAlternatives()`，需確認改動落在
`alternativesForKeys()`。

---

## 合併記錄

### 2026-11-21 — 上游 2.6.3 → 2.8.0（`43718d1`）

- **衝突**：只在 `src/buffer.{h,cpp}`：剝離函式被上游改寫（D2/D3/D7 依上文重新套用），
  以及 `buffer.h` 的新成員（並存）。
- **非核心配套**：
  - `compat/include/fcitx-utils/keysym.h` 補上上游新測試用到的
    `FcitxKey_dollar`/`G`/`H`/`K`/`Shift_L`/`Shift_R`/`Control_L`。
  - 上游 2.6.4 新增 `CaretAfterPick`，預設為「選完停在下一個字」。macOS 前端
    原本是 Return 回到結尾、⌘Return 留在原處（以 Left 模擬），因此
    `AriInputController` 明確設為 `EndOfText` 以保留原行為。上游另外兩個新設定
    （`CandidateArrowKeys`、`LiteralKeyReinterpret`）macOS 沿用預設值，尚未放進設定視窗。
  - 上游 2.7.2 起單字不再寫入 `preferences.tsv`。本機私有的 `test_user_data.cpp`、
    `test_dict_tool.sh` 依此調整預期。
- **未合併**：`f673839`（授權改為 KYL Noncommercial License 1.0）。
  這是授權決定，不是技術決定，待擁有者決定。
- **合併後測試**：除下列已知項目外全部通過——
  `test_buffer`：`catsu3`（D2）、兩個大寫原始鍵（D4）；
  `test_user_data`：`forgotten explicit preference stays forgotten after restart`
  （合併前就失敗）。

