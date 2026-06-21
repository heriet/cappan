# ストローク・ペイント

cappan の PaintStack 機能を使ったストローク（縁取り）・フィル（塗り）のサンプル集です。各サンプルには生成に使用したコマンドを併記しています。

すべてのサンプルは以下の共通オプションで生成しています。

```sh
FONT="cappan_doc/asset/font/NotoSansCJKjp-Regular.otf"
TEXT="あのイーハトーヴォのすきとおった風"
```

---

## 基本的な縁取り

### 黒い外側ストローク + 赤塗り

最もシンプルな縁取り。2px の黒いストロークの上に赤いフィルを重ねます。

![outside stroke red](image/stroke-paint/stroke_outside_red.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "2px,000000" \
  --fill "F05030" \
  --output stroke_outside_red.png
```

### マルチレイヤー（黒縁 + 白縁 + 赤塗り）

3層のレイヤーを重ねた典型的なテロップスタイル。太い黒→細い白→赤塗りの順で描画されます。

![multi layer stroke](image/stroke-paint/stroke_multi_layer.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "8px,000000" \
  --stroke "4px,FFFFFF" \
  --fill "F05030" \
  --output stroke_multi_layer.png
```

---

## ストロークポジション

### center（中心線）

パスの中心線にストロークを配置します。

![center stroke](image/stroke-paint/stroke_center.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "4px,0066CC,position=center" \
  --fill "000000" \
  --output stroke_center.png
```

### inside（内側）

パスの内側のみにストロークを配置します。グリフの外形が変わらないため、元のサイズを保ちたい場合に有用です。

![inside stroke](image/stroke-paint/stroke_inside.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "4px,CC6600,position=inside" \
  --fill "000000" \
  --output stroke_inside.png
```

---

## ラインジョイン

### miter（尖った角）

コーナーを尖った角で接合します。直角や鈍角の角が鋭くなります。

![miter join](image/stroke-paint/stroke_join_miter.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "6px,000000,join=miter" \
  --fill "F05030" \
  --output stroke_join_miter.png
```

### bevel（面取り）

コーナーを直線で面取りします。round と比べて角張った印象になります。

![bevel join](image/stroke-paint/stroke_join_bevel.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "6px,000000,join=bevel" \
  --fill "F05030" \
  --output stroke_join_bevel.png
```

---

## 半透明

### 半透明ストローク + 半透明フィル

`opacity` を指定すると、一時バッファで全グリフを描画した後にまとめて合成されるため、グリフ同士の重なりで二重ブレンドが発生しません。

![opacity stroke](image/stroke-paint/stroke_opacity.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "8px,FF0000,opacity=0.5" \
  --fill "000000,opacity=0.8" \
  --output stroke_opacity.png
```

---

## em 単位

### em 単位のストローク幅

`em` 単位を使うと、ストローク幅がフォントサイズに比例してスケールします。動画テロップやサイズ可変テキスト向けです。

![em unit stroke](image/stroke-paint/stroke_em_unit.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 \
  --stroke "0.15em,0066FF" \
  --fill "FFFFFF" \
  --output stroke_em_unit.png
```

---

## 応用例

### ネオン風テキスト

暗い背景に半透明のシアンストロークを2層重ね、白いフィルと組み合わせてネオンサインのような発光効果を作ります。

![neon text](image/stroke-paint/stroke_neon.png)

```sh
cappan render --font $FONT --text "$TEXT" --size 64 --bg-color 222222 \
  --stroke "6px,00FFFF,opacity=0.4" \
  --stroke "3px,00FFFF,opacity=0.7" \
  --fill "FFFFFF" \
  --output stroke_neon.png
```

---

## インクリメンタルレンダリングとの組み合わせ

PaintStack はインクリメンタルレンダリング（アニメーション）にも対応しています。各レイヤーのストローク・フィルがリビールストラテジーに従って段階的に表示されます。

### sweep（左→右・sequential）

![sweep stroke](image/stroke-paint/stroke_sweep_ltr_seq.png)

```sh
cappan animate --font $FONT --text "$TEXT" --size 64 \
  --frames 144 --fps 24 --hold 24 \
  --strategy sweep --sweep-direction left-to-right --timing sequential \
  --stroke "4px,000000" \
  --fill "F05030" \
  --output stroke_sweep_ltr_seq.png
```

### contour-trace（writing-order・sequential）

![contour-trace stroke](image/stroke-paint/stroke_contour_writing_seq.png)

```sh
cappan animate --font $FONT --text "$TEXT" --size 64 \
  --frames 144 --fps 24 --hold 24 \
  --strategy contour-trace --contour-ordering writing-order --timing sequential \
  --stroke "4px,000000" \
  --fill "F05030" \
  --output stroke_contour_writing_seq.png
```
