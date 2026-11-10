# CardRelicForge 插件说明

2026-10-19 新增角色导出层 `core/characters.gd`：从 `CFDesignDb.custom_characters` 生成 RitsuLib 角色模型和角色本地化，由 `CFExporter` 注册角色、生成两个池、声明依赖并写入编译引用。角色设置与旧标识修复位于 `ui/app.gd`。工具本身仍以 GDScript 运行；导出包含自定义角色时依赖 RitsuLib 0.6.7，纯卡牌/遗物项目不新增此依赖。完整说明与验证边界见 [CHARACTER_EXTENSION.md](CHARACTER_EXTENSION.md)。

> 一句话概括：**它是一个用 Godot 引擎跑的独立桌面工具，把"杀戮尖塔 2"的卡牌/遗物效果可视化地搭出来，  
> 再反向生成一套完整的、能被游戏加载的 Mod 工程（C# 源码 + 清单 + .pck + 构建脚本）。**

本文覆盖三部分：**结构组成**、**运行原理**、**功能清单**，最后是**它借用/依赖的软件与组件及其在本机的实际位置**。

- 工具目录：`D:/天马行空/StS2ModTool/CardRelicForge/`
- 目标游戏：Slay the Spire 2（v0.107.1）
- 代码量：约 **12,600 行 GDScript**（14 个源文件）

---

## 一、结构组成

### 1.1 顶层文件

| 文件                      | 作用                                                                                                                                                                                                             |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `project.godot`         | Godot **运行时工程**配置。`run/main_scene = res://scenes/main.tscn`，窗口 1280×800，`stretch/mode = "disabled"`（桌面工具必须关拉伸，否则 viewport ≠ window，左栏会被切）。                                                                     |
| `scenes/main.tscn`      | 唯一场景：一个全屏锚定的 `Control`，挂 `ui/app.gd`。                                                                                                                                                                          |
| `CardRelicForge.csproj` | **占位 C# 工程**。工具本身是纯 GDScript，这个工程只为让 mono 版引擎找到"工程程序集"，否则每次启动都打印 `.NET: Failed to load project assembly`。内含 `<Compile Remove="**/*.cs" />` 与 `exports/**` 排除（否则会误编 `exports/` 下冲 `sts2.dll` 写的源码 → 一堆 CS0246）。 |
| `cs/ForgeBootstrap.cs`  | 上面那个工程里唯一的空壳源文件（只 `GD.Print` 一行）。                                                                                                                                                                              |
| `run.cmd`               | **主启动器，纯批处理**。自动探测引擎、把 `APPDATA` 重定向到 `.forge_userdata`、然后 `--path .` 启动。                                                                                                                                      |
| `run.ps1`               | 可选 PowerShell 启动器（功能相同）。                                                                                                                                                                                       |
| `forge-paths.txt`       | 可选的路径覆盖文件（引擎 / userdir），必须纯 ASCII。                                                                                                                                                                             |
| `icon.svg`              | 图标。                                                                                                                                                                                                            |

### 1.2 界面层（`ui/`）

| 文件              | 行数   | 作用                                                                                                                             |
| --------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------ |
| `ui/app.gd`     | 2533 | **整个窗口**：工具栏、三栏外壳、列表、编辑器各区、预览/诊断栏、导出面板、窗口自适应。                                                                                  |
| `ui/widgets.gd` | 559  | **自绘主题与控件工厂**（`class_name CFWidgets`）。因为工具独立运行、没有编辑器主题可继承，所有卡片/按钮/下拉/搜索框都从这里的 `StyleBoxFlat` 现搭。含全局字号缩放 `FONT_SCALE` / `fs()`。 |

### 1.3 核心层（`core/`）—— 与界面完全解耦，可被自检脚本单独驱动

