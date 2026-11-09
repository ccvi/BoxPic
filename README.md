# BoxPic

原生 macOS 图像格式转换工具。拖进去、选格式、点转换。
支持 **60 种输入格式**（含 SVG、EPS/PostScript 与 20 余种相机 RAW）、**20 种输出格式**。

当前版本：**1.0.18**

- 系统要求：macOS 14 及以上（在 macOS 26 + Apple M 芯片上开发与验证）
- 作者：ccvi1223 · ccvi1223@qq.com
- 体积：约 2.5 MB，零外部运行时依赖

---

## 功能

| 能力 | 说明 |
|---|---|
| 拖放转换 | 拖文件或整个文件夹进窗口；也可以「文件 → 添加图片」、拖到 Dock 图标、`open -a BoxPic x.png` |
| EPS / PostScript | `.eps` / `.epsf` / `.ps` 可当输入。macOS 自带已经没有任何 PostScript 解释器，靠外部 **Ghostscript** 渲染（`brew install ghostscript`）；没装时会给一句明确的提示，而不是「不支持的格式」 |
| 格式转换 | JPG / JPEG / HEIC / HEICS / PNG / WEBP / AVIF / TIFF / PDF / GIF / BMP / JP2 / TGA / PBM / EXR / PSD / ASTC / KTX / ICNS / ICO |
| 尺寸调整 | 原始尺寸 / 最大宽度 / 最大高度 / 百分比 / 指定宽高，等比不放大 |
| 压缩质量 | 0–100%，一格 5%；只对有损格式生效（PNG/TIFF/PDF 等无损容器会标注「无损」） |
| 即时预估 | 拖进来的瞬间就按当前参数预跑一次编码，卡片直接显示「1.9 MB → ≈ 359 kB」；改任一参数立刻全部重算 |
| 前后对比 | 点缩略图进入对比视图：**一张图**，左半张是转换前的像素、右半张是转换后的像素，中间一条橙线接缝；两侧内容完全对齐，只有画质在橙线处变了。点图或按 Esc 回到网格 |
| 1:1 查看 | 对比视图右上角「1:1」按真实像素显示（会定位到橙线接缝），再点切回适应窗口。压缩痕迹只有在这个倍率下才看得见 |
| 右键菜单 | 图片上右键 → 菜单底部「在 BoxPic 中打开」（NSServices，装完即用，**不需要任何授权**） |
| 输出位置 | 默认与源文件同目录，可指定任意文件夹；重名自动加序号，**绝不覆盖源文件** |
| 批量 | 一次拖入多张，逐个转换并实时显示体积/尺寸变化 |

## 快速开始

```bash
./build-app.sh --install --no-sandbox     # 构建 + 安装到 /Applications + 出 dmg
open -a BoxPic
```

产物有两个：`dist/BoxPic.app` 和 `dist/BoxPic-<版本>.dmg`。
dmg 里只放 app 和指向 `/Applications` 的软链接 —— 拖进去就算装好。
**顺序固定：先签 app，再打 dmg**；打完会挂载回来比对里面的 cdhash，和 dist 不一致就报错。

> `--no-sandbox` 是必需的：SwiftPM 自带的 manifest 沙箱在本机（已被外层沙箱包裹）会报
> `sandbox-exec: sandbox_apply: Operation not permitted`，直接编译失败。

开发调试：

```bash
swift build -c release --disable-sandbox   # 直接编译
.build/release/BoxPic --selftest           # 应用内自检（40 项）
.build/release/BoxPic --version
```

> ⚠️ 不要直接执行 `.app/Contents/MacOS/BoxPic`——macOS 26 上那样做会让 bundle 的
> LaunchServices 登记失效，GUI 行为也不可信。验证一律用 `.build` 下的裸产物。

右键菜单不出现时：把应用启动一次（服务在首次启动时才注册），或执行
`/System/Library/CoreServices/pbs -update` 刷新缓存。兜底的「打开方式 → BoxPic」不依赖服务，安装即生效。

---

## 技术决策与踩过的坑

### 1. WebP 编码为什么不走 ImageIO

`CGImageDestinationCopyTypeIdentifiers()` 里有 21 个类型，**没有** `org.webmproject.webp` ——
系统只有 WebP 解码器，没有编码器：

- `sips -s format webp` 直接失败；
- WebKit 的 `canvas.toDataURL('image/webp')` 在 macOS 26 上返回的是 **PNG**（静默降级，
  实测三个不同质量参数返回完全相同长度）；
- 系统里也没有可 `dlopen` 的 `libwebp.dylib`。

