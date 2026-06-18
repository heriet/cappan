# cappan_cli

`cappan` CLI の全サブコマンドとオプションのリファレンスです。基本的な使い方は [CLI ガイド](../guide/cli.md) を参照してください。

## 書式

```
cappan <サブコマンド> [オプション]
```

---

## fonts

システムフォントを検索して一覧表示します。

```sh
cappan fonts
```

出力例:

```text
  Noto Sans CJK JP [Regular]
    /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc [index 0]
```

`render` と `animate` では、一覧に表示されたファミリー名またはフルネームを `--font-name` で指定できます。

---

## render

テキストを単一の画像ファイルとしてレンダリングします。

```sh
cappan render --font <path> --text <string> --output <path> [オプション]
```

### 必須オプション

| オプション | 説明 |
|-----------|------|
| `--font <path>` | フォントファイルのパス |
| `--text <string>` | レンダリングするテキスト |
| `--output <path>` | 出力ファイルのパス |

### 出力形式

出力ファイルの拡張子で形式が自動判定されます。

| 拡張子 | 形式 | 説明 |
|--------|------|------|
| `.png` | PNG | デフォルト。圧縮あり |
| `.bmp` | BMP | Windows Bitmap。無圧縮、24bit BGR |
| `.ppm` | PPM | Portable Pixmap (P6)。無圧縮 |

### オプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--size <n>` | フォントサイズ（ピクセル） | `48` |
| `--fg-color <RRGGBB>` | 前景色（16進数） | `000000`（黒） |
| `--bg-color <RRGGBB>` | 背景色（16進数） | `FFFFFF`（白） |
| `--fallback-font <path>` | フォールバックフォントのパス（複数指定可） | なし |
| `--font-name <name>` | システムフォント名で指定 | なし |
| `--font-index <n>` | TTC 内のフォントインデックス | `0` |
| `--gamma` | ガンマ補正（sRGB線形空間でブレンド） | 無効 |
| `--lcd` | LCD サブピクセルレンダリング | 無効 |
| `--fractional` | フラクショナルピクセルポジショニング | 無効 |
| `--max-width <n>` | テキストの最大幅（ピクセル）。超過時は自動折り返し | なし |
| `--text-align <name>` | テキスト揃え（`left`、`center`、`right`、`justify`） | `left` |

---

## animate

テキストをインクリメンタルアニメーションとしてレンダリングします。出力形式は APNG（デフォルト）またはフレーム連番 PNG です。

```sh
# APNGモード
cappan animate --font <path> --text <string> --output <path.apng> [オプション]

# フレーム連番モード
cappan animate --font <path> --text <string> --output-dir <dir> [オプション]
```

### 必須オプション

| オプション | 説明 |
|-----------|------|
| `--font <path>` | フォントファイルのパス |
| `--text <string>` | レンダリングするテキスト |
| `--output <path>` | 出力 APNG ファイルのパス |
| `--output-dir <dir>` | フレーム PNG を出力するディレクトリ |

`--output` と `--output-dir` はどちらか一方が必須です。

### 共通オプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--size <n>` | フォントサイズ（ピクセル） | `48` |
| `--fg-color <RRGGBB>` | 前景色（16進数） | `000000` |
| `--bg-color <RRGGBB>` | 背景色（16進数） | `FFFFFF` |
| `--fallback-font <path>` | フォールバックフォントのパス（複数指定可） | なし |
| `--font-name <name>` | システムフォント名で指定 | なし |
| `--font-index <n>` | TTC 内のフォントインデックス | `0` |
| `--gamma` | ガンマ補正 | 無効 |
| `--fractional` | フラクショナルピクセルポジショニング | 無効 |
| `--max-width <n>` | テキストの最大幅（ピクセル）。超過時は自動折り返し | なし |
| `--text-align <name>` | テキスト揃え（`left`、`center`、`right`、`justify`） | `left` |

### アニメーションオプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--frames <n>` | フレーム数 | `10` |
| `--fps <n>` | フレームレート（APNG モードのみ） | `10` |
| `--strategy <name>` | リビールストラテジー | `sweep` |
| `--sweep-direction <name>` | スウィープ方向 | `left-to-right` |
| `--timing <name>` | タイミングモード | `sequential` |
| `--contour-ordering <name>` | 輪郭描画順序 | `font-order` |
| `--easing <name>` | イージング関数 | `linear` |
| `--hold <n>` | 完成状態を保持するフレーム数 | `0` |
| `--reverse` | 逆再生（progress 1.0 → 0.0） | なし |

### ストラテジー (`--strategy`)

| 値 | 説明 |
|----|------|
| `sweep` | 指定方向へ走査しながら表示（デフォルト） |
| `fade` | 全体をフェードインして表示 |
| `contour-trace` | グリフの輪郭をなぞりながら表示 |
| `medial-axis` | 骨格線に沿ってブラシで描くように表示 |
| `distance-field` | グリフ内部から輪郭へ向かって広がるように表示 |
| `extrema-wave` | アウトラインの極値点（最上・最下・最左・最右）から波が広がるように表示 |
| `skeleton-grow` | 骨格線（中心軸）から外側へ肉付けするように表示 |
| `tangent-flow` | アウトラインの接線方向でグループ化して表示（水平→垂直→斜め） |


### スウィープ方向 (`--sweep-direction`)

| 値 | 説明 |
|----|------|
| `left-to-right` | 左から右へ（デフォルト） |
| `right-to-left` | 右から左へ |
| `top-to-bottom` | 上から下へ |
| `bottom-to-top` | 下から上へ |

### タイミング (`--timing`)

| 値 | 説明 |
|----|------|
| `sequential` | グリフを1文字ずつ順番に表示（デフォルト） |
| `simultaneous` | 全グリフを同時に表示 |
| `weighted` | グリフの複雑さに応じて時間配分を重み付けして逐次表示 |
| `overlap:<value>` | `0.0`〜`1.0` の重なり率でオーバーラップしながら表示 |

### イージング (`--easing`)

各グリフの progress に適用するイージング関数です。

| 値 | 説明 |
|----|------|
| `linear` | 等速（デフォルト） |
| `ease-in` | ゆっくり始まり加速（二次） |
| `ease-out` | 速く始まり減速（二次） |
| `ease-in-out` | ゆっくり始まりゆっくり終わる（二次） |
| `ease-in-cubic` | ゆっくり始まり加速（三次） |
| `ease-out-cubic` | 速く始まり減速（三次） |
| `ease-in-out-cubic` | ゆっくり始まりゆっくり終わる（三次） |

### 輪郭描画順序 (`--contour-ordering`)

`contour-trace` および `medial-axis` ストラテジーで使用します。

| 値 | 説明 |
|----|------|
| `font-order` | フォントデータの順序どおり（デフォルト） |
| `stroke-heuristic` | 上から下・左から右の筆順ヒューリスティック |
| `area-priority` | 面積が大きい輪郭を優先 |
| `writing-order` | 日本語の筆順に近い順序（左上→左下→右上→右下） |

フレーム連番モードでは `<dir>/frame_000.png`、`frame_001.png` … の形式でファイルが出力されます。

---

## svg

テキストを SVG ファイルとして出力します。グリフアウトラインがベクターパス（`<path>` 要素）として書き出されます。

```sh
cappan svg --font <path> --text <string> --output <path.svg> [--size <n>]
```

### 必須オプション

| オプション | 説明 |
|-----------|------|
| `--font <path>` | フォントファイルのパス |
| `--text <string>` | SVG に変換するテキスト |
| `--output <path>` | 出力 SVG ファイルのパス |

### オプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--size <n>` | フォントサイズ（ピクセル） | `48` |

各グリフは個別の `<path>` 要素になり、カーニングを反映した位置に配置されます。二次ベジェ（Q）、三次ベジェ（C）の両方に対応しています。

---

## subset

フォントをサブセットします。指定したテキストに含まれる文字のみを含む軽量フォントファイルを生成します。

```sh
cappan subset --font <path> --text <string> --output <path.ttf>
```

### 必須オプション

| オプション | 説明 |
|-----------|------|
| `--font <path>` | 入力フォントファイルのパス |
| `--text <string>` | サブセットに含める文字 |
| `--output <path>` | 出力フォントファイルのパス |

