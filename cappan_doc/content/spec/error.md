# error

cappan の各モジュールが詳細なエラー情報を報告するときの共通構造を定める。
`severity` / `location` / `message` の3要素を基本とする。

---

## 設計方針

- **制御フロー**には Zig の error union（`!T`）を使う。エラーの種別は Zig error set（`error.TableNotFound` 等）が担う
- **詳細情報の伝達**には `Diagnostics` を使う。関数がオプショナルな `diag: ?*Diagnostics` 引数を受け取り、error return 前に詳細を積む
- Zig error set が機械可読な原因識別子の役割を果たすため、独自の Reason enum は持たない

---

## DiagnosticEntry

診断メッセージ1件の構造。

```zig
pub const DiagnosticEntry = struct {
    severity: Severity,
    location: Location,
    message: []const u8,
};
```

| フィールド | 型 | 必須 | 内容 |
|---|---|---|---|
| `severity` | `Severity` | ✔ | 深刻度 |
| `location` | `Location` | ✔ | 発生箇所（テーブル・グリフ・バイトオフセット） |
| `message` | `[]const u8` | ✔ | 人間向けエラーメッセージ |

---

## severity

```zig
pub const Severity = enum { info, warning, @"error" };
```

| 値 | 意味 |
|---|---|
| `info` | 参考情報（正常動作に影響なし） |
| `warning` | 推奨範囲外だが処理続行可能 |
| `@"error"` | 整合性不一致やデータ破損（処理に影響あり） |

`Diagnostics.hasErrors()` は `severity == .@"error"` のエントリが1つでもあれば `true` を返す。

---

## location

フォント処理の発生箇所を表現する構造体。フォント固有の文脈（テーブル・グリフ・バイトオフセット）を持つ。

```zig
pub const Location = struct {
    table_tag: ?[4]u8 = null,
    glyph_id: ?u16 = null,
    offset: ?usize = null,
};
```

| フィールド | 型 | 内容 |
|---|---|---|
| `table_tag` | `?[4]u8` | エラーが発生した OpenType テーブルの 4 文字タグ（例: `"glyf"`, `"cmap"`） |
| `glyph_id` | `?u16` | エラー発生時に処理中だったグリフ ID |
| `offset` | `?usize` | フォントデータ内のバイトオフセット |

すべてオプショナルであり、特定できない箇所には `null` を設定する。

### 使用例

```zig
// glyf テーブルのグリフ 42 でエラー
.location = .{ .table_tag = "glyf".*, .glyph_id = 42 },

// cmap テーブルの先頭付近でパースエラー
.location = .{ .table_tag = "cmap".*, .offset = 12 },

// テーブルに帰属しないエラー（SFNT ヘッダーなど）
.location = .{},
```

---

## message

- 英語・小文字始まり・末尾ピリオドなし
- 可能なら期待値や実際の値を含める

```
// 良い例
"units_per_em=0 is outside recommended range [16, 16384]"
"compound glyph exceeds maximum recursion depth of 10"
"required table 'loca' not found"

// 避ける例
"invalid format"      // 具体的な情報がない
"error occurred"      // 情報がない
```

---

## Diagnostics

診断メッセージを蓄積するコレクション型。

```zig
pub const Diagnostics = struct {
    entries: std.ArrayListUnmanaged(DiagnosticEntry) = .empty,

    pub fn add(self: *Diagnostics, allocator: std.mem.Allocator, severity: Severity, location: Location, message: []const u8) !void
    pub fn addError(self: *Diagnostics, allocator: std.mem.Allocator, location: Location, message: []const u8) !void
    pub fn addWarning(self: *Diagnostics, allocator: std.mem.Allocator, location: Location, message: []const u8) !void
    pub fn addInfo(self: *Diagnostics, allocator: std.mem.Allocator, location: Location, message: []const u8) !void
    pub fn hasErrors(self: Diagnostics) bool
    pub fn deinit(self: *Diagnostics, allocator: std.mem.Allocator) void
};
```

`addError` / `addWarning` / `addInfo` は `add` の便利ラッパー。`message` は内部で `dupe` されるため、スタック上の `bufPrint` 結果をそのまま渡せる。

---

## 整形表示の標準形

CLI 出力での1行表示形式:

```
<location>: <severity>: <message>
```

**テーブル + グリフ ID がある場合:**
```
glyf[42]: error: compound glyph exceeds maximum recursion depth of 10
```

**テーブルのみ + warning の場合:**
```
head: warning: units_per_em=0 is outside recommended range [16, 16384]
```