| 文件                       | 行数   | 职责                                                                                                                    |
| ------------------------ | ---- | --------------------------------------------------------------------------------------------------------------------- |
| `core/paths.gd`          | 221  | 路径与设置解析：自动探测**解包数据目录 / 示例 mod / GodotSharp / 游戏安装 / 游戏程序集 / 0Harmony / dotnet**；读写 `resources/settings.cfg`。          |
| `core/ids.gd`            | 134  | 复刻游戏的命名规则（`StringHelper`）：`snake_case` / `slugify` / `unslugify` / 本地化键 / C# 标识符合法性。                                  |
| `core/schema.gd`         | 565  | **扫描结果的容器与索引**（`class_name CFSchema`）：枚举、卡池、角色、钩子、命令、Power、动态变量、本地化、游戏自带内容。                                           |
| `core/schema_scanner.gd` | 914  | **反推扫描器**：用正则扫解包 C# 源码 + 本地化 JSON，填充 `CFSchema`。                                                                      |
| `core/design.gd`         | 1079 | **卡牌/遗物的数据结构**：新建、规范化（`normalize`）、校验（`validate`）、描述渲染、素材路径推导。                                                        |
| `core/effect_engine.gd`  | 962  | **效果引擎**（`class_name CFEffects`）：16 种效果的参数定义、目标解析、绑定到游戏真实命令 API、C# 代码生成。                                              |
| `core/design_db.gd`      | 788  | **设计库**（`class_name CFDesignDb`，`Resource`）：卡牌/遗物数组、Mod 元信息、撤销重做、存读 JSON。                                             |
| `core/exporter.gd`       | 1557 | **导出器**（`class_name CFExporter`）：预检、生成 manifest / 本地化 / C# 源码 / csproj / 构建脚本 / README / 报告，并调用 `dotnet build` 做编译验证。 |
| `core/pck_writer.gd`     | 240  | **Godot `.pck` 读写器**：从 GDScript 直接按 GDPC 格式写出资源包（含回读校验）。                                                              |

### 1.4 工具层（`tools/`）

| 文件                     | 行数   | 作用                                                           |
| ---------------------- | ---- | ------------------------------------------------------------ |
| `tools/selftest.gd`    | 1133 | 核心层自检（约 170 项）：命名规则、pck 读写、扫描、校验、描述渲染、完整导出。                  |
| `tools/uitest.gd`      | 1653 | 界面回归（约 184 项）：三栏布局、各编辑区、真实点击"导出"、启动器健康检查、重建时序、输入防抖。          |
| `tools/compiletest.gd` | 215  | **真编译器全量验证**：16 效果 × 5 目标 + 256 Power 全部导出后跑 `dotnet build`。 |
| `tools/screenshot.gd`  | 52   | 离屏渲染一张界面截图，用于确认布局。                                           |

### 1.5 数据与产物目录

| 目录                 | 内容                                                  |
| ------------------ | --------------------------------------------------- |
| `designs/`         | 用户的设计文件（`main.json`），就是"当前正在编的卡组"。                  |
| `exports/`         | 导出产物（每个 mod 一个子目录）。                                 |
| `resources/`       | `settings.cfg`（上次的路径与偏好）、`schema_cache.json`（扫描缓存）。 |
| `.forge_userdata/` | 引擎的 `APPDATA` 重定向目标，保证工具不在系统盘乱写。                    |
| `.godot/`          | Godot 引擎自身生成的导入缓存。                                  |

---

## 二、运行原理

### 2.1 启动链路

```
双击 run.cmd
   └─ 从 %~dp0 推导路径（不读文件，避免批处理把中文路径读乱）
   └─ 依次探测引擎：..\Godot_v4.5.1-stable_mono_win64\...\<引擎>.exe
   └─ 探测失败才读 forge-paths.txt（要求纯 ASCII）
   └─ 若指向 *_console.exe（200 KB 转发壳）则自动纠正为真身（约 160 MB）
   └─ set APPDATA=<工具目录>\.forge_userdata
   └─ "<引擎>.exe" --path "<工具目录>."
         └─ Godot 加载 project.godot → 主场景 scenes/main.tscn
               └─ Control 节点挂上 ui/app.gd → _ready() 建整个界面
```

**关键点**：这是**运行时工程**，不是 EditorPlugin —— 不需要打开 Godot 编辑器，不装插件，对用户的游戏工程零影响。

### 2.2 数据流（整条链路）

