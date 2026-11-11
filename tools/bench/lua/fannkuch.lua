local function fannkuch(n)
  local perm1, perm, count = {}, {}, {}
  for i = 1, n do perm1[i] = i - 1; perm[i] = 0; count[i] = 0 end
  local max_flips, checksum, nperm, r = 0, 0, 0, n
  while true do
    while r ~= 1 do count[r] = r; r = r - 1 end
    for i = 1, n do perm[i] = perm1[i] end
    local flips = 0
    local k = perm[1]
    while k ~= 0 do
      local i, j = 1, k + 1
      while i < j do perm[i], perm[j] = perm[j], perm[i]; i = i + 1; j = j - 1 end
      flips = flips + 1
      k = perm[1]
    end
    if flips > max_flips then max_flips = flips end
    if nperm % 2 == 0 then checksum = checksum + flips else checksum = checksum - flips end
    while true do
      if r == n then print(checksum); return max_flips end
      local p0 = perm1[1]
      for i = 1, r do perm1[i] = perm1[i + 1] end
      perm1[r + 1] = p0
      count[r + 1] = count[r + 1] - 1
      if count[r + 1] > 0 then break end
      r = r + 1
    end
    nperm = nperm + 1
  end
end
print(fannkuch(10))
