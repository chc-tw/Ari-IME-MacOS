// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef ARI_IME_USER_OVERRIDE_H
#define ARI_IME_USER_OVERRIDE_H

// A short-term memory of candidate picks, ported from McBopomofo's
// UserOverrideModel (Source/Engine/UserOverrideModel.cpp, MIT licence).
//
// A pick is remembered against its context — the two words before it and the
// reading it replaced — not against the reading alone, so choosing 鍾 after 他姓
// says nothing about ㄓㄨㄥ anywhere else. Each memory decays exponentially
// with a configurable half-life and is dropped once it falls below 2^-20 (about
// thirty hours at McBopomofo's 1.5-hour half-life); the least recently used
// context is evicted beyond the capacity. Nothing here is persisted: a rare
// character picked once is preferred in that context for a while, then forgotten.

#include <chrono>
#include <istream>
#include <ostream>
#include <sstream>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <iterator>
#include <list>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace ari_ime {

class UserOverrideModel {
public:
    // One word of a conversion: `reading` identifies its syllables, `value` is
    // the text shown, and `topValue` is what the dictionary would choose for
    // the same syllables without any override.
    struct Node {
        std::string reading;
        std::string value;
        std::string topValue;
        int length = 1; // syllables spanned
    };
    using Walk = std::vector<Node>;

    // What observe() stored: the key, the suggested text, and the syllables
    // [from, to) of the walk that text covers. An empty key means nothing.
    struct Observed {
        std::string key;
        std::string value;
        int from = 0;
        int to = 0;
    };

    UserOverrideModel(std::size_t capacity, double halfLifeSeconds)
        : capacity_(capacity), decayExponent_(std::log(0.5) / halfLifeSeconds) {}
    // index_ holds iterators into lru_; a copy would point into the original.
    UserOverrideModel(const UserOverrideModel &) = delete;
    UserOverrideModel &operator=(const UserOverrideModel &) = delete;

    // Learn from a pick that turned `before` into `after`. `pickedNode` indexes
    // the node in `after` that the user chose.
    Observed observe(const Walk &before, const Walk &after,
                     std::size_t pickedNode, double timestamp) {
        if (before.empty() || pickedNode >= after.size() ||
            totalLength(before) != totalLength(after)) {
            return {};
        }
        const Node &current = after[pickedNode];
        // McBopomofo found longer phrases not worth remembering.
        if (current.length > 3) {
            return {};
        }
        // The node in the earlier walk that ended where the pick ends.
        int end = 0;
        for (std::size_t i = 0; i <= pickedNode; ++i) {
            end += after[i].length;
        }
        const std::size_t prevHead = nodeContaining(before, end - 1);
        if (prevHead >= before.size()) {
            return {};
        }
        // Splitting a word with a single character (是 for the 市 of 城市) is
        // remembered against the word the dictionary will show again next time,
        // and suggests the whole split text (成是) in its place. McBopomofo keys
        // this on the walk after the pick instead, where a later conversion,
        // which shows the unsplit word, never finds it.
        const bool breakingUp =
            current.length == 1 && before[prevHead].length > 1;
        int headStart = 0;
        for (std::size_t i = 0; i < prevHead; ++i) {
            headStart += before[i].length;
        }
        Observed stored{formKey(before, prevHead), current.value,
                        end - current.length, end};
        if (breakingUp) {
            stored.from = headStart;
            stored.to = headStart + before[prevHead].length;
            stored.value = textOf(after, stored.from, stored.to);
            if (stored.value.empty()) {
                return {};
            }
        }
        observe(stored.key, stored.value, timestamp);
        return stored;
    }

    // Replace what an earlier observation under `key` suggested, as when the
    // user goes on to fix another character of a word they just split.
    void revise(const std::string &key, const std::string &oldValue,
                const std::string &newValue, double timestamp) {
        const auto found = index_.find(key);
        if (found != index_.end()) {
            Observation &observation = found->second->second;
            const auto old = observation.overrides.find(oldValue);
            if (old != observation.overrides.end()) {
                observation.count -= old->second.count;
                observation.overrides.erase(old);
            }
        }
        observe(key, newValue, timestamp);
    }

