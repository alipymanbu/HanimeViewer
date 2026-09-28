# 生成可独立运行的 Windows 发布目录
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File frontend\scripts\package_windows.ps1
#
# 做三件事：
#   1. 用 PyInstaller 把后端打成 hanime_backend.exe
#   2. 用 Flutter 打 Windows release
#   3. 把 exe 放到 Flutter 产物旁边，得到可以直接拷走运行的目录

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$backend = Join-Path $root 'backend'
$frontend = Join-Path $root 'frontend'
$python = Join-Path $root '.venv\Scripts\python.exe'

Write-Host "项目根目录: $root" -ForegroundColor Cyan

if (-not (Test-Path $python)) {
  Write-Error "找不到 Python：$python"
}

# ---------------------------------------------------------------
# 1. 打后端
# ---------------------------------------------------------------
Write-Host "`n[1/3] 打包后端 (PyInstaller)..." -ForegroundColor Cyan

& $python (Join-Path $backend 'build_backend.py')

if ($LASTEXITCODE -ne 0) {
  Write-Error "后端打包失败"
}

# ---------------------------------------------------------------
# 2. 打 Flutter release
# ---------------------------------------------------------------
Write-Host "`n[2/3] 打包前端 (Flutter Windows release)..." -ForegroundColor Cyan

Push-Location $frontend
try {
  # --no-tree-shake-icons 是**故意的**，不要去掉。
  #
  # Flutter 默认会 tree-shake 图标字体（只保留代码里用到的图标，
  # 字体从约 1.6MB 缩到几十 KB）。但它**不可靠**，实测踩过两次：
  #
  #   1. 增量构建时会复用**过期的**树摇结果 —— 新加的图标
  #      （Icons.thumb_up / Icons.bookmark）根本不在字体里，
  #      界面上渲染成**空白**，看起来像"图标丢了"。
  #   2. 即使全量重建，它也会漏掉某些图标 —— 实测
  #      Icons.arrow_drop_down 就没被收进去（筛选栏的下拉箭头变空白）。
  #
  # 这是桌面应用，整个图标字体也才 1.6MB（发布目录本来就 45MB），
  # 为这点体积换"图标随时可能消失"的风险不划算。
  & flutter build windows --release --no-tree-shake-icons

  if ($LASTEXITCODE -ne 0) {
    Write-Error "Flutter 打包失败"
  }
}
finally {
  Pop-Location
}

$releaseDir = Join-Path $frontend 'build\windows\x64\runner\Release'

if (-not (Test-Path $releaseDir)) {
  Write-Error "找不到 Flutter 产物：$releaseDir"
}

# ---------------------------------------------------------------
# 3. 组装发布目录
# ---------------------------------------------------------------
Write-Host "`n[3/3] 组装发布目录..." -ForegroundColor Cyan

$backendExe = Join-Path $backend 'dist\hanime_backend.exe'

if (-not (Test-Path $backendExe)) {
  Write-Error "找不到后端 exe：$backendExe"
}

Copy-Item $backendExe -Destination $releaseDir -Force

$backendSize = [math]::Round((Get-Item $backendExe).Length / 1MB, 1)
$frontendSize = [math]::Round(
  (Get-ChildItem $releaseDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum / 1MB, 1)
$exeName = (Get-ChildItem $releaseDir -Filter *.exe |
  Where-Object { $_.Name -ne 'hanime_backend.exe' } |
  Select-Object -First 1).Name

Write-Host "`n=== 打包完成 ===" -ForegroundColor Green
Write-Host "发布目录: $releaseDir"
Write-Host "主程序  : $exeName"
Write-Host "后端    : hanime_backend.exe ($backendSize MB)"
Write-Host "总体积  : $frontendSize MB"
Write-Host ""
Write-Host "这个目录可以整个拷到别的电脑上直接运行（需要目标机装有 Chrome）。"
Write-Host "首次运行会自动创建浏览器配置目录并启动调试浏览器。"
