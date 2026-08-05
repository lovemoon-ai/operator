#define MyAppName "Operator Collector"
#define MyAppVersion "0.1.2"
#define MyAppPublisher "LoveMoon"
#define MyAppExeName "operator-collector.exe"

[Setup]
AppId={{D0990C8C-0A5E-4DC3-9F61-A511624220F1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\OperatorCollector
DisableProgramGroupPage=yes
OutputDir=..\..\dist\installers
OutputBaseFilename=OperatorCollector-{#MyAppVersion}-unsigned-setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=lowest

[Files]
Source: "..\..\dist\operator-collector.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autostartup}\Operator Collector"; Filename: "{app}\{#MyAppExeName}"; Parameters: "run"
Name: "{group}\Operator Collector"; Filename: "{app}\{#MyAppExeName}"; Parameters: "run"

[Run]
Filename: "{app}\{#MyAppExeName}"; Parameters: "run"; Description: "Start Operator Collector"; Flags: nowait postinstall skipifsilent
