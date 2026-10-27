## 4. 構文

### 4.1 完全文法（EBNF）

本節のEBNFが受理する構文のすべてである。

```ebnf
file            = { NEWLINE | statement } , EOF ;
statement       = simple_stmt , NEWLINE | compound_stmt ;
block           = ":" , NEWLINE , INDENT , statement , { statement } , DEDENT ;

(* ---- 単純文 ---- *)
simple_stmt     = "pass" | let_decl | const_decl | import_stmt | from_import
                | "export" , ( let_decl | const_decl )
                | assign_stmt | multi_assign | coalesce_assign | expr_stmt | return_stmt | break_stmt
                | continue_stmt | throw_stmt | defer_stmt | assert_stmt
                | panic_stmt ;
let_decl        = "let" , IDENT , [ "=" , rhs ] | destructure ;
const_decl      = "const" , IDENT , "=" , rhs | destructure ;
destructure     = ( "let" | "const" ) , ( "[" , dname , { "," , dname } , [ "," , "..." , IDENT ] , [ "," ] , "]"
                                        | "{" , dentry , { "," , dentry } , [ "," ] , "}" ) , "=" , expression ;
dpattern        = "[" , dname , { "," , dname } , [ "," , "..." , IDENT ] , [ "," ] , "]"
                | "{" , dentry , { "," , dentry } , [ "," ] , "}" ;               (* 2.3: for・内包表記のループ変数 *)
dname           = IDENT ;
dentry          = IDENT | NAME , ":" , IDENT ;
rhs             = expression | yield_expr ;
import_stmt     = "import" , module_path , [ "as" , IDENT ] ;
from_import     = "from" , module_path , "import" , import_item , { "," , import_item } ;
import_item     = IDENT , [ "as" , IDENT ] ;
module_path     = IDENT , { "." , IDENT } ;
assign_stmt     = target , assign_op , rhs ;
assign_op       = "=" | "+=" | "-=" | "*=" | "/=" | "//=" | "%=" | "..="
                | "**=" | "&=" | "|=" | "^=" | "<<=" | ">>=" ;
target          = IDENT
                | postfix , "." , NAME
                | postfix , "[" , expression , "]" ;
multi_assign    = target , "," , target , { "," , target } , "=" , expression , { "," , expression } ;   (* 2.3 *)
coalesce_assign = target , "??=" , expression ;                                  (* 2.3: 純粋なtargetのみ *)
expr_stmt       = expression | yield_expr ;
yield_expr      = "yield" , [ expression ] ;
return_stmt     = "return" , [ expression ] ;
break_stmt      = "break" , [ IDENT ] ;
continue_stmt   = "continue" , [ IDENT ] ;
throw_stmt      = "throw" , expression ;
defer_stmt      = "defer" , postfix ;            (* 最後のpostfix操作が呼出しであること *)
assert_stmt     = "assert" , expression , [ "," , expression ] ;
panic_stmt      = "panic" , expression ;

(* ---- 複合文 ---- *)
compound_stmt   = if_stmt | while_stmt | for_stmt | try_stmt | match_stmt
                | func_decl | class_decl
                | "export" , ( func_decl | class_decl ) ;
if_stmt         = "if" , ( expression | "let" , IDENT , "=" , expression ) , block ,
                  { "elif" , expression , block } , [ "else" , block ] ;
while_stmt      = [ IDENT , ":" ] , "while" , ( expression | "let" , IDENT , "=" , expression ) , block ;
for_stmt        = [ IDENT , ":" ] , "for" , ( IDENT , [ "," , IDENT ] | dpattern ) ,
                  "in" , ( expression | pipe , "if" , or_expr ) , block ;
try_stmt        = "try" , block , "catch" , [ IDENT ] , block ;
match_stmt      = "match" , expression , ":" , NEWLINE , INDENT ,
                  case_clause , { case_clause } , DEDENT ;
case_clause     = "case" , pattern , [ "if" , expression ] , block ;
func_decl       = "func" , IDENT , "(" , [ params ] , ")" , block ;
params          = param , { "," , param } , [ "," , "..." , IDENT ]
                | "..." , IDENT ;
param           = IDENT , [ "=" , expression ] ;
class_decl      = "class" , IDENT , [ "extends" , IDENT , [ "." , IDENT ] ] ,
                  ":" , NEWLINE , INDENT , class_member , { class_member } , DEDENT ;
class_member    = "pass" , NEWLINE
                | "let" , IDENT , [ "=" , expression ] , NEWLINE
                | [ "override" ] , func_decl ;

(* ---- パターン ---- *)
pattern         = literal_pattern | "_" | IDENT | array_pattern | table_pattern ;
literal_pattern = [ "-" ] , ( INT | FLOAT ) | STRING | "true" | "false" | "nil" ;
array_pattern   = "[" , [ pattern , { "," , pattern } , [ "," ] ] , "]" ;
table_pattern   = "{" , [ tpat_entry , { "," , tpat_entry } , [ "," ] ] , "}" ;
tpat_entry      = ( NAME | STRING ) , ":" , pattern ;

(* ---- 式（下に行くほど強く結合） ---- *)
expression      = lambda | arrow | conditional ;
lambda          = "func" , "(" , [ params ] , ")" , ":" , expression ;
arrow           = ( IDENT | "(" , [ params ] , ")" ) , "=>" , expression ;      (* 2.2 *)
conditional     = pipe , [ "if" , or_expr , "else" , expression ] ;
pipe            = coalesce , { "|>" , postfix } ;                                (* 2.2 *)
coalesce        = or_expr , { "??" , or_expr } ;
or_expr         = and_expr , { "or" , and_expr } ;
and_expr        = not_expr , { "and" , not_expr } ;
not_expr        = "not" , not_expr | comparison ;
comparison      = bit_or , { comp_op , bit_or } ;                                (* 2.3: 連鎖可（最大8個） *)
comp_op         = "==" | "!=" | "<" | "<=" | ">" | ">=" | "in" | "not" , "in" ;
bit_or          = bit_xor , { "|" , bit_xor } ;
bit_xor         = bit_and , { "^" , bit_and } ;
bit_and         = shift , { "&" , shift } ;
shift           = concat , { ( "<<" | ">>" ) , concat } ;
concat          = additive , { ".." , additive } ;
additive        = term , { ( "+" | "-" ) , term } ;
term            = unary , { ( "*" | "/" | "//" | "%" ) , unary } ;
unary           = ( "-" | "~" ) , unary | power ;
power           = postfix , [ "**" , unary ] ;
postfix         = primary , { call | index | member | opt_member | opt_index } ;
call            = "(" , [ arguments ] , ")" ;
arguments       = expression , { "," , expression } , [ "," , "..." , expression ] , [ "," ]
                | "..." , expression , [ "," ] ;
index           = "[" , expression , "]"
                | "[" , [ expression ] , ":" , [ expression ] , "]" ;   (* スライス糖衣 *)
member          = "." , NAME ;
opt_member      = "?." , NAME ;                                                  (* 2.3 *)
opt_index       = "?[" , expression , "]" ;                                      (* 2.3 *)
primary         = literal | IDENT | "(" , expression , ")"
                | array_lit | table_lit | super_ref | fstring ;
fstring         = "f" , STRING_BODY ;          (* §3.6.1。字句として1トークン *)
super_ref       = "super" , ( call | "." , NAME , call ) ;
array_lit       = "[" , [ expression , { "," , expression } , [ "," ] ] , "]"
                | "[" , expression , comp_clauses , "]" ;                         (* 2.2 *)
table_lit       = "{" , [ table_entry , { "," , table_entry } , [ "," ] ] , "}"
                | "{" , expression , ":" , expression , comp_clauses , "}" ;       (* 2.2 *)
comp_clauses    = "for" , ( IDENT , [ "," , IDENT ] | dpattern ) , "in" , pipe ,
                  { "for" , ( IDENT , [ "," , IDENT ] | dpattern ) , "in" , pipe | "if" , or_expr } ;
table_entry     = ( NAME | STRING | INT | "(" , expression , ")" ) , ":" , expression
                | IDENT ;                                                        (* 2.3: {x} は {x: x} *)
literal         = "nil" | "true" | "false" | INT | FLOAT | STRING ;
```