CFF フォント（.otf）のサブセッティングには未対応です。TrueType（.ttf）のみ対応しています。

---

## inspect

フォントのメタデータ、テーブル構成、整合性チェック、Unicode カバレッジ、OpenType feature、グリフ詳細を表示します。

```sh
cappan inspect --font <path> [出力選択オプション]
```

### 必須オプション

| オプション | 説明 |
|-----------|------|
| `--font <path>` | フォントファイルのパス |

### 共通オプション

| オプション | 説明 |
|-----------|------|
| `--font-name <name>` | システムフォント名で指定 |
| `--font-index <n>` | TTC 内のフォントインデックス |

### 出力選択オプション

| オプション | 説明 |
|-----------|------|
| `--summary` | フォント概要のみ |
| `--tables` | テーブル一覧のみ |
| `--validate` | 検証結果のみ |
| `--coverage` | Unicode カバレッジのみ |
| `--features` | OpenType feature 一覧のみ |
| `--glyphs` | 全グリフ詳細 |
| `--glyph <text>` | 指定テキストのグリフ詳細 |
| `--glyph-id <id[,id,...]>` | グリフ ID（カンマ区切り）でグリフ詳細 |

オプションを何も指定しない場合は `--summary`、`--tables`、`--validate`、`--coverage`、`--features` を全て表示します。`--glyphs`、`--glyph`、`--glyph-id` は明示的に指定した場合のみ実行されます。

### 出力内容

| セクション | 説明 |
|-----------|------|
| フォント概要 | ファミリー名、グリフ数、units per em、アセンダー/ディセンダー |
| テーブル一覧 | 全テーブルのタグ、オフセット、サイズ |
| 検証結果 | units_per_em 範囲、loca/glyf 整合性、hmtx/hhea 整合性など |
| Unicode カバレッジ | 主要ブロックごとのカバー率 |
| OpenType feature | GSUB/GPOS の feature tag（スクリプト・言語別） |
| グリフ詳細 | アドバンス幅、LSB、バウンディングボックス、輪郭数、ポイント数 |

### 出力フォーマット (`--format`)

| 値 | 説明 |
|----|------|
| `text` | テキスト形式（デフォルト） |
| `json` | JSON 形式 |
| `yaml` | YAML 形式 |

---

## metrics

フォントの CSS `@font-face` メトリクスを表示します。

```sh
cappan metrics --font <path> [--compare <path>]
```

### オプション

| オプション | 説明 |
|-----------|------|
| `--font <path>` | フォントファイルのパス（必須） |
| `--compare <path>` | 比較対象のフォントファイルのパス |
| `--font-name <name>` | システムフォント名で指定 |
| `--font-index <n>` | TTC 内のフォントインデックス |

### 単体表示モード

`ascent-override`、`descent-override`、`line-gap-override` を表示します。メトリクスの取得元は OS/2 sTypo → OS/2 usWin → hhea の順にフォールバックします。

### 比較モード (`--compare`)

2つのフォントのメトリクスを比較し、CSS `size-adjust` の推奨値を算出します。`size-adjust` はフォールバックフォントに適用することで、基準フォントに近い表示サイズに調整するための CSS 値です。

---

## 共通事項

### TrueType Collection (.ttc)

`.ttc` ファイルには複数のフォントが格納されています。`--font-index` で使用するフォントを選択できます。省略時は先頭のフォント（インデックス0）が使用されます。

### フォントフォールバック

`--fallback-font` でフォールバックフォントを指定できます（`render`、`animate` で使用可能）。複数指定可能です。

動作:
- 各文字について、プライマリフォント → フォールバック1 → フォールバック2 … の順にグリフを探索
- 最初にグリフが見つかったフォントのメトリクスとアウトラインを使用
- どのフォントにもグリフがない場合は、プライマリフォントの `.notdef` グリフを使用
- レイアウト（行の高さ、ベースライン）はプライマリフォントの値を使用
- カーニングは同一フォント内の隣接グリフ間でのみ適用

### 終了コード

| コード | 意味 |
|--------|------|
| `0` | 成功 |
| `1` | 処理エラー（フォント読み込み失敗、レンダリングエラーなど） |
