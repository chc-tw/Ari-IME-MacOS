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
#include <cmath>
#include <cstddef>
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

    UserOverrideModel(std::size_t capacity, double halfLifeSeconds)
        : capacity_(capacity), decayExponent_(std::log(0.5) / halfLifeSeconds) {}

    // Learn from a pick that turned `before` into `after`. `pickedNode` indexes
    // the node in `after` that the user chose.
    void observe(const Walk &before, const Walk &after, std::size_t pickedNode,
                 double timestamp) {
        if (before.empty() || pickedNode >= after.size() ||
            totalLength(before) != totalLength(after)) {
            return;
        }
        const Node &current = after[pickedNode];
        // McBopomofo found longer phrases not worth remembering.
        if (current.length > 3) {
            return;
        }
        // The node in the earlier walk that ended where the pick ends.
        int end = 0;
        for (std::size_t i = 0; i <= pickedNode; ++i) {
            end += after[i].length;
        }
        const std::size_t prevHead = nodeContaining(before, end - 1);
        if (prevHead >= before.size()) {
            return;
        }
        // Splitting a phrase into a single character keys the observation on
        // the walk after the pick, since the phrase it broke is not coming back.
        const bool breakingUp =
            current.length == 1 && before[prevHead].length > 1;
        const std::string key = breakingUp ? formKey(after, pickedNode)
                                           : formKey(before, prevHead);
        observe(key, current.value, timestamp);
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

    // Drop every memory that would suggest `candidate`. Returns how many were
    // removed.
    int forget(const std::string &candidate) {
        int removed = 0;
        for (auto it = lru_.begin(); it != lru_.end();) {
            auto &overrides = it->second.overrides;
            const auto found = overrides.find(candidate);
            if (found != overrides.end()) {
                it->second.count -= found->second.count;
                overrides.erase(found);
                ++removed;
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

    static int totalLength(const Walk &walk) {
        int total = 0;
        for (const Node &node : walk) {
            total += node.length;
        }
        return total;
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
