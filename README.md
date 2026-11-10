# CardRelicForge · 杀戮尖塔 2 卡牌 / 遗物效果制作器

**先古之民对话更新（2026-10-22）**：在「能力/角色库」的角色旁点击「先古之民对话」，编辑全部 9 位（含建筑师）的首次与重复台词，保存后可重新读取并随模组导出。另补充了达弗的尘封魔典奖励配置。使用方法见 [ANCIENT_DIALOGUES.md](ANCIENT_DIALOGUES.md)。

**独立角色更新（2026-10-20）**：新建角色与自制模型角色不再继承五个原版角色的机制和专属内容，基础充能球栏位为 0，不默认显示星星。使用独立能量界面、自己的初始牌组和两个池；可先保存草稿再补齐卡牌。更新后需重启制作器、重新导出编译并开新的一局验证，旧对局仍会保存旧球位。详见 [CHARACTER_MODELS.md](CHARACTER_MODELS.md)。

**自制角色模型（2026-10-20）**：角色设置支持导入独立 Godot 场景、战斗动画、头像和选角图片，素材随角色保存并自动打包。使用说明见 [CHARACTER_MODELS.md](CHARACTER_MODELS.md)。打开 `designs/CustomModelExample.json` 可体验「锻造木偶」，可编辑模型工程在 `resources/character_models/ForgePuppet`，已编译示例在 `exports/ForgeCustomModelExample`。

**自定义可选角色扩展（2026-10-19）**：已补齐角色模型、RitsuLib 注册、角色本地化、起始牌组/遗物及持久化设置。使用说明见 [CHARACTER_EXTENSION.md](CHARACTER_EXTENSION.md)。可通过工具打开 `designs/CharacterExample.json` 体验独立示例，编译好的示例位于 `exports/ForgeCharacterExample`。

**状态效果与角色管理更新**：修复“我无敌了”的虚弱效果，阻止抽象状态中断打牌；「能力 / 角色库」新增「初始牌组」（原版卡、自制卡、张数、持久化）和「删除角色及池」（保留内容并转入模板池，可撤销）。完整自定义初始牌组覆盖模板及旧开局注入，保存后重开即可继续编辑。

一个**独立窗口程序**：打开就能用，不需要 Godot 编辑器、不需要装插件。  
你可以在这里搭出卡牌与遗物的效果，程序直接把它导出成一个**可编译、可进游戏**的 Mod。

---

## 一、怎么启动

双击 **`run.cmd`** 即可。

> **为什么不是 `run.ps1`？** Windows 默认的执行策略是 `Restricted`（`LocalMachine` 作用域），>   
> 会直接禁止运行任何 `.ps1`，报 `SecurityError / UnauthorizedAccess / 禁止运行脚本`。>   
> 所以 `run.cmd` 现在是**纯批处理**：不读 PowerShell、不碰任何系统设置，>   
> 双击就能开。如果你更喜欢 PowerShell，也可以手动跑>   
> `powershell -ExecutionPolicy Bypass -File run.ps1`。

启动器会自动找到同目录 / 上级目录里的 Godot 4.5.1 mono 引擎并启动本程序。  
找不到时才会去看 `forge-paths.txt`（可选覆盖文件）：

```
godot=E:\你的路径\Godot_v4.5.1-stable_mono_win64.exe
```

> ⚠️ 请填**完整的引擎主程序**（约 160 MB 的那个 `Godot_v4.5.1-stable_mono_win64.exe`），  
> **不要**填旁边那个 `..._console.exe`。后者只有 200 KB 左右，只是个转发壳。  
> 两个启动器都会自动把 `_console.exe` 纠正成主程序。
>
> ⚠️ `forge-paths.txt` 请保持**纯 ASCII**：`run.cmd` 是用批处理读它的，>   
> 而批处理对 UTF-8 / 中文路径不可靠。默认情况下压根不需要这个文件。

> 说明：本程序本身也是一个 Godot「运行时工程」，所以需要那个引擎来跑；  
> 但它**不会**打开编辑器界面，对你的游戏工程没有任何影响。

