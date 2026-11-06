# 删除临时编译仓库（classic token 必须有 delete_repo 作用域，否则 GitHub 返回 403 "Must have admin rights to Repository"）。
#
#   $env:GITHUB_TOKEN="ghp_..."
#   powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\delete-repo.ps1 -ListOnly
#   powershell ... -File .\delete-repo.ps1 -RepoName yzl-ios-build-261105-200256
#   powershell ... -File .\delete-repo.ps1 -Prefix yzl-ios-build -Yes       # 批量清掉所有临时仓库
param(
    [string]$RepoName = "",
    [string]$Prefix = "yzl-ios-build",
    [switch]$ListOnly,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN（需要 delete_repo 作用域）" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "没有令牌，无法继续。" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-delete-repo"
}
$api = "https://api.github.com"

$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
$owner = $me.login
Write-Host "账号 $owner"

$targets = @()
if (-not [string]::IsNullOrWhiteSpace($RepoName)) {
    $targets += $RepoName
}
if ($ListOnly -or $targets.Count -eq 0) {
    # 先赋值再走管道：@(Invoke-RestMethod ...) 在 PS 5.1 下会把整个 JSON 数组当成一个元素，
    # 那样 $_.name 是所有仓库名的数组，-like 会全部命中。
    $raw = Invoke-RestMethod -Uri "$api/user/repos?per_page=100&affiliation=owner" -Headers $headers
    $repos = @($raw | ForEach-Object { $_ })
    $targets = @($repos | Where-Object { $_.name -like ($Prefix + '*') } | ForEach-Object { $_.name })
    Write-Host ("匹配 {0}* 的仓库：{1} 个" -f $Prefix, $targets.Count)
    foreach ($r in $repos) {
        Write-Host ("  {0,-34} {1,-8} {2} KB" -f $r.name, $(if ($r.private) { 'private' } else { 'PUBLIC' }), $r.size)
    }
}
if ($ListOnly) { return }
if ($targets.Count -eq 0) { Write-Host "没有要删的仓库。"; return }

if (-not $Yes) {
    Write-Host ("将要删除：{0}" -f ($targets -join ', '))
    $ans = Read-Host "确认删除请输入 YES（不可恢复）"
    if ($ans -ne 'YES') { Write-Host "已取消。"; return }
}

foreach ($name in $targets) {
    try {
        Invoke-RestMethod -Uri "$api/repos/$owner/$name" -Headers $headers -Method Delete | Out-Null
        Write-Host "  已删除 $owner/$name"
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) {
            Write-Host "  403：这把 token 没有 delete_repo 作用域。重新生成 token 时勾上，或在手机浏览器里用 Danger Zone 删除：$name"
        } else {
            Write-Host ("  删除失败 {0}：{1}" -f $name, $_.Exception.Message.Split([char]10)[0])
        }
    }
}
