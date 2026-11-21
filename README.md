# 羽签 Quillmark

在 iPad 上像批注 PDF 一样批注 HTML 网页。目标设备 iPad Air 4（iPadOS 17+），支持 Apple Pencil。

## 当前功能（v0.2 · 网页实时批注）

- 导入本地 `.html`（连同 `xxx_files` 资源文件夹）、整个网页文件夹，或输入网址（保存为 `.webarchive`，可离线）
- **网页保持可用**：按钮、折叠展开、标签页、表单、视频照常工作；不再转成 PDF，没有强制分页
- 页面宽度跟随 iPad，横竖屏切换时自动重新排版
- **笔迹挂在网页元素上**：内容展开 / 收起 / 重新排版时，笔迹跟着对应段落移动；元素被隐藏时笔迹一起隐藏；网页结构变化后按文字内容重新找到位置
- Apple Pencil 书写，手指操作网页（点按钮、滚动、缩放）；Pencil 不会误触网页按钮；可切换“手指书写”（此时双指滚动）
- 圆珠笔 / 钢笔 / 毛笔（压感、速度、防抖、预测点）、荧光笔（正片叠底、直线模式）
- 橡皮：精确擦除 / 整笔擦除，可“只擦荧光笔”；Pencil 二代双击切换
- 撤销 / 重做，自动保存；网页里指向其他页面的链接用 Safari 打开
- 旧版本（v0.1）转换的 PDF 文档仍可打开批注
- **投屏全屏无黑边**（v0.5）：用 AirPlay 屏幕镜像（如 OfflineMirror / UxPlay）或线缆投屏时，大屏幕只显示工具栏下方的网页与批注内容，并自动按外接屏比例（16:9 / 16:10 / 3:2 / 4:3）动态扩展显示区域、关闭电视过扫描留边，上下左右铺满无黑边、不拉伸不变形；右上角投屏图标可随时切换「全屏无黑边 / 适应屏幕」与完整镜像

## 编译（无需 Mac，使用 Codemagic）

每次推送到 `main`，[Codemagic](https://codemagic.io) 会按 `codemagic.yaml`：

1. 用 XcodeGen 根据 `project.yml` 生成工程
2. 编译未签名的 `Quillmark.ipa`
3. 在 iPad 模拟器上运行单元测试
4. 把结果发到邮箱；IPA 在 Codemagic 构建页面的 **Artifacts** 里下载

（GitHub Actions 的 macOS 机器经常排不上，`.github/workflows/build.yml` 只保留手动运行。）

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
| `Quillmark/Import` | 导入 HTML / 保存网页为 webarchive |
| `Quillmark/Web` | 网页实时批注：编辑器、页面内脚本 `qm-runtime.js`、元素锚定 |
| `Quillmark/Model` | 文档库、批注数据、撤销/重做 |
| `Quillmark/UI` | SwiftUI 界面 |
| `QuillmarkTests` | 单元测试（CI 中运行） |
