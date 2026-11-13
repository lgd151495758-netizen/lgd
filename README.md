# 羽签 Quillmark

在 iPad 上像批注 PDF 一样批注 HTML 网页。目标设备 iPad Air 4（iPadOS 17+），支持 Apple Pencil。

## 当前功能（M1 + M2）

- 导入本地 `.html` 文件（会连同浏览器“网页，全部”保存的 `xxx_files` 资源文件夹）、整个网页文件夹，或直接输入网址
- 两种转换模式：**A4 分页**（默认，按打印排版分页，文字可选）/ **整张长页**（保留网页原样）
- 自研墨迹引擎：圆珠笔 / 钢笔 / 毛笔，压感、速度影响粗细、防抖平滑、预测点降低延迟、Apple Pencil 压力回填
- 只有 Apple Pencil 书写，手指滚动和缩放；可切换“手指书写”（此时双指滚动）
- 撤销 / 重做，自动保存

## M3 新增

- 荧光笔：5 种颜色、3 种粗细、恒定宽度，正片叠底渲染（压在文字上文字仍清晰），始终位于钢笔笔迹下方；可选“直线”模式
- 橡皮擦：**精确擦除**（只擦掉碰到的那一段，笔画被切开）/ **整笔擦除**；3 种大小；可勾选“只擦荧光笔”
- 一次擦除手势 = 一步撤销
- Apple Pencil 二代双击：按系统设置切换橡皮 / 切换到上一个工具

## 编译（无需 Mac）

每次推送到 `main`，GitHub Actions 会在 macOS 构建机上：

1. 用 XcodeGen 根据 `project.yml` 生成工程
2. 编译未签名的 `Quillmark.ipa`，发布到 Releases 的 **latest**
3. 在 iPad 模拟器上运行单元测试

下载地址：<https://github.com/lgd151495758-netizen/lgd/releases/download/latest/Quillmark.ipa>

## 安装到 iPad（Windows）

1. 安装 [Sideloadly](https://sideloadly.io/) 与 iTunes（来自 Apple 官网的非商店版本）
2. 用数据线连接 iPad，在 iPad 上点“信任此电脑”
3. 把 `Quillmark.ipa` 拖进 Sideloadly，填入 Apple ID，点 Start
4. iPad：设置 → 隐私与安全性 → 开发者模式 → 打开并重启
5. iPad：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID
6. 免费 Apple ID 签名 7 天有效，到期后用 Sideloadly 重新安装即可（数据保留）

## 目录

| 路径 | 内容 |
| --- | --- |
| `Quillmark/Ink` | 笔迹处理：压力/速度宽度模型、防抖、轮廓生成 |
| `Quillmark/Canvas` | PDF 页面上的墨迹层、Pencil 输入 |
| `Quillmark/Import` | HTML → PDF 转换 |
| `Quillmark/Model` | 文档库、批注数据、撤销/重做 |
| `Quillmark/UI` | SwiftUI 界面 |
| `QuillmarkTests` | 单元测试（CI 中运行） |
