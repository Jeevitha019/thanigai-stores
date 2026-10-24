#define AppName "Thanigai Stores"
#ifndef AppVersion
#define AppVersion "1.0.0"
#endif
#define AppPublisher "Thanigai Stores"
#define AppExeName "malligai_kadai.exe"
#define PayloadDir "stage\app"

[Setup]
AppId={{5E29A0CC-814D-4F8C-8B1B-F946844CB591}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\Malligai Kadai
DefaultGroupName=Thanigai Stores
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir=..\artifacts
OutputBaseFilename=MalligaiKadai-Setup
SetupIconFile=..\malligai_kadai\windows\runner\resources\app_icon.ico
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
CloseApplications=yes
RestartApplications=no
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
Uninstallable=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName={#AppName}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Windows desktop billing application

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel2=PostgreSQL 18 is included and runs locally under your Windows account. No Administrator permission or separate download is required. Your shop database is stored in your Windows user profile and preserved across app upgrades.

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Thanigai Stores"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Thanigai Stores"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Thanigai Stores"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent runasoriginaluser
