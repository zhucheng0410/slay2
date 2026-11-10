# 自定义角色模型（2026-10-20）

新建角色默认是独立角色，使用自己的 Godot 场景、贴图、动画、初始牌组、卡牌池和遗物池。角色通过 RitsuLib 注册，默认直接解锁。自制模型角色不再从五个原版角色读取机制或专属内容；旧版原版外观记录保留兼容入口。

## 独立角色更新（示例 1.0.2，趣味小mod 1.0.1）

- 基础充能球栏位为 0，不默认显示储君星星计数；不继承原版角色的起始牌组、初始遗物、专属奖励卡、专属遗物和专属药水。
- 新角色默认使用可替换的锻造木偶；选填图片、商店和营火模型留空时使用制作器自带素材。能量显示、转场和出牌轨迹也采用独立资源。通用音效、无色卡框和通用药水／遗物仍可使用。
- 创建后可以先保存草稿，再配置初始牌组与奖励卡。导出时会检查是否缺少开局或奖励卡牌。原版卡仍可由作者逐张加入完整初始牌组。
- 旧自制模型记录读取后自动转为独立模式，原角色 ID、池 ID、已配置的完整牌组、生命、金币和能量保留。尚未配置独立初始牌组的旧角色，需要补齐后再导出。
- 当前设计的原始副本位于 `.forge_userdata/backups/independent-characters/`。独立角色删除后，保留卡牌进入无色池，保留遗物进入通用池。

先关闭制作器和游戏，再安装新 DLL、PCK、JSON，重启制作器并开新的一局验证。旧对局存档保存了创建时的基础球位，继续旧对局可能仍有三个球位；本次不会直接修改游戏存档。如果以后主动使用增加球位／生成充能球的卡牌或遗物，游戏仍会按这些效果显示球位。

安装包：`exports/interesting-independent-install.zip`、`exports/ForgeCustomModelExample-install.zip`。需要完整 RitsuLib 0.6.7；目标游戏 API 0.107.1。

## 先体验完整示例

1. 重启 `run.cmd`，在工具中打开 `designs/CustomModelExample.json`。
2. 打开「能力 / 角色库」→「锻造木偶」→「编辑角色」。可以看到已启用的自定义模型、场景和动画设置。
3. 示例包含独立卡池、遗物池、起始牌组、抽牌与格挡配方，以及自制战斗形象、头像、选角立绘、选角背景、商店与休息处形象。
4. 已编译的示例在 `exports/ForgeCustomModelExample`。将 `exports/ForgeCustomModelExample-install.zip` 解压到游戏的 `mods` 目录，并安装完整的 **RitsuLib 0.6.7**。目录应为 `mods/ForgeCustomModelExample/ForgeCustomModelExample.dll`，同目录还需 JSON 和 PCK。
5. 重启游戏，在新游戏的角色选择界面寻找「锻造木偶」。角色较多时使用 RitsuLib 的翻页／滚动功能。

新示例使用不同 Mod ID，可单独安装。`designs/main.json` 中的自制模型角色已迁移为独立角色，卡牌、遗物、数值和完整初始牌组保留；`designs/CharacterExample.json` 仍为旧版兼容示例。

### 2026-10-20 修复版（示例 1.0.1）

修复自制模型导出后出现 `Could not create directory: res://resources`：设置与设计保存改用磁盘绝对路径，不受导出资源包挂载影响。

修复标准模式无法选角、每日挑战地图透明和上一房间画面残留。旧版图片是 `ImageTexture`，游戏的选角图标和地图标记要求 `CompressedTexture2D`，类型转换异常会中断整个界面初始化。新版导出真实的 `.ctex` 无损纹理，同时改写场景依赖类型，并在导出时检查角色图片类型。

