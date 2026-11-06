# M2-b 引擎基线构建：api.github.com only 触发 + 轮询 + 取回产物。
#
# 与 api-publish.ps1 同一套通道（本机 github.com POST 不通，GET 全通），
# 触发的是 build-engine-ipa.yml（Amethyst fork-overlay 引擎构建，
# 见 docs/M2B-ENGINE.md），产物是带全套 JRE + 图形栈 + YZL UI 的 .tipa。
#
#   $env:GITHUB_TOKEN="github_pat_..."   # fine-grained：Contents RW + Workflows RW
#   powershell -ExecutionPolicy Bypass -File .\scripts\publish-engine.ps1
#
# 可选参数：
#   -RepoName 名字       # 复用已有仓库（默认自动找名字带 ios 的）
#   -AmethystRef main    # pin 的 Amethyst 分支/SHA（默认 main）
#   -TimeoutMinutes 100  # 引擎构建比外壳慢，默认 100 分钟
#
# 注意：引擎构建跑 macOS runner。私有仓库按 10 倍计费，所以本脚本
# 默认把仓库建为/保持 Public（iOS 端本就按 GPLv3 开源，见 README 合规节）。
param(
    [string]$RepoName = "",
    [string]$Owner = "",
    [string]$AmethystRef = "main",
    [string]$SourceDir = "YZL-Launcher-iOS",
    [int]$TimeoutMinutes = 100,
    [switch]$Private
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::Expect100Continue = $false
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "no token" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-ios-engine-publish"
}
$api = "https://api.github.com"
$json = "application/json"
$wfFile = "build-engine-ipa.yml"
$wfName = "Engine baseline (M2-b experiment)"

function Post-Json($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Put-Json($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Patch-Json($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Patch -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Try-Get($uri) {
    try { return Invoke-RestMethod -Uri $uri -Headers $headers } catch { return $null }
}

Write-Host "[1/8] token identity"
$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
$login = $me.login
Write-Host "      $login"

Write-Host "[2/8] 定位仓库"
if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = $login }
if ([string]::IsNullOrWhiteSpace($RepoName)) {
    $listed = @()
    try {
        $raw = Invoke-RestMethod -Uri "$api/user/repos?per_page=100&affiliation=owner" -Headers $headers
        $listed = @($raw | ForEach-Object { $_ })
    } catch {
        Write-Host "      列仓库失败：$($_.Exception.Message.Split([char]10)[0])"
    }
    $cand = @($listed | Where-Object { $_.name -match '(?i)ios' } | Sort-Object -Property updated_at -Descending)
    if ($cand.Count -gt 0) {
        $RepoName = $cand[0].name
        Write-Host "      自动选中：$Owner/$RepoName"
    } else {
        $RepoName = 'yzllauncher-ios'
        Write-Host "      没有名字带 ios 的仓库，按默认名 $Owner/$RepoName 继续"
    }
}
$repoUri = "$api/repos/$Owner/$RepoName"
$repo = Try-Get $repoUri
if ($null -eq $repo) {
    try {
        $repo = Post-Json "$api/user/repos" @{
            name        = $RepoName
            private     = [bool]$Private
            auto_init   = $false
            description = "YZL Launcher iOS engine baseline (M2-b fork-overlay build)"
        }
        Write-Host "      created (private=$([bool]$Private))"
    } catch {
        Write-Host "      建仓失败（fine-grained token 通常不能建仓）：$($_.Exception.Message.Split([char]10)[0])"
        Write-Host "      请在手机浏览器（蜂窝流量）打开 https://github.com/new 手动建空仓库 $RepoName（不要勾 README），再重跑。"
        throw "仓库不存在且无法自动创建"
    }
} else {
    Write-Host "      exists (private=$($repo.private))"
}
if ($repo.private) {
    Write-Host "      !! 私有仓库 macOS 分钟 10 倍计费，引擎构建约 20-40 分钟，免费额度可能不够。"
    Write-Host "      !! 建议 Public（本脚本不强制；网页 Settings -> General -> Danger Zone 改可见性）。"
}

Write-Host "[3/8] seed initial commit if repo is empty"
$ref = Try-Get "$repoUri/git/ref/heads/main"
if ($null -eq $ref) {
    $readmePath = Join-Path $SourceDir "README.md"
    if (Test-Path $readmePath) {
        $content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($readmePath))
    } else {
        $content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# YZL Launcher iOS`n"))
    }
    Put-Json "$repoUri/contents/README.md" @{
        message = "chore: seed repo"
        content = $content
    } | Out-Null
    $ref = Invoke-RestMethod -Uri "$repoUri/git/ref/heads/main" -Headers $headers
    Write-Host "      seeded README.md"
} else {
    Write-Host "      main already exists"
}
$parentSha = $ref.object.sha

Write-Host "[4/8] upload blobs（含 engine/ 补丁与脚本，GitHub 工作流要用的就是它们）"
$base = (Resolve-Path $SourceDir).Path
$skipDirs = @('\.git\', '\build\', '\build-test\', '\build-output\', '\dist\', '\dist-engine\', '\bin\', '\obj\', '\node_modules\')
$skipExt  = @('.ipa', '.tipa', '.zip', '.exe', '.dll', '.log')
$files = @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object {
    $path = $_.FullName
    $hit = $false
    foreach ($s in $skipDirs) {
        if ($path -like ('*' + $s + '*')) { $hit = $true; break }
    }
    (-not $hit) -and ($skipExt -notcontains $_.Extension)
})
Write-Host "      $($files.Count) files"
$tree = @()
$i = 0
foreach ($f in $files) {
    $i++
    Write-Progress -Activity "upload" -Status $f.Name -PercentComplete ($i * 100 / $files.Count)
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $b64 = [Convert]::ToBase64String($bytes)
    $sha = (Post-Json "$repoUri/git/blobs" @{ content = $b64; encoding = "base64" }).sha
    $rel = $f.FullName.Substring($base.Length + 1) -replace "\\", "/"
    $mode = if ($rel -match "\.sh$") { "100755" } else { "100644" }
    $tree += @{ path = $rel; mode = $mode; type = "blob"; sha = $sha }
}
Write-Progress -Activity "upload" -Completed
Write-Host "      $($tree.Count) files uploaded"

Write-Host "[5/8] tree + commit + force update main"
$rootTree = Post-Json "$repoUri/git/trees" @{ tree = $tree }
$commit = Post-Json "$repoUri/git/commits" @{
    message = "YZL iOS engine (M2-b): fork-overlay patches, YZLUI target, engine CI"
    tree    = $rootTree.sha
    parents = @($parentSha)
}
Patch-Json "$repoUri/git/refs/heads/main" @{ sha = $commit.sha; force = $true } | Out-Null
Write-Host "      commit $($commit.sha.Substring(0,7)) on main"

Write-Host "[6/8] dispatch build-engine-ipa.yml (AmethystRef=$AmethystRef)"
$sinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-2)
Post-Json "$repoUri/actions/workflows/$wfFile/dispatches" @{
    ref    = "main"
    inputs = @{ amethyst_ref = $AmethystRef }
} | Out-Null

