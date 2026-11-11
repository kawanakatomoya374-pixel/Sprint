local function factorial_digits(n)
  local d = {}
  for i = 1, 9000 do d[i] = 0 end
  d[1] = 1
  local len_d = 1
  for m = 2, n do
    local carry = 0
    for i = 1, len_d do
      local v = d[i] * m + carry
      d[i] = v % 10000
      carry = math.floor(v / 10000)
    end
    while carry > 0 do
      len_d = len_d + 1
      d[len_d] = carry % 10000
      carry = math.floor(carry / 10000)
    end
  end
  local s = 0
  for i = 1, len_d do s = s + d[i] end
  return s
end
print(factorial_digits(9000))
