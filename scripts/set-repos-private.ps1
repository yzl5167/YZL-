# 一次性把指定 GitHub 仓库改成私有（或改回公开），用于"源码不公开"的收口操作。
#
#   $env:GITHUB_TOKEN="ghp_..."
#   powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\set-repos-private.ps1
#   powershell ... -File .\set-repos-private.ps1 -Public          # 改回公开（PC 客户端下载挂了就用这个回滚）
#   powershell ... -File .\set-repos-private.ps1 -Repos 'YZL-','YZLLauncher'
#
# 注意：改私有之后，GitHub Releases 的匿名下载链接会立刻 404。PC 启动器的自动更新实测走的是
# Gitee（UpdateService.cs:50 指向 gitee.com/rainy-waves/YZL-Launcher-Update/...），不受影响；
# 但旧版 Python 启动器 YZLLauncher 的 v1.4.x Release 链接会失效。
param(
    [string[]]$Repos = @('YZL-', 'YZLLauncher', 'YZL-Launcher-Update'),
    [switch]$Public
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN（classic，需 repo 作用域）" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "没有令牌，无法继续。" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-repo-visibility"
}
$api = "https://api.github.com"

$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
$owner = $me.login
$wantPrivate = -not $Public
Write-Host ("账号 {0}，目标可见性：{1}" -f $owner, $(if ($wantPrivate) { '私有' } else { '公开' }))

foreach ($name in $Repos) {
    if ($name -match '^yzl-ios-build') {
        Write-Host ("  跳过 {0}（这是编译用的临时仓库，由 ephemeral-build.ps1 自己负责删除）" -f $name)
        continue
    }
    $uri = "$api/repos/$owner/$name"
    try {
        $repo = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 25
    } catch {
        Write-Host ("  {0} 取不到，跳过：{1}" -f $name, $_.Exception.Message.Split([char]10)[0])
        continue
    }
    $busy = Invoke-RestMethod -Uri ($uri + '/actions/runs?status=in_progress&per_page=5') -Headers $headers -TimeoutSec 25
    if ($busy.total_count -gt 0) {
        Write-Host ("  {0} 正在跑 Actions 构建，先等它结束再改可见性（跳过）" -f $name)
        continue
    }
    if ($repo.private -eq $wantPrivate) {
        Write-Host ("  {0} 已经是{1}，不用动" -f $name, $(if ($repo.private) { '私有' } else { '公开' }))
        continue
    }
    $body = @{ private = $wantPrivate } | ConvertTo-Json
    $after = Invoke-RestMethod -Uri $uri -Headers $headers -Method Patch -Body $body -ContentType 'application/json' -TimeoutSec 25
    Write-Host ("  {0}: private {1} -> {2}   (size={3}KB)" -f $name, $repo.private, $after.private, $repo.size)
}

Write-Host ''
Write-Host '核对结果：'
$all = Invoke-RestMethod -Uri "$api/user/repos?per_page=100&affiliation=owner" -Headers $headers -TimeoutSec 25
foreach ($r in ($all | Sort-Object { $_.name })) {
    Write-Host ("  {0,-30} {1}" -f $r.name, $(if ($r.private) { 'private' } else { 'PUBLIC' }))
}
Write-Host 'DONE'
