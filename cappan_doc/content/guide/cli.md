# CLIガイド

`cappan` はフォントファイルからテキストをレンダリングするコマンドラインツールです。

```
cappan <サブコマンド> [オプション]
```

---

## テキストを画像にレンダリング

```sh
cappan render --font DejaVuSans.ttf --text "Hello, World!" --output hello.png
```

フォントサイズや色を変更するには `--size`、`--fg-color`、`--bg-color` を指定します。

```sh
cappan render --font font.ttf --text "cappan" --output out.png \
  --size 64 --fg-color FF0000 --bg-color 000000
```

出力形式は拡張子で自動判定されます（`.png` / `.bmp` / `.ppm`）。

---

## テキストアニメーション

```sh
cappan animate --font font.ttf --text "Hello" --output hello.apng \
  --frames 20 --fps 12
```

アニメーションの表示方法は `--strategy` で選べます。

| ストラテジー | 効果 |
|-------------|------|
| `sweep` | 方向を指定してスウィープ表示（デフォルト） |
| `fade` | フェードイン |
| `contour-trace` | 輪郭をなぞるように表示 |
| `medial-axis` | 骨格線に沿って描くように表示 |

```sh
# 輪郭トレース、1文字ずつ
cappan animate --font font.ttf --text "ABC" --output abc.apng \
  --strategy contour-trace --timing sequential

# フェード、全文字同時
cappan animate --font font.ttf --text "Hello" --output hello.apng \
  --strategy fade --timing simultaneous
```

フレーム連番PNGとして出力することもできます。

```sh
cappan animate --font font.ttf --text "Hello" --output-dir ./frames --frames 10
```

---

## SVG出力

テキストをベクター形式で出力します。

```sh
cappan svg --font DejaVuSans.ttf --text "Hello" --output hello.svg
```

---

## フォント情報

### フォント検索

システムにインストールされたフォントを一覧表示します。

```sh
cappan fonts
```

### フォント詳細

フォントのメタデータやテーブル構成を確認できます。

```sh
cappan inspect --font DejaVuSans.ttf
```

### CSSメトリクス

`@font-face` 向けのメトリクス値を表示します。

```sh
cappan metrics --font DejaVuSans.ttf
```

---

## フォントサブセット

テキストに必要なグリフのみを含む軽量フォントを生成します。

```sh
cappan subset --font DejaVuSans.ttf --text "Hello World" --output subset.ttf
```

---

## フォントフォールバック

プライマリフォントにないグリフをフォールバックフォントから取得できます。`render` と `animate` で使えます。

```sh
cappan render --font DejaVuSans.ttf --fallback-font NotoSansCJKjp.otf \
  --text "Hello こんにちは" --output mixed.png
```

---

全オプションの詳細は [CLI リファレンス](../spec/cappan_cli.md) を参照してください。
