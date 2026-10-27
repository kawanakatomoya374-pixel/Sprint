## 20. C埋め込みAPI

### 20.1 原則

- 公開ヘッダは`sprint.h`の1つだけ。以下の名前・型・意味は規範である（C API major 2）。
- すべての関数は`SpVM`を1つのスレッドからだけ呼ぶ（`sp_interrupt`を除く）。異なる`SpVM`は異なるスレッドで同時に使ってよい。
- 処理系はグローバルな可変状態を持たない。
- APIはC++例外・`longjmp`をhostへ漏らさない。

### 20.2 型・設定・VM

```c
#include <stddef.h>
#include <stdint.h>

#define SP_API_MAJOR 2
#define SP_API_MINOR 0

typedef struct SpVM      SpVM;
typedef struct SpObj     SpObj;
typedef struct SpProgram SpProgram;
typedef struct SpRef     SpRef;

typedef enum SpType {
    SP_T_NIL = 0, SP_T_BOOL = 1, SP_T_INT = 2, SP_T_FLOAT = 3,
    SP_T_STRING = 4, SP_T_ARRAY = 5, SP_T_TABLE = 6, SP_T_FUNCTION = 7,
    SP_T_CLASS = 8, SP_T_INSTANCE = 9, SP_T_MODULE = 10, SP_T_ITERATOR = 11,
    SP_T_COROUTINE = 12, SP_T_ERROR = 13, SP_T_NATIVE = 14
} SpType;

typedef struct SpValue {
    uint8_t type;
    uint8_t _pad[7];
    union { int64_t i; double f; int b; SpObj *o; } as;
} SpValue;   /* sizeof == 16 */

typedef enum SpStatus {
    SP_OK = 0,
    SP_E_RUNTIME = 1,        /* 未処理のcatch可能error。sp_last_error()で取得 */
    SP_E_CONFIG = 2,
    SP_E_PERMISSION = 3,     /* 未処理のPermissionError */
    SP_E_IMPORT = 4,
    SP_E_COMPILE = 12,       /* sp_diagnostic*()で取得 */
    SP_E_LOAD = 13,
    SP_E_MEMORY = 14,
    SP_E_PANIC = 101,
    SP_E_TIMEOUT = 124,
    SP_E_INTERRUPT = 130,
    SP_EXIT = 256            /* sys.exit。sp_exit_code()で取得 */
} SpStatus;

enum {
    SP_CAP_STDIO_READ  = 1u << 0, SP_CAP_STDIO_WRITE = 1u << 1,
    SP_CAP_FS_READ     = 1u << 2, SP_CAP_FS_WRITE    = 1u << 3,
    SP_CAP_CLOCK       = 1u << 4, SP_CAP_RANDOM      = 1u << 5
};

/* 割り当て関数: new_size == 0 なら解放してNULLを返す。
   ptr == NULL なら新規確保。失敗時はNULL（ptrはそのまま有効）。 */
typedef void *(*SpAllocFn)(void *ud, void *ptr, size_t old_size, size_t new_size);

/* stream: 1 = stdout, 2 = stderr。書けたバイト数を返す（len未満は IOError）。 */
typedef size_t    (*SpWriteFn)(void *ud, int stream, const char *data, size_t len);
/* 最大capバイトを読む。0 = EOF、負 = エラー（IOError）。 */
typedef ptrdiff_t (*SpReadFn)(void *ud, char *buf, size_t cap);
/* module名（"net.http"）からsourceを返す。見つからなければ SP_E_IMPORT。
   *src は sp_compile が戻るまで有効でなければならない。 */
typedef SpStatus  (*SpLoaderFn)(void *ud, const char *dotted_name,
                                const char **src, size_t *len,
                                const char **display_path);

typedef struct SpLimits {
    uint64_t max_source_bytes, max_heap_bytes, max_string_bytes;
    uint32_t max_module_count, max_call_depth, max_operand_stack, max_handlers;
    uint32_t max_defer_records, max_defer_values;
    uint32_t max_array_length, max_table_entries, max_trace_frames;
    uint32_t max_native_reentry, max_native_roots, stdout_buffer_bytes;
    uint64_t max_runtime_ms, max_instructions;
} SpLimits;

typedef struct SpConfig {
    uint16_t api_major, api_minor;           /* sp_config_initが設定 */
    SpAllocFn alloc; void *alloc_ud;         /* NULLならmalloc/realloc/free */
    SpLimits limits;
    uint32_t capabilities;
    const char *const *read_roots;  size_t read_root_count;
    const char *const *write_roots; size_t write_root_count;
    SpWriteFn write; SpReadFn read; void *io_ud;
    SpLoaderFn loader; void *loader_ud;
    int deterministic;
    int no_stdlib;
} SpConfig;

void     sp_config_init(SpConfig *cfg);          /* 既定値（§18.4、capabilityなし） */
SpStatus sp_vm_new(const SpConfig *cfg, SpVM **out);
void     sp_vm_free(SpVM *vm);                   /* 全オブジェクト・SpRef・programを解放 */
void     sp_interrupt(SpVM *vm);                 /* スレッド安全・シグナル安全 */
```

