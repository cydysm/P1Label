# LabelPrinter 项目经验

本文件是给未来 agent 会话的项目记忆。改代码前先读这里。

## 架构速查

- `P1Label/Sources/LabelCanvas.swift` — 交互画布。文件头注释解释了拖拽机制，**改拖拽相关代码前必读**。
- `P1Label/Sources/LPAPI.swift` — 打印协议编码（逆向自 Detong lpapi-ble-uni SDK）。
- `P1Label/Sources/P1USB.swift` — libusb 传输。`sendPage` 的盲发节奏是对硬件验证过的设计，勿改。
- `P1Label/Sources/P1BLE.swift` — CoreBluetooth 蓝牙传输（2026-11 真机验证通过），与 P1USB
  共同遵循文件内声明的 `P1Transport` 协议（同步阻塞接口，PrintModel 从 detached task 驱动）。
  要点：GATT 拓扑按 DothanTech 参考（service FF00/FF02/FF01，回退 FFE0，UUID 不中再按
  特征属性兜底）；`sendPage` 保持 USB 验证的 512B/15ms 包络（GATT 写按 MTU 拆分凑满
  窗口再睡），写确认超时单次重试（页不能截断，否则打印机卡死到断电）；调参常量集中在
  文件顶部。设备选择：记住上次设备 UUID 自动直连，唯一候选自动连，多台弹菜单手选。
- `tools/*.py` — 硬件校准/探测脚本（历史产物，硬编码路径可接受）。
- `tools/drag_harness/` — 拖拽跟手率客观测量环境（2026-11 由外部 AI 构建，结论已验证）。
  原理：合成鼠标事件拖拽 + 逐帧截图 + 图像分析求"元素位移/光标位移"比率。
  实测基准：旧代码（手势宿主每帧移动）ratio 均值 0.530、逐帧两位置振荡；
  新代码（静态手势面）ratio 恒 1.000、落点零误差。详见该目录 README 与
  `results/`（analysis_*.txt、drag_log.json）。重跑方法：整个目录拷回
  `/tmp/p1harness` 后执行 `./run.sh <srcdir> <outdir>`；analyze.py 需带 numpy 的
  python3（homebrew，非 /usr/bin/python3），PNG 回退模式下结果打印到 stdout。
  注意：2026-11 起画布新增吸附对齐（`LabelCanvas.snapped`），拖拽轨迹靠近对齐线时
  元素位移会被吸附修正——重跑 harness 与历史基准对比前先考虑这一影响。

## 已踩过的坑（勿重蹈）

### 1. SwiftUI 拖拽不跟手：先查输入侧，再查渲染侧

排查顺序（按此顺序，不要跳步）：

1. **手势宿主视图在拖拽中是否每帧移动**（如 `.offset()` 跟随预览）。是 → translation
   在移动的参考系里测量，形成定点递推：
   `dx_i = round(cursorΔ/s − dx_{i−1})`，不动点 `dx = cursorΔ/2`。可观测症状（全部实测）：
   - 跟手率恒为 ~0.5（旧代码插桩均值 0.530），渲染优化治不了
   - 亚像素步长下元素在"原位/指针处"两个位置间逐帧交替，视觉融合成"残影"
     ——不是同帧画两份；松手因步数奇偶不同而"弹回"
   - 插桩实例：手仅移动 1pt，元素相邻两帧相差 60pt
   - 只把"doc 写入移到松手时"无效：振荡发生在 preview 计算本身，与写入时机无关
   修复 = 单一静态手势面 + 纸面坐标手动 hitTest（现状实现见 `LabelCanvas.swift` 头注释）。
   验证方法学：插桩记录 translation 序列求跟手率；给修复版**前置预测合格标准**
   （20 步拖拽落点 x=152, y=0）再实测比对——预测命中才是因果确认。
2. **@Published 属性在拖拽帧被反复赋值**——@Published 赋相同值也触发 objectWillChange，
   整棵视图树每帧重算。赋值前加相等性守卫。
3. **渲染成本**：静态/动态层分离（`ElementsCanvas` + `.equatable()`），每帧只画被拖元素。

教训（2026-11 P1 画布实际案例）：前两次修复（2、3）方向对但都没治好不跟手，
直到换到输入侧（1）才解决。**同一症状第二次修复无效时，必须换子系统排查，
不要在原假设上加码。**

### 2. Binding 不要捕获数组下标

`doc.elements[idx]` 闭包捕获 idx，元素删除的同一 SwiftUI 事务里控件回写 → 越界崩溃
（EXC_BREAKPOINT，崩溃帧在 binding getter/setter 闭包）。按元素 id 查找，查不到安全跳过。

### 3. 预览与打印用不同排版引擎

画布预览 = SwiftUI `Text`，打印 = CoreText（`measureText`）。换行点极端情况（CJK 长文）
可能有差异。若用户报"打出来的和预览不一样"，先查这里。

## 修改纪律

- 打印路径（`LPAPI`/`P1USB`/`P1BLE`/`LabelRenderer.pagePayload`）的字节流行为经过真机验证，
  重构时保持字节等价，改动需真机复验。
- `build.sh` 构建并签名 app；改完 Swift 代码后用它验证编译，再让用户真机确认。
- 本项目以 GPL-3.0-or-later 开源：新增源文件照抄现有文件的 GPL 许可头；
  第三方组件/致谢记录在 `THIRD-PARTY-NOTICES.md`，勿静态链接 libusb。
