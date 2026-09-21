@echo off
REM build_all.bat
REM --------------
REM windows-server フォルダ直下に、このファイル・ScreenMirrorServer.spec・setup.iss を置いて実行してください。
REM 事前準備:
REM   1. pip install pyinstaller
REM   2. Inno Setup をインストール (https://jrsoftware.org/isdl.php)
REM      既定インストール先: C:\Program Files (x86)\Inno Setup 6\ISCC.exe

setlocal

echo === Step 1/2: PyInstaller でexe化 ===
pyinstaller ScreenMirrorServer.spec --noconfirm --clean
if errorlevel 1 (
    echo PyInstallerのビルドに失敗しました。
    exit /b 1
)

echo === Step 2/2: Inno Setup でインストーラー作成 ===
set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if not exist %ISCC% (
    set ISCC="%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
)
if not exist %ISCC% (
    echo Inno Setup が見つかりません。ISCC.exe のパスを確認してください。
    exit /b 1
)
%ISCC% setup.iss
if errorlevel 1 (
    echo インストーラーのビルドに失敗しました。
    exit /b 1
)

echo === 完了 ===
echo インストーラーは Output\ScreenMirrorTouchDisplayServer-Setup-1.03.exe に生成されました。
endlocal
