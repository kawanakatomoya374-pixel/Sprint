## 21. C実装要件

### 21.1 言語と依存

- 処理系はISO C11（hosted）で実装する。VLA、コンパイラ拡張を必須にしてはならない。
- 計算型goto、`__builtin_*_overflow`等の拡張は`#if`で囲んだ最適化としてのみ使ってよく、拡張なしのビルドと結果が一致しなければならない。
- 外部依存はCの標準ライブラリとOS API（POSIXまたはWin32）だけ。SHA-256、UTF-8検証、JSON、TOML（limits・manifestに必要な部分集合）は処理系内に実装する。
- `strtod`は正しく丸める実装を前提とする（glibc、musl、macOS libc、MSVC UCRTは満たす）。満たさないプラットフォームでは処理系同梱の変換を使う。
- OS依存部（ファイル、時計、エントロピー、シグナル）は`sp_platform_*.c`に隔離する。

### 21.2 品質要件（MUST）

- `-std=c11 -Wall -Wextra -Wpedantic`（または同等）で警告なくビルドできる。
- コンフォーマンステストがAddressSanitizer・UndefinedBehaviorSanitizer有効で全件合格する。
- 符号付き整数overflow、未初期化読み出し、範囲外アクセスなどCの未定義動作を起こさない。
- Lexer・Parser・image loaderは、任意の入力に対してクラッシュ・無限ループ・上限を超える割り当てを起こさない（SHOULD: fuzzingで検証する）。
- Parserの再帰深さは§18.4の入れ子上限で制限する。VM実行・GCはC再帰を使わない（§17.7、§18.1）。

### 21.3 ソース構成（推奨・層との対応）

```text
include/sprint.h            公開API（§20）
src/sp_source.c             層1: UTF-8検証、改行正規化
src/sp_lexer.c              層2: token、INDENT/DEDENT
src/sp_parser.c sp_ast.c    層3: AST
src/sp_resolver.c           層4: scope、module graph、静的診断
src/sp_compiler.c           層5: bytecode生成
src/sp_verify.c sp_image.c  層5: verifier、serializer/loader
src/sp_vm.c                 層6: 実行ループ、呼出し、例外、defer
src/sp_value.c sp_string.c sp_array.c sp_table.c sp_class.c
src/sp_coroutine.c sp_gc.c sp_error.c sp_api.c
src/sp_lib_*.c              stdlib（prelude, math, str, table, io, fs, time, sys, json, random, gc, coroutine）
src/sp_platform_posix.c sp_platform_win32.c
src/sp_sha256.c sp_fmt.c    SHA-256、数値の文字列化
cli/main.c                  sprint CLI（APIだけを使う）
tests/conformance/          §22.3形式のテスト
```

- CLIは公開API（§20）だけを使って実装する（APIの完全性の検証を兼ねる）。
- Compiler・Resolverの作業領域はarena（bump allocator）を使い、コンパイル完了時に一括解放してよい。コンパイル時の割り当ては§1.3の対象外である。

### 21.4 性能目標（SHOULD）

- 起動（`sprint run`で空のプログラム）5ms以内。`libsprint`のコードサイズ500KB以内（-Os、x86-64）。
- 実装技法の推奨: dispatchにcomputed goto（利用可能な場合）、GET_MEMBER/INVOKE/LOAD_LINKにロード時に確保するinline cache、メンバ名はロード時にinternして比較をpointer比較にする、instanceのフィールドは固定スロット。
- これらの最適化は観測可能な挙動を変えてはならない。

### 21.5 実装順序（推奨）

1. Source・Lexer・INDENT/DEDENT（テスト: 字句）
2. Parser・AST・診断（テスト: 構文・位置）
3. Value、string、array、table、GC（最初からGCを入れる）
4. Resolver・Compiler・最小VM（定数、local、算術、call/return）
5. 制御フロー、closure/cell、for/range
6. error、try、defer、panic、assert、match
7. class、module/import、program image、verifier
8. coroutine
9. stdlib、capability、limits、決定性モード
10. REPL、fmt、lint、disasm/inspect

各段階で、AST直接評価ではなく必ずbytecode経路でテストを通す。