- `sp_vm_new`は`cfg->api_major != SP_API_MAJOR`なら`SP_E_CONFIG`。
- VMの全メモリは`alloc`経由で確保する（A7）。

### 20.3 programの実行

```c
SpStatus sp_compile(SpVM *vm, const char *entry_module, SpProgram **out);
SpStatus sp_load_image(SpVM *vm, const uint8_t *data, size_t len, SpProgram **out);
SpStatus sp_save_image(SpVM *vm, const SpProgram *p, int debug_info,
                       uint8_t **data, size_t *len);   /* sp_free_bufferで解放 */
void     sp_free_buffer(SpVM *vm, void *buf);
SpStatus sp_run(SpVM *vm, SpProgram *p, int argc, const char *const *argv);
void     sp_program_free(SpVM *vm, SpProgram *p);

typedef struct SpDiagnostic {
    const char *kind; int code; const char *message; const char *file;
    uint32_t line, column, end_line, end_column;
    uint64_t offset, end_offset;
} SpDiagnostic;
size_t              sp_diagnostic_count(const SpVM *vm);
const SpDiagnostic *sp_diagnostic(const SpVM *vm, size_t i);
SpValue             sp_last_error(SpVM *vm);   /* SP_E_RUNTIME / SP_E_PERMISSION の後 */
int                 sp_exit_code(SpVM *vm);    /* SP_EXIT の後 */
```

- 1つのVMで`sp_run`できるprogramは1つだけ（2回目は`SP_E_CONFIG`）。別のprogramを実行するには新しいVMを作る。

### 20.4 値API

```c
static inline SpValue sp_nil(void);
static inline SpValue sp_bool(int b);
static inline SpValue sp_int(int64_t i);
static inline SpValue sp_float(double f);

SpStatus    sp_new_string(SpVM *vm, const char *utf8, size_t len, SpValue *out);
const char *sp_string_data(SpValue s, size_t *len);     /* NUL終端あり */
SpStatus    sp_new_array(SpVM *vm, size_t capacity, SpValue *out);
size_t      sp_array_len(SpValue a);
SpStatus    sp_array_get(SpVM *vm, SpValue a, int64_t i, SpValue *out);
SpStatus    sp_array_set(SpVM *vm, SpValue a, int64_t i, SpValue v);
SpStatus    sp_array_push(SpVM *vm, SpValue a, SpValue v);
SpStatus    sp_new_table(SpVM *vm, size_t capacity, SpValue *out);
SpStatus    sp_table_get(SpVM *vm, SpValue t, SpValue key, SpValue *out, int *found);
SpStatus    sp_table_set(SpVM *vm, SpValue t, SpValue key, SpValue v);
int         sp_table_next(SpValue t, size_t *cursor, SpValue *key, SpValue *val);
SpStatus    sp_get_member(SpVM *vm, SpValue obj, const char *name, SpValue *out);
SpStatus    sp_call(SpVM *vm, SpValue callee, int argc, const SpValue *argv, SpValue *ret);
SpStatus    sp_throw(SpVM *vm, const char *kind, const char *fmt, ...);
SpStatus    sp_panic(SpVM *vm, const char *message);
const char *sp_type_name(SpValue v);

SpStatus    sp_ref(SpVM *vm, SpValue v, SpRef **out);   /* hostが保持するroot */
SpValue     sp_ref_get(const SpRef *r);
void        sp_unref(SpVM *vm, SpRef *r);
```

