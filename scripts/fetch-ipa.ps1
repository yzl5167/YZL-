# 只负责「触发云构建 / 取回 IPA」，不上传源码。
# 首次上传源码用 scripts/api-publish.ps1；之后改代码、重试构建、只想拿包都用本脚本。
# 本文件必须是 UTF-8 BOM（PowerShell 5.1 按 GBK 读无 BOM 的中文脚本会乱码）。
#
#   $env:GITHUB_TOKEN = "github_pat_..."
#   powershell -ExecutionPolicy Bypass -File .\scripts\fetch-ipa.ps1
#   powershell ... -File .\scripts\fetch-ipa.ps1 -NoTrigger
#   powershell ... -File .\scripts\fetch-ipa.ps1 -RunId 1234567890
#   powershell ... -File .\scripts\fetch-ipa.ps1 -RepoUrl https://github.com/owner/repo -OutputDir dist
param(
    [string]$RepoUrl = "",
    [string]$Owner = "",
    [string]$RepoName = "",
    [string]$OutputDir = "dist",
    [int]$TimeoutMinutes = 35,
    [int]$RunId = 0,
    [switch]$NoTrigger
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::Expect100Continue = $false
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "缺少 GITHUB_TOKEN" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-ios-fetch-ipa"
}
$api = "https://api.github.com"
$workflowFile = "build-ipa.yml"
$artifactName = "YZLLauncher-unsigned-ipa"

function Try-Get($uri) {
    try { return Invoke-RestMethod -Uri $uri -Headers $headers } catch { return $null }
}

function Parse-RunDate($value) {
    return [DateTime]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}

function Show-FailureLogs($run) {
    Write-Host "      网页日志：$($run.html_url)"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("yzl-ios-logs-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = Join-Path $tmp "logs.zip"
        Invoke-WebRequest -Uri "$($run.url)/logs" -Headers $headers -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp "out") -Force
        $hits = @(Get-ChildItem -LiteralPath (Join-Path $tmp "out") -Recurse -File -Filter *.txt |
            Select-String -Pattern "error:|fatal error|The following build commands failed|exit code" |
            Select-Object -First 40)
        if ($hits.Count -eq 0) {
            Write-Host "      日志里没匹配到 error:，请展开查看完整日志包"
        } else {
            Write-Host "      ---- 编译错误摘录 ----"
            foreach ($h in $hits) { Write-Host ("      {0}" -f $h.Line.Trim()) }
            Write-Host "      ---- 摘录结束 ----"
        }
    } catch {
        Write-Host "      拉取日志失败：$($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[1/5] 校验 token"
$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
Write-Host "      账号 $($me.login)"

Write-Host "[2/5] 定位仓库"
if (-not [string]::IsNullOrWhiteSpace($RepoUrl)) {
    if ($RepoUrl -match '^(?:https?://|git@)?[^/:\s@]+(?::\d+)?[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$' -or
        $RepoUrl -match '^([^/\s]+)/([^/\s]+?)(?:\.git)?$') {
        $Owner = $Matches[1]
        $RepoName = $Matches[2]
    } else {
        throw "看不懂仓库地址：$RepoUrl"
    }
}
if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = $me.login }
if ([string]::IsNullOrWhiteSpace($RepoName)) {
    $listed = @(Try-Get "$api/user/repos?per_page=100&affiliation=owner")
    $cand = @($listed | Where-Object { $_.name -match '(?i)ios' } | Sort-Object -Property updated_at -Descending)
    if ($cand.Count -eq 0) { throw "没找到名字带 ios 的仓库，请传 -RepoName 或 -RepoUrl" }
    $RepoName = $cand[0].name
}
$repoUri = "$api/repos/$Owner/$RepoName"
$repo = Try-Get $repoUri
if ($null -eq $repo) { throw "仓库不可见：$Owner/$RepoName（私有仓库需要 token 有该仓库权限）" }
Write-Host "      $($repo.full_name)（private=$($repo.private)）"
if ($repo.private) {
    Write-Host "      提醒：私有仓库 macOS Runner 按 10 倍计费，建议改成 Public。"
}

