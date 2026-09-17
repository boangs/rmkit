# 首页插画素材

放这里的图会按「季节 + 天气」自动选用, 文件名必须完全一致。

- 格式: **JPEG (.jpg)**, 入库前由 PNG 原稿转换 (`sips -s format jpeg -s formatOptions 85`),
  单张约 600-900 KB。原稿是 PNG 也行, 但不要把几 MB 的 PNG 直接提交进仓库。
- 尺寸: 现有素材为 **1086 × 1448 (3:4 竖构图)**。横构图同样可用, **主体放中间**即可。
- 显示方式: 首页插画区按宽度铺满后**居中裁切**, 竖图只会露出中间一条横带,
  所以画面重点不要压在最上或最下。
- 墨水屏注意: 水墨 / 淡彩风格, 大面积留白; 避免整片深色 (刷新慢、易残影);
  避免细密纹理与噪点 (抖动后发脏); 不要文字和边框。

## 缺图时怎么办

不必凑满 24 张。缺哪张就按下面的顺序自动借用, 一路借不到才用自带的矢量插画:

1. 夜间图 (只有晴 / 多云有)
2. 同季节的白天图
3. 邻近季节的同款天气 (顺序见 `weather.js` 里的 `SEASON_ALT`)
4. `scene.svg`

## 现有 19 张

| 文件名 | 季节 | 天气 |
|---|---|---|
| `spring-clear.jpg` | 春 | 晴 |
| `spring-cloudy.jpg` | 春 | 多云 / 阴 |
| `spring-rain.jpg` | 春 | 雨 |
| `spring-snow.jpg` | 春 | 雪 |
| `spring-fog.jpg` | 春 | 雾 |
| `summer-clear.jpg` | 夏 | 晴 |
| `summer-rain.jpg` | 夏 | 雨 |
| `summer-storm.jpg` | 夏 | 雷雨 |
| `summer-fog.jpg` | 夏 | 雾 |
| `autumn-clear.jpg` | 秋 | 晴 |
| `autumn-cloudy.jpg` | 秋 | 多云 / 阴 |
| `autumn-rain.jpg` | 秋 | 雨 |
| `autumn-snow.jpg` | 秋 | 雪 |
| `autumn-storm.jpg` | 秋 | 雷雨 |
| `autumn-fog.jpg` | 秋 | 雾 |
| `winter-clear.jpg` | 冬 | 晴 |
| `winter-cloudy.jpg` | 冬 | 多云 / 阴 |
| `winter-snow.jpg` | 冬 | 雪 |
| `winter-storm.jpg` | 冬 | 雷雨 |

## 还缺 5 张 (按值不值得补排序)

| 文件名 | 季节 | 天气 | 说明 |
|---|---|---|---|
| `summer-cloudy.jpg` | 夏 | 多云 / 阴 | **常见**, 建议补; 现在借春天那张 |
| `winter-fog.jpg` | 冬 | 雾 | 常见 (冬雾 / 霾), 建议补; 现在借秋天那张 |
| `winter-rain.jpg` | 冬 | 雨 | 南方冬雨常见, 建议补; 现在借秋天那张 |
| `spring-storm.jpg` | 春 | 雷雨 | 春雷不少, 可补; 现在借秋天那张 |
| `summer-snow.jpg` | 夏 | 雪 | 确实罕见, 不必补; 现在借春天那张 |

## 可选: 夜间版 8 张

只有晴和多云需要夜间版; 不提供时夜里自动用白天那张。墨水屏上夜景会大片发黑,
建议画成淡墨月夜而不是纯黑。

`spring-clear-night.jpg`、`spring-cloudy-night.jpg`、`summer-clear-night.jpg`、
`summer-cloudy-night.jpg`、`autumn-clear-night.jpg`、`autumn-cloudy-night.jpg`、
`winter-clear-night.jpg`、`winter-cloudy-night.jpg`