### 从 GitHub 下载后提示找不到 Godot

GitHub 下载包不包含 Godot 引擎。把项目解压到任意目录后，如果电脑上已有 Godot 4.5.1 **.NET / Mono** 版本：

1. 在文本编辑器中打开项目目录里的 `forge-paths.txt`。
2. 添加一行 `godot=`，后面填实际的 Godot **.NET / Mono 主程序**完整路径，例如：
   ```text
   godot=C:\Godot\Godot_v4.5.1-stable_mono_win64.exe
   ```
3. 保存并再次双击 `run.cmd`。

路径必须是 ASCII 字符；如果 Godot 安装目录含中文，请把 Godot 移到纯英文路径（如 `C:\Godot`），或将 Godot 文件夹放在 `CardRelicForge` 同级目录，让启动器自动查找。必须使用带 .NET / Mono 的 4.5.1 版本，普通标准版不能运行此工具。无需把 Godot 上传到 GitHub。

### 启动失败排查

| 现象                                                                          | 原因                                            | 处理                                                                                                                    |
| --------------------------------------------------------------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `SecurityError` / `UnauthorizedAccess` / `禁止运行脚本`                           | 系统执行策略是 `Restricted`（Windows 默认），禁止跑 `.ps1`   | 已修复：改用纯批处理的 `run.cmd`。或手动 `powershell -ExecutionPolicy Bypass -File run.ps1`。**不要去改系统执行策略**                           |
| 提示「无法加载」/ `.NET: Failed to load project assembly`                           | 工程声明了 `project/assembly_name` 但没有对应的 C# 程序集   | 已修复：自带 `CardRelicForge.csproj` + `cs/ForgeBootstrap.cs`。若删过就恢复，再跑 `dotnet build CardRelicForge.csproj -c Debug`       |
| 窗口一闪就没了                                                                     | 引擎路径指向了 200 KB 的 `_console.exe` 壳             | 已修复：启动器自动纠正；或手填主程序路径                                                                                                  |
| `无法将"REM"项识别为 cmdlet`                                                       | `.ps1` 里用了 `REM` 注释（那是批处理写法，PowerShell 用 `#`） | 已修复；自己改脚本时注释一律用 `#`                                                                                                   |
| 路径里的中文变成乱码（如 `天马行空` → `澶╅┈琛岀┖`）                                             | PowerShell / 批处理按 ANSI/OEM 码页读文件              | 已修复：路径一律从 `%~dp0` 推导，不靠读文件；`run.ps1` 读 `forge-paths.txt` 时显式指定 UTF-8                                                  |
| `run.cmd` 报「系统找不到指定的路径」                                                     | `forge-paths.txt` 里有非 ASCII 路径被批处理读乱          | 让文件保持纯 ASCII，或删掉覆盖行走自动探测                                                                                              |
| 找不到 dotnet                                                                  | 机器没装 .NET SDK                                 | 装 .NET SDK 9；只影响「导出后编译」和程序集构建，不影响界面                                                                                   |
| 改字段时刷屏 `Parent node is busy setting up children`、`add_child() failed`，或直接闪退 | 编辑控件在信号回调里内联重建了整栏界面，而此时引擎正处在子节点构建阶段           | 已修复：所有重建改为帧末延迟执行（`schedule_rebuild()` + 同帧合并）。若你自己加了新控件，**不要**在它的信号回调里直接调 `_build_editor()` 等，改调 `schedule_rebuild()` |
| `Object was freed while a signal is being emitted from it`                  | 在信号发射过程中用 `free()` 释放了发信号的控件                  | 已修复：清空列用 `queue_free()`。自己写清理逻辑时别用 `free()`                                                                           |

### 导出后进游戏不生效排查