所以内置了 **libwebp 1.5.0 的编码器子集**（BSD 许可，见 `Sources/CLibWebP/COPYING`），
只编译 `enc` / `dsp` / `utils` / `sharpyuv`，`dec` 只留头文件（解码仍走系统 ImageIO）。

- 源码保持 `src/` 前缀的目录结构：libwebp 内部用 `#include "src/webp/encode.h"`；
- 移除了 SSE/AVX/MSA/MIPS/WASM 变体，**保留 NEON** —— arm64 上 `WEBP_USE_NEON` 是默认开启的，
  删掉 NEON 会有一堆 `_VP8EncDspInitNEON` 未定义符号；
- `config.h` 由 cmake 生成一次后入库（`src/webp/config.h`），避免构建时装 cmake；
- `WebPEncodeRGBA` 要**直通 alpha**，而 `CGContext` 出的是预乘 alpha，编码前必须反预乘，
  否则半透明边缘偏暗。

### 2. 右键菜单用 NSServices，不用访达扩展

最初按常规思路写了 FinderSync `.appex`，装完菜单永远不出现。查下来是 macOS 26 的死结：

- `pluginkit -m` / `pluginkit -e use` 对外部进程一律返回
  `unauthorized discovery flag (PKDiscoverAll)`，命令行既查不到也开不了；
- `FIFinderSyncController.isExtensionEnabled` 恒为 `false`，应用侧也读不到真实状态；
- 系统设置的扩展列表里条目时有时无，让用户去勾选本身就是个差体验。

对照参考产品的截图，发现 Kompressor 用的是 **NSServices**（服务菜单），改过去就通了：
`Info.plist` 里声明 `NSServices`（`NSMessage = openImageInBoxPic`、
`NSRequiredContext.NSApplicationIdentifier = com.apple.finder`、`NSSendFileTypes` 为图像 UTI），
`AppDelegate` 实现同名 `@objc` 方法，启动时设 `NSApp.servicesProvider = self` 并调
`NSUpdateDynamicServices()`。**装完即用，零授权，也不需要沙箱 entitlement。**
随后删掉了整个 `Ext/` 目录与打包脚本里的扩展编译/签名段。

### 3. ICNS 不能用 ImageIO 写

`CGImageDestinationFinalize` 对 `com.apple.icns` 在 macOS 26 上直接返回 `false`（单张、多张都一样）。
改成自己拼容器：`'icns'` + 总长度 + 若干 `(4 字节类型 + 4 字节长度 + PNG)`，
类型码 `icp4/icp5/ic11/ic12/ic07/ic13/ic08/ic14/ic09/ic10`，同时覆盖 1x 与 @2x。

### 4. ICO 必须是正方形

边长只能是 16/24/32/48/64/128/256，非正方形源图直接 Finalize 失败。
实现：等比缩到 ≤256 后居中放进 256×256 透明画布（letterbox，不裁剪内容）。

### 5. SVG 输入

ImageIO 完全不认识 SVG（`CGImageSourceCreateWithURL` 返回 count=0）。
走 `NSImage`（内部是 `_NSSVGImageRep`）再自己光栅化到 2400 px 宽；
`NSImage.size` 给的是 viewBox 尺寸，用于显示「原始尺寸」。

### 5.5 EPS 为什么要靠 Ghostscript

macOS 26 自带的东西里**没有任何 PostScript 解释器**，四条路全试过：

- `CGImageSourceCreateWithURL` 对 `.eps` 返回 `count = 0`；
- `NSImage(data:)` 直接返回 nil；
- `CGPSConverter`（CoreGraphics 里的老 API）—— dlsym 调得到，`CGPSConverterConvert` 返回 **true 但产出 0 字节**，
  只剩个空壳；而且在 Swift 里已被标成 obsoleted，连直接调用都不行；
- `sips -s format png x.eps` 会打印出目标路径却不写文件；`cupsfilter` 直接报
  「无滤镜可从 application/postscript 转换成 application/pdf」。

所以只能外挂 Ghostscript：运行时依次探测 `/opt/homebrew/bin/gs`、`/usr/local/bin/gs`、
`/opt/local/bin/gs`、`/usr/bin/gs` 和 `PATH`，命中就用
`-sDEVICE=png16m -dEPSCrop -r<dpi>` 渲成 PNG 再走同一条解码链路；没命中就抛一句
「brew install ghostscript」的人话 —— 而不是让用户对着「不支持的格式」发呆。

两个细节：

- **dpi 从 `%%BoundingBox` 反推**：目标是长边 ≈ 2400 px，`dpi = 2400 × 72 ÷ 长边(pt)`。
  网格里的「原始尺寸」用的是同一个函数，所以界面上的数字和真正渲染出来的像素一像素不差。
