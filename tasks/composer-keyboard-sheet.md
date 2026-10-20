# Composer 键盘替换面板 — 2026-10-20

## 范围与基线

- 产品方根据两张照片确认：Editing 且屏幕键盘已显示时，点击 `+` 让键盘下沉并由等高液态玻璃面板接替，入口顺时针旋转 45° 成为关闭按钮。
- 一级选项顺序为模型、思考、插件、图片、文件；图标统一灰色圆底，行距宽松。原悬浮菜单的推理强度文案同步改为思考。
- 关闭不自动弹键盘；点输入区重新唤回键盘。保留编辑器、草稿、选区和当前模型配置所有权。
- 键盘隐藏时保留已验收的原悬浮菜单动效。最初保留其余四项禁用；后续产品方明确要求思考接入真实请求，见 `composer-thinking-request-plan.md`。插件、图片、文件仍保持原门控。
- 生产代码基线：`ce40a7d81a4f4536313ab88a2625fc0a34631382`，源分支 `codex/restore-ui-polish-20261018`；本次分支 `codex/composer-keyboard-sheet-20261020`。
- 上游意图：Blueprint `ca5ffd514e75935174a66205439a44a0c6d3ef1d`，同名分支，未合并 main。

## 所有权与退出

- Composer 保持原有 Draft / 编辑器身份；原生宿主只协调菜单占据的底部空间、原生焦点与入口图标。
- 新面板的呈现所有者负责玻璃、布局、模型子层和动画完成清理；不改变原悬浮菜单的动效函数。
- 打开前读取当前窗口实际键盘遮挡范围，包含底部安全区；不写死键盘高度。较矮键盘与大字号允许滚动。
- 键盘失焦交接面板时保留 Editing 布局；普通 SwiftUI 配置刷新不得再次弹键盘。明确点按输入区才恢复原生焦点。
- 再次点 `+`、背景退出、Workspace 输入抑制、宿主卸载、窗口尺寸变化都须释放菜单与保留空间。动画中反向操作也须只完成一次清理。
- marked text 不通过替换编辑器或写回旧文本处理；原生失焦提交后仍从同一编辑器报告最终文本及选区。

## 验证

