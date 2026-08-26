// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_MACOS_BOPOMOFO_H
#define ARI_MACOS_BOPOMOFO_H

#include <string>

namespace ari {

// Render the raw keys of an in-progress syllable as the reading they stand for
// (for example "cj0" -> "ㄏㄨㄢ" on the 大千 layout). Returns an empty string
// when the keys do not form a readable syllable.
//
// Ari's pre-edit deliberately shows the keys themselves, because a run of keys
// may still turn out to be English. Showing the reading beside them is what
// makes the choice visible: if "ui" is being read as ㄧㄛ rather than left as
// English, the user can see it immediately instead of discovering it several
// characters later.
std::string readingForKeys(const std::string &keys);

} // namespace ari

#endif // ARI_MACOS_BOPOMOFO_H