**location がない場合:**
```
error: sfnt version 0xDEADBEEF is not recognized
```

`formatEntry(allocator, entry) ![]u8` でこの形式の文字列を生成できる。

---

## Zig エラーセットとの関係

制御フローは Zig error union、詳細情報は `Diagnostics` が担う。エラー発生源の関数はオプショナルな `diag: ?*Diagnostics` 引数を受け取り、error return 前に詳細を積む。

```zig
pub fn init(allocator: Allocator, data: []const u8, diag: ?*Diagnostics) !Font {
    const head_record = parser.findTable(offset_table, "head".*) orelse {
        if (diag) |d| d.addError(allocator, .{ .table_tag = "head".* }, "required table 'head' not found") catch {};
        return error.TableNotFound;
    };
    // ...
}
```

呼び出し側は詳細が不要なら `null` を渡す:

```zig
// テストコード（詳細不要）
var font = try Font.init(allocator, data, null);

// CLI（詳細をユーザーに表示）
var diag: Diagnostics = .{};
defer diag.deinit(allocator);
var font = Font.init(allocator, data, &diag) catch |err| {
    for (diag.entries.items) |entry| {
        const msg = formatEntry(allocator, entry) catch continue;
        defer allocator.free(msg);
        std.debug.print("  {s}\n", .{msg});
    }
    return err;
};
```

コンポーネント別パターン:

| コンポーネント | パターン | 補足 |
|---|---|---|
| `cappan_core` | `diag: ?*Diagnostics` 引数 + Zig error union | error return 前に詳細を積む |
| `cappan_inspect` | `Diagnostics` に検証結果を蓄積 | 複数の問題を一括報告 |
| `cappan_subset` | Zig error union（前提チェックで早期失敗） | 将来 `diag` 追加可能 |
| `cappan_embed` | Zig error union | 将来 `diag` 追加可能 |
| `cappan_pathify` | パススルー（cappan_core のエラーをそのまま伝搬） | — |
| `cappan_metrics` | エラーなし（フォールバック値を使用） | — |
| `cappan_cli` | `Diagnostics` を stderr に整形表示して exit | ユーザー向け最終出力 |

---

## Zig エラーセット一覧

### ParseError（`cappan_core.font.parser`）

| Zig error | 発生条件 |
|---|---|
| `error.InvalidSfntVersion` | SFNT ヘッダーのバージョンが不正 |
| `error.UnexpectedEof` | テーブルデータの読み取り中にバッファ境界超過 |
| `error.TableNotFound` | 指定タグのテーブルがディレクトリに存在しない |
| `error.OutOfMemory` | テーブルレコード配列の割り当て失敗 |

### GlyfError（`cappan_core.font.table.glyf`）

| Zig error | 発生条件 |
|---|---|
| `error.CompoundGlyphTooDeep` | コンポーネントグリフの再帰が深さ上限（10）超過 |
| `error.InvalidGlyphId` | グリフ ID が `maxp.numGlyphs` の範囲外 |
| `error.UnexpectedEof` | グリフデータの読み取り中にバッファ境界超過 |
| `error.OutOfMemory` | 輪郭・ポイント配列の割り当て失敗 |

### CffError（`cappan_core.font.table.cff`）

| Zig error | 発生条件 |
|---|---|
| `error.InvalidCff` | CFF ヘッダーまたは INDEX 構造が不正 |
| `error.UnexpectedEof` | CFF データの読み取り中にバッファ境界超過 |

### CharstringError（`cappan_core.font.charstring`）

| Zig error | 発生条件 |
|---|---|
| `error.StackOverflow` | オペランドスタックが上限（48）超過 |
| `error.StackUnderflow` | オペレータ実行時にスタックのオペランド不足 |
| `error.InvalidSubroutine` | サブルーチンインデックスが範囲外 |
| `error.CallDepthExceeded` | サブルーチンネスト深度が上限（10）超過 |
| `error.InvalidCff` | CharString バイトコードが不正 |
| `error.UnexpectedEof` | CharString データが途中で切れている |
| `error.OutOfMemory` | 輪郭・ポイント配列の割り当て失敗 |

### SubsetError（`cappan_subset.subsetter`）

| Zig error | 発生条件 |
|---|---|
| `error.CffNotSupported` | CFF フォントへのサブセッティング試行 |
| `error.NoLocaTable` | `loca` テーブルが存在しない |
| `error.NoGlyfTable` | `glyf` テーブルが存在しない |

### Font.init 固有

| Zig error | 発生条件 |
|---|---|
| `error.InvalidFontIndex` | TTC コレクションのインデックスが収録フォント数超過 |