```
 ① 解包数据（反编译的 C# 源码 + 本地化 JSON）
        │  StS2ModTool/解包文件/.godot/
        ▼
 ② CFSchemaScanner  —— 正则扫描（~3400 个 .cs，约 1 秒）
        │  · 扫 src/Core：枚举 / 卡池 / 角色 / 可覆写钩子 / 命令 API / Power / DynamicVar
        │  · 扫 localization：中文与英文标题
        │  · 收尾：卡池↔角色互链、枚举取本地化标签、Power 中文名、
        │          合成 PowerVar<具体Power>、标记可用钩子
        ▼
 ③ CFSchema  —— 反推出来的"游戏描述"（枚举 24 个访问器、256 个 Power、183 个钩子…）
        │
        ├──────────────► ④ UI 下拉框的选项全部来自这里（不硬编码任何枚举/卡池/钩子/Power）
        ▼
 ⑤ CFDesignDb（designs/main.json）—— 用户搭的卡牌/遗物
        │  · CFDesign：新建 / normalize / validate / 描述渲染
        │  · CFEffects：效果 → 绑定到真实命令 → 生成 C# 代码
        ▼
 ⑥ CFExporter —— 预检 + 生成完整 mod 工程
        │  · manifest .json、本地化 .json、Cards/*.cs、Relics/*.cs、ModEntry.cs
        │  · Patches/StartingContentPatches.cs（开局注入，Harmony）
        │  · .csproj、build.ps1 / build.cmd、forge-paths.txt、README、EXPORT_REPORT.md
        │  · CFPckWriter：把本地化打成 <id>.pck
        ▼
 ⑦ exports/<ModId>/ —— 可编译、可进游戏的 Mod
        │  · verify_build()：调 dotnet build 冲真实 sts2.dll 编译
        │  · _stage_dll()：把编译产物复制到 mod 根目录（与 json/pck 同级）
        ▼
 ⑧ 把整个文件夹拷进 <游戏>\mods\ → 启动游戏
```

**核心设计哲学（贯穿全工具）**：

1. **一切选项都从游戏数据反推**，不硬编码。工具里唯一"写死"的知识是 `CFSchema.ROLE_ANCHORS`  
   （语义角色 → C# 枚举类型名，如 `card_rarity → CardRarity`），而且它也能从界面重指。
2. **效果种类是本工具自己的词汇，但绑定必须是游戏的真实 API**。每个效果的 `receiver`/`method`  
   都会拿去和扫描到的 `src/Core/Commands/*.cs` 命令表核对，核对不上的会在界面上被标出来，  
   而不是悄悄生成编不过的代码。
3. **能编译 ≠ 正确**。所以除了字符串断言，还内置了真编译器验证（`verify_build` / `compiletest`）。

### 2.3 效果 → C# 代码的生成逻辑（`CFEffects` + `CFExporter`）

每个效果在界面上被拆成：**目标** + **数值** + **段数** + **循环** + **条件** + **附加项**（Power / 关键字 / 生成哪张牌）。

生成时逐层展开：

- **目标**决定 C# 表达式与调用形态。`TARGETS` 表里每项带：
  - `expr`：目标表达式（如 `base.Owner.Creature`、`base.Owner.Creature.CombatState.HittableEnemies`）
  - `list`：是否是 `IEnumerable<Creature>`。单生物命令（`GainBlock`/`Heal`/`GainMaxHp`）要 `foreach` 包一层；  
    有列表重载的（`CreatureCmd.Damage` / `PowerCmd.Apply`）不能包。
  - `attack`：`AttackCommand` 的流式后缀。留空表示该目标无法用 AttackCommand 表达（如全体友军），  
    此时自动退回 `CreatureCmd.Damage`。
  - 遗物场景下目标表达式还会从**钩子的参数绑定**里解析（`_creature`、`_card`…），  
    而不是只能用 owner。
- **数值**可以是字面量，也可以绑定到动态变量 → 走 `base.DynamicVars["名字"]`（索引器形式）。
- **循环**：按次数 / 按变量，生成 `for` 循环；变量名必须非空且已在"数值"区声明（预检会拦）。
- **条件**：左值 运算符 右值 → `if (...)`。
- **升级**：`_emit_upgrade_lines` 逐条生成 `UpgradeValueBy` / `AddKeyword` 等。

**动态变量（DynamicVar）是这里最容易错的地方**，工具专门处理了"一个变量三个名字"的问题：

| 名字空间              | 值                      | 用途                                              |
| ----------------- | ---------------------- | ----------------------------------------------- |
| 用户变量名             | `"power"`              | 描述里的占位符 `{power:diff()}`                        |
| `DynamicVar.Name` | 默认 `"VulnerablePower"` | `DynamicVarSet` 字典的 key                         |
| 属性访问器             | `"Vulnerable"`         | `base.DynamicVars.Vulnerable`（只有 6 个 Power 有这个） |

因此：用户把变量命名为 `power` 时，生成器必须写  
`new PowerVar<VulnerablePower>("power", 2m)`（用 2 参构造改掉字典 key），  
读取时走 `base.DynamicVars["power"]`（索引器），否则运行期抛 `KeyNotFoundException`。

### 2.4 为什么必须编译成 dll

