; Windows installer (Inno Setup 6), built by .github/workflows/desktop-release.yml:
;   ISCC /DAppVersion=1.0.6 /DAppDir=<flutter build output> /DRepoDir=<checkout>
;        /DOutputDir=<dir> /DOutputName=<file name without .exe> explorer.iss
;
; Installs for the current user (no admin prompt), in %LOCALAPPDATA%\Programs.
; Not in Program Files: web views (WebView2) keep their data next to the .exe
; and fail where the app can't write.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId: Windows uses it to find earlier installs to upgrade.
AppId={{EAA7C0DF-E7B1-46D6-9B1E-DC41961AE3D9}
AppName=Explorer
AppVersion={#AppVersion}
AppVerName=Explorer {#AppVersion}
AppPublisher=MSatyam-Mishra
AppPublisherURL=https://github.com/MSatyam-Mishra/explorer
AppSupportURL=https://github.com/MSatyam-Mishra/explorer/issues
AppUpdatesURL=https://github.com/MSatyam-Mishra/explorer/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Explorer
DefaultGroupName=Explorer
DisableProgramGroupPage=yes
LicenseFile={#RepoDir}\LICENSE
SetupIconFile={#RepoDir}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\explory.exe
UninstallDisplayName=Explorer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequired=lowest
CloseApplications=yes
; The file types below: File Explorer picks them up without a restart.
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Versions up to 1.0.6 named the program explorer.exe.
Type: files; Name: "{app}\explorer.exe"

[Icons]
Name: "{autoprograms}\Explorer"; Filename: "{app}\explory.exe"
Name: "{autodesktop}\Explorer"; Filename: "{app}\explory.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\explory.exe"; Description: "{cm:LaunchProgram,Explorer}"; Flags: nowait postinstall skipifsilent

[Registry]
; "Open with": Explorer is in the Open with menu of each type in
; file-types.txt, and under Choose another app for every other file.
; Nothing becomes the default; Windows asks the user for that. Settings >
; Default apps lists Explorer with those types.
Root: HKA; Subkey: "Software\Classes\Applications\explory.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Explorer"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\explory.exe\DefaultIcon"; ValueType: string; ValueData: """{app}\explory.exe"",0"
Root: HKA; Subkey: "Software\Classes\Applications\explory.exe\shell\open\command"; ValueType: string; ValueData: """{app}\explory.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\*\OpenWithList\explory.exe"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Explory.File"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Explory.File\Application"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Explorer"
Root: HKA; Subkey: "Software\Classes\Explory.File\shell\open\command"; ValueType: string; ValueData: """{app}\explory.exe"" ""%1"""
Root: HKA; Subkey: "Software\MSatyam-Mishra\Explorer\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Explorer"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\MSatyam-Mishra\Explorer\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "The universal file manager: open, edit and share almost any file."
Root: HKA; Subkey: "Software\MSatyam-Mishra\Explorer"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\MSatyam-Mishra"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Explorer"; ValueData: "Software\MSatyam-Mishra\Explorer\Capabilities"; Flags: uninsdeletevalue
; Each type in file-types.txt (one per line, # for comments).
#define TypesFile FileOpen(AddBackslash(SourcePath) + "file-types.txt")
#sub FileTypeEntries
  #define Ext Trim(FileRead(TypesFile))
  #if Ext != "" && Copy(Ext, 1, 1) != "#"
Root: HKA; Subkey: "Software\Classes\.{#Ext}\OpenWithProgids"; ValueType: string; ValueName: "Explory.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\MSatyam-Mishra\Explorer\Capabilities\FileAssociations"; ValueType: string; ValueName: ".{#Ext}"; ValueData: "Explory.File"
  #endif
#endsub
#for {0; !FileEof(TypesFile); 0} FileTypeEntries
#expr FileClose(TypesFile)