| 现象                                                                                                                                                                | 原因                                                                                            | 处理                                                                |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| mod 在列表里显示「已加载」，但进游戏**一张卡都没有**；日志里有 `[ERROR] Mod manifest for mod <id> declares that it should load an assembly, but no assembly at path ...\<id>.dll was found!` | 只把 `exports/<ModId>/` 文件夹拷进了 `mods/`，**没有先编译**。此时文件夹里只有 `<id>.json` + `<id>.pck`，缺 `<id>.dll` | **已改进**：导出时会在根目录留 `!!! 先编译再安装 !!!.txt`，报告与界面也会警告。正确做法见下           |
| 同上                                                                                                                                                                | `.pck` 只能装本地化与素材，**不能定义卡牌/遗物**。卡牌是 C# 类，必须编进 `<id>.dll`                                       | 先跑 `build.cmd` 生成 `<id>.dll`，再把**整个文件夹**（含 dll）拷到 `mods/<ModId>/` |

> ⚠️ 重要：游戏对「缺 dll」**不报致命错**——它照常加载 `.pck`，把 mod 标成>   
> `Loaded`，只在日志里留一行 `[ERROR] … no assembly … was found!`。>   
> 所以症状是「mod 看起来装上了，但什么都没发生」，而不是崩溃。>   
> 排查第一站永远是 `%APPDATA%\SlayTheSpire2\logs\godot*.log`：>   
> 正常应有 `[INFO] Loading assembly DLL …\<id>.dll` 与>   
> `[INFO] Finished mod initialization for '<名字>' (<id>)`。

| 现象                                                                                                                  | 原因                                                                                 | 处理                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 卡牌名字显示成 `XXX.title` 这样的原始键名                                                                                         | `.pck` 里的本地化键与卡牌类名推导出的 `Slugify(类名)` 不一致                                           | 卡牌 ID = `Slugify(类名)`（`NinefoldStrike` → `NINEFOLD_STRIKE`），本地化键为 `<ENTRY>.title` / `<ENTRY>.description`；两者必须对上                                                            |
| 读卡池时抛异常 / 卡牌到处都搜不到                                                                                                  | 忘了 `ModHelper.AddModelToPool<对应CardPool, T>()`                                     | 导出的 `ModEntry.cs` 已自动生成；手写时要显式注册                                                                                                                                            |
| 编译报 `CS0029`（无法隐式转换为 `DynamicVarSet`）+ `CS0103`，位置在卡牌源码的 `for (int i = 0; i < base.DynamicVars..IntValue; i++)` 这一行 | 循环方式选了「按变量」，但**没有选具体变量**（`loop.var` 是空串）。空名字会生成 `DynamicVars..IntValue` —— 一个空成员访问 | **已修复**：① 现在切到「按变量」会自动选中一个已声明的变量；② 若一个变量都没声明，下拉框会显示「（请先在上方添加数值）」；③ 预检会把它判为**错误**并阻止导出；④ 生成器兜底，绝不会再写出 `DynamicVars..`。正确做法：先在上方「数值」区添加一个变量（如 `Repeat` / `RepeatVar`），再在循环里选它 |
| 编译报 `CS1061`（找不到 `IntValue` 成员），循环引用的是自己没声明的变量名                                                                     | 循环变量指向了一个不存在的数值                                                                    | 同上：预检会报错，先去「数值」区添加同名变量                                                                                                                                                      |

---

## 二、界面长什么样

左边一列 / 中间编辑器 / 右边预览诊断栏：

| 区域 | 作用                                                                                        |
| -- | ----------------------------------------------------------------------------------------- |
| 左栏 | 你做的卡牌与遗物列表（带错误角标）、Mod 信息（ID / 名称 / 作者 / 版本）                                               |
| 中栏 | 选中内容后的全部编辑区：① 标识 ② 文字（顶部直接显示「游戏要的本地化键」，并实时检查占位符 / 格式化器） ③ 属性 ④ 动态变量 ⑤ 效果/触发时机 ⑥ 升级 ⑦ 开局注入 |
| 右栏 | 卡面预览（自动渲染描述）、数值估算、校验列表、**导出为 Mod** 面板                                                     |

