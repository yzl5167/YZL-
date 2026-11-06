# api.github.com only publish + cloud build (this network blocks github.com POST, GET works).
#
#   $env:GITHUB_TOKEN="ghp_..."
#   powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\api-publish.ps1
#
#   # 仓库叫什么不重要：留空 -RepoName 会自动找你账号里名字带 ios 的那个
#   powershell ... -File .\api-publish.ps1 -RepoName my-fancy-name
#   powershell ... -File .\api-publish.ps1 -Owner SomeOrg -RepoName yzl-ios
#   # 或者直接把 git 地址粘进来，owner/name 自己解析
#   powershell ... -File .\api-publish.ps1 -RepoUrl https://github.com/yzl5167/YZL-.git
#
# Steps: find/create repo -> seed empty repo via Contents API -> upload blobs -> tree -> commit
#        -> force update refs/heads/main -> workflow_dispatch -> poll -> download artifact.
param(
    [string]$RepoName = "YZL-",
    [string]$RepoUrl = "",
    [string]$Owner = "",
    [string]$SourceDir = "YZL-Launcher-iOS",
    [int]$TimeoutMinutes = 35,
    [switch]$Public
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::Expect100Continue = $false
# 控制台用 UTF-8，避免中文输出被 GBK 打乱
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "no token" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-ios-api-publish"
}
$api = "https://api.github.com"
$json = "application/json"

function Post-Json($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Put-Json($uri, $body) {
    # Contents API 建/改文件必须用 PUT，POST 会返回 404
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

Write-Host "[2/8] 定位仓库（名字随你叫什么，脚本自己找）"
if (-not [string]::IsNullOrWhiteSpace($RepoUrl)) {
    # 支持 https://github.com/owner/name(.git)、git@github.com:owner/name(.git)、纯 owner/name
    if ($RepoUrl -match '^(?:https?://|git@)?[^/:\s@]+(?::\d+)?[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$' -or $RepoUrl -match '^([^/\s]+)/([^/\s]+?)(?:\.git)?$') {
        $Owner = $Matches[1]
        $RepoName = $Matches[2]
        Write-Host "      从地址解析出仓库：$Owner/$RepoName"
    } else {
        throw "看不明白这个仓库地址：$RepoUrl"
    }
}
if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = $login }

if ([string]::IsNullOrWhiteSpace($RepoName)) {
    $listed = @()
    try {
        # 注意：@(Invoke-RestMethod ...) 在 PS 5.1 下会把整个 JSON 数组当成一个对象塞进数组，
        # 导致 $_.name 变成"所有仓库名"的数组、-like 全部命中。先赋值再走管道才能正确展开。
        if ($Owner -eq $login) {
            $raw = Invoke-RestMethod -Uri "$api/user/repos?per_page=100&affiliation=owner" -Headers $headers
        } else {
            $raw = Invoke-RestMethod -Uri "$api/users/$Owner/repos?per_page=100" -Headers $headers
        }
        $listed = @($raw | ForEach-Object { $_ })
    } catch {
        Write-Host "      列仓库失败（fine-grained token 可能没有 Accounts 读权限）：$($_.Exception.Message.Split([char]10)[0])"
    }
    $cand = @($listed | Where-Object { $_.name -match '(?i)ios' } | Sort-Object -Property updated_at -Descending)
    if ($cand.Count -gt 0) {
        $RepoName = $cand[0].name
        Write-Host "      自动选中名字带 ios 的仓库：$Owner/$RepoName（其它候选：$(($cand.name) -join ', ')）"
    } elseif ($listed.Count -gt 0) {
        Write-Host "      这个账号里没有名字带 ios 的仓库。现有仓库："
        $listed | ForEach-Object { Write-Host ('        ' + $_.name + '  (fork=' + $_.fork + ', private=' + $_.private + ')') }
        Write-Host "      想复用其中某个就加参数 -RepoName 那个名字；否则去网页新建一个空仓库（不勾 README）。"
        throw "还没有可用的 iOS 仓库"
    } else {
        $RepoName = 'yzllauncher-ios'
        Write-Host "      列不出仓库，按默认名 $Owner/$RepoName 继续（拿不到就下面会教你手动建）"
    }
}

$repoUri = "$api/repos/$Owner/$RepoName"
$repo = Try-Get $repoUri
if ($null -eq $repo) {
    if ($Owner -ne $login) {
        Write-Host "      找不到 $Owner/$RepoName，且跨账号（组织）建仓不能走 /user/repos。"
        Write-Host "      请在浏览器里先在 $Owner 下新建空仓库 $RepoName（Public、不勾 Add a README），再重跑本脚本。"
        throw "目标仓库不存在"
    }
    # fine-grained token 不能建仓（实测 403 "Resource not accessible by personal access token"），
    # 所以先试一次，失败就把需要人工做的那一步打印清楚。
    try {
        $repo = Post-Json "$api/user/repos" @{
            name        = $RepoName
            private     = (-not $Public)
            auto_init   = $false
            description = "YZL Launcher iOS (Minecraft Java Edition sideload launcher, WIP)"
        }
        Write-Host "      created (private=$(-not $Public))"
    } catch {
        Write-Host "      建仓失败：$($_.Exception.Message.Split([char]10)[0])"
        Write-Host "      请用浏览器（手机流量，别连同一个 WiFi）手动建一个空仓库："
        Write-Host "        https://github.com/new  ->  名称 $RepoName，建议 Public，不要勾选 Add a README"
        Write-Host "      这个名字如果被 GitHub 判重复，随便换一个（比如加年份或改成 YZL-Launcher-iOS），"
        Write-Host "        然后带参数重跑：-RepoName 你建的那个名字 —— 脚本不挑名字。"
        Write-Host "      若不想手动建仓：改用 classic token（勾选 repo + workflow），权限更大但能自动建仓。"
        throw "仓库不存在且无法自动创建"
    }
} else {
    Write-Host "      exists (private=$($repo.private))"
}
if ($repo.private) {
    Write-Host "      注意：私有仓库的 macOS 分钟数按 10 倍计费，免费额度 100 分钟/月只够约 10 分钟 macOS 构建。"
    Write-Host "            iOS 端本来就要按 GPLv3 开源，建议把这个仓库改成 Public（macOS Runner 免费）。"
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
        message = "chore: seed repo so Git Data API can be used"
        content = $content
    } | Out-Null
    $ref = Invoke-RestMethod -Uri "$repoUri/git/ref/heads/main" -Headers $headers
    Write-Host "      seeded README.md"
} else {
    Write-Host "      main already exists"
}
$parentSha = $ref.object.sha
Write-Host "      parent $parentSha"

