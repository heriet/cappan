# 開発者ガイド

## 前提条件

- [Zig](https://ziglang.org/) 0.16.0 以降
- [Docker](https://docs.docker.com/get-docker/) および Docker Compose（開発環境用）

## ビルド

```sh
make build
```

## テストの実行

```sh
make test
```

## フォーマット

```sh
make fmt
```

## CLIの使用

`cappan` CLI でテキストをフォントファイルからレンダリングできます。

```sh
# PNG画像へレンダリング
cappan render --font /path/to/font.ttf --text "Hello" --output out.png

# アニメーションAPNGへレンダリング
cappan animate --font /path/to/font.ttf --text "Hello" --output out.apng
```

使い方は [CLI ガイド](cli.md)、全オプションの詳細は [CLI リファレンス](../spec/cappan_cli.md) を参照してください。

## ライブラリとしての使用

`cappan_core` をZigプロジェクトの依存ライブラリとして利用できます。

```zig
const cappan = @import("cappan_core");

// フォントを読み込む
const font_data = try std.fs.cwd().readFileAlloc(allocator, "font.ttf", 50 * 1024 * 1024);
defer allocator.free(font_data);

var font = try cappan.font.Font.init(allocator, font_data);
defer font.deinit();

// テキストをRGBAビットマップへレンダリング
var bitmap = try cappan.render.renderer.renderText(allocator, font, "Hello", .{
    .pixel_size = 48.0,
    .fg_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .bg_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
});
defer bitmap.deinit();

// PNGとして書き出す
const file = try std.fs.cwd().createFile("out.png", .{});
defer file.close();
try cappan.image.png.writePngRgba(allocator, bitmap, file.writer());
```