Write-Host "[7/8] wait for macOS engine build（通常 15-40 分钟，耐心等）"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$run = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
    $runs = Invoke-RestMethod -Uri "$repoUri/actions/runs?branch=main&per_page=20" -Headers $headers
    $fresh = @($runs.workflow_runs | Where-Object {
        $_.name -eq $wfName -and
        [DateTime]::Parse($_.created_at, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() -ge $sinceUtc
    } | Sort-Object { [DateTime]::Parse($_.created_at, [System.Globalization.CultureInfo]::InvariantCulture) } -Descending)
    if ($fresh.Count -eq 0) { Write-Host "      no run yet（工作流可能还没被识别，首次推送约需半分钟）"; continue }
    $run = $fresh[0]
    $elapsed = [int]((Get-Date) - [DateTime]::Parse($run.created_at)).TotalMinutes
    Write-Host ("      run {0}: {1} / {2}  ({3} min)" -f $run.id, $run.status, $run.conclusion, $elapsed)
    if ($run.status -eq "completed") { break }
}
if ($null -eq $run -or $run.status -ne "completed") {
    throw "timeout after $TimeoutMinutes min（手机浏览器开 $repoUri/actions 看进度）"
}

if ($run.conclusion -ne "success") {
    Write-Host "      ENGINE BUILD FAILED: $($run.conclusion)"
    Write-Host "      web logs: $($run.html_url)"
    $logZip = Join-Path (Get-Location) "yzl-engine-build-logs.zip"
    $logDir = Join-Path (Get-Location) "yzl-engine-build-logs"
    try {
        Invoke-WebRequest -Uri "$($run.url)/logs" -Headers $headers -OutFile $logZip
        if (Test-Path $logDir) { Remove-Item -Recurse -Force $logDir }
        Expand-Archive -Path $logZip -DestinationPath $logDir -Force
        Remove-Item $logZip
        Write-Host "      logs saved -> $logDir"
        $hits = Get-ChildItem -LiteralPath $logDir -Recurse -File -Include *.txt |
            Select-String -Pattern "error:|fatal|FAILED|failure:|CMake Error|make\[\*\*\*" -Context 0,2 |
            Select-Object -First 60
        if ($hits.Count -eq 0) {
            Write-Host "      日志里没匹配到 error，请人工看 $logDir"
        } else {
            Write-Host "      ---- 失败摘录（贴回给代理分析）----"
            foreach ($h in $hits) { Write-Host ("      {0}" -f $h.Line.Trim()) }
            Write-Host "      ---- 摘录结束 ----"
        }
    } catch {
        Write-Host "      拉日志失败：$($_.Exception.Message)"
    }
    exit 1
}

Write-Host "[8/8] download artifacts -> dist-engine\"
$arts = Invoke-RestMethod -Uri "$($run.url)/artifacts" -Headers $headers
$out = Join-Path (Get-Location) "dist-engine"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Path $out | Out-Null
$got = 0
foreach ($art in $arts.artifacts) {
    if ($art.expired) { continue }
    $zip = Join-Path $out ("$($art.name).zip")
    Invoke-WebRequest -Uri $art.archive_download_url -Headers $headers -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $out -Force
    Remove-Item $zip
    $got++
}
Write-Host "      $got 个 artifact 已解压 -> $out"
Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
    Write-Host ("      {0}  ({1:N0} KB)" -f $_.FullName.Substring($out.Length + 1), ($_.Length / 1KB))
}
Write-Host ""
Write-Host "DONE。下一步：把 dist-engine\YZL-engine.tipa 传到 TrollStore 设备安装联调。"
Write-Host "若构建失败，把上面的『失败摘录』整段贴回会话即可。"
