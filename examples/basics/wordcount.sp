# 単語数え: 標準入力の代わりに文字列を使う
import table
let text = "the quick brown fox jumps over the lazy dog the end"
let counts = {}
for w in text.split(" "):
    counts[w] = (counts[w] or 0) + 1
let words = table.keys(counts)
words.sort(func(a, b): counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
for w in words.slice(0, 3):
    print(w, counts[w])
