const UNIT = 10

class Hidden:
    let tag = "hidden"
    let base_n = UNIT * 2
    func hello(self):
        return "hello from " .. self.tag

export class Shape extends Hidden:
    let name = "shape"
    let sides = 0
    let pts = []
    let scale = UNIT
    func init(self, name = "shape", sides = 0):
        self.name = name
        self.sides = sides
    func area(self):
        return 0
    func describe(self):
        return self.name .. "/" .. to_string(self.sides) .. "/" .. to_string(self.scale)

export class Named:
    let label = "anon"
    func show(self):
        return "<" .. self.label .. ">"

export class Plain:
    pass
