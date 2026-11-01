import gc
let before = gc.stats().live_objects
let garbage = []
for i in range(256):
    garbage.append([i])
let allocated = gc.stats().live_objects
garbage = nil
gc.collect()
let after = gc.stats().live_objects
print(allocated > before, after < allocated, after > 0)
