// SPDX-License-Identifier: GPL-3.0-or-later
//
// The short-term memory of candidate picks (src/user_override.h), which
// replaces libchewing's permanent learning. A pick is preferred again in the
// same context, decays away, and is never written to the user dictionary.
//
// Layout is 大千: w8_ = ㄊㄚ, vu/4 = ㄒㄧㄥˋ, 5j/_ = ㄓㄨㄥ, _ = Space. The test
// only assumes that 鍾 is not libchewing's choice for the last syllable.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>

#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "user_data.h"
#include "user_override.h"
#include "zhuyin.h"

static int failures = 0;
static int checks = 0;

namespace {

void check(bool ok, const char *label) {
    ++checks;
    if (!ok) {
        ++failures;
        printf("FAIL %s\n", label);
    }
}

void checkEq(const std::string &got, const std::string &want,
             const char *label) {
    ++checks;
    if (got != want) {
        ++failures;
        printf("FAIL %-48s got=\"%s\" want=\"%s\"\n", label, got.c_str(),
               want.c_str());
    }
}

void type(Buffer &buffer, const char *keys) {
    for (const char *p = keys; *p; ++p) {
        buffer.handleKey(*p == '_'
                             ? fcitx::Key(FcitxKey_space)
                             : fcitx::Key(static_cast<fcitx::KeySym>(
                                   static_cast<unsigned char>(*p))));
    }
}

// Everything but the last character.
std::string withoutLast(const std::string &text) {
    std::size_t cut = text.size();
    while (cut > 0 && (static_cast<unsigned char>(text[cut - 1]) & 0xC0) == 0x80) {
        --cut;
    }
    return cut > 0 ? text.substr(0, cut - 1) : std::string{};
}

std::string typed(const char *keys) {
    Buffer buffer;
    type(buffer, keys);
    return buffer.preeditText();
}

// Open the candidate window on the last character and pick `text`, paging
// forward as needed. Returns false when it is not offered.
bool pickLast(Buffer &buffer, const std::string &text) {
    buffer.handleKey(fcitx::Key(FcitxKey_Down));
    for (int page = 0; page < buffer.candidatePageCount(); ++page) {
        const auto candidates = buffer.candidates();
        for (int i = 0; i < static_cast<int>(candidates.size()); ++i) {
            if (candidates[static_cast<std::size_t>(i)] == text) {
                return buffer.selectCandidate(i).handled;
            }
        }
        buffer.handleKey(fcitx::Key(FcitxKey_Page_Down));
    }
    return false;
}

void teach(const char *keys, const std::string &pick) {
    Buffer buffer;
    type(buffer, keys);
    check(pickLast(buffer, pick), "the pick is offered");
    buffer.handleKey(fcitx::Key(FcitxKey_Return));
}

void testModel() {
    using Model = ari_ime::UserOverrideModel;
    Model model(2, 5400.0);
    model.observe("k", "鍾", 0);
    checkEq(model.suggest("k", 0), "鍾", "a pick is suggested right away");
    checkEq(model.suggest("k", 5400), "鍾", "and still after one half-life");
    checkEq(model.suggest("k", 5400.0 * 21), "",
            "and dropped once it decays below 2^-20");

    model.observe("k", "中", 10);
    model.observe("k", "中", 20);
    checkEq(model.suggest("k", 30), "中", "the more frequent pick wins");

    model.observe("a", "x", 0);
    model.observe("b", "y", 0);
    checkEq(model.suggest("k", 30), "", "the least recently used context is evicted");
    check(model.size() == 2, "capacity is respected");

    check(model.forget("y") == 1, "forget reports what it removed");
    checkEq(model.suggest("b", 0), "", "a forgotten pick is gone");
}

void testContext() {
    Buffer::clearUserOverrides();
    const std::string before = typed("w8_vu/45j/_");
    const std::string context = withoutLast(before);
    check(before == context + "中" || before == context + "鐘" ||
              before == context + "終" || before == context + "忠",
          "鍾 is not the default after the context");
    const std::string alone = typed("5j/_");
    check(alone != "鍾", "鍾 is not the default on its own");

    teach("w8_vu/45j/_", "鍾");
    checkEq(typed("w8_vu/45j/_"), context + "鍾",
            "the pick is applied in the same context, as it is typed");
    checkEq(typed("5j/_"), alone, "and nowhere else");

    // A run that starts after English is a new run; the memory still applies
    // to its words, keyed on the run's own context.
    Buffer::clearUserOverrides();
    teach("5j/_", "鍾");
    Buffer afterEnglish;
    type(afterEnglish, "su3cl3");  // a live run of two syllables…
    type(afterEnglish, "ab");      // …English straight after it…
    type(afterEnglish, "5j/_");    // …then a syllable peeled into a new run
    const std::string text = afterEnglish.preeditText();
    check(text.size() >= 3 && text.compare(text.size() - 3, 3, "鍾") == 0,
          "a new run after English gets the remembered pick too");
    Buffer::clearUserOverrides();
    teach("w8_vu/45j/_", "鍾");

    // Typing on past it must not undo it.
    Buffer longer;
    type(longer, "w8_vu/45j/_");
    type(longer, "su3");
    check(longer.preeditText().rfind(context + "鍾", 0) == 0,
          "the applied pick holds while typing continues");

    // Re-opening candidates elsewhere in the run re-feeds it; the remembered
    // pick is pinned like an explicit one.
    Buffer reopened;
    type(reopened, "w8_vu/45j/_");
    reopened.handleKey(fcitx::Key(FcitxKey_Left));
    reopened.handleKey(fcitx::Key(FcitxKey_Left));
    reopened.handleKey(fcitx::Key(FcitxKey_Down));
    reopened.handleKey(fcitx::Key(FcitxKey_Escape));
    checkEq(reopened.preeditText(), context + "鍾",
            "re-opening candidates keeps the remembered pick");

    Buffer::clearUserOverrides();
    checkEq(typed("w8_vu/45j/_"), before, "the memory does not outlive the process");
}

void testNothingPersisted() {
    Buffer::clearUserOverrides();
    teach("w8_vu/45j/_", "鍾");
    check(!std::filesystem::exists(ari_ime::userPreferencePath()),
          "a pick writes no preference sidecar");
    Zhuyin engine;
    bool learned = false;
    for (const auto &entry : engine.userPhrases()) {
        learned = learned || entry.phrase.find("鍾") != std::string::npos;
    }
    check(!learned, "a pick teaches libchewing nothing");
}

void testSaveAndLoad() {
    // The memory survives a restart (D19): what is saved loads back, decay
    // keeps counting across the gap, and a foreign file is refused.
    using Model = ari_ime::UserOverrideModel;
    Model model(10, 5400.0);
    model.observe("k", "鍾", 100);
    model.observe("k", "中", 200);
    model.observe("k", "中", 300);
    model.observe("j", "重", 400);
    std::stringstream saved;
    model.save(saved);

    Model restored(10, 5400.0);
    std::stringstream copy(saved.str());
    check(restored.load(copy, 500), "a saved memory loads");
    check(restored.size() == 2, "with every context");
    checkEq(restored.suggest("k", 500), "中", "the counts come back");
    checkEq(restored.suggest("j", 500), "重", "and every pick");

    Model later(10, 5400.0);
    std::stringstream again(saved.str());
    later.load(again, 400 + 5400.0 * 21);
    check(later.size() == 0, "what decayed while it was off is dropped");

    Model refused(10, 5400.0);
    refused.observe("x", "y", 0);
    std::stringstream foreign("something else\nk\t鍾\t1\t0\n");
    check(!refused.load(foreign, 0), "an unknown file is refused");
    checkEq(refused.suggest("x", 0), "y", "and leaves the memory alone");
}

void testPickMemoryFile() {
    const auto path = ari_ime::userDataDir() / "pick-memory.tsv";
    Buffer::clearUserOverrides();
    check(!std::filesystem::exists(path), "clearing removes the saved memory");
    teach("w8_vu/45j/_", "鍾");
    std::ifstream in(path);
    std::stringstream text;
    text << in.rdbuf();
    check(text.str().find("鍾") != std::string::npos, "a pick is saved to disk");
    Buffer::clearUserOverrides();
    check(!std::filesystem::exists(path), "and clearing removes it again");
    {
        Buffer sensitive;
        sensitive.setLearningAllowed(false);
        type(sensitive, "w8_vu/45j/_");
        pickLast(sensitive, "鍾");
        sensitive.handleKey(fcitx::Key(FcitxKey_Return));
    }
    check(!std::filesystem::exists(path), "a sensitive field saves nothing");
}

void testSensitiveField() {
    Buffer::clearUserOverrides();
    const std::string before = typed("w8_vu/45j/_");
    {
        Buffer sensitive;
        sensitive.setLearningAllowed(false);
        type(sensitive, "w8_vu/45j/_");
        check(pickLast(sensitive, "鍾"), "a sensitive field can still pick");
        sensitive.handleKey(fcitx::Key(FcitxKey_Return));
    }
    checkEq(typed("w8_vu/45j/_"), before, "but the pick is not remembered");
}

void testForget() {
    Buffer::clearUserOverrides();
    const std::string before = typed("w8_vu/45j/_");
    teach("w8_vu/45j/_", "鍾");
    Buffer buffer;
    type(buffer, "w8_vu/45j/_");
    checkEq(buffer.preeditText(), withoutLast(before) + "鍾",
            "remembered before forgetting");
    buffer.handleKey(fcitx::Key(FcitxKey_Down));
    // Highlight 鍾 and forget it.
    const auto candidates = buffer.candidates();
    int at = -1;
    for (int i = 0; i < static_cast<int>(candidates.size()); ++i) {
        if (candidates[static_cast<std::size_t>(i)] == "鍾") {
            at = i;
        }
    }
    check(at >= 0, "鍾 is on the first page");
    for (int i = 0; i < at; ++i) {
        buffer.handleKey(fcitx::Key(FcitxKey_Down)); // ↓ moves the highlight
    }
    const KeyResult forgot = buffer.handleKey(fcitx::Key(
        FcitxKey_Delete, fcitx::KeyStates{fcitx::KeyState::Shift}));
    check(forgot.notification.find("已忘記") == 0, "Shift+Delete forgets it");
    checkEq(typed("w8_vu/45j/_"), before, "and it is no longer applied");
}

// Pick `text` for the character right of the caret after `left` presses of ←.
bool pickAt(Buffer &buffer, int left, const std::string &text) {
    for (int i = 0; i < left; ++i) {
        buffer.handleKey(fcitx::Key(FcitxKey_Left));
    }
    return pickLast(buffer, text);
}

// Picking a single character inside a word splits it (是 for the 市 of 城市).
// The next conversion shows the unsplit word again, so that is where the
// memory must be found.
void testSplitWord() {
    Buffer::clearUserOverrides();
    // vm03 t/6 g4 = ㄒㄩㄢˇ ㄔㄥˊ ㄕˋ, which the dictionary reads as 選城市.
    const std::string before = typed("vm03t/6g4");
    const std::string alone = typed("t/6g4");
    std::string split;
    {
        Buffer buffer;
        type(buffer, "vm03t/6g4");
        check(pickLast(buffer, "是"), "是 is offered for the last syllable");
        split = buffer.preeditText();
        buffer.handleKey(fcitx::Key(FcitxKey_Return));
    }
    check(before != split, "the pick split a word");
    checkEq(typed("vm03t/6g4"), split, "the split is applied next time");
    checkEq(typed("vm03t/6g4ji3"), split + typed("ji3"),
            "and holds while typing continues");
    checkEq(typed("t/6g4"), alone, "only in its own context");

    // libchewing re-picks the rest of a split word on its own; fixing that
    // too revises the memory instead of keeping the first guess.
    Buffer::clearUserOverrides();
    std::string fixed;
    {
        Buffer buffer;
        type(buffer, "ji3t/6g4gp6ak7"); // 我 ㄔㄥˊ ㄕˋ 什麼
        check(pickAt(buffer, 3, "是"), "是 can split the middle word");
        buffer.handleKey(fcitx::Key(FcitxKey_End));
        check(pickAt(buffer, 4, "成"), "and 成 fixes its first character");
        fixed = buffer.preeditText();
        buffer.handleKey(fcitx::Key(FcitxKey_Return));
    }
    checkEq(fixed, "我成是什麼", "both picks took");
    checkEq(typed("ji3t/6g4gp6ak7"), fixed,
            "the revised split is what comes back");

    // Forgetting a character forgets a split that contains it.
    ari_ime::UserOverrideModel model(4, 5400.0);
    model.observe("k", "成是", 0);
    check(model.forget("是") == 1 && model.suggest("k", 0).empty(),
          "forgetting 是 drops the split 成是");
    Buffer::clearUserOverrides();
}

void testCustomPhrase() {
    Buffer::clearUserOverrides();
    // 妳號 (ㄋㄧˇ ㄏㄠˋ) is in no dictionary: compose it by hand first.
    Buffer buffer;
    type(buffer, "su3cl4");
    const std::string plain = buffer.preeditText();
    check(plain != "妳號", "妳號 is not a dictionary phrase");
    check(pickAt(buffer, 2, "妳"), "妳 can be picked for the first character");
    checkEq(buffer.preeditText(), "妳號", "composed by hand");

    // Shift+← twice from the end marks both characters.
    buffer.handleKey(fcitx::Key(FcitxKey_End));
    const fcitx::Key shiftLeft(FcitxKey_Left,
                               fcitx::KeyStates{fcitx::KeyState::Shift});
    buffer.handleKey(shiftLeft);
    checkEq(buffer.markStatus(), "自訂詞需為 2–8 個中文字",
            "one character is too short to add");
    buffer.handleKey(shiftLeft);
    check(buffer.markedRange() == std::make_pair(0, 2), "both characters are marked");
    checkEq(buffer.markStatus(), "Enter 加入自訂詞「妳號」", "Enter would add it");
    const KeyResult added = buffer.handleKey(fcitx::Key(FcitxKey_Return));
    checkEq(added.notification, "已加入自訂詞「妳號」", "Enter adds it");
    check(!added.hasCommit, "and does not commit the composition");
    check(buffer.markedRange().first < 0, "the mark is cleared");

    Buffer::clearUserOverrides(); // only the custom phrase may be at work now
    checkEq(typed("su3cl4"), "妳號", "a custom phrase wins conversion afterwards");

    Buffer again;
    type(again, "su3cl4");
    again.handleKey(shiftLeft);
    again.handleKey(shiftLeft);
    checkEq(again.markStatus(), "已有自訂詞「妳號」", "an existing phrase is reported");

    // Esc drops the mark but stays in editing.
    again.handleKey(fcitx::Key(FcitxKey_Escape));
    check(again.markedRange().first < 0 && again.isEditing(),
          "Esc clears the mark and keeps editing");

    Zhuyin engine;
    check(engine.forgetUserPhrase("妳號") > 0, "a custom phrase can be removed");
    checkEq(typed("su3cl4"), plain, "and conversion returns to the dictionary");
}

} // namespace

int main() {
    @autoreleasepool {
        NSString *sandbox = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"ari-user-override-test-%d", getpid()]];
        setenv("ARI_IME_USER_DATA_DIR", sandbox.UTF8String, 1);
        setenv("CHEWING_USER_PATH", sandbox.UTF8String, 1);
        unsetenv("ARI_IME_DISABLE_AUTOLEARN");

        testModel();
        testContext();
        testNothingPersisted();
        testSaveAndLoad();
        testPickMemoryFile();
        testSensitiveField();
        testForget();
        testSplitWord();
        testCustomPhrase();

        [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
    }
    printf("\n%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
