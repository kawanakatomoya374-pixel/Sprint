import itertools as it
import strutil as su

print(it.enumerate(["a", "b"], 1), it.zip([1, 2, 3], ["x", "y"]), it.zip([1], [2], [3]))
print(it.take([1, 2, 3], 2), it.take([1], 5), it.drop([1, 2, 3], 1), it.drop([1], 5))
print(it.take_while([1, 2, 5, 1], x => x < 3), it.drop_while([1, 2, 5, 1], x => x < 3))
print(it.chunks([1, 2, 3, 4, 5], 2), it.windows([1, 2, 3, 4], 3), it.pairwise([1, 2, 3]))
print(it.flatten([[1], [2, 3], []]), it.flat_map([1, 2], x => [x, x * 10]), it.chain([1], [2], [3]))
print(it.unique([3, 1, 3, 2, 1]), it.unique(["a", "B", "b"], s => s.lower()))
print(it.group_by([1, 2, 3, 4, 5], x => x % 2), it.count_by(["a", "bb", "c"], s => len(s)))
print(it.partition([1, 2, 3, 4], x => x > 2), it.sum([1, 2, 3]), it.sum([0.5, 0.25], 0.0), it.product([2, 3, 4]))
print(it.min_by(["ccc", "a", "bb"], s => len(s)), it.max_by(["ccc", "a", "bb"], s => len(s)), it.min_by([], s => s))
print(it.sorted([3, 1, 2]), it.sort_by(["ccc", "a", "bb"], s => len(s)), it.reversed([1, 2, 3]))
print(it.first([5, 6]), it.last([5, 6]), it.first([], "none"), it.repeat("z", 3), it.range_list(4), it.range_list(1, 10, 3))
print(it.index_by([{id: 1}, {id: 2}], r => r.id))
try:
    it.chunks([1], 0)
catch e:
    print(e.kind)

print("[" .. su.pad_left("ab", 5) .. "][" .. su.pad_right("ab", 5, ".") .. "][" .. su.center("ab", 7, "*") .. "]")
print(su.capitalize("hELLO"), su.title("the quick  brown fox"), su.words("  a b   c "))
print(su.is_digits("123"), su.is_digits("12a"), su.is_alpha("abC"), su.is_alpha(""), su.is_space(" \t"))
print(su.truncate("hello world", 8), su.truncate("hi", 8), su.truncate("héllo wörld", 8))
print(su.indent("a\nb\n\nc", "> "))
print(su.wrap("the quick brown fox jumps over the lazy dog", 12))
print(su.reverse("abc"), su.reverse("héllo"), su.lines("x\ny\n"))
