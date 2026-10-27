### 15.18 guiplus（2.4、同梱module）

`import guiplus`（`import guiplus as gp`）。`gui`の上に書かれた、描画中心のウィジェット集。`gui`と同じく**整数演算のみ**（正弦は内蔵の整数表。libmを使わない）で、同じイベント列は同じピクセルを生む。`gui.Widget`を別moduleから継承しており（§10.1）、`gui.column([...])`などにそのまま入れられ、`app.snapshot()`に含まれる。

| 項目 | 仕様 |
|---|---|
| `chart(kind, series, labels=[], w=260, h=160)`（`Chart`） | `kind`は`"line"` `"area"` `"bar"` `"scatter"` `"pie"` `"donut"`。`series`は`[{name, values, color}]`（数のarrayだけでも可。`scatter`の`values`は`[x, y]`の組。`pie`/`donut`は先頭のseriesの値がスライスで`labels`が名前）。`title` `legend` `grid` `show_values` `y_min` `y_max`、`set_series`、`selected`と`on_pick`（クリックした点・棒・スライス）、`hit_at(x, y)` `describe(hit)` `y_range()` `ticks()` `slice_degrees()`。y軸は1・2・5×10^nの刻みに丸める。ポインタが乗ると値のreadoutを描く。 |
| `canvas_view(w, h, on_draw=nil, bg=0xffffff)`（`CanvasView`） | 固定大きさの自前の`gfx` canvas（`canvas`）。`on_draw(view, canvas)`と`redraw()` `clear()` `resize(w, h)`。`on_pointer(view, kind, x, y, button)`は`"down"`、押している間の`"move"`、`"up"`を表面の座標で受ける。 |
| `color_picker(rgb=0x4c8dff, on_change=nil)`（`ColorPicker`） | 彩度/明度の正方形と色相バー。`color()`（`0xRRGGBB`）、`set_color(rgb)`、`set_hsv(h, s, v)`、`hue` `sat` `val`（0..359 / 0..100 / 0..100）。Left/Right=彩度、Up/Down=明度、PageUp/PageDown=色相（Shiftで10倍）。 |
| `calendar(year, month, day, on_change=nil)`（`Calendar`） | 月表示。月送りの矢印、日のクリック、矢印キー（日・週）、PageUp/PageDown（月）。`date()` `set_date(y, m, d)`、`week_start`（0=日曜、1=月曜）、`today = [y, m, d]`（窓は時計を持たないので利用側が与える）。日付計算の関数: `is_leap(y)` `days_in_month(y, m)` `weekday(y, m, d)`（0=日曜）`days_from_civil(y, m, d)` / `civil_from_days(n)`（1970-01-01基準）。 |
| `icon(canvas, name, x, y, size, color)` / `ICONS` | `ICONS`の名前: close check plus minus left right up down menu search folder file gear play pause stop trash star home。12単位の格子を`size`ピクセルに拡大して描く。未知の名前はValueError。 |
| `IconButton(name, on_click=nil, tip="")` / `toolbar(items)` / `StatusBar(parts)` | `toolbar`の項目は`[icon, on_click, tip]`または区切りの`"-"`。`StatusBar`は区切り線つきの文字列片の帯で、最後の片は右寄せ、`set_text(i, s)`。 |
| `isin(deg)` / `icos(deg)` / `hex_color(rgb)` / `PALETTE` | 整数度の正弦・余弦（×1000）、`"#rrggbb"`、既定の系列色。 |