Write-Host "[4/8] upload blobs via api.github.com"
$base = (Resolve-Path $SourceDir).Path
# 这里不走 git，所以 .gitignore 不会被自动尊重：手工把构建产物/仓库/包文件挡掉，
# 否则某天本地留下的 build/ 或 *.ipa 会被当成源码一起传上去。
# 故意用 -like 而不是 -match：Windows 路径里的 \b \i \o 在 .NET 正则里是非法/歧义转义。
$skipDirs = @('\.git\', '\build\', '\build-test\', '\build-output\', '\dist\', '\bin\', '\obj\', '\node_modules\', '\.deriveddata\')
$skipExt  = @('.ipa', '.tipa', '.zip', '.exe', '.dll', '.log')
$files = @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object {
    $path = $_.FullName
    $hit = $false
    foreach ($s in $skipDirs) {
        if ($path -like ('*' + $s + '*')) { $hit = $true; break }
    }
    (-not $hit) -and ($skipExt -notcontains $_.Extension)
})
Write-Host "      $($files.Count) files (git/build 产物与 ipa/zip 已排除)"
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
Write-Host "      $($tree.Count) files"

Write-Host "[5/8] tree + commit + force update ref"
$rootTree = Post-Json "$repoUri/git/trees" @{ tree = $tree }
$commit = Post-Json "$repoUri/git/commits" @{
    message = "YZL Launcher iOS: universal shell (iOS 15+), device-code auth, segmented downloader, CI + signing scripts"
    tree    = $rootTree.sha
    parents = @($parentSha)
}
Patch-Json "$repoUri/git/refs/heads/main" @{ sha = $commit.sha; force = $true } | Out-Null
Write-Host "      commit $($commit.sha.Substring(0,7)) on main"

