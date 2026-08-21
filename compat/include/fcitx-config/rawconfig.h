// SPDX-License-Identifier: GPL-3.0-or-later
// Minimal stand-in for Fcitx5's RawConfig, used by builds that have no
// Fcitx5 (headless WASM, macOS). It implements just the value/subtree access
// that layout.h's enum annotations and the layout tests rely on.
#ifndef ARI_WASM_FCITX_CONFIG_RAWCONFIG_H
#define ARI_WASM_FCITX_CONFIG_RAWCONFIG_H

#include <map>
#include <memory>
#include <string>
#include <string_view>

namespace fcitx {

class RawConfig {
public:
    RawConfig() = default;

    const std::string &value() const { return value_; }
    void setValue(std::string value) { value_ = std::move(value); }
    RawConfig &operator=(std::string value) {
        value_ = std::move(value);
        return *this;
    }

    // Path components are separated by '/', as in Fcitx5.
    void setValueByPath(std::string_view path, std::string value) {
        node(path, /*create=*/true)->setValue(std::move(value));
    }

    RawConfig *get(std::string_view path) { return node(path, false); }
    const RawConfig *get(std::string_view path) const {
        return const_cast<RawConfig *>(this)->node(path, false);
    }

private:
    RawConfig *node(std::string_view path, bool create) {
        RawConfig *current = this;
        while (!path.empty() && current) {
            const std::size_t slash = path.find('/');
            const std::string_view head =
                slash == std::string_view::npos ? path : path.substr(0, slash);
            path = slash == std::string_view::npos ? std::string_view{}
                                                   : path.substr(slash + 1);
            const std::string key(head);
            auto it = current->children_.find(key);
            if (it == current->children_.end()) {
                if (!create) {
                    return nullptr;
                }
                it = current->children_
                         .emplace(key, std::make_unique<RawConfig>())
                         .first;
            }
            current = it->second.get();
        }
        return current;
    }

    std::string value_;
    std::map<std::string, std::unique_ptr<RawConfig>> children_;
};

} // namespace fcitx

#endif // ARI_WASM_FCITX_CONFIG_RAWCONFIG_H
