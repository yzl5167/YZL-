# YZL Launcher iOS 一键云构建（Windows 可直接运行）
#
# 作用：用你的 GitHub 令牌，把本地源码推成私有仓库 -> 触发 macOS Runner 编译
#      -> 等构建完成 -> 下载未签名 IPA，之后你用 AltServer 自签或 TrollStore 直装。
#
# 运行（在 d:\yzl启动器开放 目录下）：
#   $env:GITHUB_TOKEN="github_pat_..."   # 只勾 Contents: Read and write + Workflows
#   powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\ci-bootstrap.ps1
#
# 可选参数：
#   -RepoName yzl-launcher-ios   -Public            # 公开仓库（macOS 分钟数不受限）
param(
    [string]$RepoName = "yzl-launcher-ios",
    [switch]$Public
)

$ErrorActionPreference = "Stop"

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = Read-Host "粘贴 GitHub fine-grained token（Contents 写 + Workflows）"
}
if ([string]::IsNullOrWhiteSpace($token)) { throw "没有令牌，无法继续。" }

$headers = @{
    Authorization = "Bearer $token"
    Accept        = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"   = "yzl-ios-bootstrap"
}
$api = "https://api.github.com"

Write-Host "[1/6] 校验令牌身份..."
$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
$login = $me.login
Write-Host "  账号：$login"

$projectDir = Join-Path (Get-Location) "YZL-Launcher-iOS"
if (-not (Test-Path $projectDir)) { throw "找不到 $projectDir，请在 d:\yzl启动器开放 下运行。" }

Write-Host "[2/6] 创建仓库 $login/$RepoName（私有）..."
$repoUrl = "$api/repos/$login/$RepoName"
try {
    $repo = Invoke-RestMethod -Uri $repoUrl -Headers $headers
    Write-Host "  仓库已存在，复用。"
} catch {
    $body = @{
        name          = $RepoName
        private       = (-not $Public)
        auto_init     = $false
        description   = "YZL Launcher iOS (Minecraft Java Edition sideload launcher, WIP)"
    } | ConvertTo-Json
    $repo = Invoke-RestMethod -Uri "$api/user/repos" -Headers $headers -Method Post -Body $body -ContentType "application/json"
    Write-Host "  已创建。"
}

Write-Host "[3/6] git 初始化与提交..."
Push-Location $projectDir
try {
    if (-not (Test-Path ".git")) { git init -b main | Out-Null }
    git config user.name  $login
    git config user.email "$($me.id)+$login@users.noreply.github.com"
    git add .
    $hasChanges = (& git status --porcelain)
    if ($hasChanges) {
        git commit -m "YZL Launcher iOS: M0 shell + M1 auth/download core, build and signing scripts" | Out-Null
        Write-Host "  已提交。"
    } else {
        Write-Host "  无新改动。"
    }

    $authUrl = "https://x-access-token:$token@github.com/$login/$RepoName.git"
    $remoteExists = (& git remote get-url origin 2>$null)
    if ($remoteExists) { git remote set-url origin $authUrl } else { git remote add origin $authUrl }
    git push -u origin main
    Write-Host "  已推送。"
} finally {
    Pop-Location
}

Write-Host "[4/6] 等待 Actions 构建（macOS runner，通常 5-15 分钟）..."
$deadline = (Get-Date).AddMinutes(35)
$run = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $runs = Invoke-RestMethod -Uri "$api/repos/$login/$RepoName/actions/runs?branch=main&per_page=5" -Headers $headers
    $run = $runs.workflow_runs | Where-Object { $_.name -eq "Build unsigned IPA" } | Select-Object -First 1
    if ($null -eq $run) { $run = $runs.workflow_runs | Select-Object -First 1 }
    if ($null -eq $run) { Write-Host "  还没出现构建记录..."; continue }
    Write-Host ("  状态：{0} / {1}" -f $run.status, $run.conclusion)
    if ($run.status -eq "completed") { break }
}
if ($null -eq $run -or $run.status -ne "completed") { throw "等待超时，去 Actions 页面看进度。" }
if ($run.conclusion -ne "success") {
    Write-Host "  构建失败（$($run.conclusion)）。" -ForegroundColor Red
    Write-Host "  日志：$($run.html_url)"
    Write-Host "  把这页的报错原文复制给我，我来修。"
    exit 1
}

Write-Host "[5/6] 下载产物..."
$artifacts = Invoke-RestMethod -Uri "$api/repos/$login/$RepoName/actions/runs/$($run.id)/artifacts" -Headers $headers
if ($artifacts.total_count -lt 1) { throw "构建成功但没有 artifact。" }
$artifact = $artifacts.artifacts | Select-Object -First 1
$zipPath = Join-Path (Get-Location) "yzl-artifact.zip"
Invoke-WebRequest -Uri "$($artifact.archive_download_url)" -Headers $headers -OutFile $zipPath
$outDir = Join-Path (Get-Location) "yzl-ios-build"
if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
Expand-Archive -Path $zipPath -DestinationPath $outDir -Force
Remove-Item $zipPath
$ipa = Get-ChildItem -Recurse -Path $outDir -Filter "*.ipa" | Select-Object -First 1
if ($null -eq $ipa) { throw "artifact 里没找到 ipa。" }

Write-Host "[6/6] 完成。"
Write-Host "  未签名 IPA：$($ipa.FullName)"
Write-Host ""
Write-Host "接下来："
Write-Host "  A) TrollStore 机型（iOS 14.0b2-16.6.1 / 16.7RC / 17.0）：把 ipa 传到手机 -> 文件 App 长按共享 -> TrollStore 安装。"
Write-Host "  B) 其它机型：用 Windows 上的 AltServer 右键 Sign App 签名（约 7 天），JIT 需要 AltServer/StikDebug 附加。"
Write-Host "  注意：这只是外壳 App，能装能看界面，但还进不了游戏（M2 才接 Java 内核）。"
