import str
let s = "  Hello, World  "
print(s.trim().upper(), s.trim().lower(), s.find("World"), s.replace("l", "L"))
print(str.format("{} + {} = {}", 1, 2, 3), str.join(["a", "b"], "-"))
print("héllo".char_count(), "abc".slice(1, 2), "a" .. "b" .. 1)
