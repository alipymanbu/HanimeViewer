$ErrorActionPreference = 'Stop'

# 验证打出来的 MSIX：签名、内容、清单、发布者和证书对不对得上。
# 注意：PowerShell 5.1 按系统代码页读脚本，字符串里写中文会解析失败，
# 所以下面的提示文字一律用英文（注释里可以用中文）。

$msix = "E:\Hanime\HanimeViewer\HanimeData\Release\HanimeViewer.msix"

Write-Host "=== 1. signature ==="
$sig = Get-AuthenticodeSignature $msix
Write-Host "  Status : $($sig.Status)"
Write-Host "  Signer : $($sig.SignerCertificate.Subject)"
Write-Host "  Issuer : $($sig.SignerCertificate.Issuer)"
Write-Host "  Thumb  : $($sig.SignerCertificate.Thumbprint)"

Write-Host ""
Write-Host "=== 2. contents (msix is just a zip) ==="
$tmp = Join-Path $env:TEMP "hv_msix_unpack"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

Copy-Item $msix (Join-Path $tmp "pkg.zip")
Expand-Archive -Path (Join-Path $tmp "pkg.zip") -DestinationPath (Join-Path $tmp "x") -Force

$root = Join-Path $tmp "x"

Get-ChildItem $root | ForEach-Object {
  if ($_.PSIsContainer) { "  [DIR] " + $_.Name }
  else { "  " + $_.Name.PadRight(34) + [math]::Round($_.Length/1KB,1) + " KB" }
}

Write-Host ""
Write-Host "=== 3. required files ==="
foreach ($f in @("frontend.exe", "hanime_backend.exe", "flutter_windows.dll", "AppxManifest.xml")) {
  $p = Join-Path $root $f
  if (Test-Path $p) {
    Write-Host ("  {0,-24} OK  ({1} KB)" -f $f, [math]::Round((Get-Item $p).Length/1KB,1))
  } else {
    Write-Host ("  {0,-24} MISSING !!" -f $f)
  }
}

$dataDir = Join-Path $root "data"
if (Test-Path $dataDir) {
  $n = (Get-ChildItem $dataDir -Recurse -File).Count
  Write-Host ("  {0,-24} OK  ({1} files)" -f "data\ (flutter assets)", $n)
} else {
  Write-Host ("  {0,-24} MISSING !!" -f "data\ (flutter assets)")
}

Write-Host ""
Write-Host "=== 4. AppxManifest.xml ==="
[xml]$m = Get-Content (Join-Path $root "AppxManifest.xml") -Encoding utf8
$id = $m.Package.Identity
Write-Host "  Identity Name : $($id.Name)"
Write-Host "  Publisher     : $($id.Publisher)"
Write-Host "  Version       : $($id.Version)"
Write-Host "  Architecture  : $($id.ProcessorArchitecture)"
$app = $m.Package.Applications.Application
Write-Host "  DisplayName   : $($m.Package.Properties.DisplayName)"
Write-Host "  App Id        : $($app.Id)"
Write-Host "  Executable    : $($app.Executable)"
Write-Host "  EntryPoint    : $($app.EntryPoint)"
Write-Host "  Capabilities  : $($m.Package.Capabilities.Capability.Name -join ', ')"

Write-Host ""
Write-Host "=== 5. publisher vs certificate (must match or install fails) ==="
$manifestPublisher = $id.Publisher
$certSubject = $sig.SignerCertificate.Subject
Write-Host "  manifest: $manifestPublisher"
Write-Host "  cert    : $certSubject"
if ($manifestPublisher -eq $certSubject) {
  Write-Host "  -> MATCH"
} else {
  Write-Host "  -> MISMATCH !!"
}

Remove-Item $tmp -Recurse -Force

exit 0