游戏的 `ReflectionHelper.GetSubtypesInMods<AbstractModel>()` **只枚举已加载的 mod 程序集**，  
纯数据（只有 `.pck`）加不进卡牌。所以导出产物**同时**包含：

- `<ModId>.dll` —— 卡牌/遗物类（C# 编译进去的）
- `<ModId>.pck` —— 本地化文案与素材（引擎直接读的，由 `CFPckWriter` 按 Godot GDPC 格式手写）

⚠️ 缺 dll 时游戏**不报致命错**：它照常加载 pck、把 mod 标成 `Loaded`，只在日志留一行  
`[ERROR] ... no assembly at path ... was found!`。症状是"mod 看起来装上了，但什么都没加"。


### 2.5 `.pck` 是怎么写出来的（`core/pck_writer.gd`）

不依赖任何外部打包器，直接按 Godot 4 的 GDPC 格式手写二进制：

```
头部 128 字节：magic "GDPC" / 版本 3 / 引擎版本 4.5.1 / flags=2 / file_base=128 / dir_offset
数据区：各文件字节流（按路径排序，保证可复现）
目录区：文件数 + 每项(path_len, path, offset, size, md5, flags) + 结尾 0
```

自检里用 `ProjectSettings.load_resource_pack()` 回读验证，确认引擎真能加载。

---

## 三、功能清单

### 3.1 界面布局

三栏 + 状态栏：

| 区域           | 功能                                                          |
| ------------ | ----------------------------------------------------------- |
| **左栏（列表）**   | 卡牌/遗物列表（带错误角标）、Mod 信息（ID / 名称 / 作者 / 版本 / 描述）。              |
| **中栏（编辑器）**  | ① 标识 ② 文字 ③ 属性 ④ 动态变量 ⑤ 效果/触发时机 ⑥ 升级 ⑦ 开局注入。                |
| **右栏（预览诊断）** | 卡面预览（自动渲染描述）、数值估算、校验列表、**导出为 Mod** 面板。                      |
| **工具栏**      | `＋ 卡牌` `＋ 遗物` `↶ 撤销` `↷ 重做` `另存为` `打开` `设置`；窄窗口时自动依次收起次要按钮。 |
| **状态栏**      | 当前扫描/保存状态提示。                                                |

窗口**自适应屏幕**：启动时把窗口钳制到可用桌面区域（留 24 px 边距并居中），  
三栏宽度按 `list → editor → rail` 顺序收缩（下限 180/380/240），拖窗口时实时重算。

### 3.2 编辑能力

- **卡牌**：类名/ID、卡池、类型、稀有度、目标、费用、关键字、标签、数值。
- **遗物**：类名/ID、稀有度、卡池、触发时机。
- **文字**：中/英双语标题与描述（可选写出全部 14 种语言）；顶部实时显示"游戏要的本地化键"，  
  并即时检查占位符与 SmartFormat 格式化器是否合法。
- **动态变量**：从扫描到的 `DynamicVar` 子类里选类型（含 256 个 `PowerVar<具体Power>`，附中文名），  
  设初始值/升级值；界面下方直接显示"生成成什么 C# 形式"。
- **效果**：见下表。支持快捷按钮"＋ 给敌人上 debuff" / "＋ 给自己上 buff"，  
  效果标题带目标颜色标识（绿=自己，红=敌人）。
- **触发时机（遗物）**：来自 `AbstractModel` 的 183 个可覆写钩子；每个触发点可设  
  触发方式 = 总是 / 每回合首次 / 每回合第 N 次 / 计数叠加；钩子参数可绑定到效果目标。
- **升级**：定义升级后各变量的变化。
- **开局注入**：勾选后选角色 + 份数，导出时自动生成 Harmony 补丁把这张牌塞进该角色起始牌组，  
  或让角色开局带着这件遗物。

### 3.3 支持的 16 种效果

| 分组   | 效果                | 绑定的游戏 API                                                         |
| ---- | ----------------- | ----------------------------------------------------------------- |
| 输出   | 造成伤害（含多段）         | `DamageCmd.Attack`（遗物自动改 `CreatureCmd.Damage`）                    |
| 输出   | 直接伤害（可无视格挡）       | `CreatureCmd.Damage`                                              |
| 防御   | 获得格挡              | `CreatureCmd.GainBlock`                                           |
| 生命   | 治疗 / 提升最大生命       | `CreatureCmd.Heal` / `GainMaxHp`                                  |
| 资源   | 能量 / 星能 / 金币 / 锻造 | `PlayerCmd.GainEnergy` / `GainStars` / `GainGold`                 |
| 牌堆   | 抽牌                | `CardPileCmd.Draw`                                                |
| 牌堆   | 弃牌 / 消耗 / 升级卡牌    | `CardSelectCmd.*` + `CardCmd.Discard` / `Exhaust` / `Upgrade`     |
| 牌堆   | 生成一张牌             | `CombatState.CreateCard` → `CardPileCmd.AddGeneratedCardToCombat` |
| 牌堆   | 给这张牌附加关键字         | `CardModel.AddKeyword`（仅卡牌）                                       |
| 增益减益 | 施加 Buff / Debuff  | `PowerCmd.Apply<T>`                                               |

