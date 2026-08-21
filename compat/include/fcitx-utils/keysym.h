// SPDX-License-Identifier: GPL-3.0-or-later
// X11-compatible key symbols needed by the platform-neutral Ari buffer.
#ifndef ARI_WASM_FCITX_UTILS_KEYSYM_H
#define ARI_WASM_FCITX_UTILS_KEYSYM_H

#include "key.h"

inline constexpr fcitx::KeySym FcitxKey_space = 0x0020;
inline constexpr fcitx::KeySym FcitxKey_apostrophe = 0x0027;
inline constexpr fcitx::KeySym FcitxKey_quotedbl = 0x0022;
inline constexpr fcitx::KeySym FcitxKey_bracketleft = 0x005b;
inline constexpr fcitx::KeySym FcitxKey_bracketright = 0x005d;
inline constexpr fcitx::KeySym FcitxKey_z = 0x007a;

inline constexpr fcitx::KeySym FcitxKey_1 = 0x0031;
inline constexpr fcitx::KeySym FcitxKey_9 = 0x0039;

inline constexpr fcitx::KeySym FcitxKey_Tab = 0xff09;
inline constexpr fcitx::KeySym FcitxKey_ISO_Left_Tab = 0xfe20;
inline constexpr fcitx::KeySym FcitxKey_Return = 0xff0d;
inline constexpr fcitx::KeySym FcitxKey_KP_Enter = 0xff8d;
inline constexpr fcitx::KeySym FcitxKey_BackSpace = 0xff08;
inline constexpr fcitx::KeySym FcitxKey_Delete = 0xffff;
inline constexpr fcitx::KeySym FcitxKey_Escape = 0xff1b;
inline constexpr fcitx::KeySym FcitxKey_Left = 0xff51;
inline constexpr fcitx::KeySym FcitxKey_Up = 0xff52;
inline constexpr fcitx::KeySym FcitxKey_Right = 0xff53;
inline constexpr fcitx::KeySym FcitxKey_Down = 0xff54;
inline constexpr fcitx::KeySym FcitxKey_Page_Up = 0xff55;
inline constexpr fcitx::KeySym FcitxKey_Page_Down = 0xff56;
inline constexpr fcitx::KeySym FcitxKey_End = 0xff57;
inline constexpr fcitx::KeySym FcitxKey_Begin = 0xff58;
inline constexpr fcitx::KeySym FcitxKey_Home = 0xff50;
inline constexpr fcitx::KeySym FcitxKey_Insert = 0xff63;

inline constexpr fcitx::KeySym FcitxKey_KP_0 = 0xffb0;
inline constexpr fcitx::KeySym FcitxKey_KP_1 = 0xffb1;
inline constexpr fcitx::KeySym FcitxKey_KP_2 = 0xffb2;
inline constexpr fcitx::KeySym FcitxKey_KP_3 = 0xffb3;
inline constexpr fcitx::KeySym FcitxKey_KP_4 = 0xffb4;
inline constexpr fcitx::KeySym FcitxKey_KP_5 = 0xffb5;
inline constexpr fcitx::KeySym FcitxKey_KP_6 = 0xffb6;
inline constexpr fcitx::KeySym FcitxKey_KP_7 = 0xffb7;
inline constexpr fcitx::KeySym FcitxKey_KP_8 = 0xffb8;
inline constexpr fcitx::KeySym FcitxKey_KP_9 = 0xffb9;
inline constexpr fcitx::KeySym FcitxKey_KP_Decimal = 0xffae;
inline constexpr fcitx::KeySym FcitxKey_KP_Divide = 0xffaf;
inline constexpr fcitx::KeySym FcitxKey_KP_Multiply = 0xffaa;
inline constexpr fcitx::KeySym FcitxKey_KP_Subtract = 0xffad;
inline constexpr fcitx::KeySym FcitxKey_KP_Add = 0xffab;
inline constexpr fcitx::KeySym FcitxKey_KP_Equal = 0xffbd;
inline constexpr fcitx::KeySym FcitxKey_KP_Space = 0xff80;
inline constexpr fcitx::KeySym FcitxKey_KP_Prior = 0xff9a;
inline constexpr fcitx::KeySym FcitxKey_KP_Next = 0xff9b;
inline constexpr fcitx::KeySym FcitxKey_KP_End = 0xff9c;
inline constexpr fcitx::KeySym FcitxKey_KP_Begin = 0xff9d;
inline constexpr fcitx::KeySym FcitxKey_KP_Insert = 0xff9e;
inline constexpr fcitx::KeySym FcitxKey_KP_Home = 0xff95;
inline constexpr fcitx::KeySym FcitxKey_KP_Left = 0xff96;
inline constexpr fcitx::KeySym FcitxKey_KP_Up = 0xff97;
inline constexpr fcitx::KeySym FcitxKey_KP_Right = 0xff98;
inline constexpr fcitx::KeySym FcitxKey_KP_Down = 0xff99;
inline constexpr fcitx::KeySym FcitxKey_KP_Delete = 0xff9f;

// Printable ASCII keysyms are their ASCII code point (X11 convention).
inline constexpr fcitx::KeySym FcitxKey_exclam = 0x0021;
inline constexpr fcitx::KeySym FcitxKey_parenleft = 0x0028;
inline constexpr fcitx::KeySym FcitxKey_parenright = 0x0029;
inline constexpr fcitx::KeySym FcitxKey_period = 0x002e;
inline constexpr fcitx::KeySym FcitxKey_slash = 0x002f;
inline constexpr fcitx::KeySym FcitxKey_3 = 0x0033;
inline constexpr fcitx::KeySym FcitxKey_4 = 0x0034;
inline constexpr fcitx::KeySym FcitxKey_colon = 0x003a;
inline constexpr fcitx::KeySym FcitxKey_less = 0x003c;
inline constexpr fcitx::KeySym FcitxKey_greater = 0x003e;
inline constexpr fcitx::KeySym FcitxKey_question = 0x003f;
inline constexpr fcitx::KeySym FcitxKey_braceleft = 0x007b;
inline constexpr fcitx::KeySym FcitxKey_c = 0x0063;
inline constexpr fcitx::KeySym FcitxKey_g = 0x0067;
inline constexpr fcitx::KeySym FcitxKey_i = 0x0069;
inline constexpr fcitx::KeySym FcitxKey_j = 0x006a;
inline constexpr fcitx::KeySym FcitxKey_l = 0x006c;
inline constexpr fcitx::KeySym FcitxKey_s = 0x0073;
inline constexpr fcitx::KeySym FcitxKey_u = 0x0075;
inline constexpr fcitx::KeySym FcitxKey_v = 0x0076;

inline constexpr fcitx::KeySym FcitxKey_F1 = 0xffbe;

#endif // ARI_WASM_FCITX_UTILS_KEYSYM_H
