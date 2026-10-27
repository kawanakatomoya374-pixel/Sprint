### 15.14 gui（2.1、2.2〜2.4で拡張。同梱module）

`import gui`。`gfx`の上に書かれたretained-modeのウィジェットtoolkitで、ソースは処理系のバイナリに埋め込まれる（同梱module。`gui`は予約名であり、プロジェクトの`gui.sp`は無視される）。**ネイティブウィンドウは持たない**。プログラムが`App`へイベント列（スクリプト、ホストプログラム、記録したトレース）を与えると、`App`がウィジェットの状態を更新してコールバックを呼び、`draw()`が`gfx` canvasへ描画する。描画は整数演算のみで、同一のイベント列は同一のピクセルを生む（§19.1）。

- イベントは`{type: ...}`のtable。生成関数: `mouse_move(x,y)` `mouse_down(x,y,button=1)` `mouse_up(x,y,button=1)` `wheel(x,y,dy)` `key(name)` `text(s)` `tick(ms)` `quit_event()`。
- ウィジェット: `Widget`（基底）、`Panel` `Label` `Button` `Checkbox` `Slider` `ProgressBar` `TextInput` `ListBox` `Separator` `ImageView` `Tabs`（`tabs(labels, pages)`）`Dropdown`（`dropdown(items, selected)`。リストは他のすべての上に描かれ、外側のクリック・Escapeで閉じる）`TextArea`（`textarea(text, rows)`。複数行、Up/Downは桁を保つ）。`MenuBar`（`menubar([[ラベル, [[項目, action(app)], "-", …]], …])`。見出しのクリックで一覧が他のすべての上に開き、項目の実行・別見出しへの切替・外側クリック/Escapeで閉じる。Left/Right/Up/Down/Enterで操作可）`Tree`（`tree(roots, w, h, on_select)`、節点は`node(label, children)`。矢印クリックまたはRight/Leftで開閉、Up/Down/Home/Endで選択、ホイールでスクロール、`expand_all`/`collapse_all`）。座標を直接指定する従来の構築（`Button("OK", x, y, w, h)`）と、layoutに任せる短い構築関数（下記）の両方を使える。コールバックは`on_click` `on_change`等のプロパティに関数を代入する。クリックで焦点は最も近いfocus可能な祖先に移る。
- **layout engine**: `column(children, gap=6, pad=6)` / `row(...)`（`Box`）と`grid(cols, children, gap=6, pad=6)`（`Grid`）。構築関数: `label(text, scale=1)` `button(text, on_click=nil)` `checkbox(text, checked=false, on_change=nil)` `slider(lo, hi, value, on_change=nil)` `input(text="", placeholder="")` `progress(value=0)` `listbox(items, on_select=nil, rows=4)` `image(canvas, zoom=1)` `separator()` `spacer(flex=1)` `panel(title, child)`。
  - 各ウィジェットは`pref()`（希望の大きさ`[w, h]`）を持つ。`Box`は主軸方向に子を並べ、`flex > 0`の子（`spacer()`や`w.set_flex(n)`）が余白を重みで分け合う（端数は最後のflex子）。`align`（交差軸）は`"stretch"`（既定）`"start"` `"center"` `"end"`、`justify`（主軸、flexがないとき）は`"start"` `"center"` `"end"` `"between"`。
  - `Box`・`Grid`の大きさは、親が`Box`/`Grid`ならその割当、そうでなければ`pref()`（`set_size(w, h)`で固定、`app.fill(box)`で窓全体）。`Grid`は列ごとの最大幅・行ごとの最大高でセルを揃える。
  - `scroll(content, w, h)`（`ScrollView`）は背の高い子を表示窓に収め、ホイール・Up/Down/PageUp/PageDown/Home/Endでスクロールし、はみ出しは`gfx`のclipで切る。
  - layoutは`App`が必要なとき（子の追加・文字列変更の後、最初のイベントまたは`draw()`の前）に1回行う。`app.relayout()`で明示もできる。
