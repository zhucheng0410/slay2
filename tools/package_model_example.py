"""Package only the runtime files, plus an independent editable model project."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parents[1]
mod_id = 'ForgeCustomModelExample'
mod = root / 'exports' / mod_id
with ZipFile(root/'exports'/f'{mod_id}-install.zip', 'w', ZIP_DEFLATED) as archive:
    for suffix in ('.json', '.dll', '.pck'):
        path = mod/(mod_id+suffix)
        assert path.stat().st_size > 0, path
        archive.write(path, f'{mod_id}/{path.name}')
    archive.write(mod/'CHARACTERS.md', f'{mod_id}/CHARACTERS.md')
    archive.write(root/'CHARACTER_MODELS.md', f'{mod_id}/CHARACTER_MODELS.md')
    archive.writestr('安装说明.txt', '独立角色版 1.0.2：自制角色不再继承原版角色机制和专属内容，基础球位为 0，不默认显示星星，使用独立能量界面。保留先前选角、地图图片与导出保存修复。先完全退出游戏，再将 ForgeCustomModelExample 文件夹放到游戏 mods 目录，覆盖旧版同名 DLL、PCK、JSON 三个文件。需要完整 RitsuLib 0.6.7，针对游戏 API 0.107.1。重启后开新的一局选择“锻造木偶”；旧对局仍可能保留旧球位。其他自制模型角色也需重启制作器后重新导出并编译。\n')
with ZipFile(root/'exports'/'ForgePuppet-model-source.zip', 'w', ZIP_DEFLATED) as archive:
    for path in sorted((root/'resources/character_models/ForgePuppet').iterdir()):
        if path.is_file() and not path.name.startswith('.'):
            archive.write(path, f'ForgePuppet/{path.name}')
    archive.write(root/'CHARACTER_MODELS.md', 'CHARACTER_MODELS.md')
for name in (f'{mod_id}-install.zip', 'ForgePuppet-model-source.zip'):
    path = root/'exports'/name
    with ZipFile(path) as archive:
        assert archive.testzip() is None
        print(name, path.stat().st_size, archive.namelist())
