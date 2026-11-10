"""Package the rebuilt runtime files, with matching versions and instructions."""
import json
import shutil
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parents[1]
for mod_id, aliases in {
    'interesting': ['interesting-independent-install.zip', 'interesting-model-fix-install.zip'],
    'ForgeCustomModelExample': ['ForgeCustomModelExample-install.zip'],
}.items():
    folder = root / 'exports' / mod_id
    version = json.loads((folder / f'{mod_id}.json').read_text(encoding='utf-8'))['version']
    archive_path = root / 'exports' / f'{mod_id}-ancients-install.zip'
    with ZipFile(archive_path, 'w', ZIP_DEFLATED) as archive:
        for suffix in ('.dll', '.pck', '.json'):
            source = folder / (mod_id + suffix)
            assert source.stat().st_size > 0
            archive.write(source, f'{mod_id}/{source.name}')
        archive.write(folder / 'CHARACTERS.md', f'{mod_id}/CHARACTERS.md')
        for doc in ('ANCIENT_DIALOGUES.md', 'CHARACTER_MODELS.md'):
            archive.write(root / doc, f'{mod_id}/{doc}')
        archive.writestr('安装说明.txt',
            f'2026-10-22 先古之民对话更新：{mod_id} {version}\n'
            '包含全部 9 位先古之民（含建筑师）的首次与重复台词，以及达弗尘封魔典的有效先古卡奖励。\n'
            '保留独立角色、自制模型、零基础球位与地图资源修复。\n'
            f'完全退出游戏，将 {mod_id} 文件夹放入游戏 mods 目录，覆盖原模组同名 DLL、PCK、JSON 三个文件。\n'
            '需要完整 RitsuLib 0.6.7，实际编译及接口验证针对游戏 API 0.107.1。\n'
            '重启制作器，在「能力/角色库 → 先古之民对话」编辑和保存，修改后重新导出并编译。\n'
            '未修改游戏安装文件或对局存档；建议开新局验证。自动接口测试不能代替完整跑局及多模组兼容检查。\n')
    with ZipFile(archive_path) as archive:
        assert archive.testzip() is None
        for suffix in ('.dll', '.pck', '.json'):
            assert archive.read(f'{mod_id}/{mod_id}{suffix}') == (folder / (mod_id + suffix)).read_bytes()
    for alias in aliases:
        shutil.copyfile(archive_path, root / 'exports' / alias)
    print(f'{archive_path.name}: {version}, {archive_path.stat().st_size} bytes, verified')
