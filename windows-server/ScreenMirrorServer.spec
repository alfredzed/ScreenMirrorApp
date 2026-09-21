# -*- mode: python ; coding: utf-8 -*-
# ScreenMirrorServer.spec
# ------------------------
# windows-server フォルダ内に置いて、以下でビルドしてください:
#   pyinstaller ScreenMirrorServer.spec
#
# 生成物: dist/ScreenMirrorServer/ScreenMirrorServer.exe (onedir構成)
# onedir構成にしている理由: onefileより起動が速く、依存DLLの問題も切り分けやすいため。
# インストーラー側でこのフォルダごと配布します。

block_cipher = None

a = Analysis(
    ['server.py'],
    pathex=[],
    binaries=[],
    datas=[('tools', 'tools')],
    hiddenimports=[
        'cv2',
        'numpy',
        'mss',
        'websockets',
        'pynput',
        'pynput.keyboard',
        'pynput.mouse',
        'pyautogui',
        'comtypes',
        'av',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['dxcam'],  # dxcamはネイティブクラッシュのため配布版では同梱しない
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='ScreenMirrorServer',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,  # サーバーログを見たいのでコンソール表示のまま
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='ScreenMirrorServer',
)