    // The remembered pick for the node at `head`, or "" when there is none.
    std::string suggest(const Walk &walk, std::size_t head,
                        double timestamp) const {
        if (head >= walk.size()) {
            return {};
        }
        return suggest(formKey(walk, head), timestamp);
    }

    void observe(const std::string &key, const std::string &candidate,
                 double timestamp) {
        auto found = index_.find(key);
        if (found == index_.end()) {
            lru_.emplace_front(key, Observation{});
            index_.emplace(key, lru_.begin());
            lru_.front().second.update(candidate, timestamp);
            if (lru_.size() > capacity_) {
                index_.erase(lru_.back().first);
                lru_.pop_back();
            }
            return;
        }
        lru_.splice(lru_.begin(), lru_, found->second);
        found->second->second.update(candidate, timestamp);
    }

    std::string suggest(const std::string &key, double timestamp) const {
        const auto found = index_.find(key);
        if (found == index_.end()) {
            return {};
        }
        const Observation &observation = found->second->second;
        std::string candidate;
        double best = 0;
        for (const auto &[value, entry] : observation.overrides) {
            const double s = score(entry.count, observation.count,
                                   entry.timestamp, timestamp);
            if (s > best) {
                candidate = value;
                best = s;
            }
        }
        return candidate;
    }

    // Drop every memory that would put `candidate` on screen, including a
    // split word that contains it. Returns how many were removed.
    int forget(const std::string &candidate) {
        int removed = 0;
        for (auto it = lru_.begin(); it != lru_.end();) {
            auto &overrides = it->second.overrides;
            for (auto found = overrides.begin(); found != overrides.end();) {
                if (!candidate.empty() &&
                    found->first.find(candidate) != std::string::npos) {
                    it->second.count -= found->second.count;
                    found = overrides.erase(found);
                    ++removed;
                } else {
                    ++found;
                }
            }
            if (overrides.empty()) {
                index_.erase(it->first);
                it = lru_.erase(it);
            } else {
                ++it;
            }
        }
        return removed;
    }

    void clear() {
        lru_.clear();
        index_.clear();
    }

    std::size_t size() const { return lru_.size(); }

    // Persistence (D19). One line per context, most recent first:
    //   key \t candidate \t count \t timestamp [\t candidate \t count \t timestamp ...]
    // McBopomofo keeps this in memory only; Ari's server restarts on every
    // update, which erased everything learned, so it is saved and reloaded.
    static constexpr const char *kHeader = "# Ari IME pick memory v1";

    void save(std::ostream &out) const {
        out << kHeader << '\n';
        for (const auto &[key, observation] : lru_) {
            if (!storable(key)) {
                continue;
            }
            std::string line = key;
            for (const auto &[candidate, o] : observation.overrides) {
                if (!storable(candidate)) {
                    continue;
                }
                std::ostringstream fields;
                fields.precision(17);
                fields << '\t' << candidate << '\t' << o.count << '\t'
                       << o.timestamp;
                line += fields.str();
            }
            if (line.size() > key.size()) {
                out << line << '\n';
            }
        }
    }

    // Replace the memory with what `in` holds, dropping what has already
    // decayed away by `timestamp`. Returns false on an unknown format.
    bool load(std::istream &in, double timestamp) {
        std::string line;
        if (!std::getline(in, line) || line != kHeader) {
            return false;
        }
        clear();
        while (std::getline(in, line) && lru_.size() < capacity_) {
            std::vector<std::string> fields;
            std::size_t start = 0;
            for (std::size_t tab; (tab = line.find('\t', start)) != std::string::npos;
                 start = tab + 1) {
                fields.push_back(line.substr(start, tab - start));
            }
            fields.push_back(line.substr(start));
            if (fields.size() < 4 || (fields.size() - 1) % 3 != 0 ||
                fields[0].empty() || index_.count(fields[0])) {
                continue;
            }
            Observation observation;
            for (std::size_t i = 1; i + 2 < fields.size(); i += 3) {
                char *end = nullptr;
                const unsigned long count = std::strtoul(fields[i + 1].c_str(), &end, 10);
                const double when = std::strtod(fields[i + 2].c_str(), nullptr);
                if (fields[i].empty() || count == 0 ||
                    score(1, 1, when, timestamp) == 0.0) {
                    continue; // malformed, or forgotten by now anyway
                }
                Override &o = observation.overrides[fields[i]];
                o.count = count;
                o.timestamp = when;
                observation.count += count;
            }
            if (observation.overrides.empty()) {
                continue;
            }
            lru_.emplace_back(fields[0], std::move(observation));
            index_.emplace(fields[0], std::prev(lru_.end()));
        }
        return true;
    }

