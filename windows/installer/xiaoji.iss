; 小记 Windows 安装器（Inno Setup 6）
;
; CI 用法：ISCC.exe /DMyAppVersion=1.10.1 windows\installer\xiaoji.iss
; 产物：windows\installer\Output\xiaoji-<版本>-windows-x64-setup.exe
;
; 默认按当前用户安装到 %LOCALAPPDATA%\Programs\Xiaoji，不需要管理员权限，
; 也不会弹 UAC。安装器本身未做 Authenticode 签名，SmartScreen 仍会提示
; 「未知发布者」—— 这是没有代码签名证书时的必然结果。

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "小记"
#define MyAppExeName "xiaoji.exe"

[Setup]
AppId={{8F3C5B2A-6D41-4E7B-9C2A-5F1D3E8A7B64}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
DefaultDirName={autopf}\Xiaoji
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=xiaoji-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
VersionInfoVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} 安装程序

[Languages]
; 官方安装包不一定带简体中文语言文件。CI 检测到后才传 /DWithZh，
; 避免在没有该文件时编译失败。
#ifdef WithZh
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Files]
; 整个 Release 目录都要带上：exe 依赖同级的 data\ 与 flutter_windows.dll。
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "运行{#MyAppName}"; \
    Flags: nowait postinstall skipifsilent
