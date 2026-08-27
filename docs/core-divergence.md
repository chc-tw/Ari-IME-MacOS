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