首次启动会自动扫描解包数据，并载入一份示例内容（**九重打击** / **铁壁护符**），  
你可以直接改，也可以点「＋ 卡牌 / ＋ 遗物」从零开始。

---

## 三、支持的效果范围

**基础效果**（⑤ 效果）  
`damage` 伤害（含多段） · `damage_direct` 无视格挡的伤害 · `block` 格挡 · `heal` 治疗 ·  
`gain_max_hp` 提升生命上限 · `energy` 能量 · `star` 星能 · `draw` 抽牌 · `discard` 弃牌 ·  
`exhaust` 消耗 · `upgrade_card` 升级牌 · `generate_card` 生成卡 · `apply_power` 施加 Buff/Debuff ·  
`add_keyword` 加关键字 · `gain_gold` 获得金币 · `forge` 锻造

每个效果都能单独设置：

- **目标**：卡牌自身 / 自己 / 全体敌人 / 随机敌人 / 全体友军
- **数值**：直接填数字，或绑定到④里的动态变量
- **段数**：多段攻击
- **循环**：按变量循环 / 按次数循环（例如「打 9 段」= 循环 `Repeat` 次）
- **条件**：满足表达式才执行（左值 运算符 右值）
- **ValueProp / Power / 关键字 / 生成哪张牌**：全部从解包数据里动态列出来

**遗物触发时机**（⑤ 触发时机）  
时机列表直接来自游戏 `AbstractModel` 的 183 个可覆写钩子（如 `BeforeCombatStart`、  
`AfterPlayerTurnStart`…），每个触发点还能设置**触发方式**：总是 / 每回合首次 / 每回合第 N 次 / 计数叠加。

**Buff / Debuff 与关键字**  
241 个游戏内 Power（含是否属于 Debuff；另有 15 个游戏自带的**测试替身** `Mock*Power` 已从选择器里排除，  
Retain / Sly / Eternal）都是下拉选择，不需要记类名。

**开局牌组 / 开局遗物**  
⑦ 栏勾选「启用开局注入」→ 选角色 → 设份数。导出时会自动生成一个 Harmony 补丁，  
把这张牌塞进该角色的起始牌组，或让该角色开局就带着这件遗物。

---

## 四、导出之后怎么进游戏

点右栏 **「预检」** 看有没有错误，再点 **「导出 Mod」**。  
还有一个 **「编译验证（dotnet build）」** 按钮：它会就地调 `dotnet build`，  
用**真实的游戏程序集** `sts2.dll` 检查你生成的东西能不能编过 —— 这是唯一能发现  
「程序集路径写错 / 少 import 命名空间 / 覆写签名不对」这类问题的手段。  
导出的目录结构如下（`<ModId>` 就是你在左栏填的 ID）：

```
<导出目录>/<ModId>/
├─ <ModId>.json          ← mod 清单（id / name / has_dll / has_pck …）
├─ <ModId>.dll           ← build.ps1 编译后产生，必须和 json 同级
├─ <ModId>.pck           ← 本地化与素材（本工具直接按 Godot 格式写出）
├─ build.ps1 / build.cmd ← 一键编译
├─ forge-paths.txt       ← 游戏与引擎路径（build.ps1 读它，所以脚本本身是纯 ASCII）
├─ src/                  ← ModEntry.cs + 每张牌 / 每件遗物一个 .cs + .csproj
├─ assets/               ← 各语言本地化 json
├─ lib/<版本>/           ← 兼容性标记
└─ README.md / EXPORT_REPORT.md
```

进游戏只差两步：

1. **编译** —— 双击导出目录里的 `build.ps1`（需要 .NET SDK 9）。  
   产物在 `src/.godot/mono/temp/bin/Release/<ModId>.dll`。
2. **安装** —— 把 `<ModId>.dll`、`<ModId>.pck`、`<ModId>.json` 三个文件一起  
   复制到游戏 exe 同级的 `mods/` 目录（可以放子文件夹里），启动游戏即可。

---

