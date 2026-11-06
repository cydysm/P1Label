# P1Label

macOS 标签打印应用，配套德佟（Detong/DothanTech）P1 热敏标签打印机，支持
**USB** 与**蓝牙 LE** 双通道无线打印。

P1Label is a macOS label editor & printer for the Detong P1 thermal label
printer, over USB (libusb) and Bluetooth LE (CoreBluetooth).

## 功能

- **重构版主窗口**：左侧设置面板（设备状态卡 / 添加元素 / 元素属性 /
  纸张 / 打印五张卡片），右侧画布区带信息条与缩放状态栏
- **自由画布**：文本 / 二维码 / 条码元素，拖拽、角点缩放、对齐标线吸附；
  选中元素可编辑内容与属性，右上角 **×** 直接删除；元素拖拽自动钳制在
  纸张范围内
- **高清预览**：二维码 / 条形码以 4× 分辨率渲染、背景透明，元素叠放时
  互不遮挡
- **双通道打印**：USB（libusb）与蓝牙 LE（CoreBluetooth）一键切换，
  蓝牙侧自动扫描 / 记住上次设备
- **打印设置**：份数、浓度（1–16）、模切/连续纸、间隙长度、水平偏移、
  上下边距
- **打印管线**：CoreText/CoreGraphics 排版 → 384 点阵 1-bit 光栅 →
  RLE 行编码 → LPAPI 协议（对硬件实测校准的字节流）
- **浅色外观**：app 固定浅色渲染，深色系统下选区、菜单等系统部件
  同样保持浅色

## 构建

要求：macOS 12+、Xcode Command Line Tools、[Homebrew](https://brew.sh)。

```bash
brew install libusb
cd P1Label
./build.sh          # 产物 P1Label.app，libusb 已打包为自包含应用
```

无 Xcode 工程 / SPM —— 纯 `swiftc` 脚本构建，新增源文件需同步加入
`build.sh` 的编译列表。

## 使用

1. 启动 app，顶部设备状态卡选择 **USB** 或 **蓝牙**：
   - USB：插入打印机即连；连接失败时点 **重连** 重试；
   - 蓝牙：打印机会被自动扫描，唯一候选自动连接，多台时弹出列表手选；
     注意多数机型只允许单连接，请先断开手机打印 App 的占用。
2. 左侧编辑标签，右侧画布拖放排版（拖近其它元素出现粉色对齐标线）；
   选中元素后可修改内容、字号、位置，点选中框右上角的 **×** 删除。
3. 点右下角 **打 印**，进度显示在状态栏上方。蓝牙权限
   （NSBluetoothAlwaysUsageDescription）首次使用时系统授权。

## 纸张尺寸说明（重要）

**目前仅在一种纸张上实测通过：40 × 30 mm 模切标签（间隙 3 mm）**——即默认
文档尺寸。打印路径的所有硬件校准参数（水平校准偏移 `leftPadDots = 68`、盲发
节奏、浓度曲线）都以它标定。

- App 内可设置的尺寸范围是宽 20–48 mm、高 10–100 mm，**其他尺寸只是理论可用，
  未实测**。
- 换用其他宽度纸张时，内容可能整体水平偏移——先调打印设置里的"水平偏移"
  补偿；偏移明显异常时需要重新标定 `leftPadDots`（见 `tools/offset_test.py`）。
- 连续纸（无间隙）模式与更高/更窄纸张的页结束行为未验证。
- 欢迎实测其他纸张后反馈结果或提交校准参数。

## 项目结构

```
P1Label/
  build.sh             构建 + 自包含打包 + ad-hoc 签名
  Sources/
    LPAPI.swift        LPAPI 协议编码（线格式 [0x1F cmd EBV(len) data crc]）
    P1USB.swift        libusb USB 传输 + P1Transport 协议
    P1BLE.swift        CoreBluetooth 蓝牙传输（GATT FF00/FF02/FF01，回退 FFE0）
    LabelRenderer.swift  文档模型 + CoreText/CoreGraphics 渲染 + 光栅化
    LabelCanvas.swift  SwiftUI 交互画布（静态手势面拖拽机制，见文件头注释）
    MainWindow.swift   主窗口界面（设计稿样式：侧栏卡片 / 画布区 / 自绘控件）
    P1LabelApp.swift   App 入口 + PrintModel
tools/                 硬件校准/探测脚本与拖拽测量环境（历史产物）
```

## 协议与硬件

- 打印协议逆向自 Detong 官方 BLE SDK（lpapi-ble-uni）的线缆格式，协议为
  传输无关的纯字节流，USB 与蓝牙走同一编码。
- `tools/print_test.py` 头注释记录了完整的页数据流；`tools/probe.py`
  记录了命令表。**修改打印路径（LPAPI/P1USB/P1BLE/LabelRenderer.pagePayload）
  前请阅读 `AGENTS.md`** —— 其中的字节流节奏是对硬件验证过的设计。

## 许可

本项目代码以 [GPL-3.0-or-later](LICENSE) 发布。
第三方组件声明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
（libusb — LGPL-2.1 动态链接；lpapi-ble-uni — ISC，仅作协议来源致谢）。

## 免责声明

本项目与打印机制造商无任何关联。协议为独立逆向实现，仅用于对自己拥有的
设备实现互操作；使用本软件造成的任何后果由使用者自行承担。
