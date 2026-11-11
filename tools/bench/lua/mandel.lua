local function mandel(size)
  local inside = 0
  for py = 0, size - 1 do
    local ci = 2.0 * py / size - 1.0
    for px = 0, size - 1 do
      local cr = 2.0 * px / size - 1.5
      local zr, zi, i = 0.0, 0.0, 0
      while i < 50 and zr * zr + zi * zi <= 4.0 do
        local t = zr * zr - zi * zi + cr
        zi = 2.0 * zr * zi + ci
        zr = t
        i = i + 1
      end
      if i == 50 then inside = inside + 1 end
    end
  end
  return inside
end
print(mandel(2000))
