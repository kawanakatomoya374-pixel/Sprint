function sieve(n) {
  const flags = [];
  for (let i = 0; i <= n; i++) flags[i] = true;
  let count = 0;
  let i = 2;
  while (i <= n) {
    if (flags[i]) {
      count = count + 1;
      let j = i * i;
      while (j <= n) { flags[j] = false; j = j + i; }
    }
    i = i + 1;
  }
  return count;
}
console.log(sieve(5000000));
