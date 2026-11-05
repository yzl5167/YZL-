# Windows 上把「未签名 IPA」自签成「可直接安装的 IPA」。
# 本文件必须是 UTF-8 BOM（PowerShell 5.1 按 GBK 读无 BOM 的中文脚本会乱码）。
#
#   路线 A（免费 Apple ID，推荐）：不需要本脚本，用 Sideloadly 的 Export 模式，见 docs/SIGNING.md。
#   路线 B（有 .p12 + .mobileprovision，可自动化 / CI 用）：
#     $env:P12_PASSWORD = "..."
#     powershell -ExecutionPolicy Bypass -File .\scripts\sign-ipa.ps1 `
#       -P12 certs\dev.p12 -MobileProvision certs\dev.mobileprovision -TeamId ABCDE12345
param(
    [string]$Ipa = "dist\YZLLauncher-unsigned.ipa",
    [string]$P12 = "",
    [string]$MobileProvision = "",
    [string]$TeamId = "",
    [string]$Password = "",
    [string]$BundleId = "com.yzl.launcher",
    [string]$Output = "dist\YZLLauncher-signed.ipa",
    [string]$Entitlements = "packaging\entitlements.free.plist",
    [string]$Zsign = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Show-FreeAppleIDGuide {
    Write-Host ""
    Write-Host "还没有 .p12 证书，本脚本无法签名。免费 Apple ID 请走 Sideloadly 的导出模式："
    Write-Host "  1. 官网装 Sideloadly（Windows 需非商店版 iTunes + iCloud）"
    Write-Host "  2. 把 dist\YZLLauncher-unsigned.ipa 拖进窗口，填自己的 Apple ID"
    Write-Host "  3. Advanced options -> Signing mode 选 Export（不是 Apple ID Sideload）"
    Write-Host "  4. Start -> 选保存路径 -> 得到已签名 .ipa 文件"
    Write-Host "  限制：免费账号 7 天有效、同时最多 3 个自签 App、每周最多 10 个 App ID。"
    Write-Host "  装完在 iPhone：设置 -> 通用 -> VPN 与设备管理 -> 信任你的 Apple ID。"
    Write-Host "  详见 docs/SIGNING.md。"
}

if ([string]::IsNullOrWhiteSpace($P12) -or [string]::IsNullOrWhiteSpace($MobileProvision)) {
    Write-Host "缺少 -P12 / -MobileProvision。"
    Show-FreeAppleIDGuide
    exit 1
}
if ([string]::IsNullOrWhiteSpace($TeamId)) {
    throw "缺少 -TeamId（developer.apple.com -> Membership 里 10 位 Team ID，entitlement 模板要用）"
}
if ([string]::IsNullOrWhiteSpace($Password)) { $Password = $env:P12_PASSWORD }
if ([string]::IsNullOrWhiteSpace($Password)) { $Password = Read-Host "p12 密码" }

foreach ($p in @($Ipa, $P12, $MobileProvision, $Entitlements)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "找不到文件：$p" }
}

if ([string]::IsNullOrWhiteSpace($Zsign)) {
    $cmd = Get-Command zsign -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $Zsign = $cmd.Source }
}
if ([string]::IsNullOrWhiteSpace($Zsign) -or -not (Test-Path -LiteralPath $Zsign)) {
    throw @"
找不到 zsign。它是跨平台的 codesign 实现（Windows 原生，无需 Xcode）：
  https://github.com/zhlynn/zsign  -> 用 VS2022 打开 build/windows/vs2022/zsign.sln 编译，
  或取第三方预编译包；然后把 exe 放到 PATH，或用 -Zsign 传完整路径。
"@
}

Write-Host "[1/4] 生成 entitlement（TeamID 占位替换）"
$template = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Entitlements).Path)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("yzl-sign-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$ent = Join-Path $tmp "entitlements.plist"
[IO.File]::WriteAllText($ent, $template.Replace("TEAMID", $TeamId), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "      team=$TeamId bundle=$BundleId"

Write-Host "[2/4] zsign 签名"
$outDir = Split-Path -Parent $Output
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$signArgs = @(
    "-k", (Resolve-Path -LiteralPath $P12).Path,
    "-p", $Password,
    "-m", (Resolve-Path -LiteralPath $MobileProvision).Path,
    "-e", $ent,
    "-b", $BundleId,
    "-z", "9",
    "-o", $Output,
    (Resolve-Path -LiteralPath $Ipa).Path
)
& $Zsign @signArgs
if ($LASTEXITCODE -ne 0) { throw "zsign 签名失败（exit $LASTEXITCODE）：证书、描述文件、bundle id、entitlement 是否匹配？" }

Write-Host "[3/4] 校验签名"
& $Zsign -C $Output
if ($LASTEXITCODE -ne 0) { Write-Host "      校验命令返回 $LASTEXITCODE，请人工确认输出" }

Write-Host "[4/4] 清理"
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

$dest = (Resolve-Path -LiteralPath $Output).Path
Write-Host ("      已签名 IPA：{0} ({1:N0} KB)" -f $dest, ((Get-Item -LiteralPath $dest).Length / 1KB))
Write-Host ""
Write-Host "安装：把这个 .ipa 用 Sideloadly / AltServer / Apple Configurator 装到已注册 UDID 的设备。"
Write-Host "首次打开前：iPhone 设置 -> 通用 -> VPN 与设备管理 -> 信任证书。"
Write-Host "注意：M2 引擎还需要 JIT，iOS 18.x 上要用 StikDebug / SideJITServer 附加，签名本身不解决 JIT。"
Write-Host "DONE"
