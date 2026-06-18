# cappan_subset

`cappan_subset` モジュールがフォントのサブセッティングを担当します。指定したコードポイントのみを含む軽量なTrueTypeフォントを生成します。

---

## 概要

サブセッティングとは、フォントファイルから必要なグリフだけを抽出し、サイズの小さいフォントを生成する処理です。Webフォントの転送量削減やPDF埋め込みでの最小化に利用します。

**対応形式:** TrueType（`.ttf`）のみ。CFFフォント（`.otf`）は非対応です。

---

## subsetFont

サブセッティングのメイン関数です。

```zig
pub fn subsetFont(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
    options: SubsetOptions,
) ![]u8
```

| 引数 | 型 | 説明 |
|------|----|------|
| `allocator` | `std.mem.Allocator` | 出力バッファの確保に使用 |
| `font` | `cappan_core.font.Font` | 元フォント（パース済み） |
| `codepoints` | `[]const u21` | サブセットに含めるコードポイント列 |
| `options` | `SubsetOptions` | サブセッティングオプション |

戻り値は呼び出し元が `allocator.free()` で解放する必要があります。

---

## SubsetOptions

```zig
pub const SubsetOptions = struct {
    keep_name_table: bool = true,
};
```

| フィールド | デフォルト | 説明 |
|-----------|-----------|------|
| `keep_name_table` | `true` | `name` テーブルを出力フォントに保持するか |

---

## SubsetError

```zig
pub const SubsetError = error{
    CffNotSupported,
    NoLocaTable,
    NoGlyfTable,
};
```

| エラー | 説明 |
|--------|------|
| `CffNotSupported` | CFFフォントはサポート外（`font.cff != null` の場合） |
| `NoLocaTable` | `loca` テーブルが存在しない |
| `NoGlyfTable` | `glyf` テーブルが存在しない |

---

## 内部処理の概要

```
subsetFont
  ├─ 1. グリフ収集（collectGlyphs）
  │     コードポイント → グリフID変換
  │     コンポジットグリフのコンポーネントを再帰的に収集
  │     グリフ0（.notdef）を必ず含める
  │     重複排除・ソート
  │
  ├─ 2. グリフIDリマッピング（buildGlyphMapping）
  │     旧グリフID → 新グリフID の変換テーブルを構築
  │
  └─ 3. SFNTアセンブル（assembleSfnt）
        各テーブルを再構築し、SFNTヘッダー付きで出力
```

---

## テーブル再構築一覧

| テーブル | 処理内容 |
|---------|---------|
| `glyf` | 使用グリフのアウトラインデータを抽出し、コンポーネントIDをリマッピング |
| `loca` | 新しい `glyf` のオフセット配列を再構築。オフセットが `0x1FFFE` 以下なら short 形式（format 0）、それ以外は long 形式（format 1） |
| `cmap` | 指定コードポイントのみを含む Format 12 テーブルを生成 |
| `hmtx` | 使用グリフの水平メトリクスのみ抽出 |
| `head` | `index_to_loc_format` を更新して再構築 |
| `maxp` | `num_glyphs` を新グリフ数に更新 |
| `hhea` | `number_of_h_metrics` を新グリフ数に更新 |
| `post` | Format 3.0（グリフ名なし）として出力 |
| `name` | `keep_name_table = true` の場合、元テーブルをそのままコピー |

---

## 使用例

```zig
const cappan_core = @import("cappan_core");
const cappan_subset = @import("cappan_subset");

const font_data = try std.fs.cwd().readFileAlloc(allocator, "input.ttf", 10_000_000);
defer allocator.free(font_data);

var font = try cappan_core.font.Font.init(allocator, font_data);
defer font.deinit();

const codepoints = [_]u21{ 'H', 'e', 'l', 'l', 'o', '!', 'あ', 'い', 'う' };
const subset_data = try cappan_subset.subsetter.subsetFont(
    allocator,
    font,
    &codepoints,
    .{ .keep_name_table = true },
);
defer allocator.free(subset_data);

try std.fs.cwd().writeFile("subset.ttf", subset_data);
```

---

## 制限事項

- **CFFフォント非対応:** `font.cff != null` の場合は `SubsetError.CffNotSupported` を返します。OpenType CFF（`.otf`）フォントにはサブセッティングを適用できません。
- コンポジットグリフのコンポーネントは自動的に収集されます（明示的にコードポイントを指定する必要はありません）。
- `kern`・`GPOS`・`GSUB` などのレイアウトテーブルは出力フォントに含まれません。