### 4.2 優先順位と結合性（正本）

| 優先（強→弱） | 演算子 | 結合性 |
|---:|---|---|
| 1 | `()` `[]` `.` `?.` `?[]` 呼出し・添字・メンバ | 左 |
| 2 | `**` | 右（`2**3**2 == 512`、`-2**2 == -4`、`2**-1 == 0.5`） |
| 3 | 単項`-` `~` | 右 |
| 4 | `*` `/` `//` `%` | 左 |
| 5 | `+` `-` | 左 |
| 6 | `..` | 左（連鎖は1回の割り当てに最適化、§7.4） |
| 7 | `<<` `>>` | 左 |
| 8 | `&` | 左 |
| 9 | `^` | 左 |
| 10 | `\|` | 左 |
| 11 | `==` `!=` `<` `<=` `>` `>=` `in` `not in` | 連鎖（2.3）。`a < b < c`は`a < b and b < c`（`b`は1回だけ評価、§7.6）。2.2では`ParseError`だった |
| 12 | `not` | 右（`not a == b`は`not (a == b)`） |
| 13 | `and` | 左・短絡 |
| 14 | `or` | 左・短絡 |
| 15 | `??` | 左・短絡（§7.9）。`or`より弱く、`\|>`より強い |
| 16 | `\|>` | 左（§7.10）。右辺は後置式（呼出し・メンバ・括弧式） |
| 17 | `x if c else y` | 右 |
| 18 | `func(...): expr`、`x => expr`、`(a, b) => expr` | —（本体は式全体を取る） |

