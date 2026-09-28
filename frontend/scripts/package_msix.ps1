# 一键打出 MSIX 安装包
#
# 用法（在项目根目录或任意位置都行）：
#   powershell -ExecutionPolicy Bypass -File frontend\scripts\package_msix.ps1
#
# 依次做五件事：
#   1. 用 PyInstaller 把后端打成 hanime_backend.exe
#   2. 用 Flutter 打 Windows release
#   3. 把后端 exe 拷到 Flutter 产物旁边（**关键**：flutter build 不会做这一步，
#      少了它 MSIX 里就没有后端）
#   4. 用 msix 包打 MSIX（不再重复 build，用第 2 步的产物）
#   5. 校验打出来的包（签名 / 清单 / 文件齐不齐）
#
# 产物：E:\Hanime\HanimeViewer\HanimeData\Release\
#         HanimeViewer.msix      安装包
#         安装说明.md            怎么装
#   外加 frontend\msix_cert\HanimeViewer.cer（要一起发给用户）
#
# 注意：PowerShell 5.1 按系统代码页读脚本，**字符串里不要写中文**，
# 否则会解析失败（注释里可以写）。

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$backend = Join-Path $root 'backend'
$frontend = Join-Path $root 'frontend'
$python = Join-Path $root '.venv\Scripts\python.exe'
$releaseDir = Join-Path $frontend 'build\windows\x64\runner\Release'
$msixOut = Join-Path $root 'HanimeData\Release'
$certDir = Join-Path $frontend 'msix_cert'

Write-Host "project root: $root" -ForegroundColor Cyan

if (-not (Test-Path $python)) {
  Write-Error "python venv not found: $python"
}

# ---------------------------------------------------------------
# 0. 证书 + 图标
# ---------------------------------------------------------------
Write-Host "`n[0/6] certificate..." -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make_msix_cert.ps1')
if ($LASTEXITCODE -ne 0) { Write-Error "certificate step failed" }

# 图标是**脚本生成**的，不是手工丢进来的图：
#   app_icon.ico  -> exe / 任务栏（带圆角）
#   msix_logo.png -> 开始菜单磁贴（不带圆角、四周不留一点透明）
# 要改图标就改 make_icons.py，别直接替换这两个文件 ——
# 下一次打包会被覆盖回去。
Write-Host "`n[0/6] icons..." -ForegroundColor Cyan
$iconScript = Join-Path $PSScriptRoot 'make_icons.py'
if (Test-Path $iconScript) {
  & $python $iconScript
  if ($LASTEXITCODE -ne 0) {
    # 不致命：图标本来就在仓库里，生成失败就用现成的那份。
    # 通常是没装 Pillow。
    Write-Host "  WARNING: icon generation failed - keeping the ones in the repo." -ForegroundColor Yellow
    Write-Host "           to regenerate: `"$python`" -m pip install pillow" -ForegroundColor Yellow
  }
} else {
  Write-Host "  (make_icons.py not found, keeping existing icons)"
}

# ---------------------------------------------------------------
# 1. 后端
# ---------------------------------------------------------------
Write-Host "`n[1/6] backend (PyInstaller)..." -ForegroundColor Cyan
& $python (Join-Path $backend 'build_backend.py')
if ($LASTEXITCODE -ne 0) { Write-Error "backend build failed" }

# ---------------------------------------------------------------
# 2. 前端
# ---------------------------------------------------------------
Write-Host "`n[2/6] frontend (Flutter Windows release)..." -ForegroundColor Cyan

Push-Location $frontend
try {
  # --no-tree-shake-icons 是**故意的**，不要去掉。
  # Flutter 的图标树摇不可靠，实测踩过两次：增量构建会复用过期结果、
  # 全量构建也可能漏掉某些图标（渲染成空白）。整个字体才 1.6MB，
  # 换"图标随时可能消失"的风险不划算。
  & flutter build windows --release --no-tree-shake-icons
  if ($LASTEXITCODE -ne 0) { Write-Error "flutter build failed" }
}
finally {
  Pop-Location
}

if (-not (Test-Path $releaseDir)) {
  Write-Error "flutter output not found: $releaseDir"
}

# ---------------------------------------------------------------
# 3. 把后端 exe 放到前端产物旁边
# ---------------------------------------------------------------
Write-Host "`n[3/6] copy backend exe next to the app..." -ForegroundColor Cyan

$backendExe = Join-Path $backend 'dist\hanime_backend.exe'
if (-not (Test-Path $backendExe)) {
  Write-Error "backend exe not found: $backendExe"
}

Copy-Item $backendExe -Destination $releaseDir -Force
Write-Host ("  hanime_backend.exe -> release dir ({0} MB)" -f [math]::Round((Get-Item $backendExe).Length / 1MB, 1))

# ---------------------------------------------------------------
# 4. 打 MSIX
# ---------------------------------------------------------------
Write-Host "`n[4/6] MSIX..." -ForegroundColor Cyan

if (-not (Test-Path $msixOut)) {
  New-Item -ItemType Directory -Force -Path $msixOut | Out-Null
}

Push-Location $frontend
try {
  # --build-windows false：用上面那一步的产物，不要在这里再 build 一次。
  # 再 build 一次本身没问题（flutter 不会删掉多余文件，后端 exe 还在），
  # 但白等一分钟，而且容易让人以为"后端是 flutter 带出来的"。
  & dart run msix:create --build-windows false
  if ($LASTEXITCODE -ne 0) { Write-Error "msix:create failed" }
}
finally {
  Pop-Location
}

# ---------------------------------------------------------------
# 5. 给 MSIX 打补丁（磁贴背景色 / 应用名颜色 / 四种磁贴排版）
# ---------------------------------------------------------------
Write-Host "`n[5/6] patch the msix..." -ForegroundColor Cyan

# msix 包把 BackgroundColor 写死成 transparent，在 Win10 上会导致
# 「图标外面一圈别的颜色」+「磁贴上的应用名是黑字看不清」。
# 它没有配置项可改，所以只能打完拆开改、再打回去、重新签名。
# 细节见 patch_msix.ps1 开头的注释。
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'patch_msix.ps1')
if ($LASTEXITCODE -ne 0) { Write-Error "msix patch failed" }

# ---------------------------------------------------------------
# 6. 校验 + 把证书和说明放到一起
# ---------------------------------------------------------------
Write-Host "`n[6/6] verify..." -ForegroundColor Cyan

& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify_msix.ps1')
if ($LASTEXITCODE -ne 0) { Write-Error "verification failed" }

Copy-Item (Join-Path $certDir 'HanimeViewer.cer') -Destination $msixOut -Force

Write-Host "`n=== done ===" -ForegroundColor Green
Get-ChildItem $msixOut | ForEach-Object {
  Write-Host ("  {0,-24} {1} KB" -f $_.Name, [math]::Round($_.Length / 1KB, 1))
}

exit 0
