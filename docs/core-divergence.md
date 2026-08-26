# 核心分歧記錄

上游：[kaiyasi/Ari-IME](https://github.com/kaiyasi/Ari-IME)

macOS 移植的原則是**核心零修改**——`src/` 與上游相同，是「功能一致」的可驗證
保證。本文件逐條記錄每一處必要的例外：改了什麼、為什麼、上游的行為是什麼、
以及實測衝擊。

檢查上游是否動到這些地方：`bash scripts/check-upstream.sh`

---

## D1 — `Buffer::pendingSyllable()`（唯讀存取器）

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