每个效果可设：**目标**（卡牌自身 / 自己 / 全体敌人 / 随机敌人 / 全体友军）、**数值**（字面量或变量）、  
**段数**、**循环**（按变量 / 按次数）、**条件**（左值 运算符 右值）、以及按需的  
**Power / 关键字 / 生成哪张牌 / 目标牌堆**。

### 3.4 校验与预览

- **预检（`preflight`）**：Mod ID 合法性、卡牌与遗物的字段完整性、**本地化键跨条目冲突检测**、  
  效果绑定是否能在扫描到的命令 API 里解析、开局注入冲突、循环变量是否已声明、  
  描述里的格式化器是否存在……分级为 error / warning / info，error 会阻止导出（可强制忽略）。
- **卡面预览**：按当前数值渲染描述文本（含升级后预览）。
- **数值估算**：汇总一张牌的伤害/格挡等数值。
- **导出报告**：`EXPORT_REPORT.md` 逐条列出生成的文件与仍需人工处理的项（如素材图路径）。

### 3.5 导出与编译验证

- **导出 Mod**：一键生成完整工程（见 2.2 第 ⑥ 步的清单）。
- **编译验证（dotnet build）**：就地调 `dotnet build`，冲**真实的游戏程序集** `sts2.dll` 编译，  
  这是唯一能发现"程序集路径写错 / 少 import 命名空间 / 覆写签名不对"这类问题的手段。  
  编译成功后自动把 dll 复制到 mod 根目录（`_stage_dll`），使该文件夹可整个拷进 `mods/`。

### 3.6 自检（开发/维护用）

```bash
# 核心层（约 170 项）
<godot> --headless --path . --script res://tools/selftest.gd
# 界面层（约 184 项；默认跳过真实编译，几秒跑完）
<godot> --headless --path . --script res://tools/uitest.gd
# 真编译器全量验证（约 30 秒，需要装好游戏与 dotnet）
<godot> --headless --path . --script res://tools/compiletest.gd
```

两项自检都应以 `===== PASSED =====` 结束。

---

## 四、借用 / 依赖的软件与组件（及本机实际位置）

> 工具本身**没有引入任何第三方 GDScript 库**，所有功能都是自己实现的。  
> 下面这些是它**运行、扫描、编译**所依赖的外部软件与组件。

### 4.1 必需 —— 工具运行所依赖

| 组件                                         | 用途                                                                                                             | 本机位置                                                                                                                   |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Godot Engine 4.5.1 stable（mono/.NET 版）** | 工具本身的运行宿主（运行时工程）。**用真身主程序，约 160 MB**；旁边的 `*_console.exe` 只是 200 KB 转发壳，启动器会自动纠正。                               | `D:/天马行空/StS2ModTool/Godot_v4.5.1-stable_mono_win64/Godot_v4.5.1-stable_mono_win64/Godot_v4.5.1-stable_mono_win64.exe` |
| **GodotSharp（引擎自带的 C# 绑定程序集）**             | 生成的 mod `csproj` 通过 `HintPath` 引用它；工具自身的占位工程也用它。由 `CFPaths.detect_godotsharp_dir()` 探测。                        | `D:/天马行空/StS2ModTool/Godot_v4.5.1-stable_mono_win64/Godot_v4.5.1-stable_mono_win64/GodotSharp/`（内含 `Api/`、`Tools/`）    |
| **Godot.NET.Sdk 4.5.1**                    | 生成与占位 csproj 的 SDK（`<Project Sdk="Godot.NET.Sdk/4.5.1">`）。注意它**锁死输出路径**到 `src/.godot/mono/temp/bin/<Config>/`。 | 由 NuGet 缓存提供（随 .NET SDK 还原）                                                                                            |

### 4.2 必需 —— 扫描与编译所依赖