- 🔴 **临时 PNG 必须在返回前就解码进内存**（`kCGImageSourceShouldCacheImmediately: true`）。
  `CGImageSourceCreateImageAtIndex` 默认懒加载，而临时文件在 `defer` 里已经删掉了 ——
  返回出去的其实是一张「文件已经不在了」的图，画出来全黑。自检里平均色是 (0,0,0) 才发现这条。

### 6. 质量参数只对有损格式有效

ImageIO 对 PNG/TIFF/PDF/PBM/TGA 会**完全忽略** `kCGImageDestinationLossyCompressionQuality`，
实测同一张图 q=0.9 与 q=0.4 输出字节数一模一样。所以 UI 上这些格式的质量条置灰并显示「无损」，
而不是让用户拖了半天发现体积没变。

### 7. 预估值就是最终值，不是抽样

「拖进来立刻显示转换后多大」的实现是：**预跑一次真正的编码**，走和点转换时完全相同的
`load → targetSize → resize → encode` 路径，只是不落盘。

- 自检里有硬断言：`estimate().bytes == convert().byteCount`，JPG 与 WebP 两条路径都验；
- 另加一条稳定性断言：同一组参数连算两次必须字节完全一致，换质量必须跟着变
  （界面上两个位置的数字若出现差异，只允许由「参数变了」解释，不允许来自估算抖动）；
- 预编码是串行的、低优先级；拖动质量条时停手 350 ms 才重算，避免每一帧都跑一遍；
- 参数一变先 `invalidateResults()` 把旧结果与旧预估全部作废，再重算，绝不拿旧参数的数字糊弄人。

⚠️ 一个坑：`scheduleEstimates` 会取消上一轮任务，被取消的任务可能停在
`estimating = true` 却没拿到结果；若重算时的过滤条件里含 `!estimating`，这些任务会被
永远跳过，卡片卡在「计算中…」再也不动。所以重算前必须先把没有结果的 `estimating` 清掉。

### 7.5 对比预览必须从编码后的字节解码

这是踩得最深的一个坑：对比视图里「质量拖到 5%，左右两张图还是一模一样」。

原因不是参数没生效，而是预览图取自**编码前**的 CGImage —— 压缩劣化发生在 `encode` 这一步，
拿编码前的图缩一张，画质当然一点没变。改成 `encode → data → CGImageSourceCreateThumbnailAtIndex`
之后，5% 的文字立刻糊成一团。

同样的道理，预览**必须按当前参数现渲**（`renderPreview`），不能缓存成「导入时那张」：
参数变了画质就变了，缓存会让对比视图说谎。代价是每次进对比视图要重编一张图（一两百毫秒），
换来的是所见即所得；顺带把十几张任务各挂一张 1400 px 位图的内存也省了。

### 7.6 对比图是「一张画」，不是两张图并排

要求是「用一张图，左边半张、右边半张」：画布就是输出图的尺寸，**左半取转换前的像素、
右半取转换后的像素**，接缝压在正中画一条橙线。因为两半是同一张画的不同部分，接缝两侧内容
天然对齐，看起来就是一张完整的图，只有画质在橙线处变了。

走过两次弯路，都记在这儿：

1. **两个并排的 `Image`** —— 宽高比不一致时 `.fit` 各缩各的，中间露出黑缝、甚至一高一低，
   观感就是「两张图」。
2. **左右各塞一张完整缩图** —— 接缝两侧内容对不上，画面在中间跳一下；而且整套图被压进窗口
   显示，缩得越小越看不出压缩痕迹。

尺寸不同的情况（比如 50% 缩小）用 `fitRect` 各自等比居中放进同一块画布，接缝仍然对得齐。
自检里有像素级断言：接缝左边 20 px 的像素必须等于原图同坐标像素，右边 20 px 必须等于结果同坐标像素。

### 7.7 1:1 倍率下要定位到接缝

适应窗口时 900 px 的图被压到 55% 显示、2048 px 的图只剩 12%，重采样会把块效应和色渗
全部抹平 —— 用户会以为质量参数没生效。所以对比视图给了一个「1:1」开关，
一个图像像素对一个屏幕物理像素（`NSScreen.backingScaleFactor`）。

进入 1:1 时必须滚到画面正中（橙线接缝），不能停在左上角 —— 停在角落只能看到左图的边，
什么也对比不出来。实现是 `ScrollViewReader.scrollTo("seam", anchor: .center)`，
再用 `.frame(minWidth:minHeight:)` 保证图比窗口小时也是居中而不是缩在左上方。

### 8. 尺寸计算是纯函数

