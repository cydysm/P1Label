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
- `P1Label/Sources/PaperSizes.swift` — 纸张尺寸预设目录：每尺寸一条预设（宽/高/纸型/
  间隙/`leftPadDots` 标定/`hardwareVerified`）。适配新纸张 = 在此加一条预设 → 真机标定
  `leftPadDots` → 回填该条并置 `hardwareVerified: true`，UI/渲染/拖拽上限自动跟随。
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
- **硬件验证范围：仅 40×30mm 模切纸（默认文档尺寸）**。其他纸张尺寸（UI 允许
  20–48mm 宽）从未实测；`leftPadDots=68` 是按该纸张标定的水平校准，勿假设
  全尺寸通用。用户报"其他纸打偏/打不全"时先查这里。
- `build.sh` 构建并签名 app；改完 Swift 代码后用它验证编译，再让用户真机确认。
  swiftc 命令**显式列出全部 .swift 源文件**，新增源文件必须同步加入，否则不会被编译。
- 本项目以 GPL-3.0-or-later 开源：新增源文件照抄现有文件的 GPL 许可头；
  第三方组件/致谢记录在 `THIRD-PARTY-NOTICES.md`，勿静态链接 libusb。

---

## Git 工作流规则

本仓库的 Git 工作流规则。所有 agent 必须遵守，除非用户在当次对话中明确覆盖。

### 0. 动手前自检

在执行任何 `git commit` / `git push` 之前，确认：

- [ ] 当前分支不是 `main`
- [ ] 分支名符合 `<type>/<short-desc>` 规范
- [ ] 已从最新 `main` 切出
- [ ] 提交信息符合 Conventional Commits
- [ ] 没有未跟踪的敏感文件（.env、密钥、本地配置）

任何一项不满足，先修正再继续。

### 1. 绝对禁止

- 禁止直接 `git push origin main`
- 禁止在本地 `main` 上 commit 后 push
- 禁止为了推小改动临时关闭或绕过 main 分支保护
- 禁止 `git push --force` / `--force-with-lease` 到 `main`
- 禁止合并后保留源分支（本地和远程都要删）
- 禁止把不相关改动混进同一个 PR
- 禁止在未跑通 CI/测试的情况下合并

遇到"推不上去"，正确反应是**转到新分支走 PR**，不是关保护。

### 2. 开始任何改动

```bash
git switch main
git pull --ff-only
git switch -c <type>/<short-desc>
```

分支类型：

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 修 bug |
| `docs` | 文档 |
| `refactor` | 重构，不改行为 |
| `test` | 测试 |
| `chore` | 构建、依赖、杂项 |
| `perf` | 性能 |

命名示例：`fix/auth-timeout`、`docs/readme-typo`、`feat/export-csv`。

分支名只描述范围，不预测大小。事后发现是小修复，不需要改名。

### 3. 提交信息

Conventional Commits：

```
<type>(<scope>): <subject>
```

- subject 用祈使句、小写开头、不加句号
- 一个 commit 只做一件事
- 合并时默认 Squash，main 上一个 PR 一个 commit

### 4. 推送与合并

```bash
git push -u origin <branch>
```

然后在 GitHub/GitLab 开 PR：

1. 标题清晰，关联 issue（如有）
2. 等 CI 通过
3. **Squash merge**
4. 合并后删除远程分支（平台设置自动删）
5. 本地清理：

```bash
git switch main
git pull --ff-only
git branch -D <branch>   # squash 后 -d 会报 not fully merged，确认 PR 已合并后用 -D
```

### 5. 已经在本地 main 上改了怎么办

**未 commit：**

```bash
git switch -c <type>/<short-desc>
# 改动会跟着带到新分支
```

**已 commit：**

```bash
git branch <type>/<short-desc>
git reset --hard origin/main
git push -u origin <type>/<short-desc>
```

**已经本地 merge 了一堆：**

```bash
git branch <type>/<short-desc>
git reset --hard origin/main
git push -u origin <type>/<short-desc>
```

然后开 PR。混了不相关改动就拆分支；个人项目可接受一个批次 PR，但标题写清楚。

执行 `reset --hard` 前必须确认没有未提交改动，先 `git status`。

### 6. 分支清理

已合并分支立即删。定期执行：

```bash
git fetch --prune
git branch --merged main
git branch -d <branch>          # 普通 merge 用 -d
git branch -D <branch>          # squash merge 后用 -D
git push origin --delete <branch>
```

判断可删：

- 已合并进 main
- PR 已关闭且不继续
- 超过 30 天无活动
- 实验分支，结论已转 issue/PR

长期保留只允许：`main`、`release/*`、`gh-pages` 等明确用途分支。

### 7. 分支太多

- 同主题小修合并到一个分支/PR，不要一个 typo 一个分支
- 文档/格式类改动攒成 `docs/cleanup` 批次
- 不做的分支：先在 issue 里留结论，再删
- 远程只保留"有打开 PR"的分支
- 每月清理一次

不要为了整理历史去 rebase 一堆旧分支，个人项目收益低。

### 8. 合并策略

- 默认 **Squash merge**
- main 历史保持线性，一个 PR 一个 commit
- 大功能要保留提交粒度时，可在 PR 中说明改用 Rebase merge，但需用户确认
- 不使用 Merge commit，除非用户明确要求

### 9. 紧急例外

唯一允许绕过 PR 的情况：线上事故且无法等待 CI。

流程：

1. 先告知用户，说明为什么不能走 PR
2. 建 `hotfix/<desc>` 分支
3. 最小改动 + 最快验证
4. 推分支，开 PR，标记 urgent
5. 合并后补 issue 记录
6. 不允许直接推 main，不允许关保护

### 10. 给 agent 的行为约束

- 不要自作主张改分支策略
- 不要为了"省事"直接操作 main
- 执行破坏性命令（`reset --hard`、`branch -D`、`push --delete`）前先 `git status` 并说明影响
- 不确定时先问用户，不要猜
- 每次完成任务后报告：分支名、commit、PR 链接、是否已清理