- 回归先行提交：`43e719e`；[RED run 39405618475](https://github.com/54zhien/Zen-Agent/actions/runs/39405618475) 完成 XcodeGen 和构建，真实 UI 测试在键盘未退出（41 行）及底部面板未出现（44 行）两条断言失败；1 项测试、2 项失败。未重跑或覆盖此记录。
- 回归覆盖真实屏幕键盘退出、等高面板、输入框位置、五项顺序、关闭不重弹、点输入区唤回、草稿保留、模型选择和返回。
- CI XcodeGen、构建与回归结果须按实际 SHA 记录；模拟器与构建不替代液态材质、动画和手感的实机验收。

### 首版与审查

- 首版源码 `ae4c0e2` 的 [专项运行 39407634150](https://github.com/54zhien/Zen-Agent/actions/runs/39407634150) 完成构建；键盘退出断言通过，但一级面板及 sheet 元素未出现，测试失败。导出 AX 层级已显示入口恢复「更多操作」，说明面板实际关闭，不能称为单纯 AX 识别问题。
- 独立审查指出面板只保留了原生 Composer 位置，未将窗口面板与时间线实际视口的交叠计入内容留白。Single 时间线跨到底部安全区，Split 保持键盘安全视口，不能直接向基础 Composer 高度叠加原始键盘高度。
- 额外回归为 `SplitContainerUITests.testKeyboardSheetKeepsLatestMessageAboveComposerInSingleAndSplit`：实际 Single 和下方源 Split、最后一条 `Assistant response 19`、followingBottom 收敛及消息与输入框之间的屏幕坐标间距。
- 测试 fixture 显式对齐历史 seed 的 `preview-unavailable-instance` / `preview-model`，只在 `ZEN_KEYBOARD_MENU_UI_TEST` 标记下启用真实 FakeProvider 目标。`39409072459` 与 `39409331217` 被后继测试 fixture／关闭路径日志提交替代而取消；均不是行为 RED 或 GREEN。
- 关闭路径诊断保留于独立分支 `codex/composer-sheet-occlusion-red-20261020`，`bab4f57` / `39409646340`，不把临时诊断作为最终产品逻辑。

### SF 图标追加要求

- 产品方指定两套菜单及模型二级标题同步改用 `theatermasks`、`tachometer`、逆时针 45° 的 `powercord`、`photo.on.rectangle.angled`、`paperclip`。
- 六档仪表为低、中、高、极高、Max、Ultra，分别推进总弧长的 1/6 至 6/6；指针左侧实线、右侧灰色等距圆点。最初追加要求只含图标；后续确认解除思考禁用并接真实请求，按各模型声明的可用档位选择。
- [SF 原始符号测量 39410388169](https://github.com/54zhien/Zen-Agent/actions/runs/39410388169) 在 macOS 使用实际 AppKit/SF Symbols 导出五个符号，均存在。`tachometer` 的六个 variableValue PNG SHA-256 完全一致（`836DD7E32A04197E10894396DCBE7F6577DCA5002D7DEE615BCFD40EF1CF2A0C`），不能依赖该参数旋转指针；采用保留 SF 中央指针、旋转并配合弧线／圆点的呈现。
- 最终专项范围包含完整 `ZenAgentTests`、ComposerMotion 两项、最新消息遮挡和共享 Dock 换窗回归，并执行实际 iPad axis；同时导出六档浅色／深色预览用于像素检查。旧全量 CI 与专项结果分别记录，不将 profile 中的 skipped job 算作通过。

### 面板关闭路径的实证

- [旧 xcresult 诊断导出 39413487745](https://github.com/54zhien/Zen-Agent/actions/runs/39413487745) 未重建或重跑测试，直接解出已保留的 `39409646340` 原始诊断。
- `StandardOutputAndStandardError-com.zhien.zen.txt` 在两项失败用例均记录首次关闭源为 `textViewShouldBeginEditing(_:)`，随后重复询问；当时 view、installed 和 window 都是 402×874，排除这次失败由窗口尺寸守卫引发。
- 修复将 UIKit 焦点许可询问与用户显式输入交互区分：面板保留期间拒绝自动重新开始编辑；编辑器触摸及 AX activation 才允许恢复键盘。保留同一个 UITextView 的子类实例，未重建编辑器或草稿。
- 窗口尺寸／失活的关闭守卫保留；临时 print 诊断不进入最终生产源码。等高与输入框、Single/Split 最新消息位置仍由真实 UI 回归验证。

- 首版全量 [39407633152](https://github.com/54zhien/Zen-Agent/actions/runs/39407633152) 的 XcodeGen、构建和 iPad axis 成功；Phone 全量已有 Composer、Files、Settings、Sidebar 及分屏相关失败，并输出 TEST FAILED，整体最终 cancelled，不能算全量通过。保留所有原记录，不将专项结果替代全量验收。

### 原生回归第二轮

- `72366cf` / [39416463321](https://github.com/54zhien/Zen-Agent/actions/runs/39416463321) 与 `a02ffb9` / [39417163812](https://github.com/54zhien/Zen-Agent/actions/runs/39417163812) 均真实构建后失败，保留结果，不算 GREEN。后者 iPad axis 通过；思考六档选择、三/四档切换与共享 Dock 焦点回归通过。
- 后者 Single/Split 最后一条消息被 Composer 遮挡：native bounds 分别高 874 / 434，bottom inset 却都只有 335（sheet），缺少 Composer 自身约 136。SwiftUI 内层 proxy 已扣除 safe-area inset，不能作为原生外框；改复用现有 native viewport 绑定，将 UIScrollView.bounds 转到 UIWindow，保留 base + overlay overlap。增加 offset 不影响窗口外框的单测，最新消息的屏幕位置断言不放宽。
- 高度断言原来读 AX Keyboard 的局部 233；native guide 顶边 539、window 底边 874 与实际 sheet 335 一致，输入框位置断言已通过。改用打开前的 native guide + window 测完整占用高度，未降低实际 sheet 高度。
- 原生容器 accessibilityElementsHidden 未屏蔽 SwiftUI 根层“思考”按钮；子层与根层重复。两套菜单通过观察到的 activeLevel 在 SwiftUI 层隐藏非活动 AX 子树，保留视觉动画，并断言同名按钮只有一个。
- 完整单测 1138 项仅旧 Lift 诊断断言失败：期望显示横移等于原始 42pt，但 10/19 已引入边界阻尼（3191c69 / d41b4afe），旧基线源码亦如此，实测显示 1.84845pt。仅将 transport 诊断改成方向为正且小于原始拖距；保留纵轴与 progress 断言，精确几何及屏幕边界仍由 SurfaceLiftGeometryTests 覆盖。
- 已检查 a02ffb9 导出的六档浅/深色原生 PNG 与五行面板：图标均匀圆底、SF 指针随等级推进、剩余灰点等距；尚待修复后同 SHA 构建与 UI 回归。