`ImageEngine.targetSize(for:options:)` 不碰图像数据，自检直接打表比对。
缩小超过 1/2 时逐级对半缩放，避免一次性插值丢细节。

### 9. 原始尺寸不能取缩略图尺寸

导入时为了快，用 640 px 缩略图填网格。但**「之前」的尺寸必须读真实像素**，
否则对比视图会显示 `599 × 640` 这种假数字（实测踩过）。

### 10. 打包脚本的删除方式

沙箱环境里裸 `rm -rf` 会把旧产物丢进废纸篓并重命名成 `BoxPic.app 13-20-25-868.app`，
一路堆几十个副本，还会让 LaunchServices 记一堆幽灵路径。
统一改成 `find "$dir" -depth -delete`（见 `delete_tree`）。

---

## 结构

```
BoxPic/
├── Package.swift              # SwiftPM：BoxPic 可执行 + CLibWebP C target
├── VERSION                    # 版本号唯一来源
├── build-app.sh               # 编译 / 自检 / 图标 / 签名 / 安装
├── Resources/
│   ├── Info.plist             # CFBundleDocumentTypes + NSServices（右键菜单）
│   └── icon-master.png        # 1024 母版，打包时生成 icns
├── Sources/
│   ├── BoxPic/
│   │   ├── main.swift
│   │   ├── App/               # AppDelegate / AppModel / SelfTest
│   │   ├── Core/              # Formats / ImageEngine / PostScript / WebPEncoder / Preferences / Support
│   │   └── UI/                # MainView / ThumbnailCard / CompareView / ControlBar / Theme
│   └── CLibWebP/              # libwebp 1.5.0 编码器子集（BSD）
└── dist/
    ├── BoxPic.app
    └── BoxPic-<版本>.dmg      # 安装包（app + /Applications 软链接）
```

## 约束

- 零第三方运行时依赖；唯一的嵌入式 C 代码是 libwebp（BSD，许可证随包携带）。
- 不声明 testTarget（本机只有 Command Line Tools，声明了会因缺 XCTest 编不过）；
  自检走 `--selftest`，打包脚本拿它当发布门禁。
- 签名用固定本机证书 `FastFind Local Signing`；安装用 `ditto` 且**复制后绝不重签**
  （重签会把证书覆盖成 ad-hoc，cdhash 变化 → 系统授权失效）。
- 源文件永不覆盖：目标与源同路径时自动加序号。

## 数据位置

| 内容 | 位置 |
|---|---|
| 偏好设置 | `~/Library/Preferences/com.ccvi1223.boxpic.plist`（JSON，键 `BoxPic.Preferences.v1`） |
| 输出文件 | 默认与源文件同目录，或用户指定目录 |
| 自检日志 | 打包时写 `/tmp/boxpic-selftest.log` |

## 版本规则

`VERSION` 是唯一来源，补丁位按源码指纹自动递增（源码有改动 → 1.0.0 → 1.0.1）。
`--bump` 强制 +1，`--no-bump` 保持不变。`VERSION` 与 `VERSION.fingerprint` 必须入库。
打包脚本同时把这个版本号写回本 README 的「当前版本」一行。

## 诊断

```bash
.build/release/BoxPic --selftest          # 40 项：格式表 / 尺寸 / SVG / EPS / WebP / 全格式落盘 / 质量 /
                                          #        预估=实际 / 预估稳定 / 预览带压缩痕迹 /
                                          #        对比图左原图右结果 / 不覆盖
.build/release/BoxPic --version
# 把「预估 → 渲染预览 → 合成对比图」整条链路跑一遍并落盘，附带两侧边缘能量
.build/release/BoxPic --compare-probe <源图> <输出.png> [质量]
codesign -d -r- /Applications/BoxPic.app  # 指定要求不能出现 cdhash
ls -d ~/.Trash/BoxPic.app* 2>/dev/null    # 应始终为空
```

## 已知问题

- 质量参数对无损格式（PNG/TIFF/PDF/PBM/TGA/BMP/GIF/PSD/EXR）无效，UI 已标注「无损」。
- DDS / PVR 系统能"写"但产出空文件，已从格式表移除。
- ASTC / KTX 输出为未压缩纹理，体积很大（几 MB 到几十 MB），属格式本身特性。
- 相机 RAW 走 `CGImageSourceCreateThumbnailAtIndex` 的系统 RAW 管线，个别机型可能只出预览尺寸。
- 多图批量目前串行处理（单张内部已是多线程），几十张时耗时为各张之和。
- 未转换时对比视图的「之后」是内存里编出来的预览图，最长边 900 px；它只用于看效果，
  不是最终落盘文件的副本。
