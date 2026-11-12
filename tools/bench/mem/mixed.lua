local keep, total = {}, 0
for round = 0, 299 do
  local head = nil
  for i = 0, 4999 do head = {val = i, next = head} end
  local p = head
  while p do total = total + p.val; p = p.next end
  local t = {}
  for i = 0, 499 do t["k" .. tostring(i)] = {i, i + 1} end
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  total = total + c
  if round % 20 == 0 then keep[#keep + 1] = head end
end
print(string.format("%d", total), #keep)
