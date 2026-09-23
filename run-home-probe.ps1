[CmdletBinding()]
param(
    [switch]$UseCookieEnv
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$resultPath = Join-Path $repoRoot 'probe-result.txt'
$potDir = $null
$potProcess = $null

function Write-Result([string]$Line) {
    $Line | Tee-Object -FilePath $resultPath -Append
}

function Require-Version([string]$Command, [string]$Pattern, [string]$InstallCommand, [string]$Label) {
    $commandPath = Get-Command $Command -ErrorAction SilentlyContinue
    if ($null -eq $commandPath) {
        Write-Host "$Label 未检测到。请先执行：$InstallCommand" -ForegroundColor Yellow
        throw "missing_$Command"
    }
    $version = (& $Command --version 2>&1 | Out-String).Trim()
    if ($version -notmatch $Pattern) {
        Write-Host "$Label 版本不符合要求：$version" -ForegroundColor Yellow
        Write-Host "请执行：$InstallCommand" -ForegroundColor Yellow
        throw "bad_$Command"
    }
    Write-Result "PROBE_DEPENDENCY=PASS name=$Label version=$($version -replace '\s+', '_')"
}

function Start-PotService {
    $script:potDir = Join-Path ([IO.Path]::GetTempPath()) ("ytm-bgutil-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:potDir | Out-Null
    $archive = Join-Path $script:potDir 'bgutil.tar.gz'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/tags/2.0.0.tar.gz' -OutFile $archive
    tar -xzf $archive -C $script:potDir --strip-components=1
    $serverDir = Join-Path $script:potDir 'server'
    Push-Location $serverDir
    try {
        npm ci --ignore-scripts --no-audit --no-fund | Out-Null
        npx tsc | Out-Null
        $script:potProcess = Start-Process -FilePath 'node' -ArgumentList @('build/main.js', '--host', '127.0.0.1') -WorkingDirectory $serverDir -RedirectStandardOutput 'NUL' -RedirectStandardError 'NUL' -PassThru
    } finally {
        Pop-Location
    }
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:4416/ping' -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                Write-Result 'PROBE_TOKEN_SERVICE=PASS bind=127.0.0.1:4416 version=2.0.0 runtime=node22'
                return
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw 'bgutil_health_timeout'
}

function Stop-PotService {
    if ($null -ne $script:potProcess) {
        Stop-Process -Id $script:potProcess.Id -Force -ErrorAction SilentlyContinue
        $script:potProcess = $null
    }
    if ($null -ne $script:potDir -and (Test-Path $script:potDir)) {
        Remove-Item -LiteralPath $script:potDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:potDir = $null
    }
}

function Invoke-Probe([string]$GradleArgument, [string]$Group) {
    & $script:gradlew ':probe:desktopProbeRun' $GradleArgument 2>&1 | ForEach-Object {
        Write-Result ([string]$_)
    }
    if ($LASTEXITCODE -ne 0) {
        throw "gradle_$Group`_exit_$LASTEXITCODE"
    }
}

try {
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    Write-Result 'PROBE_HOME_RUN=START'
    Require-Version 'java' 'version\s+"21(?:\.|")' 'winget install EclipseAdoptium.Temurin.21.JDK' 'JDK21'
    Require-Version 'node' '^v22\.' 'winget install --id OpenJS.NodeJS.22 --exact' 'Node22'
    $script:gradlew = Join-Path $repoRoot 'gradlew.bat'
    if (-not (Test-Path $script:gradlew)) { throw 'gradlew_missing' }
    if ($UseCookieEnv -and [string]::IsNullOrWhiteSpace($env:YT_COOKIE)) {
        throw 'UseCookieEnv_requested_but_YT_COOKIE_is_empty'
    }

    $cookieArg = if ($UseCookieEnv) { '--cookie=env:YT_COOKIE' } else { $null }
    Write-Host '=== 家宽 NONE：不声明 PoToken provider ===' -ForegroundColor Cyan
    $noneDesktopArgs = '--providers=NONE'
    if ($cookieArg) { $noneDesktopArgs += " $cookieArg" }
    Invoke-Probe "-PdesktopArgs=$noneDesktopArgs" 'NONE'

    Write-Host '=== 家宽 EXTERNAL：本机 bgutil PoToken 服务 ===' -ForegroundColor Cyan
    Start-PotService
    $externalDesktopArgs = '--providers=EXTERNAL --pot-url=http://127.0.0.1:4416/get_pot'
    if ($cookieArg) { $externalDesktopArgs += " $cookieArg" }
    Invoke-Probe "-PdesktopArgs=$externalDesktopArgs" 'EXTERNAL'

    Write-Result 'PROBE_HOME_RUN=COMPLETE'
    Write-Host "结果已写入：$resultPath" -ForegroundColor Green
} catch {
    Write-Result "PROBE_HOME_RUN=FAIL errorType=$($_.Exception.GetType().Name)"
    Write-Host "运行失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-PotService
}
