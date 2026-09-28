# 给打好的 MSIX 打两处补丁，然后重新签名。
#
# 为什么需要这一步
# ================
# msix 包生成的 manifest 里写死了这么一句：
#
#     <uap:VisualElements BackgroundColor="transparent" ...>
#
# 它在 Windows 10 上会引发两个问题（都是实测出来的）：
#
#   1. 开始菜单里**图标外面一圈留白**。
#      Win10 会把应用图标放在一块"底板"上，底板颜色取的就是这个
#      BackgroundColor。transparent 会落回默认色，于是深色的图标
#      被一圈浅色底板围住。
#   2. 磁贴上的**应用名看不清**。
#      Windows 按 BackgroundColor 的明暗来决定名字用黑字还是白字；
#      transparent 被当成浅色 -> 画成黑字 -> 压在深色图标上看不见。
#
# 把 BackgroundColor 改成图标本身的颜色（#121214）两个问题一起解决：
# 底板和图标同色 -> 连成一片没有圈；背景是深色 -> 名字自动变白字。
#
# msix 包**没有**提供配置项来改这个值（configuration.dart 里也没有），
# 所以只能打完之后拆开改、再打回去、重新签名。
#
# 顺带还做两件事：
#   * 用 make_tiles.py 把四种磁贴（小/中/宽/大）重新排版 ——
#     默认生成的四种尺寸长得一模一样，应用名会压在图标上；
#   * 把 "A new Flutter project." 这种占位描述换掉。
#
# 用法：powershell -ExecutionPolicy Bypass -File patch_msix.ps1
#
# 注意：字符串里别写中文（PowerShell 5.1 按系统代码页读脚本）。

param(
  [string]$MsixPath = "E:\Hanime\HanimeViewer\HanimeData\Release\HanimeViewer.msix"
)

$ErrorActionPreference = 'Stop'

$frontend = Resolve-Path (Join-Path $PSScriptRoot '..')
$python = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) '.venv\Scripts\python.exe'
$certDir = Join-Path $frontend 'msix_cert'
$pfx = Join-Path $certDir 'HanimeViewer.pfx'
$password = 'HanimeViewer'

# 图标底色，和 make_icons.py 里的 BG 必须一致
$tileColor = '#121214'
$appDescription = 'HanimeViewer - a desktop client for hanime1.me'

# msix 包自带 MakeAppx / signtool，不用装 Windows SDK
$toolkit = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.flutter-io.cn\msix-3.18.0\lib\assets\MSIX-Toolkit\Redist.x64'
if (-not (Test-Path $toolkit)) {
  $toolkit = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev\msix-3.18.0\lib\assets\MSIX-Toolkit\Redist.x64'
}

$makeappx = Join-Path $toolkit 'MakeAppx.exe'
$signtool = Join-Path $toolkit 'signtool.exe'

if (-not (Test-Path $makeappx)) {
  # 退回到 Windows SDK
  $sdk = Get-ChildItem 'E:\Windows Kits\10\bin', 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'makeappx.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
  if ($sdk) { $makeappx = $sdk.FullName }
}
if (-not (Test-Path $signtool)) {
  $sdk = Get-ChildItem 'E:\Windows Kits\10\bin', 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
  if ($sdk) { $signtool = $sdk.FullName }
}

foreach ($tool in @($makeappx, $signtool)) {
  if (-not (Test-Path $tool)) { Write-Error "tool not found: $tool" }
}

Write-Host "  MakeAppx : $makeappx"
Write-Host "  signtool : $signtool"

if (-not (Test-Path $MsixPath)) { Write-Error "msix not found: $MsixPath" }
if (-not (Test-Path $pfx)) { Write-Error "certificate not found: $pfx" }

# ---------------------------------------------------------------
# 1. 拆开
# ---------------------------------------------------------------
$work = Join-Path $env:TEMP 'hv_msix_patch'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

Write-Host "  unpacking..."
& $makeappx unpack /p $MsixPath /d $work /o | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "makeappx unpack failed" }

# ---------------------------------------------------------------
# 2. 改 manifest
# ---------------------------------------------------------------
$manifestPath = Join-Path $work 'AppxManifest.xml'

Write-Host "  patching manifest..."
$manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)

$before = $manifest

$manifest = $manifest.Replace(
  'BackgroundColor="transparent"',
  "BackgroundColor=`"$tileColor`""
)

$manifest = $manifest.Replace(
  'Description="A new Flutter project."',
  "Description=`"$appDescription`""
)

$manifest = $manifest.Replace(
  '<Description>A new Flutter project.</Description>',
  "<Description>$appDescription</Description>"
)

if ($manifest -eq $before) {
  Write-Host "  WARNING: nothing changed - did the template change upstream?" -ForegroundColor Yellow
}

if ($manifest -notmatch [regex]::Escape("BackgroundColor=`"$tileColor`"")) {
  Write-Error "BackgroundColor was not patched"
}

[System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "    BackgroundColor -> $tileColor"
Write-Host "    Description     -> $appDescription"

# ---------------------------------------------------------------
# 3. 重排磁贴
# ---------------------------------------------------------------
Write-Host "  re-laying out tiles..."
& $python (Join-Path $PSScriptRoot 'make_tiles.py') $work
if ($LASTEXITCODE -ne 0) { Write-Error "make_tiles.py failed" }

# ---------------------------------------------------------------
# 4. 重新打包
# ---------------------------------------------------------------
Write-Host "  packing..."
& $makeappx pack /d $work /p $MsixPath /o | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "makeappx pack failed" }

# ---------------------------------------------------------------
# 5. 重新签名（重新打包之后签名就没了）
# ---------------------------------------------------------------
Write-Host "  signing..."
& $signtool sign /fd SHA256 /f $pfx /p $password $MsixPath | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "signtool sign failed" }

$sig = Get-AuthenticodeSignature $MsixPath
if (-not $sig.SignerCertificate) { Write-Error "package is not signed" }

Write-Host "  signed by $($sig.SignerCertificate.Subject)"

Remove-Item $work -Recurse -Force

exit 0