- 失敗する可能性のあるAPIは`SpStatus`を返す。Sprint側の規則で失敗した場合（型違い、範囲外、上限）は対応するerrorを保留状態にして`SP_E_RUNTIME`（MemoryErrorなら`SP_E_MEMORY`）を返す。native関数はその値をそのままreturnすればよい。
- `sp_table_next`: `*cursor = 0`から始め、挿入順に次のentryを返して1、終わりなら0。反復中にtableの構造を変更した場合の結果は「残りのentryを返さず0を返す」。
- **root規則**: native関数の実行中に生成した値は、そのnative呼出しのroot stackに自動登録され、native関数がreturnするまで回収されない（上限`max_native_roots`）。native呼出しをまたいで値を保持するには`sp_ref`を使う。`SpValue`をhost側のグローバル変数などに`sp_ref`なしで保存してはならない。

### 20.5 native関数とnative module

```c
typedef SpStatus (*SpNativeFn)(SpVM *vm, int argc, const SpValue *argv, SpValue *ret);

#define SP_VARIADIC 0xFFFFu
enum {
    SP_NATIVE_ALLOCATES  = 1u << 0,   /* 割り当てを行い得る */
    SP_NATIVE_CALLS_BACK = 1u << 1    /* sp_callでSprintの関数を呼び得る */
};

typedef struct SpNativeDesc {
    const char *name;
    uint16_t    min_arity, max_arity;  /* max_arity == SP_VARIADIC で可変 */
    uint32_t    capability;            /* 必要なSP_CAP_*（0なら不要） */
    uint32_t    flags;
    SpNativeFn  fn;
} SpNativeDesc;

SpStatus sp_register_module(SpVM *vm, const char *dotted_name,
                            const SpNativeDesc *fns, size_t count);
```

- `sp_register_module`は`sp_compile`/`sp_load_image`より前に呼ぶ。登録したmoduleはbuiltin module（§14.3の1）として扱う。
- VMはnative関数を呼ぶ前にarityとcapabilityを検査する（違反はTypeError / PermissionError）。`*ret`は`nil`で初期化されている。
- native関数は`SP_OK`を返すか、`sp_throw`/`sp_panic`の戻り値、または失敗したAPIの戻り値をそのまま返す。それ以外の値を返した場合、VMはRuntimeErrorとして扱う。
- `SP_NATIVE_ALLOCATES`がないnative関数の中で割り当てを伴うAPIを呼ぶと、そのAPIは割り当てずにRuntimeErrorを保留して`SP_E_RUNTIME`を返す（「隠れた割り当てなし」をnative境界でも保証する）。
- `SP_NATIVE_CALLS_BACK`がないnative関数の中で`sp_call`を呼ぶと、同様にRuntimeError。`sp_call`の入れ子は`max_native_reentry`まで。`sp_call`で呼んだSprintコード内で`yield`するとRuntimeError。
- native関数は`argv`の値を変更しない。
- `sp_call`が`SP_E_PANIC` / `SP_E_MEMORY` / `SP_E_TIMEOUT` / `SP_E_INTERRUPT` / `SP_EXIT`を返した場合、native関数はほかのAPIを呼ばずに、その値を直ちにreturnしなければならない。`SP_E_RUNTIME`の場合はerrorが保留されており、そのままreturnすればerrorが呼出し元へ伝播する（catchして続行するC APIはない。Sprint側で`try`を使う）。

### 20.6 native iterator ABI（正本）

`for`（`FOR_NEXT`、§17.6）とhostの間のiterator契約。stdlibの`range`（for外）・`s.codepoints()`もこのABIで実装する。