更新时先完全退出游戏和制作器，使用修复包中同一批 DLL、PCK、JSON 覆盖原模组对应文件，再重新启动。其他曾用旧制作器导出的自制模型角色也需要重新「导出并编译」。仅替换图片或继续使用旧 DLL 不会修复旧的资源路径。安装包仍需完整 RitsuLib 0.6.7。

本次也从现有 `designs/main.json` 重建了「趣味小mod」，包为 `exports/interesting-model-fix-install.zip`；角色、卡牌、遗物和设计文件内容保留。

## 给已有角色换模型

进入「编辑角色」，点击「使用自制模型示例：锻造木偶」，保存即可把该角色换成示例外观。也可以勾选「使用自定义角色模型」，选择自己的模型文件夹，再填写文件路径。

所有路径都相对于选中的模型文件夹。例如该文件夹中有 `scenes/battle.tscn`，战斗模型填写 `scenes/battle.tscn`，不要填写电脑的绝对路径。素材内的 `res://` 则相对于这个模型文件夹；建议选择独立 Godot 模型工程的根目录。

| 字段 | 文件类型 | 用途 |
| --- | --- | --- |
| 战斗模型 | `.tscn`，必填 | 游戏战斗中的角色形象 |
| 商店模型 | `.tscn`，选填 | 商店中的角色形象 |
| 休息处模型 | `.tscn`，选填 | 营火处的角色形象 |
| 头像／地图图标 | PNG、WebP、JPG、SVG | 顶栏头像和地图标记 |
| 选角按钮立绘 | 同上 | 角色选择按钮；示例为 132×195 |
| 选角背景 | 同上 | 选中角色后的背景；示例为 1920×900 |

选填资源留空时使用制作器自带素材。可关闭「连接战斗动画」使用静态模型。修改完成后，保存角色，再「导出并编译」更新游戏中的 DLL、PCK 和 JSON 三个文件。

## 制作自己的模型

可复制 `resources/character_models/ForgePuppet` 到自己的工作目录，在 Godot 4.5.1 中打开其中的 `project.godot`。这是独立的模型工程；工具本身仍通过 `run.cmd` 启动。

示例素材是原创矢量木偶，不包含参考插件的美术资源。把 `puppet.svg` 换成自己的透明图片，或在 `Visuals` 下添加 Sprite2D、Polygon2D、骨骼节点与动画。使用 PNG 时，将场景中对应的纹理资源改为 PNG，再导入整个模型工程目录。

战斗场景需要以下直接子节点：

```text
角色根节点（Node2D）
├─ Visuals（Node2D，也可为 Sprite2D / AnimatedSprite2D）
│  └─ 自己的模型图层
├─ Bounds（Control，角色选择与血条范围）
├─ CenterPos（Marker2D，受击特效位置）
├─ IntentPos（Marker2D，意图位置）
├─ OrbPos（Marker2D，选填）
├─ TalkPos（Marker2D，选填）
└─ AnimationPlayer（使用关键帧动画时）
```

推荐将上述定位节点设为「场景唯一名称」，角色脚底放在原点 `(0, 0)`，头部位于负 Y 方向。RitsuLib 的节点工厂会将普通场景转换为游戏的 `NCreatureVisuals`，无需给场景挂游戏的 C# 脚本。

使用 `AnimationPlayer` 时保持该节点名；使用帧动画时将动画节点命名为 `AnimatedSprite2D`。工具会检查所填名称是否真实存在。

| 游戏动作 | 示例动画 | 播放规则 |
| --- | --- | --- |
| Idle / Revive | `idle` | 循环待机；复活恢复待机 |
| Attack | `attack` | 播放一次后回到待机 |
| Cast | `cast` | 播放一次后回到待机 |
| Hit | `hit` | 播放一次后回到待机 |
| Dead | `dead` | 停留在死亡姿态 |

动画名可以在角色设置中修改；除待机外，留空会复用待机。攻击与施放延迟可设为 0～10 秒，用来对齐动画与卡牌效果。自己的动画应重置位移、旋转、透明度等使用过的属性，避免死亡或受击姿态残留到待机。

