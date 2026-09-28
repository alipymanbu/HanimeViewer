$ErrorActionPreference = 'Stop'

# 给 MSIX 生成一张自签名证书。
#
# 为什么不用 msix 包默认那张 "Msix Testing"：那张证书的 subject 是
# 写死的、也没有导出成文件，用户没法信任它 —— 装的时候只会得到
# "证书链不受信任"。自己生成一张 subject 是 CN=HanimeViewer 的，
# 导出 .cer 一起发给用户，装一次就行。

$outDir = "E:\Hanime\HanimeViewer\frontend\msix_cert"
$password = "HanimeViewer"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$pfx = Join-Path $outDir "HanimeViewer.pfx"
$cer = Join-Path $outDir "HanimeViewer.cer"

# 已经生成过就直接用（重打 MSIX 时不要每次都换证书，
# 换了的话用户得重新信任一次）
#
# 注意：Windows PowerShell 5.1 的 Get-PfxCertificate **没有** -Password 参数
# （PowerShell 7 才有），所以这里只判断文件在不在，不去读它。
if ((Test-Path $pfx) -and (Test-Path $cer)) {
  Write-Host "certificate already exists, reusing it:"
  Write-Host "  $pfx"
  Write-Host "  $cer"
  exit 0
}

Write-Host "creating a self-signed certificate..."

# 代码签名用的扩展：
#   1.3.6.1.5.5.7.3.3 = Extended Key Usage: Code Signing
#   2.5.29.19         = Basic Constraints (CA=false)
$cert = New-SelfSignedCertificate `
  -Type Custom `
  -Subject "CN=HanimeViewer" `
  -KeyUsage DigitalSignature `
  -FriendlyName "HanimeViewer MSIX signing" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @(
    "2.5.29.37={text}1.3.6.1.5.5.7.3.3",
    "2.5.29.19={text}"
  ) `
  -NotAfter (Get-Date).AddYears(10)

$secure = ConvertTo-SecureString -String $password -AsPlainText -Force

Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

Write-Host "  wrote $pfx"
Write-Host "  wrote $cer"
Write-Host "  Subject   : $($cert.Subject)"
Write-Host "  Thumbprint: $($cert.Thumbprint)"
Write-Host "  NotAfter  : $($cert.NotAfter)"

# 从个人证书库里删掉：签名用 pfx 就够了，不用在用户证书库里留一份
Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
Write-Host "  removed the temp copy from Cert:\CurrentUser\My"

exit 0