## 五、为什么必须编译成 dll

游戏的 `ReflectionHelper.GetSubtypesInMods<AbstractModel>()` **只枚举已加载的 mod 程序集**，  
纯数据（只有 .pck）加不进卡牌。所以本工具的产物**同时**包含：

- `<ModId>.dll` —— 卡牌 / 遗物类（编译进去的）
- `<ModId>.pck` —— 本地化文案与素材（引擎直接读的）

`.pck` 由 `core/pck_writer.gd` 按 Godot 的 GDPC 格式手写生成，已在自检里用  
`ProjectSettings.load_resource_pack()` 验证过能被引擎正常加载。

---

## 六、目录说明（想改代码时看这里）

```
CardRelicForge/
├─ project.godot          运行时工程配置（main_scene = scenes/main.tscn）
├─ CardRelicForge.csproj  占位 C# 工程：只为满足 mono 引擎的程序集探测
├─ cs/ForgeBootstrap.cs   上面那个工程里唯一的（空壳）源文件
├─ forge-paths.txt        引擎 / userdir 路径（脚本按 UTF-8 读，勿加 BOM）
├─ run.cmd / run.ps1      启动器（纯 ASCII，PowerShell 5.1 兼容）
├─ scenes/main.tscn       唯一场景：一个挂着 ui/app.gd 的 Control
├─ ui/
│  ├─ app.gd              整个窗口：工具栏、三栏、各编辑区、预览、导出面板
│  └─ widgets.gd          自绘主题与小部件工厂（独立运行，不继承编辑器主题）
├─ core/
│  ├─ paths.gd            路径与设置（自动探测解包目录 / 引擎 / 游戏 / Harmony）
│  ├─ ids.gd              类名 / Entry / 本地化键 的命名规则
│  ├─ schema.gd           扫描结果的容器与索引
│  ├─ schema_scanner.gd   正则扫描 src/Core + localization，反推枚举/卡池/钩子/命令…
│  ├─ design.gd           卡牌与遗物的数据结构、校验、描述渲染
│  ├─ effect_engine.gd    16 种效果的参数定义、目标解析与 C# 代码生成
│  ├─ design_db.gd        设计库（增删改 + 撤销重做 + 存读 json）
│  ├─ exporter.gd         预检与导出（manifest / pck / C# / csproj / 构建脚本）
│  └─ pck_writer.gd       Godot .pck 写入与回读校验
├─ tools/
│  ├─ selftest.gd         核心层自检（169 项，含效果×目标矩阵 / 全 Power 矩阵 / 循环变量守卫 / 占位符校验 / 素材路径回归）
│  ├─ uitest.gd           界面自检（184 项，含真实导出、启动器健康检查、重建时序、输入防抖、本地化键提示）
│  ├─ compiletest.gd      真编译器验证：所有效果 × 目标 × Buff 导出成 mod 后跑 dotnet build（需装好游戏 + dotnet）
│  └─ screenshot.gd       离屏渲染一张界面截图，便于确认布局
├─ designs/               你的设计文件（.json）
├─ exports/               导出产物
└─ resources/settings.cfg 上次的路径与偏好
```

---

## 七、自检

```powershell
# 核心层：命名规则 / pck 读写 / 扫描 / 校验 / 描述渲染 / 完整导出
GODOT --headless --path . --script res://tools/selftest.gd

# 界面层：三栏布局 / 列表 / 编辑器各区块 / 预览 / 校验 / 点「导出」的真实产物 /
# 开局注入补丁 / 存取往返 / 启动器健康检查（默认跳过真实编译，几秒跑完）
GODOT --headless --path . --script res://tools/uitest.gd
```

两项都应以 `===== PASSED =====` 结束（当前 169 + 184 项）。

界面自检会驱动真实的「导出 Mod」按钮，而导出会把 `last_export_dir` 写进 `resources/settings.cfg`；  
自检在退出前会把该文件**按原字节**写回（`_finish`），所以跑测试不会改掉你自己的导出路径。

