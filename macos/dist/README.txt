Ari IME（macOS）

注音輸入法，可以中英混打，不用切換輸入法。基於 Ari IME 與 libchewing。

需求：Apple Silicon（M 系列晶片）Mac，macOS 14 以上。

安裝
  1. 打開「終端機」，貼上下面這行後按 Return（路徑請換成你解壓縮的位置）：
       bash ~/Downloads/AriIME-*/install.sh
  2. 系統設定 → 鍵盤 → 輸入方式 → 編輯… → ＋ → 繁體中文 → Ari IME
  3. 登出再登入（或重新開機）。第一次安裝一定要做。

為什麼要用終端機？
  這個 App 沒有向 Apple 付費簽名，直接打開會被 macOS 擋下，顯示「無法驗證開發者」。
  安裝腳本會告訴 macOS 信任這一份 App。輸入法看得到你打的每一個字，
  如果不放心，可以到原始碼頁面自己檢查或自己編譯。

更新
  下載新版、解壓縮，重新執行 install.sh 即可，不用再登出。自訂詞和設定都會保留。

移除
  bash ~/Downloads/AriIME-*/uninstall.sh
  （加上 --purge 會一併刪除自訂詞與設定）

原始碼與授權
  https://github.com/chc-tw/Ari-IME-MacOS
  GPL-3.0-or-later，授權全文見同資料夾的 LICENSE。
