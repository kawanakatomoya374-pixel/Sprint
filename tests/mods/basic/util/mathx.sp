export const PI2 = 6.28
export let counter = 0

export func inc(n):
    counter += 1
    return n + 1

export class Point:
    let x = 0
    func init(self, x):
        self.x = x
    func get(self):
        return self.x

func hidden():
    return 1

print("init mathx")