- **2.3の追加ウィジェット**（構築関数）:
  - `table(columns, rows=[], w=240, h=120, on_select=nil)`（`Table`）: `columns`は名前または`[名前, 幅]`（幅0は残りを等分）、`rows`は行arrayのarray。見出しのクリックで昇順→降順に安定ソート（`<`の規則。列内の型が比較できないとTypeError）、行のクリック・Up/Down/Home/Endで選択、ホイールでスクロール。`set_rows` `sort_by(col, desc=false)`（`col = -1`で元の順） `selected_row()` `select_pos(i)`。
  - `splitter(a, b, vertical=false, pos=100)`（`Splitter`）: 2つの子をドラッグできる4pxの仕切りで分ける。`pos`は最初の子の大きさで、`min_a`/`min_b`（既定24）で制限される。子が`Box`ならsplitterが与えた大きさになる。`on_change`は離したとき。
  - `spinner(value=0, lo=0, hi=100, step=1, on_change=nil)`（`Spinner`）: 右端の上下半分のクリック、Up/Down/PageUp/PageDown/Home/End、ホバー中のホイール。範囲外は丸める。
  - `radio(items, selected=0, on_change=nil)`（`RadioGroup`）: 項目のクリックまたはUp/Down。`current()`。
  - `PopupMenu`と**コンテキストメニュー**: `app.context_menu(x, y, entries)`は点の位置にメニューを出す（窓の外にはみ出さないよう位置を寄せる）。ウィジェットの`context`に項目の配列（または`function(widget) → 配列`）を入れ、`button == 3`（右ボタン）で`mouse_down`すると祖先を含めて最初の`context`が開く。項目の形は`MenuBar`と同じ（`[ラベル, action(app)]`と区切りの`"-"`）。開いている間はキーがメニューへ届き（Up/Down/Enter/Escape）、外側のクリックで閉じる。テスト用の`app.right_click(x, y)`。
  - **tooltip**: ウィジェットの`tip`（文字列。既定`""`）。ポインタが500仮想ms（`advance`）以上そのウィジェットの上に止まると、ポインタの近くに表示される。マウス操作・移動で消える。`app.hover_at(x, y)`で位置だけを動かせる。
  - **toast**: `app.toast(message, ms=2000)`は右下に積まれる通知を出し、仮想時計で`ms`後に消える（最後の300msはフェードアウト）。
  - 追加イベントはない（右ボタンは`mouse_down(x, y, 3)`）。いずれも時計は`tick`だけで進むので、記録・再生とスナップショット検査はそのまま使える。
- **modal**: `dialog(app, title, message, labels, on_choice)`は画面中央にmessage boxを出し、閉じるまでイベントはそこだけに届く（背景は暗くなる、Escapeは`on_choice(-1)`）。任意のウィジェットは`app.open_modal(widget)` / `app.close_modal()`で同様に出せる。
- **theme**: `set_theme("dark" | "light" | palette)`と`app.set_theme(...)`。配色は`THEME`（実行中のパレット）で、ウィジェットは描画のたびに読む。
- **animation**: `app.animate(from, to, ms, on_update, ease="out", on_done=nil)`は仮想時計上で整数を補間する（`ease`は`"linear"` `"in"` `"out"` `"in_out"`）。時間は`advance(ms)`（または`tick`イベント）でのみ進む。
- **記録と再生**: `app.start_recording()` / `app.stop_recording()`はイベント（`tick`を含む）の列を返し、`app.replay(events)`が再生する。`encode_trace(events)` / `decode_trace(text)`はJSONとの相互変換。
- **スナップショット検査**: `app.snapshot()`（描画結果のhash）、`expect_snapshot(app, hash, label)`（不一致で`AssertionError`）、`pixel_diff(a, b)`、`app.screenshot(path)`。
- `App(width, height, title="")`: `add` `fill(box)` `find(name)` `post(ev)` `dispatch(ev)` `pump()` `run(source, on_frame=nil)` `advance(ms)`（仮想時計。`after`/`every`のタイマ）`set_focus` `focus_next` `quit` `draw()`（canvasを返す）と、テスト用の合成操作`click(x,y)` `drag(x0,y0,x1,y1)` `type_text(s)` `press(key)` `scroll(x,y,dy)`。
- 時計・入力・ファイルには触れない。PNG保存は`canvas.save_png(path)`（`--allow-write`が必要、§15.13）。

