# 第三方组件声明 (Third-Party Notices)

本项目的原创代码以 GPL-3.0-or-later 发布（见 `LICENSE`）。它依赖/参考以下第三方组件：

## libusb — GNU Lesser General Public License v2.1 (LGPL-2.1)

- 用途：USB 传输（`P1Label/Sources/P1USB.swift` 通过 C 模块桥接调用）。
- 链接方式：**动态链接**。构建脚本将 `libusb-1.0.0.dylib` 打包进
  `P1Label.app/Contents/Frameworks/`，未做任何静态链接。
- 源码：https://github.com/libusb/libusb
- 许可：https://github.com/libusb/libusb/blob/master/COPYING

依据 LGPL-2.1 第 4/6 条，你可以将本应用中的 libusb 动态库替换为你自行构建的
兼容版本（例如加入 `--enable-debug-log` 重新编译），替换方式为覆盖
`P1Label.app/Contents/Frameworks/libusb-1.0.0.dylib` 后重新签名。

## lpapi-ble-uni (DothanTech) — ISC License

- 用途：打印线缆协议（LPAPI）的**参考实现**。本项目的 `LPAPI.swift` 及
  `P1BLE.swift` 是对协议格式的独立逆向实现，未复制其代码；协议线格式本身
  不受版权保护，此处仅作来源致谢。
- 包页：https://www.npmjs.com/package/lpapi-ble-uni
- 许可：npm 包 `package.json` 声明 `license: "ISC"`（作者 DothanTech），
  包内未附带许可全文。ISC 许可与 MIT 等价（宽松许可），标准文本如下：

```
ISC License

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
```

## Apple 系统框架

CoreBluetooth、SwiftUI、CoreGraphics/CoreText 等随 macOS 系统分发，无需单独声明。
