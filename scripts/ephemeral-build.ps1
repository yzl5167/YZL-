# 临时公开仓库编译法：把本机 iOS 源码推到一个新建的**公开**仓库 -> 触发 macOS Runner 免费编译
# -> 把 IPA/TIPA 下载到本地 -> **立刻删掉那个仓库**（编译失败则改成私有保留现场，方便查日志）。
#
# 为什么临时公开：GitHub 只对公开仓库免费放行标准 macOS Runner；私有仓库按 $0.062/分钟计费
# （Free 计划只有 2000 标准分钟/月）。源码因此只在编译那十几分钟里短暂可见，编完即删。
#
#   $env:GITHUB_TOKEN="ghp_..."        # classic token，需要 repo + workflow 作用域
#   powershell -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\ephemeral-build.ps1
#   powershell ... -File .\ephemeral-build.ps1 -KeepRepo            # 调试：编完不删
#   powershell ... -File .\ephemeral-build.ps1 -ReuseRepo yzl-ios-build-261105-1930
#
param(
    [string]$RepoPrefix = "yzl-ios-build",
    [string]$RepoName = "",
    [string]$ReuseRepo = "",
    [string]$SourceDir = "YZL-Launcher-iOS",
    [string]$OutputDir = "",
    [string]$Branch = "main",
    [int]$TimeoutMinutes = 35,
    [switch]$KeepRepo,
    [switch]$ForceNew
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
[Net.ServicePointManager]::Expect100Continue = $false
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 兜底：只要临时仓库已经被转成公开，脚本任何一步崩掉都必须先把它转回私有，
# 绝不能让源码因为一次异常就一直挂在公开仓库上（实测踩过：上传中途 404，收尾没跑到）。
$repoHidden = $true
trap {
    if ($repoUri -and $headers -and -not $repoHidden) {
        Write-Host "      [兜底] 脚本异常，先把临时仓库转回私有"
        try {
            Invoke-RestMethod -Uri $repoUri -Headers $headers -Method Patch `
                -Body (@{ private = $true } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
            $repoHidden = $true
            Write-Host "      已转回私有 $repoUri"
        } catch {
            Write-Host "      兜底也失败了（网络或令牌问题），请手动去网页把这个仓库设为私有：$repoUri"
        }
    }
    if ($_) { Write-Host ("      异常：" + $_.Exception.Message.Split([char]10)[0]) }
    exit 1
}

$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { $token = Read-Host "GITHUB_TOKEN（classic，需 repo+workflow）" }
if ([string]::IsNullOrWhiteSpace($token)) { throw "没有令牌，无法继续。" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "yzl-ios-ephemeral-build"
}
$api  = "https://api.github.com"
$json = "application/json"
$workflowFile = "build-ipa.yml"
$wantedArtifacts = @('YZLLauncher-unsigned-ipa', 'YZLLauncher-trollstore-tipa')

function Invoke-Post($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Invoke-Patch($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Patch -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Invoke-Put($uri, $body) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body ($body | ConvertTo-Json -Depth 8) -ContentType $json
}
function Try-Get($uri) {
    try { return Invoke-RestMethod -Uri $uri -Headers $headers } catch { return $null }
}
function Parse-RunDate($value) {
    return [DateTime]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
function Show-FailureLogs($run) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("yzl-ios-logs-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = Join-Path $tmp "logs.zip"
        Invoke-WebRequest -Uri "$($run.url)/logs" -Headers $headers -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp "out") -Force
        $hits = @(Get-ChildItem -LiteralPath (Join-Path $tmp "out") -Recurse -File -Filter *.txt |
            Select-String -Pattern "error:|fatal error|The following build commands failed" |
            Select-Object -First 40)
        if ($hits.Count -eq 0) {
            Write-Host "      日志里没匹配到 error:，完整日志包在 $tmp"
        } else {
            Write-Host "      ---- 编译错误摘录 ----"
            foreach ($h in $hits) { Write-Host ("      {0}" -f $h.Line.Trim()) }
            Write-Host "      ---- 摘录结束 ----"
        }
    } catch {
        Write-Host "      拉日志失败：$($_.Exception.Message)"
    }
}

Write-Host "[1/7] 校验令牌与目录"
$me = Invoke-RestMethod -Uri "$api/user" -Headers $headers
$owner = $me.login
$projDir = (Resolve-Path (Join-Path (Get-Location) $SourceDir)).Path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'YZL-iOS-builds'
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Write-Host "      账号 $owner / 源码 $projDir / 产物 $OutputDir"

if ([string]::IsNullOrWhiteSpace($ReuseRepo) -and -not $ForceNew -and [string]::IsNullOrWhiteSpace($RepoName)) {
    # 优先复用上次留下的临时仓库：GitHub 删仓库要 delete_repo 作用域，没有它就一直堆仓库，
    # 复用时「临时转公开 -> 编译 -> 取包 -> 转回私有」，效果一样且不落新库。
    # 先赋值再接管道：直接把 Invoke-RestMethod 塞进管道时它可能把整个 Object[] 当一个对象传下去，
    # 那样 $_.name 变成"所有仓库名拼成的数组"，-like 会全部命中，可能误把主仓库转公开。
    $repoList = Invoke-RestMethod -Uri "$api/user/repos?per_page=100&affiliation=owner" -Headers $headers
    $existing = @($repoList | ForEach-Object { $_ } |
        Where-Object { $_.name -is [string] -and $_.name -like ($RepoPrefix + '-*') } |
        Sort-Object updated_at -Descending)
    if ($existing.Count -gt 0) {
        $ReuseRepo = [string]$existing[0].name
        Write-Host "      发现可复用的临时仓库 $ReuseRepo（不再新建；要强制新建加 -ForceNew）"
    }
}
# 双保险：要复用的名字必须真的带临时仓库前缀，否则宁可新建，绝不把别的仓库转公开
if (-not [string]::IsNullOrWhiteSpace($ReuseRepo) -and $ReuseRepo -notlike ($RepoPrefix + '-*')) {
    Write-Host "      拒绝复用「$ReuseRepo」：不是 $RepoPrefix-* 临时仓库，改为新建"
    $ReuseRepo = ""
    $ForceNew = $true
}

if (-not [string]::IsNullOrWhiteSpace($ReuseRepo)) {
    $RepoName = $ReuseRepo
    $repoUri = "$api/repos/$owner/$RepoName"
    $repo = Try-Get $repoUri
    if ($null -eq $repo) { throw "找不到要复用的仓库 $owner/$RepoName" }
    Write-Host "[2/7] 复用仓库 $owner/$RepoName，临时转为公开（只有公开仓库的 macOS Runner 免费）"
    Invoke-Patch $repoUri @{ private = $false } | Out-Null
    $repoHidden = $false
} else {
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        $RepoName = "{0}-{1}" -f $RepoPrefix, (Get-Date).ToString('yyMMdd-HHmmss')
    }
    Write-Host "[2/7] 新建公开仓库 $owner/$RepoName"
    Invoke-Post "$api/user/repos" @{
        name         = $RepoName
        private      = $false
        auto_init    = $false
        has_issues   = $false
        has_wiki     = $false
        has_projects = $false
        description  = "TEMP public build mirror for YZL Launcher iOS. Deleted right after the artifact is downloaded."
    } | Out-Null
    $repoUri = "$api/repos/$owner/$RepoName"
}

Write-Host "[3/7] 确保 $Branch 分支存在（Git Data API 需要 parent commit，空仓库先塞一个 README）"
if ($null -eq (Try-Get "$repoUri/git/ref/heads/$Branch")) {
    $readmePath = Join-Path $projDir "README.md"
    if (Test-Path $readmePath) {
        $seed = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($readmePath))
    } else {
        $seed = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# YZL Launcher iOS (temp build mirror)`n"))
    }
    Invoke-Put "$repoUri/contents/README.md" @{
        message = "chore: seed temp build mirror"
        content = $seed
    } | Out-Null
    Write-Host "      已建 $Branch"
} else {
    Write-Host "      $Branch 已存在（复用仓库，不重复建）"
}

Write-Host "[4/7] 上传源码树"
$skipDirs = @('\.git\', '\build\', '\build-test\', '\build-output\', '\dist\', '\bin\', '\obj\', '\node_modules\', '\.deriveddata\')
$skipExt  = @('.ipa', '.tipa', '.zip', '.exe', '.dll', '.log')
$all = @(Get-ChildItem -LiteralPath $projDir -Recurse -File)
$files = @($all | Where-Object {
    $path = $_.FullName
    $hit = $false
    foreach ($s in $skipDirs) { if ($path -like ('*' + $s + '*')) { $hit = $true; break } }
    (-not $hit) -and ($skipExt -notcontains $_.Extension)
})
Write-Host "      $($files.Count) 个文件（本地共 $($all.Count) 个，已排除 build-output 与二进制产物）"
$tree = @()
$n = 0
foreach ($f in $files) {
    $n++
    Write-Progress -Activity "upload" -Status $f.Name -PercentComplete ($n * 100 / $files.Count)
    $rel = $f.FullName.Substring($projDir.Length + 1) -replace "\\", "/"
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
    # 实测会遇到偶发 404（同一份内容上一次还能成功），所以带退避重试，别整轮白跑
    $sha = $null
    for ($try = 1; $try -le 4 -and -not $sha; $try++) {
        try {
            $sha = (Invoke-Post "$repoUri/git/blobs" @{ content = $b64; encoding = "base64" }).sha
        } catch {
            if ($try -ge 4) {
                Write-Host ("      blob 上传彻底失败：{0} -> {1}" -f $rel, $_.Exception.Message.Split([char]10)[0])
                throw
            }
            Write-Host ("      {0} 第 {1} 次失败，{2} 秒后重试" -f $rel, $try, ($try * 6))
            Start-Sleep -Seconds ($try * 6)
        }
    }
    $mode = if ($rel -match '\.sh$') { "100755" } else { "100644" }
    $tree += @{ path = $rel; mode = $mode; type = "blob"; sha = $sha }
}
Write-Progress -Activity "upload" -Completed
$rootTree = Invoke-Post "$repoUri/git/trees" @{ tree = $tree }
$parent = Invoke-RestMethod -Uri "$repoUri/git/ref/heads/$Branch" -Headers $headers
$commit = Invoke-Post "$repoUri/git/commits" @{
    message = "temp build mirror (ephemeral): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') local time"
    tree    = $rootTree.sha
    parents = @($parent.object.sha)
}
Invoke-Patch "$repoUri/git/refs/heads/$Branch" @{ sha = $commit.sha; force = $true } | Out-Null
Write-Host "      commit $($commit.sha.Substring(0,7)) on $Branch"

Write-Host "[5/7] 触发 $workflowFile 并等待 macOS 构建（通常 5-20 分钟）"
$sinceUtc = [DateTime]::UtcNow.AddMinutes(-2)
Invoke-Post "$repoUri/actions/workflows/$workflowFile/dispatches" @{ ref = $Branch } | Out-Null
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$run = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $runs = Try-Get "$repoUri/actions/runs?branch=$Branch&per_page=20"
    if ($null -eq $runs) { continue }
    $fresh = @($runs.workflow_runs | Where-Object { (Parse-RunDate $_.created_at) -ge $sinceUtc } |
        Sort-Object { Parse-RunDate $_.created_at } -Descending)
    if ($fresh.Count -eq 0) { Write-Host "      还没排队上"; continue }
    $run = $fresh[0]
    Write-Host ("      run {0}: {1} / {2}" -f $run.id, $run.status, $run.conclusion)
    if ($run.status -eq "completed") { break }
}
if ($null -eq $run -or $run.status -ne "completed") {
    Write-Host "      超时了（$TimeoutMinutes 分钟）。仓库 $RepoName 转成私有保留现场，别再公开挂着。"
    Invoke-Patch $repoUri @{ private = $true } | Out-Null
    throw "构建超时；可用 -ReuseRepo $RepoName 重试"
}

Write-Host "[6/7] 下载产物到 $OutputDir"
$ok = ($run.conclusion -eq "success")
if (-not $ok) { Write-Host "      构建结论是 $($run.conclusion)，先抓错误给你看" }
$got = @()
if ($ok) {
    $arts = Try-Get "$($run.url)/artifacts"
    foreach ($name in $wantedArtifacts) {
        $art = @($arts.artifacts | Where-Object { $_.name -eq $name -and -not $_.expired } | Select-Object -First 1)
        if ($art.Count -eq 0) { Write-Host "      没有 artifact：$name（可能这次构建没产出 .tipa）"; continue }
        $a = $art[0]
        $zip = Join-Path $env:TEMP ("yzl-art-" + $a.id + ".zip")
        Invoke-WebRequest -Uri $a.archive_download_url -Headers $headers -OutFile $zip
        $tmpOut = Join-Path $env:TEMP ("yzl-art-" + $a.id)
        if (Test-Path $tmpOut) { Remove-Item -Recurse -Force $tmpOut }
        Expand-Archive -Path $zip -DestinationPath $tmpOut -Force
        Get-ChildItem -LiteralPath $tmpOut -Recurse -File | ForEach-Object {
            $dest = Join-Path $OutputDir $_.Name
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            $got += $dest
        }
        Remove-Item -Force $zip
        Remove-Item -Recurse -Force $tmpOut
    }
    $fileLines = @()
    foreach ($g in $got) {
        $fi = Get-Item -LiteralPath $g
        $hash = (Get-FileHash -LiteralPath $g -Algorithm SHA256).Hash.ToLower()
        $fileLines += ("{0}  {1:N0} bytes  sha256={2}" -f $fi.Name, $fi.Length, $hash)
        Write-Host ("      {0}  {1:N0} bytes" -f $fi.Name, $fi.Length)
    }
} else {
    Show-FailureLogs $run
}

Write-Host "[7/7] 收尾：让临时仓库不再公开"
$repoOutcome = ""
if ($KeepRepo) {
    $repoOutcome = "保留公开（-KeepRepo）"
    Write-Host "      -KeepRepo：仓库 $owner/$RepoName 仍是公开的，调试完记得处理掉"
} elseif ($ok -and $got.Count -gt 0) {
    try {
        Invoke-RestMethod -Uri $repoUri -Headers $headers -Method Delete | Out-Null
        $repoOutcome = "已删除"
        Write-Host "      已删除临时仓库 $owner/$RepoName，源码不再公开"
    } catch {
        Invoke-Patch $repoUri @{ private = $true } | Out-Null
        $repoOutcome = "删除被拒（缺 delete_repo 作用域），已转回私有"
        Write-Host ("      删除被拒：" + $_.Exception.Message.Split([char]10)[0])
        Write-Host "      已把 $owner/$RepoName 转回**私有**——下次运行会自动复用它（临时公开 -> 编译 -> 转回私有），不会越堆越多。"
        Write-Host "      想真的删掉：token 勾上 delete_repo 作用域后跑 scripts\delete-repo.ps1 -Prefix $RepoPrefix"
    }
} else {
    Invoke-Patch $repoUri @{ private = $true } | Out-Null
    $repoOutcome = "已转私有保留现场"
    if (-not $ok) {
        Write-Host "      构建失败：已转私有保留现场（不公开）。修好后重跑会自动复用 $RepoName"
    } else {
        Write-Host "      没拿到产物：先转私有，避免一直公开挂着"
    }
}

if ($got.Count -gt 0) {
    $info = Join-Path $OutputDir '最新包信息.txt'
    $lines = @()
    $lines += ("生成时间(本地): " + (Get-Date).ToString('s'))
    $lines += ("仓库: $owner/$RepoName   run: $($run.id)   commit: $($run.head_sha)")
    $lines += ("构建结论: $($run.conclusion)   仓库处置: $repoOutcome")
    $lines += $fileLines
    [System.IO.File]::WriteAllLines($info, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "      清单写入 $info"
}
Write-Host "DONE"
