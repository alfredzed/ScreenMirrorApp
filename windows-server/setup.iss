; setup.iss
; ---------
; ScreenMirrorServer 配布用インストーラー定義
; Inno Setup (https://jrsoftware.org/isinfo.php) で以下のようにビルドしてください:
;   1. PyInstallerでビルド済みの dist\ScreenMirrorServer フォルダをこのファイルと同じ階層に用意
;   2. Inno Setup Compiler (ISCC.exe) でこの .iss をコンパイル
;      "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup.iss
;
; 生成物: Output\ScreenMirrorTouchDisplayServer-Setup-1.03.exe

#define MyAppName "ScreenMirror Touch Display Server"
#define MyAppVersion "1.03"
#define MyAppPublisher "ScreenMirrorApp Project"
#define MyAppExeName "ScreenMirrorServer.exe"

[Setup]
AppId={{8F1B7A2E-4C3D-4E5A-9B6F-1234567890AB}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\ScreenMirrorServer
DefaultGroupName=ScreenMirrorApp
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=ScreenMirrorTouchDisplayServer-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
; インストール時に管理者権限を要求する(ファイアウォール規則の追加に必要)
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "デスクトップにショートカットを作成する"; GroupDescription: "追加のショートカット:"
Name: "firewallrule"; Description: "Windowsファイアウォールに受信規則を追加する(ポート8765/TCP)"; GroupDescription: "ネットワーク設定:"; Flags: checkedonce

[Files]
; PyInstallerでビルドしたonedir一式をまるごと同梱する
Source: "dist\ScreenMirrorServer\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "tools\iproxy\*"; DestDir: "{app}\tools\iproxy"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "tools\LIBIMOBILEDEVICE_LICENSE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "tools\IPROXY_GPLv2.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion; Check: FileExists(ExpandConstant('{src}\README.md'))

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; インストール完了後、選択されていればファイアウォール規則を追加する
[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('firewallrule') then
  begin
    Exec('netsh.exe',
      'advfirewall firewall add rule name="ScreenMirror Touch Display Server" dir=in action=allow protocol=TCP localport=8765',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

[UninstallRun]
; アンインストール時にファイアウォール規則も削除する
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ScreenMirror Touch Display Server"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"