| 组件                                           | 用途                                                                                                                                       | 本机位置                                                                               |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| **Slay the Spire 2 游戏本体**                    | 提供真实程序集与 mods 目录。由 `CFPaths.detect_game_dir()` 从候选 Steam 路径探测。                                                                           | `E:/steam/steamapps/common/Slay the Spire 2/`                                      |
| **`sts2.dll`（游戏程序集）**                        | **编译 mod 时的唯一引用来源**（所有游戏 API 的真相）。设置项 `game_assembly` 指向它。                                                                               | `E:/steam/steamapps/common/Slay the Spire 2/data_sts2_windows_x86_64/sts2.dll`     |
| **`0Harmony.dll`（Lib.Harmony 2.4.2.0，游戏自带）** | 开局牌组/遗物注入的 Harmony 补丁。**注意它和 `sts2.dll` 同级，不在游戏根目录** —— 写错路径就 CS0246。                                                                    | `E:/steam/steamapps/common/Slay the Spire 2/data_sts2_windows_x86_64/0Harmony.dll` |
| **.NET SDK 9**                               | 编译导出的 mod（`dotnet build`）；也构建工具自身的占位程序集。由 `CFPaths.detect_dotnet()` 探测，候选 `C:/Program Files/dotnet/dotnet.exe` 等，最终回退到 PATH 上的 `dotnet`。 | 系统安装（PATH 上）                                                                       |
| **反编译产物（"解包文件"）**                            | **扫描器的输入**：枚举、卡池、角色、183 个钩子、命令 API、256 个 Power、本地化表全从这里读。设置项 `source_root` 指向它。                                                          | `D:/天马行空/StS2ModTool/解包文件/.godot/`（含 `src/Core`、`localization/{zhs,eng,…}`）        |

### 4.3 可选 —— 用于生成解包数据 / 作为参照

| 组件                                    | 用途                                                                           | 本机位置                                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **GDRE Tools v2.6.4**（Godot RE Tools） | 把游戏的 `.pck` 解包、并反编译 C# 程序集，产出上面那份"解包文件"。是**一次性准备工具**，CardRelicForge 运行时不调用它。 | `D:/天马行空/StS2ModTool/GDRE_tools-v2.6.4-windows/gdre_tools.exe`                      |
| **参考 mod：HextechRunes**               | 导出目录布局的**模仿对象**（设置项 `sample_mod`）。工具让 `exports/<ModId>/` 的目录结构与它保持一致。        | `D:/天马行空/StS2ModTool/3747501308/`（含 `HextechRunes.dll` / `.json` / `.pck` / `lib/`） |
| **游戏内置本地化表**                          | Power 中文名（`powers.json` 的 `<ENTRY>.title`）等由扫描器直读。                           | `解包文件/.godot/localization/zhs/powers.json`（及 `eng/`）                                |

### 4.4 明确**不**依赖的东西

- ❌ 不需要 Godot **编辑器**（是运行时工程，不是 EditorPlugin）。
- ❌ 不需要任何第三方 GDScript 插件/库。
- ❌ 不需要改 Windows 执行策略（启动器是纯批处理，不碰系统设置）。
- ❌ 不修改用户的游戏工程（`designer/` 等同级工程与它无关）。

---

## 五、本机路径速查（设置文件实际内容）

`CardRelicForge/resources/settings.cfg`：

```ini
source_root="D:/天马行空/StS2ModTool/解包文件/.godot"
sample_mod="D:/天马行空/StS2ModTool/3747501308"
godotsharp_dir="D:/天马行空/StS2ModTool/Godot_v4.5.1-stable_mono_win64/Godot_v4.5.1-stable_mono_win64/GodotSharp"
game_dir="E:/steam/steamapps/common/Slay the Spire 2"
game_assembly="E:/steam/steamapps/common/Slay the Spire 2/data_sts2_windows_x86_64/sts2.dll"
compat_target="0.107.1"
```

导出产物结构（`exports/<ModId>/`）：

```
<ModId>/
├─ <ModId>.json           mod 清单（id / name / has_dll / has_pck …）
├─ <ModId>.dll            编译产物（_stage_dll 复制到此处，必须与 json 同级）
├─ <ModId>.pck            本地化与素材
├─ build.ps1 / build.cmd  一键编译
├─ forge-paths.txt        游戏与引擎路径（脚本读它，保持纯 ASCII）
├─ src/                   ModEntry.cs + Cards/*.cs + Relics/*.cs + Patches/*.cs + .csproj
├─ assets/                各语言本地化 json
├─ lib/<版本>/            兼容性标记
└─ README.md / EXPORT_REPORT.md
```
