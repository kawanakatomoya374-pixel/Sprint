local cos, sin, pi = math.cos, math.sin, math.pi
local function fft(re, im, n, cs, sn)
  local j = 0
  for i = 0, n - 2 do
    if i < j then
      re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
      im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
    end
    local m = n / 2
    while m >= 1 and j >= m do j = j - m; m = math.floor(m / 2) end
    j = j + m
  end
  local size = 2
  while size <= n do
    local half = size / 2
    local step = n / size
    local k = 0
    while k < n do
      for jj = 0, half - 1 do
        local wr, wi = cs[jj * step + 1], sn[jj * step + 1]
        local a = k + jj + 1
        local b = a + half
        local xr = re[b] * wr - im[b] * wi
        local xi = re[b] * wi + im[b] * wr
        re[b] = re[a] - xr
        im[b] = im[a] - xi
        re[a] = re[a] + xr
        im[a] = im[a] + xi
      end
      k = k + size
    end
    size = size * 2
  end
end
local n = 2 ^ 17
local cs, sn = {}, {}
for i = 0, n - 1 do cs[i + 1] = cos(-2.0 * pi * i / n); sn[i + 1] = sin(-2.0 * pi * i / n) end
local acc = 0.0
for r = 0, 11 do
  local re, im = {}, {}
  for i = 0, n - 1 do re[i + 1] = ((i * 31 + r) % 17) / 17.0; im[i + 1] = 0.0 end
  fft(re, im, n, cs, sn)
  acc = acc + re[2] + im[4]
end
print(string.format("%d", math.floor(acc * 1000)))
