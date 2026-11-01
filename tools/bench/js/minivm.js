function run(code, n) {
  const stack = [0, 0, 0, 0, 0, 0, 0, 0, 0];
  let sp = 0, pc = 0, acc = 0, steps = 0;
  while (steps < n) {
    const op = code[pc];
    if (op === 0) { stack[sp] = code[pc + 1]; sp++; pc += 2; }
    else if (op === 1) { sp--; acc += stack[sp]; pc++; }
    else if (op === 2) { stack[sp - 1] = stack[sp - 1] * 3 + 1; pc++; }
    else if (op === 3) { stack[sp] = stack[sp - 1]; sp++; pc++; }
    else if (op === 4) pc = 0;
    else pc++;
    steps++;
  }
  return acc;
}
console.log(run([0, 7, 3, 2, 1, 1, 0, 5, 2, 1, 4], 6000000));
