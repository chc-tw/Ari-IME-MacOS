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

**檔案**：`src/buffer.cpp`（`tryPeelEnglish`、`tryPeelEnglishTone1`）、
`src/buffer.h`（新增私有 `peelInto()`）
**類型**：**行為變更**
**衝擊**：`test_buffer` 19891 checks 中 **1 個預期值改變**（見下）

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
`learningAllowed_` 為假（密碼欄位、關閉學習）時不寫入。

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

`peelInto()` 因此必須記錄**實際按下的鍵序**（`runTyped_`），記憶是以使用者按了
什麼為鍵，而非正規化後的形式。

**合併風險**：中。新增為主，但 `freezeAll()` 與 `handleEnter()` 各有一處小改動。