```c
typedef enum SpIterResult {
    SP_ITER_ITEM = 0,   /* out[0..arity-1] に値を書いた */
    SP_ITER_END  = 1,   /* 終了。out は使われない */
    SP_ITER_FAIL = 2    /* sp_throw 等でerrorを保留した */
} SpIterResult;

typedef struct SpTracer SpTracer;
void sp_trace_value(SpTracer *t, SpValue v);

typedef struct SpIterClass {
    uint32_t     abi;          /* SP_ITER_ABI (= 2) */
    const char  *kind;         /* to_string 用の名前（例: "range"） */
    uint8_t      arity;        /* 1ステップの値の数: 1 または 2 */
    uint8_t      allocates;    /* next が割り当てを行い得るなら 1 */
    size_t       state_size;   /* 状態のバイト数（VMがiterator内に確保） */
    SpIterResult (*next)(SpVM *vm, void *state, SpValue out[2]);
    void         (*trace)(void *state, SpTracer *t);  /* SpValueを持たなければNULL */
} SpIterClass;

#define SP_ITER_ABI 2u

SpStatus     sp_new_iterator(SpVM *vm, const SpIterClass *cls,
                             const void *init_state, SpValue *out);  /* A */
SpIterResult sp_iter_next(SpVM *vm, SpValue it, SpValue out[2]);
```

契約:

1. `sp_new_iterator`は`state_size`バイトの状態をiteratorオブジェクト内に確保し、`init_state`をコピーする（`init_state`がNULLなら0埋め）。状態は以後移動しない。
2. `next`はFOR_NEXTまたは`sp_iter_next`からだけ呼ばれる。一度`SP_ITER_END`または`SP_ITER_FAIL`を返したiteratorに対して、VMは`next`を二度と呼ばない（以後は常にEND扱い）。
3. `next`は`sp_call`を呼んではならない（iteratorはSprintコードを実行しない、H1）。呼んだ場合はRuntimeError。
4. `allocates == 0`のiteratorの`next`内で割り当てを伴うAPIを呼ぶと、§20.5と同じくRuntimeError。
5. `next`が`out`に書いた値と、生成した値はroot規則（§20.4）に従う。
6. 状態内に`SpValue`を保持するなら`trace`で全部を`sp_trace_value`に渡す。`trace`はGC中に呼ばれ、VM APIを呼んではならない。
7. iteratorにfree関数はない。状態にOSリソースやmallocしたpointerを保持してはならない（必要ならnative object、§20.7を使う）。
8. `cls`はiteratorが存在する間有効でなければならない（通常は`static const`）。

### 20.7 native object

```c
typedef struct SpNativeClass {
    uint32_t    abi;            /* SP_NATIVE_ABI (= 2) */
    const char *name;
    size_t      size;
    void (*trace)(void *self, SpTracer *t);   /* NULL可 */
    void (*release)(void *self);              /* NULL可。GC回収時・VM破棄時に1回呼ばれる */
} SpNativeClass;
#define SP_NATIVE_ABI 2u

SpStatus sp_new_native(SpVM *vm, const SpNativeClass *cls, SpValue *out, void **self); /* A */
void    *sp_native_data(SpValue v, const SpNativeClass *cls);  /* 型違いはNULL */
```

`release`はhost資源を解放するためのC関数であり、VM APIを呼んではならない（Sprintコードを呼ぶ手段はない）。`release`の呼ばれる時点は観測可能な挙動に影響してはならない（Sprintレベルのファイナライザではない）。

### 20.8 参照実装の既知の逸脱

- `SpConfig.alloc`（カスタムアロケータ）は`NULL`のみ受け付ける。`NULL`以外を渡した`sp_vm_new`は`SP_E_CONFIG`で失敗する。
- 1つの`SpVM`を複数スレッドから同時に使ってはならない。`sp_interrupt`だけは任意のスレッド（シグナルハンドラを含む）から呼べる。複数の`SpVM`を別スレッドで同時に使うのは自由である。
- 実行時間制限（`max_runtime_ms`）と`sp_interrupt`はstep budgetの分割境界（既定`2^20` step）で検査されるため、停止は最大でその分だけ遅れる。停止時の終了コードはそれぞれ124・130。
