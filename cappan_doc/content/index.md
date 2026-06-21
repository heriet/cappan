# cappan

**cappan**（活版）はpure Zig実装のフォントレンダリングエンジンです。ライブラリ及びツール群を提供しています。

![medial-axis writing-order weighted](guide/image/incremental-rendering/medial_axis_writing_weighted.png)

[ブラウザ Demo](https://heriet.github.io/cappan/demo/)

- このプロジェクトの大部分はAIによって実装されています
- 個人の学習・実験を主とした目的で管理されており、急な破壊的変更を行うことがあります。重要な製品での利用は推奨しません

## できること

- フォントファイルからテキストをレンダリング
- テキストが文字ごとに現れる **インクリメンタルレンダリング**
- フォントの **メタデータ確認**・**整合性検証**
- 必要な文字だけを含む **軽量フォントファイル** の生成（サブセッティング）
- フォント間の CSS メトリクス比較
- など

## 使い方の例

テキストを PNG 画像にレンダリングする:

```sh
cappan render --font DejaVuSans.ttf --text "Hello, World!" --output hello.png
```

テキストアニメーションを生成する:

```sh
cappan animate --font DejaVuSans.ttf --text "Hello" --output hello.apng --strategy sweep
```

フォントの情報を確認する:

```sh
cappan inspect --font DejaVuSans.ttf
```

## コンポーネント

| コンポーネント | 説明 |
|--------------|------|
| `cappan_core` | フォントパース、ラスタライズ、レンダリング、画像出力のコアライブラリ |
| `cappan_cli` | コマンドラインインターフェース（`render` / `animate` / `subset` / `fonts` サブコマンド） |
| `cappan_subset` | TrueType フォントサブセッティング |
| `cappan_embed` | PDF フォント埋め込みユーティリティ |
| `cappan_inspect` | フォントメタデータ解析・検証ツール |
| `cappan_pathify` | グリフアウトライン→SVG パス変換 |
| `cappan_metrics` | CSS font metrics 計算・フォント間メトリクス比較 |

## ガイド

- [CLI ガイド](guide/cli.md) — コマンドの使い方
- [インクリメンタルレンダリング](guide/incremental-rendering.md) — テキストアニメーションの出力例
- [ストローク・ペイント](guide/stroke-paint.md) — 縁取り・マルチレイヤー描画の出力例
- [開発ガイド](guide/developer-guide.md) — ビルド・テスト・ライブラリとしての利用