代入は式ではなく文である。`a = b = c`、`f(x = 1)`、`if x = 1:`は`ParseError`。

複合代入`x op= e`は`x = x op e`と等価で、`x`が`a[i]`や`a.b`のとき部分式`a`・`i`は**1回だけ**評価される。`**=` `&=` `|=` `^=` `<<=` `>>=`は2.1で追加された。`??=`は2.3で追加された（§7.9。複合代入の一種ではなく`if a == nil: a = v`の糖衣）。

### 4.3 構文上の追加規則（静的検査）

次はすべてコンパイルエラーである（終了コード12）。

1. 空ブロック（`pass`を使う）。
2. `defer`の式の最後の操作が呼出しでない。`defer`の呼出しがspread（`...`）を含む、または`super`呼出しである。
3. `super`が`super(...)`または`super.name(...)`以外の形で使われた。メソッド外の`super`。
4. `yield`が`expr_stmt`・`let`/`const`の初期化子・代入右辺以外に現れた。
5. `break`/`continue`がloop外、または関数境界を越える。ラベルが存在しない、または同一関数内で重複。
6. `return`が関数外（module top-level）に現れた。
7. 同じパターン内で同じ束縛名が2回現れた。パターンの入れ子が16段を超えた。
8. `import`/`from`がファイル先頭の連続したimport群以外に現れた（コメント・空行は可）。関数・ブロック内のimport。
9. `class`宣言、`export`がmodule top-level以外に現れた。
10. lambdaの本体は単一の式であり、文は書けない（文法上不可能）。複数文が必要なら`func`宣言を使う。lambda本体の`yield`は不可（`yield`は式ではないため文法上不可能）。
11. 1つの`match`で`case _`または無条件の束縛パターンより後に別の`case`がある（到達不能）。
