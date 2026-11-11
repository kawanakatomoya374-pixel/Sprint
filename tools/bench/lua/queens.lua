local function solve(n, row, cols, d1, d2)
  if row == n then return 1 end
  local c = 0
  for col = 0, n - 1 do
    if cols[col + 1] == 0 and d1[row + col + 1] == 0 and d2[row - col + n + 1] == 0 then
      cols[col + 1] = 1; d1[row + col + 1] = 1; d2[row - col + n + 1] = 1
      c = c + solve(n, row + 1, cols, d1, d2)
      cols[col + 1] = 0; d1[row + col + 1] = 0; d2[row - col + n + 1] = 0
    end
  end
  return c
end
local n = 12
local function z(k) local t = {} for i = 1, k do t[i] = 0 end return t end
print(solve(n, 0, z(n), z(2 * n), z(2 * n + 1)))
