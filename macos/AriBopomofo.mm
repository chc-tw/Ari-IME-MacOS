// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#include "AriBopomofo.h"

#include "layout.h"
#include "zhuyin.h"

namespace ari {

namespace {

// libchewing owns the key-to-Bopomofo mapping for every supported layout, so
// ask it rather than keeping a second table here that could drift. One context
// is kept for the process, as the core does for its own scratch probes;
// building one loads the dictionaries.
Zhuyin &scratchContext() {
    static Zhuyin *context = nullptr;
    static inputer::KeyboardLayout layout = inputer::currentKeyboardLayout();
    if (!context) {
        context = new Zhuyin();
        layout = inputer::currentKeyboardLayout();
    }
    if (layout != inputer::currentKeyboardLayout()) {
        layout = inputer::currentKeyboardLayout();
        context->setKeyboardLayout(layout);
    }
    return *context;
}

} // namespace

std::string readingForKeys(const std::string &keys) {
    if (keys.empty()) {
        return {};
    }
    Zhuyin &context = scratchContext();
    if (!context.ok()) {
        return {};
    }
    context.feedSequence(keys);
    // An in-progress syllable carries no tone, so nothing converts and the
    // pre-edit holds exactly the pending Bopomofo.
    std::string reading = context.hasBopomofo() ? context.preedit() : std::string{};
    context.resetAll();
    return reading;
}

} // namespace ari
