function run(steps) {
  let x = 0.0, y = 1.0, vx = 0.5, vy = 0.0; const dt = 0.001;
  for (let i = 1; i <= steps; i++) {
    const r2 = x * x + y * y;
    const r3 = r2 * Math.sqrt(r2);
    vx = vx - x / r3 * dt;
    vy = vy - y / r3 * dt;
    x = x + vx * dt;
    y = y + vy * dt;
  }
  return x + y;
}
console.log(run(10000000));
