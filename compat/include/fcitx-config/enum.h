// SPDX-License-Identifier: GPL-3.0-or-later
// Stand-in for Fcitx5's configuration enum metadata.
//
// Fcitx5 generates marshall/unmarshall helpers for enums declared with
// FCITX_CONFIG_ENUM_NAME so they persist as stable strings ("Eten") rather
// than ordinals. Builds without Fcitx5 need the same mapping: the macOS
// frontend stores the value in NSUserDefaults and the layout tests assert on
// it, so this shim implements the macro rather than discarding it.
#ifndef ARI_WASM_FCITX_CONFIG_ENUM_H
#define ARI_WASM_FCITX_CONFIG_ENUM_H

#include <fcitx-config/rawconfig.h>

#include <string>

#define FCITX_CONFIG_ENUM_NAME(TYPE, ...)                                      \
    inline const char *const *TYPE##EnumNames() {                              \
        static const char *const names[] = {__VA_ARGS__, nullptr};             \
        return names;                                                          \
    }                                                                          \
    inline void marshallOption(fcitx::RawConfig &config, const TYPE value) {   \
        const char *const *names = TYPE##EnumNames();                          \
        const int index = static_cast<int>(value);                             \
        for (int i = 0; i <= index; ++i) {                                     \
            if (!names[i]) {                                                   \
                return;                                                        \
            }                                                                  \
        }                                                                      \
        config.setValue(names[index]);                                         \
    }                                                                          \
    inline bool unmarshallOption(TYPE &value, const fcitx::RawConfig &config,  \
                                 bool /*partial*/) {                           \
        const char *const *names = TYPE##EnumNames();                          \
        for (int i = 0; names[i]; ++i) {                                       \
            if (config.value() == names[i]) {                                  \
                value = static_cast<TYPE>(i);                                  \
                return true;                                                   \
            }                                                                  \
        }                                                                      \
        return false;                                                          \
    }

#endif // ARI_WASM_FCITX_CONFIG_ENUM_H