商店／休息处场景可使用独立外观，循环动画可设 `AnimationPlayer.autoplay`。休息处场景必须有 `ControlRoot`（Control）和设为场景唯一名称的 `Hitbox`（Control）；推荐保留示例中的 `SelectionReticle`、`ThoughtBubbleLeft`、`ThoughtBubbleRight`，分别用于选择框和对话气泡定位。角色在这些场景中的交互由游戏与 RitsuLib 处理；本次不提供营火动作的单独映射编辑器。

## 保存与打包

点击「保存角色」时，工具把模型源文件复制到 `designs/character_assets/<内容摘要>/`，并把角色的模型路径、动画名称、数值和池关联一起写进当前设计 JSON。相同素材复用副本，更新素材会产生新副本，便于撤销。原文件夹移动或删除后，已经保存的角色仍然使用本地副本。

再次修改外部模型后，需要重新选择修改后的模型文件夹并保存，才会更新素材副本。迁移工具到另一台电脑时，请同时带上设计 JSON 和 `designs/character_assets`；单独的 JSON 不内嵌图片。

导出时，每个角色的资源放到独立的 `res://<ModId>/characters/<角色类名>/` 下；场景引用会同步改写。图片会转换成 Godot `CompressedTexture2D`（`.ctex`，PNG 无损数据）并写入 PCK，保留透明度，游戏不依赖模型源文件、编辑器或 `.godot/imported` 缓存。修改 Mod ID 后会重新生成资源路径。

支持无脚本 `.tscn`、`.tres`、上述图片、`.gdshader` 和 `.gdshaderinc`。所有被引用资源必须位于模型文件夹内。脚本、动画方法调用轨道、二进制导入缓存、直接引用外部工程、GLB/FBX 和第三方 Spine 插件资源不在本次导入范围；工具会报出不支持的依赖。这里提供的是可替换的 Godot 2D 模型接入，不是通用建模或骨骼格式转换器。

导出会实际回读 PCK，检查场景加载、节点类型和战斗动画名称；模型错误会停止导出和后续编译。角色、卡牌、遗物和能力配方仍保存在本地 JSON 数据库中。

## 验证

开发检查入口：`tools/charactermodeltest.gd`（导入、持久化、资源加载和编译）、`tools/characteruitest.gd`（角色与模型设置）、`tools/model_runtime`（独立 Godot 进程加载真实游戏及 RitsuLib 类型）。

本次回归新增：挂载导出 PCK 后连续保存并重读设置、保存并重开角色设计；逐像素比较导出图片及透明度；调用游戏真实的 `CharacterSelectIcon`、`CharacterSelectLockedIcon`、`MapMarker` 属性。旧测试只检查 `Texture2D` 基类，漏掉了游戏要求的具体纹理类型。

独立角色更新通过模型导出 54 项、角色界面 30 项、真实游戏类型运行 63 项、旧记录兼容编译 23 项和核心 190 项检查。运行测试直接加载示例与「趣味小mod」的 DLL、PCK，验证零球位、无默认星星、独立药水池、独立能量显示与转场、选角与地图图标。用最小玩家对象执行真实 `PlayerCombatState` 构造两次，验证连续两场初始化均无球位、星星或宠物。战斗动画覆盖攻击、待机、受击、施放、死亡和复活。日志位于 `.forge_userdata/independent-*.log`。

编译日志中的 `NU1900` 为 NuGet 漏洞信息源访问警告，最终为 0 个编译错误。无头 Godot 仍有证书存储和部分退出资源回收提示，不属于本次检查断言失败。

本机验证目标为游戏 API **0.107.1**、**RitsuLib 0.6.7**、**Godot 4.5.1 .NET**。未启动完整游戏进行实际选角、战斗跑局和多人联机，其他游戏版本也未逐一验证。