```sprint
import gui
let app = gui.App(240, 120, "demo")
let b = gui.Button("Hi", 10, 10, 60, 22)
b.on_click = func(w): print("clicked")
app.add(b)
app.click(20, 20)
app.draw().save_png("demo.png")
```

- **2.4の追加（入力・編集）**:
  - イベント: `mouse_down(x, y, button=1, mods="", clicks=1)`、`mouse_up(x, y, button=1, mods="")`。`mods`は押されている修飾キーの文字列（`"Ctrl"` `"Shift"` `"Alt"`の`+`連結）、`clicks`はホストが数える連続クリック数。キー名は修飾キーを前置する（`"Ctrl+Shift+Z"`）。`parse_key(k)`（export）は`[ctrl, alt, shift, 基本名]`を返す。`app.mods`・`app.clicks`は直近のイベントの値。
  - **`TextInput`・`TextArea`**（共通の`TextBase`）: `cursor`・`anchor`による選択（Shift+矢印/クリック、Ctrl+A）、`app.clipboard`を介したCtrl+C/X/V、Ctrl+Z / Ctrl+Y（Ctrl+Shift+Z）のundo/redo（連続した入力は1つにまとまる）、Ctrl+Left/Right/Backspace/Deleteの単語単位の移動・削除、ダブルクリックで単語・トリプルクリックで行の選択、ドラッグ選択。`on_change` `readonly` `max_len` `placeholder` `password` `on_submit`。入力は印字可能ASCIIと、フォントに字形のある日本語文字に絞られる（字形が無い文字は捨てられる）。`cursor`・`anchor`・`first`・`position()`の列はUTF-8のバイトオフセットで、移動・削除・クリック位置は常に文字境界にそろう。`max_len`は文字数。表示幅は`gfx.text_advance`で計算されるため、Label・Button・Tabs・メニュー・ツールチップ・グラフ凡例なども日本語の幅に合う。`Label.set_wrap`は日本語を任意の文字間で折り返す（行の高さは日本語を含むと12画素）。
  - **`app.bind(combo, fn)` / `app.unbind(combo)`**: キー組合せ（`"Ctrl+S"` `"F5"`）に`fn(app)`を割り当てる。フォーカス中のウィジェットより先に処理される。テスト用に`double_click` `triple_click` `click_with(x, y, mods)`。
- **2.4の追加（表示・layout）**:
  - 長い内容のウィジェット（`ListBox` `Table` `Tree` `TextArea` `ScrollView`）はスクロールバーを持ち、つまみのドラッグ・溝のクリック・ホイールで動く。
  - `label(text, scale=1, wrap=0)`: `wrap > 0`で`wrap`桁に単語単位で折り返す（`wrap_lines(s, cols)`はexport。1語が長いときは桁で切る）。`align`は`"left"` `"center"` `"right"`。
  - `flow(children, hgap=6, vgap=6, pad=6)`（`Flow`）: 幅に収まらなくなったら次の行へ折り返す。`stack(children)`（`Stack`）: 子を同じ領域に重ねる（後の子が手前）。`expander(title, content, is_open=true)`（`Expander`）: 見出しのクリック・Left/Right/Spaceで開閉し、閉じている間は中身が非表示（`on_toggle`）。
  - **ドラッグ＆ドロップ**: ドラッグ元の`drag_data`（値または`function(widget)`）と`drag_label`、ドロップ先の`on_drop(target, data, source)`と`drop_ok(target, data)`。4px以上動いたらドラッグが始まり、ポインタの近くにラベルが描かれる。受け入れ可能な先にだけ`on_drop`が呼ばれる。