界面自检里的**启动器健康检查**专门盯「双击能不能开起来」这类问题：  
`run.cmd` / `run.ps1` / `forge-paths.txt` 是否纯 ASCII 无 BOM、`.cmd` 是否 CRLF、  
若走 PowerShell 是否带 `ExecutionPolicy Bypass`、`.ps1` 是否误用 `REM` 注释、  
是否从 `%~dp0` 推导路径、是否会自动纠正 `_console.exe` 壳、  
占位 C# 工程是否排除了 `exports/`。这些坑都真实踩过，所以固化成断言。

**重建时序检查**则盯另一类问题：改动编辑器里的字段会触发整栏重建，如果重建  
内联执行，Godot 会报 `Parent node is busy setting up children`（实测会直接崩溃）。  
自检里用一个 `child_entered_tree` 探针，在**引擎的子节点构建阶段**改写字段，  
确认：① 回调确实被触发（否则断言是空的）② 进程不崩。

想连**真实 `dotnet build`** 一起验证（约 15 秒，能编译出 dll）：

```powershell
$env:FORGE_VERIFY_BUILD = "1"
GODOT --headless --path . --script res://tools/uitest.gd
```

`FORGE_VERIFY_BUILD` 只编译**一张示例卡**。要把**所有**效果、**所有**目标、**所有** Buff 一次性真编一遍：

```powershell
# 真编译器全量验证（约 30 秒；需要装好游戏与 dotnet）
GODOT --headless --path . --script res://tools/compiletest.gd
```

它把 16 种效果 × 5 种目标、256 个 Power 的 `Apply<T>` 与 `PowerVar<T>`、一件挂满效果的  
遗物全部导出到 `exports/_compiletest/`（每次跑之前清空），再调 `dotnet build`。退出码 0 就说明  
生成的 C# 真的编得过 —— selftest / uitest 只能断言生成的**字符串**，「API 到底存不存在、重载  
对不对得上、类型解析得到吗」只有编译器能回答。

---

## 八、已知的坑（都已经在生成器里处理掉了）


