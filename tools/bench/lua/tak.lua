local function tak(x, y, z)
  if y >= x then return z end
  return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))
end
local function ack(m, n)
  if m == 0 then return n + 1 end
  if n == 0 then return ack(m - 1, 1) end
  return ack(m - 1, ack(m, n - 1))
end
print(tak(28, 18, 8), ack(2, 400), ack(3, 7))
