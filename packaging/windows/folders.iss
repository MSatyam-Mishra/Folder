; Windows installer (Inno Setup 6), built by .github/workflows/desktop-release.yml:
;   ISCC /DAppVersion=1.0.6 /DAppDir=<flutter build output> /DRepoDir=<checkout>
;        /DOutputDir=<dir> /DOutputName=<file name without .exe> folders.iss
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
AppName=Folders
AppVersion={#AppVersion}
AppVerName=Folders {#AppVersion}
AppPublisher=MSatyam-Mishra
AppPublisherURL=https://github.com/MSatyam-Mishra/explorer
AppSupportURL=https://github.com/MSatyam-Mishra/explorer/issues
AppUpdatesURL=https://github.com/MSatyam-Mishra/explorer/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Folders
DefaultGroupName=Folders
DisableProgramGroupPage=yes
LicenseFile={#RepoDir}\LICENSE
SetupIconFile={#RepoDir}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\folders.exe
UninstallDisplayName=Folders
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
; Versions up to 1.0.6 named the program explorer.exe, later ones explory.exe,
; and 1.0.10 and 1.0.11 folder.exe.
Type: files; Name: "{app}\explorer.exe"
Type: files; Name: "{app}\explory.exe"
Type: files; Name: "{app}\folder.exe"

[Icons]
Name: "{autoprograms}\Folders"; Filename: "{app}\folders.exe"
Name: "{autodesktop}\Folders"; Filename: "{app}\folders.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\folders.exe"; Description: "{cm:LaunchProgram,Folders}"; Flags: nowait postinstall skipifsilent

[Registry]
; "Open with": Folders is in the Open with menu of each type in
; file-types.txt, and under Choose another app for every other file.
; Nothing becomes the default; Windows asks the user for that. Settings >
; Default apps lists Folders with those types.
; What the app registered under its old names (Explorer, then Folder), for
; those updating from them.
Root: HKA; Subkey: "Software\Classes\Applications\explory.exe"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\Classes\*\OpenWithList\explory.exe"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\Classes\Explory.File"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\MSatyam-Mishra\Explorer"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: none; ValueName: "Explorer"; Flags: deletevalue dontcreatekey
Root: HKA; Subkey: "Software\Classes\Applications\folder.exe"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\Classes\*\OpenWithList\folder.exe"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\Classes\FolderApp.File"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\MSatyam-Mishra\Folder"; Flags: deletekey dontcreatekey
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: none; ValueName: "Folder"; Flags: deletevalue dontcreatekey
Root: HKA; Subkey: "Software\Classes\Applications\folders.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Folders"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\folders.exe\DefaultIcon"; ValueType: string; ValueData: """{app}\folders.exe"",0"
Root: HKA; Subkey: "Software\Classes\Applications\folders.exe\shell\open\command"; ValueType: string; ValueData: """{app}\folders.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\*\OpenWithList\folders.exe"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\FoldersApp.File"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\FoldersApp.File\Application"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Folders"
Root: HKA; Subkey: "Software\Classes\FoldersApp.File\shell\open\command"; ValueType: string; ValueData: """{app}\folders.exe"" ""%1"""
Root: HKA; Subkey: "Software\MSatyam-Mishra\Folders\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Folders"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\MSatyam-Mishra\Folders\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "The universal file manager: open, edit and share almost any file."
Root: HKA; Subkey: "Software\MSatyam-Mishra\Folders"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\MSatyam-Mishra"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Folders"; ValueData: "Software\MSatyam-Mishra\Folders\Capabilities"; Flags: uninsdeletevalue
; Each type in file-types.txt (one per line, # for comments).
#define TypesFile FileOpen(AddBackslash(SourcePath) + "file-types.txt")
#sub FileTypeEntries
  #define Ext Trim(FileRead(TypesFile))
  #if Ext != "" && Copy(Ext, 1, 1) != "#"
Root: HKA; Subkey: "Software\Classes\.{#Ext}\OpenWithProgids"; ValueType: none; ValueName: "Explory.File"; Flags: deletevalue dontcreatekey
Root: HKA; Subkey: "Software\Classes\.{#Ext}\OpenWithProgids"; ValueType: none; ValueName: "FolderApp.File"; Flags: deletevalue dontcreatekey
Root: HKA; Subkey: "Software\Classes\.{#Ext}\OpenWithProgids"; ValueType: string; ValueName: "FoldersApp.File"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\MSatyam-Mishra\Folders\Capabilities\FileAssociations"; ValueType: string; ValueName: ".{#Ext}"; ValueData: "FoldersApp.File"
  #endif
#endsub
#for {0; !FileEof(TypesFile); 0} FileTypeEntries
#expr FileClose(TypesFile)
