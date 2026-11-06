<#
  Packages the Windows build (flutter build windows --release) as:
    folders-v<version>-windows-x64-setup.exe   Inno Setup installer
    folders-v<version>-windows-x64.msix        signed MSIX
    folders-v<version>-windows.msixbundle      signed bundle of the MSIX
  Used by .github/workflows/desktop-release.yml; works locally too:
    pwsh packaging/windows/make-packages.ps1 -Version 1.0.6 -CertificatePath my.pfx -CertificatePassword ...
  The MSIX files are signed with a self-signed certificate (public part:
  packaging/windows/folders-msix.cer), which users trust once to install them.
#>
param(
  [Parameter(Mandatory)] [string] $Version,
  [string] $AppDir = 'build/windows/x64/runner/Release',
  [string] $RepoDir = '.',
  [string] $OutDir = 'dist',
  [Parameter(Mandatory)] [string] $CertificatePath,
  [Parameter(Mandatory)] [string] $CertificatePassword,
  [switch] $SkipInstaller
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$RepoDir = (Resolve-Path $RepoDir).Path
$AppDir = (Resolve-Path $AppDir).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$name = "folders-v$Version"

function Find-SdkTool([string] $tool) {
  $found = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\$tool" -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1
  if (-not $found) { throw "$tool not found; install the Windows 10/11 SDK." }
  $found.FullName
}

function Invoke-Tool([string] $exe, [string[]] $arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $exe -Leaf) failed with exit code $LASTEXITCODE" }
}

# Installer (.exe)
if (-not $SkipInstaller) {
  $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
  if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
  if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 (ISCC.exe) not found.' }
  Invoke-Tool $iscc @(
    "/DAppVersion=$Version", "/DAppDir=$AppDir", "/DRepoDir=$RepoDir",
    "/DOutputDir=$OutDir", "/DOutputName=$name-windows-x64-setup",
    "$here\folders.iss")
}

# MSIX: the app files, the manifest and its logos.
$makeappx = Find-SdkTool 'makeappx.exe'
$signtool = Find-SdkTool 'signtool.exe'
# MSIX versions have four numbers.
$msixVersion = "$Version.0"
$stage = Join-Path ([IO.Path]::GetTempPath()) "folders-msix-$([guid]::NewGuid())"
Copy-Item -Recurse $AppDir $stage
# Web view data left by running the app from the build folder.
Remove-Item -Recurse -Force "$stage\*.WebView2" -ErrorAction SilentlyContinue
Copy-Item -Recurse "$here\msix\Assets" "$stage\Assets"
# Open with: the types in file-types.txt, less fonts (an MSIX can't take
# .ttf: Windows keeps it for its font viewer).
$fileTypes = (Get-Content "$here\file-types.txt" | Where-Object { $_.Trim() -and -not $_.StartsWith('#') -and $_.Trim() -ne 'ttf' } |
  ForEach-Object { "              <uap:FileType>.$($_.Trim())</uap:FileType>" }) -join "`n"
(Get-Content -Raw "$here\msix\AppxManifest.xml").Replace('@VERSION@', $msixVersion).Replace('@FILE_TYPES@', $fileTypes) |
  Set-Content -Encoding utf8 "$stage\AppxManifest.xml"

$msix = Join-Path $OutDir "$name-windows-x64.msix"
Invoke-Tool $makeappx @('pack', '/o', '/d', $stage, '/p', $msix)
Invoke-Tool $signtool @('sign', '/fd', 'SHA256', '/f', $CertificatePath, '/p', $CertificatePassword, $msix)

# Bundle (.msixbundle) of the MSIX, signed the same way.
$bundleIn = Join-Path ([IO.Path]::GetTempPath()) "folders-bundle-$([guid]::NewGuid())"
New-Item -ItemType Directory $bundleIn | Out-Null
Copy-Item $msix $bundleIn
$bundle = Join-Path $OutDir "$name-windows.msixbundle"
Invoke-Tool $makeappx @('bundle', '/o', '/bv', $msixVersion, '/d', $bundleIn, '/p', $bundle)
Invoke-Tool $signtool @('sign', '/fd', 'SHA256', '/f', $CertificatePath, '/p', $CertificatePassword, $bundle)

Copy-Item "$here\folders-msix.cer" (Join-Path $OutDir "$name-windows-msix-certificate.cer")
Remove-Item -Recurse -Force $stage, $bundleIn
Get-ChildItem $OutDir | Format-Table Name, Length