Write-Host "[3/5] 确定构建任务"
$run = $null
if ($RunId -gt 0) {
    $run = Try-Get "$repoUri/actions/runs/$RunId"
    if ($null -eq $run) { throw "找不到 run $RunId" }
    Write-Host "      使用指定 run $RunId"
} elseif ($NoTrigger) {
    $runs = Try-Get "$repoUri/actions/workflows/$workflowFile/runs?per_page=10"
    $candidates = @($runs.workflow_runs | Sort-Object { Parse-RunDate $_.created_at } -Descending)
    if ($candidates.Count -eq 0) { throw "这个工作流还没有运行记录" }
    $run = $candidates[0]
    Write-Host "      使用最近一次 run $($run.id)"
} else {
    $sinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-2)
    Invoke-RestMethod -Uri "$repoUri/actions/workflows/$workflowFile/dispatches" `
        -Headers $headers -Method Post `
        -Body (@{ ref = "main" } | ConvertTo-Json) -ContentType "application/json" | Out-Null
    Write-Host "      已触发，等待 macOS Runner（通常 5-20 分钟）"

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $runs = Try-Get "$repoUri/actions/runs?branch=main&per_page=20"
        if ($null -eq $runs) { continue }
        $fresh = @($runs.workflow_runs | Where-Object {
            $_.name -eq "Build unsigned IPA" -and (Parse-RunDate $_.created_at) -ge $sinceUtc
        } | Sort-Object { Parse-RunDate $_.created_at } -Descending)
        if ($fresh.Count -eq 0) { Write-Host "      run 还没出现"; continue }
        $run = $fresh[0]
        Write-Host ("      run {0}: {1} / {2}" -f $run.id, $run.status, $run.conclusion)
        if ($run.status -eq "completed") { break }
    }
}
if ($null -eq $run) { throw "没拿到构建任务（可能超时，请到 Actions 页面确认）" }

Write-Host "[4/5] 等待构建完成"
if ($run.status -ne "completed") {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline -and $run.status -ne "completed") {
        Start-Sleep -Seconds 20
        $run = Try-Get "$repoUri/actions/runs/$($run.id)"
        Write-Host ("      run {0}: {1}" -f $run.id, $run.status)
    }
}
if ($run.status -ne "completed") { throw "构建超时，请到 $($run.html_url) 查看" }
if ($run.conclusion -ne "success") {
    Write-Host "      构建失败：$($run.conclusion)"
    Show-FailureLogs $run
    exit 1
}
Write-Host "      构建成功"

Write-Host "[5/5] 下载 IPA 与 TIPA"
$arts = Try-Get "$($run.url)/artifacts"
$targets = @($arts.artifacts | Where-Object {
    -not $_.expired -and $_.name -match '(?i)(ipa|tipa)'
})
if ($targets.Count -eq 0) { throw "run $($run.id) 里没有 IPA / TIPA artifact" }

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("yzl-ios-ipa-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    foreach ($art in $targets) {
        $artDir = Join-Path $tmp ($art.name -replace '[^\w\-]', '_')
        New-Item -ItemType Directory -Path $artDir -Force | Out-Null
        $zip = Join-Path $artDir "artifact.zip"
        Invoke-WebRequest -Uri $art.archive_download_url -Headers $headers -OutFile $zip
        $extract = Join-Path $artDir "out"
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        $found = @(Get-ChildItem -LiteralPath $extract -Recurse -File |
            Where-Object { $_.Extension -in @('.ipa', '.tipa') })
        foreach ($f in $found) {
            $destName = if ($f.Extension -ieq '.tipa') {
                'com.yzl.launcher.tipa'
            } else {
                'YZLLauncher-unsigned.ipa'
            }
            $dest = Join-Path $OutputDir $destName
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            Write-Host ("      {0}: {1} ({2:N0} KB)" -f `
                $destName, (Resolve-Path -LiteralPath $dest).Path, ($f.Length / 1KB))
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "【主线 · FCL 式】com.yzl.launcher.tipa"
Write-Host "  传到 iPhone -> 文件 App 长按 -> 分享 -> TrollStore -> Install"
Write-Host "  永久签名、免 Apple ID、自动 JIT，装好 TrollStore 后全程不用电脑"
Write-Host "  设备需 iOS 14.0 beta 2 - 16.6.1 / 16.7 RC (20H18) / 17.0"
Write-Host "  推 v* tag 时 .tipa 会直接挂到 GitHub Release，手机 Safari 下载即可"
Write-Host ""
Write-Host "【备用】iOS 17.0.1+ / 18.x 装不了 TrollStore，只能用未签名 IPA 走 7 天自签"
Write-Host "  免费 Apple ID 或 .p12 证书，见 docs/SIGNING.md（当前不采用）"
Write-Host "DONE"