| 坑                                                 | 处理方式                                                                                                        |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `[ModInitializer]` 标在方法上 → **CS0592**             | 属性是 `AttributeTargets.Class`，生成器标在**类**上                                                                    |
| `RepeatVar` 参数是 `int` 不是 `decimal`                | 生成 `new RepeatVar(9)`，不加 `m` 后缀                                                                             |
| 遗物钩子里没有 `CardPlay`                                | 生成 `cardPlay: null` 字面量，不引用不存在的变量                                                                           |
| 覆写钩子的访问修饰符必须一致                                    | 扫描时记录 `public/protected`，按原样 `override`（否则 **CS0507**）                                                      |
| **`0Harmony.dll` 不在游戏根目录**                        | 它和 `sts2.dll` 同级（在 `data_sts2_windows_x86_64/`）。csproj 用 `$(GameAssemblyDir)` 从 `sts2.dll` 反推，否则 **CS0246** |
| **`typeof(角色)` 找不到类型**                            | 角色类在 `MegaCrit.Sts2.Core.Models.Characters`，生成补丁时必须 `using` 它，否则 **CS0246**                                 |
| 只加 `[ModInitializer]` 时 ModManager 不自动 `PatchAll` | 需要改开局牌组时，生成器自己调 `Harmony.PatchAll`，并引用 `0Harmony`（`Private=false`）                                          |
| PowerShell 5.1 按 ANSI 读无 BOM 的 `.ps1`             | `build.ps1` 保证 **0 个非 ASCII 字节**，路径走 `forge-paths.txt`                                                      |
| 卡牌不进卡池 → 读 Pool 抛异常                               | 每张牌都生成 `ModHelper.AddModelToPool<对应Pool, T>()`                                                              |
| 动态变量读写必须走索引器 `base.DynamicVars["名字"]`             | 属性形式 `base.DynamicVars.名字` 读的是另一套固定键，取不到就抛 `KeyNotFoundException`；生成器一律写索引器，变量名与属性同名（如 `Weak`）也安全           |
| 描述里写错格式化器名 → 游戏里整条文字渲染成空                          | SmartFormat 找不到格式化器就抛异常，`LocManager` 会把整条字符串渲染成空（日志 `No formatter with name ... found`）；工具预检会报错并列出可用格式化器    |
| 卡面 / 遗物图在游戏里加载不到（`AtlasResourceLoader: Missing sprite ...`） | 路径必须含 `packed/` 与卡池 Title：`images/packed/card_portraits/<Pool.Title>/<entry>.png` + 对应 atlas；且 pck 里只放裸 PNG 无效，须先被 Godot 导入成 `.ctex` |
| 本地化键大小写对不上 → 卡牌名字显示成 `XXX.title`                  | 键名是 `<ENTRY>.title` / `<ENTRY>.description`，而 `ENTRY = Slugify(类名)`；工具同时推导类名与键名所以不会互相错位，手写类名时要保证大小写一致       |
| 卡池的「归属角色」读成了卡池自己的类名                               | 归属关系只写在角色文件里（`ModelDb.CardPool<IroncladCardPool>()`）；池文件里只有自己的名字，所以从前一律答成池名 —— 现在从角色侧反查                     |
| **卡牌「格挡」给了谁** | `CreatureCmd.GainBlock` 的第一个参数是**要护住的生物**，不是写死的自己：生成器按效果的「目标」解析（`self` → `base.Owner.Creature`，即打出这张牌的玩家的生物），列表目标则 `foreach` 逐个给 |
| `BlockVar` 没用自己的名字注册 | 生成 `new BlockVar("Value4", 20m, …)`；若用默认名 `Block`，读值 `DynamicVars["Value4"]` 会抛 `KeyNotFoundException` —— 格挡一点不加（用户实测） |
| 单生物命令喂 `IEnumerable<Creature>` → **CS1503** | `GainBlock` / `Heal` / `GainMaxHp` 只收**单个**生物：对全体敌人 / 全体友军生成 `foreach`（`Damage` / `Apply<T>` 才用列表重载） |
| `CardCmd.Discard / Exhaust / Upgrade` 收的是**牌**不是数量 | 旧的 `Discard(ctx, 张数, owner)` 重载根本不存在：改成「先选牌（`FromHandForDiscard` / `FromHand`）再操作」，`Upgrade` 不是 async |
| `AddGeneratedCardToCombat` 只收**一张**牌 | 拆成两步：`CombatState.CreateCard<T>(base.Owner)` → `AddGeneratedCardToCombat(牌, PileType, owner, 位置)` |
| 一张牌里两个「生成一张牌」→ **CS0128** | 每个效果分到的局部变量名唯一（`generated` / `generated_2` …），不会在同一个声明空间里重名 |
| `<T>` 里的类型没 import 命名空间 → **CS0246** | `PowerVar<T>` / `Apply<T>` 要 `Models.Powers`（游戏自带的测试替身在 `.Mocks` 子命名空间，单独 `using`，并且**不进下拉框**）；`CreateCard<T>` 要 `Models.Cards`；遗物覆写签名里的 `AttackCommand` 要 `Commands.Builders` —— 生成器按类型反查命名空间 |
| 条件的右值存成数字 → 导出中断、产出 `if ()`（**CS1525**） | 设计文件是 JSON，`String(2.0)` 会抛错：一律走 `str()`，并在载入旧设计时把条件规范成字符串 |
| 遗物里没有 `this`(CardModel) / `AddKeyword` / `CombatState` | `CardModel?` 参数传 `null`；效果里的「卡牌目标」和「附加关键字」在**预检**阶段直接报错，不会悄悄生成编不过的代码 |
| `PlayerCmd.GainGold` 第三个参数是 `wasStolenBack` | 传 `true` 等于告诉游戏「这笔钱是从小偷身上抢回来的」，不是「播个动画」；生成器不传第三个参数 |