    static double now() {
        using namespace std::chrono;
        return duration<double>(system_clock::now().time_since_epoch()).count();
    }

private:
    struct Override {
        std::size_t count = 0;
        double timestamp = 0;
    };
    struct Observation {
        std::size_t count = 0;
        std::map<std::string, Override> overrides;

        void update(const std::string &candidate, double timestamp) {
            ++count;
            Override &o = overrides[candidate];
            o.timestamp = timestamp;
            ++o.count;
        }
    };

    double score(std::size_t eventCount, std::size_t totalCount,
                 double eventTimestamp, double timestamp) const {
        constexpr double kDecayThreshold = 1.0 / 1048576.0;
        const double decay =
            std::exp((timestamp - eventTimestamp) * decayExponent_);
        if (decay < kDecayThreshold || totalCount == 0) {
            return 0.0;
        }
        return static_cast<double>(eventCount) /
               static_cast<double>(totalCount) * decay;
    }

    static bool storable(const std::string &field) {
        return !field.empty() && field.find('\t') == std::string::npos &&
               field.find('\n') == std::string::npos &&
               field.find('\r') == std::string::npos;
    }

    static int totalLength(const Walk &walk) {
        int total = 0;
        for (const Node &node : walk) {
            total += node.length;
        }
        return total;
    }

    // The text of syllables [from, to) of a walk, one character per syllable.
    static std::string textOf(const Walk &walk, int from, int to) {
        std::string all;
        for (const Node &node : walk) {
            all += node.value;
        }
        std::string out;
        int at = -1;
        for (unsigned char c : all) {
            if ((c & 0xC0) != 0x80) {
                ++at;
            }
            if (at >= from && at < to) {
                out.push_back(static_cast<char>(c));
            }
        }
        return at + 1 == totalLength(walk) ? out : std::string{};
    }

    static std::size_t nodeContaining(const Walk &walk, int offset) {
        int accumulated = 0;
        for (std::size_t i = 0; i < walk.size(); ++i) {
            accumulated += walk[i].length;
            if (accumulated > offset) {
                return i;
            }
        }
        return walk.size();
    }

    // "(anterior)-(previous)-(head)". The head uses the dictionary's own choice,
    // since that is what a later conversion shows before any override; the two
    // words of context use what was actually shown. Ari's walks are contiguous
    // Chinese runs, so the start of a run reads like the start of a sentence.
    static std::string formKey(const Walk &walk, std::size_t head) {
        auto pair = [](const std::string &reading, const std::string &value) {
            return "(" + reading + "," + value + ")";
        };
        const std::string headStr =
            pair(walk[head].reading, walk[head].topValue);
        const std::string prevStr =
            head >= 1 ? pair(walk[head - 1].reading, walk[head - 1].value)
                      : "()";
        const std::string anteriorStr =
            head >= 2 ? pair(walk[head - 2].reading, walk[head - 2].value)
                      : "()";
        return anteriorStr + "-" + prevStr + "-" + headStr;
    }

    using Entry = std::pair<std::string, Observation>;
    std::size_t capacity_;
    double decayExponent_;
    std::list<Entry> lru_;
    std::map<std::string, std::list<Entry>::iterator> index_;
};

} // namespace ari_ime

#endif // ARI_IME_USER_OVERRIDE_H