layoutを使う例（`examples/gui/gui_layout.sp`）:

```sprint
import gui
let status = gui.label("ready")
let ui = gui.column([
    gui.label("Settings", 2),
    gui.row([gui.checkbox("Notify", true), gui.spacer(), gui.button("Save", w => status.set_text("saved"))]),
    status
])
let app = gui.App(200, 100)
app.fill(ui)
app.screenshot("ui.png")
```

#### 当たり判定の形状とマウスポインタ（2.6）

- `Widget.shape`: 矩形のうち「内側」とみなす画素。`shape_ellipse()` `shape_round(r)` `shape_polygon(pts)`（偶奇規則、座標はウィジェット内の画素）`shape_mask(canvas, key)`（canvasの画素が`key`でない所が内側）`set_shape(s)`。形状は**ポインタの当たり判定（`contains` `pick` `hit_test(x, y)`）だけ**に効き、描画は変えない。`gui.in_polygon(pts, x, y)`。判定は整数演算のみ。
- `set_through(true)`: クリック透過。そのウィジェット自身は選ばれず、子と背面のウィジェットが選ばれる。
- ポインタ形状: `Widget.pointer`（名前）と`cursor_kind()`。`Button` `Checkbox` `Slider`は`"hand"`、`TextInput`・`TextArea`は`"ibeam"`、その他は`"arrow"`。`App.cursor_name()`は`cursor_override`（あれば）→ドラッグ中は`"grab"`→キャプチャ中/ホバー中のウィジェットの`cursor_kind()`。`gui.cursors()`（arrow ibeam hand grab move resize_h resize_v crosshair wait no）。
- `App.show_cursor`を真にすると、`draw()`の最後にソフトウェアのポインタ（`gui.draw_cursor(canvas, name, x, y)`）を描く（既定は偽で、既存のスナップショットは変わらない）。ポインタの移動は再描画を要求する。

## 差分描画（2.8.0）

`App` は変更領域（ダメージ矩形）だけを再描画できます。

- `widget.dirty()` はそのウィジェットの周囲（影・フォーカス枠込みで12px）だけを無効化します。ホバー・フォーカス移動・`Label.set_text`（推奨サイズが変わらないとき）・`Frame` の移動などがこれを使います。
- `app.redraw()` は全面再描画を要求します（レイアウト変更、モーダル、ポップアップ、ドラッグ、トースト、ツールチップ表示中は常に全面）。`app.needs_draw = true` を直接代入した場合も全面扱いです。
- `app.draw()` の後、`app.last_rect` = `[x, y, w, h]` が実際に描いた範囲です。`gdev.present(canvas, 0, 0, x, y, w, h)` などで、その範囲だけを転送できます。
- 部分描画の結果は全面描画とピクセル単位で一致します（`tests/cases/gui/gui_damage.sp`）。

## 描画の高速化（2.8.0）

- 絶対座標は描画中だけ親がキャッシュします（`abs_x()` が親を辿らない）。
- 範囲外のウィジェットは差分描画のクリップ矩形で枝ごと省略されます。
- `Label.set_text` は推奨サイズが変わらなければ再レイアウトせず `dirty()` だけを行います。
- gfx: 水平線・`clear` は64ビット単位で埋め、半透明合成は除算なしの正確な式、クリップ内に収まる5x7文字はピクセル単位の判定なしで描きます。
- VM: テーブル/モジュールのメンバ参照 (`math.sqrt`、`THEME.text` など) は (テーブル, 名前) をキーにした直接写像キャッシュを通ります（GCで破棄）。