Write-Host "[6/8] trigger build-ipa.yml"
$wfName = "Build unsigned IPA"
$ipArtifactName = "YZLLauncher-unsigned-ipa"
# 记录触发时刻：轮询时只接受这次新建的 run，避免误取上一次已成功的老包。
$sinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-2)
Post-Json "$repoUri/actions/workflows/build-ipa.yml/dispatches" @{ ref = "main" } | Out-Null

Write-Host "[7/8] wait for macOS build (usually 5-20 min)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$run = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $runs = Invoke-RestMethod -Uri "$repoUri/actions/runs?branch=main&per_page=20" -Headers $headers
    $fresh = @($runs.workflow_runs | Where-Object {
        $_.name -eq $wfName -and
        [DateTime]::Parse($_.created_at, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() -ge $sinceUtc
    } | Sort-Object { [DateTime]::Parse($_.created_at, [System.Globalization.CultureInfo]::InvariantCulture) } -Descending)
    if ($fresh.Count -eq 0) { Write-Host "      no run yet"; continue }
    $run = $fresh[0]
    Write-Host ("      run {0}: {1} / {2}" -f $run.id, $run.status, $run.conclusion)
    if ($run.status -eq "completed") { break }
}
if ($null -eq $run -or $run.status -ne "completed") {
    throw "timeout after $TimeoutMinutes min (github.com 从本机不通，可让手机浏览器打开 $repoUri 看进度)"
}

if ($run.conclusion -ne "success") {
    Write-Host "      BUILD FAILED: $($run.conclusion)"
    Write-Host "      web logs: $($run.html_url)"

    # 本机打不开 github.com，所以直接把日志包抓回来，把编译错误就地打印出来。
    $logZip = Join-Path (Get-Location) "yzl-ios-build-logs.zip"
    $logDir = Join-Path (Get-Location) "yzl-ios-build-logs"
    try {
        Invoke-WebRequest -Uri "$($run.url)/logs" -Headers $headers -OutFile $logZip
        if (Test-Path $logDir) { Remove-Item -Recurse -Force $logDir }
        Expand-Archive -Path $logZip -DestinationPath $logDir -Force
        Remove-Item $logZip
        Write-Host "      logs saved -> $logDir"
        $hits = Get-ChildItem -LiteralPath $logDir -Recurse -File -Include *.txt |
            Select-String -Pattern "error:|fatal error|The following build commands failed|BUILD FAILED" -Context 0,1 |
            Select-Object -First 60
        if ($hits.Count -eq 0) {
            Write-Host "      日志里没匹配到 error:，请人工看 $logDir"
        } else {
            Write-Host "      ---- 编译错误摘录 ----"
            foreach ($h in $hits) { Write-Host ("      {0}" -f $h.Line.Trim()) }
            Write-Host "      ---- 摘录结束 ----"
        }
    } catch {
        Write-Host "      拉日志失败：$($_.Exception.Message)"
    }
    exit 1
}

Write-Host "[8/8] download artifact"
$arts = Invoke-RestMethod -Uri "$($run.url)/artifacts" -Headers $headers
$art = $arts.artifacts | Where-Object { $_.name -eq $ipArtifactName -and -not $_.expired } | Select-Object -First 1
if ($null -eq $art) { throw "no $ipArtifactName artifact in run $($run.id)" }
$zip = Join-Path (Get-Location) "yzl-ios-artifact.zip"
Invoke-WebRequest -Uri $art.archive_download_url -Headers $headers -OutFile $zip
$out = Join-Path (Get-Location) "yzl-ios-build"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
Expand-Archive -Path $zip -DestinationPath $out -Force
Remove-Item $zip
$ipa = Get-ChildItem -LiteralPath $out -Recurse -File -Filter *.ipa | Select-Object -First 1
if ($null -eq $ipa) {
    Write-Host "      压缩包里没找到 .ipa，内容见 $out"
} else {
    Write-Host ("      IPA: {0} ({1:N0} KB)" -f $ipa.FullName, ($ipa.Length / 1KB))
}
Write-Host "      artifact -> $out"
Write-Host "      repo: https://github.com/$Owner/$RepoName"
Write-Host "下一步：用 Windows 上的 AltServer 签这个 ipa（见 docs/SIGNING.md）。"
Write-Host "DONE"
