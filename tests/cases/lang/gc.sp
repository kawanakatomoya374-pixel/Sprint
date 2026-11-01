import gc
let root = []
for i in range(2048):
    root.append([i])
let cycle = []
cycle.append(cycle)
root.append(cycle)
gc.collect()
let stats = gc.stats()
print(len(root), root[2047][0], type(stats.live_objects), type(stats.collections))
print(root[2048][0] == root[2048])
