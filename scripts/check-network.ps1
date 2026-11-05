# Network reachability probe for the iOS build/ship pipeline (ASCII only on purpose:
# Windows PowerShell 5.1 reads .ps1 as ANSI when there is no UTF-8 BOM).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\YZL-Launcher-iOS\scripts\check-network.ps1
#
# HOW TO READ THE RESULT: only NET_* means the channel is closed. A plain HTTP status
# (even 404 / 403 / 405 on a root path) proves TLS + HTTP work, which is all we need.
#
# Pipeline needs:
#   api.github.com                -> repo/tree/commit/ref, workflow_dispatch, runs, artifacts (POST + GET)
#   objects.githubusercontent.com -> the URL the artifact zip actually redirects to for download
#   github.com                    -> only for the browser (token page, device-code login); git push too
# Not used by the pipeline: raw.githubusercontent.com (blocked here, harmless).
param(
    [int]$Tries = 3,
    [int]$TimeoutSec = 12
)

$targets = [ordered]@{
    'api.github.com (POST+GET)'      = 'https://api.github.com/meta'
    'github.com (browser/git)'       = 'https://github.com/status'
    'objects.githubusercontent.com'  = 'https://objects.githubusercontent.com/'
    'codeload.github.com'            = 'https://codeload.github.com/git/git/tar.gz/refs/heads/master'
    'raw.githubusercontent.com'      = 'https://raw.githubusercontent.com/git/git/master/README.md'
    'gitee.com (PC update feed)'     = 'https://gitee.com'
    'launchermeta.mojang.com'        = 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json'
    'piston-meta.mojang.com'         = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
    'resources.download.minecraft.net'= 'https://resources.download.minecraft.net/00/00213cd86138f6d990c9415ae34521575560ca41'
    'login.live.com (device code)'   = 'https://login.live.com/oauth20_authorize.srf'
    'auth.microsoft.com (device code)' = 'https://auth.microsoft.com/common/oauth2/device_authorization'
}

foreach ($name in $targets.Keys) {
    $uri = $targets[$name]
    $line = @()
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -MaximumRedirection 0 -TimeoutSec $TimeoutSec -ErrorAction Stop
            $line += [string]$r.StatusCode
        } catch {
            if ($null -ne $_.Exception.Response) {
                # 有 HTTP 响应 = 通道是通的，只是路径/权限不对
                $line += [string][int]$_.Exception.Response.StatusCode
            } else {
                $line += 'NET_X'
            }
        }
    }
    $okCount = @($line | Where-Object { $_ -ne 'NET_X' }).Count
    Write-Host ('{0,-34} {1}/{2}  [{3}]' -f $name, $okCount, $Tries, ($line -join ' '))
}

Write-Host ''
Write-Host 'Rules:'
Write-Host '  api.github.com all-NET_X  -> nothing works, need another network'
Write-Host '  api.github.com OK + github.com NET_X -> use scripts/api-publish.ps1 (api-only route)'
Write-Host '  objects.githubusercontent.com NET_X  -> artifact zip cannot be downloaded from this machine'
