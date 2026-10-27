// C++ library used through extern "C": the Sprint ffi module calls it like any C library.
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <numeric>
#include <string>
#include <vector>

struct Counter {
    std::vector<int> v;
};

extern "C" {
void *counter_new(void) { return new Counter(); }
void counter_add(void *c, int x) { static_cast<Counter *>(c)->v.push_back(x); }
int counter_sum(void *c) {
    auto &v = static_cast<Counter *>(c)->v;
    return std::accumulate(v.begin(), v.end(), 0);
}
int counter_max(void *c) {
    auto &v = static_cast<Counter *>(c)->v;
    return v.empty() ? 0 : *std::max_element(v.begin(), v.end());
}
void counter_free(void *c) { delete static_cast<Counter *>(c); }
// writes the reversed string into out (std::string inside, plain C in the signature)
int reverse_into(const char *s, char *out, int cap) {
    std::string r(s);
    std::reverse(r.begin(), r.end());
    if (static_cast<int>(r.size()) + 1 > cap) return -1;
    std::memcpy(out, r.c_str(), r.size() + 1);
    return static_cast<int>(r.size());
}
}
