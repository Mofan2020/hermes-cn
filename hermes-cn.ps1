#Requires -Version 5.1
<#
.SYNOPSIS
    hermes-cn —— Hermes 大陆网络加速（Windows 版）

.DESCRIPTION
    与 macOS / Linux 版功能一致。

    用法：
      hermes-cn.cmd                 进入加速环境（新的 PowerShell 窗口）
      hermes-cn.cmd run <命令>      在加速环境里执行一条命令
      hermes-cn.cmd env             打印可导入的环境变量
      hermes-cn.cmd doctor          自检
      hermes-cn.cmd apply           改写依赖清单指向镜像 + 配置 Git 镜像（长期生效）
      hermes-cn.cmd restore         撤销 apply 的所有改动
      hermes-cn.cmd install         用镜像全新安装 Hermes
      hermes-cn.cmd help            显示帮助

    选项：
      --pypi-mirror <名>            跳过探测，强制使用指定的 PyPI 镜像
      --git-mirror <地址>           跳过探测，强制使用指定的 Git 镜像地址
      --no-probe                    不做探测，直接用默认的首选源
      --yes, -y                     不询问，直接执行
      --version, -v                 显示版本

.NOTES
    项目：https://github.com/Mofan2020/hermes-cn
    许可证：MIT
#>

# 兼容基线：Windows PowerShell 5.1 与 PowerShell 7 都能跑。
# 5.1 要求脚本文件带 UTF-8 BOM，否则中文会被读成乱码；发布时已按此保存。
$ErrorActionPreference = 'Continue'

# 控制台改成 UTF-8，避免中文输出乱码。
try {
    $Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom
} catch {
}

# 老系统默认可能只开 TLS 1.0，HTTPS 镜像会直接连不上。
try {
    $Proto = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $Proto = $Proto -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $Proto
} catch {
}

$Script:Version       = '1.0.2'
$Script:OfficialOrigin = 'https://github.com/NousResearch/hermes-agent.git'
$Script:BackupSuffix  = '.hermes-cn.bak'
$Script:ProbeTimeout  = 25
$Script:ProbeGitTimeout = 120

# ---------------------------------------------------------------- 日志输出

function Write-Info { param([string]$Message) Write-Host "[hermes-cn] $Message" -ForegroundColor DarkGray }
function Write-Ok { param([string]$Message) Write-Host "  ✓ $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow }
function Write-ErrMsg { param([string]$Message) Write-Host "  ✗ $Message" -ForegroundColor Red }
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor White }

# ---------------------------------------------------------------- 基础工具

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# 把参数拼成能安全交给外部程序的一行
function ConvertTo-CommandArg {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -match '[\s"]') {
        $escaped = $Value -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        return '"' + $escaped + '"'
    }
    return $Value
}

# 跑一个外部程序，带超时。超时返回 Code=-1。
function Invoke-Process {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $null,
        [int]$TimeoutSec = 120
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $joined = ''
    foreach ($a in $Arguments) { $joined = $joined + ' ' + (ConvertTo-CommandArg $a) }
    $psi.Arguments = $joined.Trim()
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try { $null = $proc.Start() } catch {
        return [pscustomobject]@{ Code = -1; Output = ''; Error = $_.Exception.Message }
    }
    # 异步读，避免管道写满导致死锁
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return [pscustomobject]@{ Code = -1; Output = ''; Error = 'timeout' }
    }
    $proc.WaitForExit()
    return [pscustomobject]@{
        Code   = $proc.ExitCode
        Output = $stdout.Result
        Error  = $stderr.Result
    }
}

function Invoke-GitCommand {
    param([string[]]$Arguments, [string]$WorkingDirectory = $null, [int]$TimeoutSec = 120)
    return Invoke-Process -FilePath 'git' -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec
}

# HTTP 状态码。连接失败返回 0。
function Get-HttpStatus {
    param([string]$Url, [int]$TimeoutSec = 25)
    if (-not $Url) { return 0 }
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
        return [int]$resp.StatusCode
    } catch {
        $code = 0
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $code = [int]$_.Exception.Response.StatusCode
            }
        } catch { }
        return $code
    }
}

# 下载文件并算 SHA-256。失败返回空串。
function Get-RemoteFileSha256 {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120)
    try {
        Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -OutFile $OutFile -ErrorAction Stop
    } catch {
        return ''
    }
    if (-not (Test-Path -LiteralPath $OutFile)) { return '' }
    try {
        return (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLower()
    } catch {
        return ''
    }
}

function New-TempDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-cn-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $dir -Force
    return $dir
}

# 找出 Hermes 的安装目录
function Get-HermesHome {
    $candidates = @()
    if ($env:HERMES_HOME) { $candidates += $env:HERMES_HOME }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE '.hermes/hermes-agent')
        $candidates += (Join-Path $env:USERPROFILE '.hermes/hermes')
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $hasLock = Test-Path -LiteralPath (Join-Path $c 'uv.lock')
        $hasGit = Test-Path -LiteralPath (Join-Path $c '.git')
        if ($hasLock -or $hasGit) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------- 候选源表

$PypiCandidates = @(
    [pscustomobject]@{ Name = '清华';       Alias = 'tuna';   Index = 'https://pypi.tuna.tsinghua.edu.cn/simple';                Pkg = 'https://pypi.tuna.tsinghua.edu.cn/packages/' }
    [pscustomobject]@{ Name = '中科大';     Alias = 'ustc';   Index = 'https://mirrors.ustc.edu.cn/pypi/simple';                Pkg = 'https://mirrors.ustc.edu.cn/pypi/packages/' }
    [pscustomobject]@{ Name = '阿里云';     Alias = 'aliyun'; Index = 'https://mirrors.aliyun.com/pypi/simple';                Pkg = 'https://mirrors.aliyun.com/pypi/packages/' }
    [pscustomobject]@{ Name = '腾讯云';     Alias = 'tencent';Index = 'https://mirrors.cloud.tencent.com/pypi/simple';         Pkg = 'https://mirrors.cloud.tencent.com/pypi/packages/' }
    [pscustomobject]@{ Name = '北京外国语'; Alias = 'bfsu';   Index = 'https://mirrors.bfsu.edu.cn/pypi/web/simple';            Pkg = 'https://mirrors.bfsu.edu.cn/pypi/web/packages/' }
    [pscustomobject]@{ Name = '华为云';     Alias = 'huawei'; Index = 'https://mirrors.huaweicloud.com/repository/pypi/simple'; Pkg = 'https://mirrors.huaweicloud.com/repository/pypi/packages/' }
)

$GitCandidates = @(
    [pscustomobject]@{ Name = 'GitCode';    Url = 'https://gitcode.com/GitHub_Trending/he/hermes-agent.git' }
    [pscustomobject]@{ Name = 'gh-proxy.cc'; Url = 'https://gh-proxy.cc/https://github.com/NousResearch/hermes-agent.git' }
)

$GhProxyCandidates = @(
    [pscustomobject]@{ Name = 'gh-proxy.cc';  Prefix = 'https://gh-proxy.cc/https://github.com' }
    [pscustomobject]@{ Name = 'ghproxy.net';   Prefix = 'https://ghproxy.net/https://github.com' }
)

$RawCandidates = @(
    [pscustomobject]@{ Name = 'jsDelivr';  Prefix = 'https://fastly.jsdelivr.net/gh/NousResearch/hermes-agent@main' }
    [pscustomobject]@{ Name = 'gh-proxy';  Prefix = 'https://gh-proxy.net/https://raw.githubusercontent.com/NousResearch/hermes-agent/main' }
)

$Script:OfficialAssets = 'https://hermes-assets.nousresearch.com'
$Script:NpmRegistry = 'https://registry.npmmirror.com'
$Script:UvMirror = 'https://mirrors.huaweicloud.com/uv'
$Script:NodeMirror = 'https://cdn.npmmirror.com/binaries/node'
$Script:PythonMirror = 'https://registry.npmmirror.com/-/binary/python-build-standalone'

# ---------------------------------------------------------------- 探测

# PyPI 镜像：用 GET 单包页面，不用 HEAD，也不用索引根路径。
function Test-PypiMirror {
    param([string]$Index)
    if ((Get-HttpStatus -Url (($Index.TrimEnd('/')) + '/requests/')) -eq 200) { return $true }
    return (Get-HttpStatus -Url (($Index.TrimEnd('/')) + '/')) -eq 200
}

# 镜像是否真的带着 Hermes 需要的安装包
function Test-PypiArtifact {
    param([string]$PkgPrefix, [string]$RelativePath)
    if (-not $RelativePath) { return $false }
    return (Get-HttpStatus -Url ($PkgPrefix + $RelativePath)) -eq 200
}

# Git 镜像：ls-remote 必须拿到非空 refs，反爬页面不算。
function Test-GitMirror {
    param([string]$Url)
    $r = Invoke-GitCommand -Arguments @('ls-remote', $Url, 'HEAD') -TimeoutSec $Script:ProbeGitTimeout
    if ($r.Code -ne 0) { return $false }
    $out = $r.Output
    if ([string]::IsNullOrWhiteSpace($out)) { return $false }
    if ($out -match '<html' -or $out -match '<!DOCTYPE' -or $out -match 'window\.location') { return $false }
    return $true
}

# 文件代理：能取到仓库里的某个文件即可
function Test-RawProxy {
    param([string]$Prefix)
    return (Get-HttpStatus -Url (($Prefix.TrimEnd('/')) + '/scripts/install.sh')) -eq 200
}

# GitHub 代理：下载内容哈希要对，git 协议也要能用。
function Test-GhProxy {
    param([string]$Prefix)
    $rel = '/KittenML/KittenTTS/releases/download/0.8.1/kittentts-0.8.1-py3-none-any.whl'
    $expected = '482a436c4f1f3192153710376e459ff3689517ebcda7c2b051e2fd4187b41851'
    $dir = New-TempDir
    try {
        $file = Join-Path $dir 'rel.bin'
        $actual = Get-RemoteFileSha256 -Url ($Prefix + $rel) -OutFile $file -TimeoutSec 90
        if ($actual -ne $expected) { return $false }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $r = Invoke-GitCommand -Arguments @('ls-remote', ($Prefix + '/giampaolo/psutil.git'), 'HEAD') -TimeoutSec $Script:ProbeGitTimeout
    if ($r.Code -ne 0) { return $false }
    $out = $r.Output
    if ([string]::IsNullOrWhiteSpace($out)) { return $false }
    if ($out -match '<html' -or $out -match '<!DOCTYPE' -or $out -match 'window\.location') { return $false }
    return $true
}

# Git 镜像探测结果缓存：GitCode 单次要 40~55 秒，重复探测太磨人。
$Script:GitProbeCache = @()

function Test-GitMirrorCached {
    param([string]$Url)
    if ($Script:GitProbeCache -contains $Url) { return $true }
    if (Test-GitMirror -Url $Url) {
        $Script:GitProbeCache += $Url
        return $true
    }
    return $false
}

function Select-PypiMirror {
    foreach ($c in $PypiCandidates) {
        Write-Info "探测 PyPI 镜像：$($c.Name)"
        if (Test-PypiMirror -Index $c.Index) { return $c }
        Write-WarnMsg "$($c.Name) 不可用"
    }
    return $null
}

function Select-GitMirror {
    foreach ($c in $GitCandidates) {
        Write-Info "探测 Git 镜像：$($c.Name)"
        if (Test-GitMirrorCached -Url $c.Url) { return $c }
        Write-WarnMsg "$($c.Name) 不可用"
    }
    return $null
}

function Select-GhProxy {
    foreach ($c in $GhProxyCandidates) {
        Write-Info "探测 GitHub 代理：$($c.Name)"
        if (Test-GhProxy -Prefix $c.Prefix) { return $c }
        Write-WarnMsg "$($c.Name) 不可用"
    }
    return $null
}

function Select-RawProxy {
    foreach ($c in $RawCandidates) {
        Write-Info "探测文件下载代理：$($c.Name)"
        if (Test-RawProxy -Prefix $c.Prefix) { return $c }
        Write-WarnMsg "$($c.Name) 不可用"
    }
    return $null
}

# ---------------------------------------------------------------- 依赖清单改写

# 从锁文件里取一个真实安装包的相对路径，用来验证镜像是否带齐。
function Get-LockSampleArtifact {
    param([string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return '' }
    $text = [System.IO.File]::ReadAllText($LockPath)
    $m = [regex]::Match($text, 'https://files\.pythonhosted\.org/packages/[^"]*\.whl')
    if (-not $m.Success) {
        $m = [regex]::Match($text, 'https://[^"]*/packages/[^"]*\.whl')
    }
    if (-not $m.Success) {
        $m = [regex]::Match($text, 'https://files\.pythonhosted\.org/packages/[^"]*')
    }
    if (-not $m.Success) { return '' }
    $url = $m.Value
    $idx = $url.IndexOf('/packages/')
    if ($idx -lt 0) { return '' }
    return $url.Substring($idx + '/packages/'.Length)
}

# 从锁文件里读出某个安装包的期望哈希
function Get-LockExpectedHash {
    param([string]$LockPath, [string]$RelativePath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return '' }
    $base = [System.IO.Path]::GetFileName($RelativePath)
    $lines = [System.IO.File]::ReadAllLines($LockPath)
    foreach ($line in $lines) {
        if ($line.Contains('url = "') -and $line.Contains($base)) {
            $m = [regex]::Match($line, 'hash = "sha256:([0-9a-f]+)"')
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    return ''
}

# 改写锁文件：下载地址、索引地址、GitHub 地址一起改。
# 只换下载地址不够 —— 索引地址必须和环境变量指向同一个镜像，
# 否则 uv 会认为锁文件需要重新生成。
function Invoke-LockRewrite {
    param([string]$LockPath, [string]$PkgPrefix, [string]$Index, [string]$GhPrefix)

    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }

    $bak = $LockPath + $Script:BackupSuffix
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $LockPath -Destination $bak -Force
    }

    $text = [System.IO.File]::ReadAllText($LockPath)
    $text = $text.Replace('https://files.pythonhosted.org/packages/', $PkgPrefix)
    $text = $text.Replace('https://pypi.org/simple', $Index)
    if ($GhPrefix) {
        $text = $text.Replace('https://github.com/', ($GhPrefix + '/'))
    }
    # 不写 BOM，也不改换行符，保持原文件格式
    $Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($LockPath, $text, $Utf8NoBom)

    if ($text.Contains('files.pythonhosted.org')) {
        Write-ErrMsg "lock 改写后仍有 pythonhosted 残留：$LockPath"
        return $false
    }
    return $true
}

# 依赖声明文件里也写着 GitHub 地址，必须和锁文件一起改，否则 uv 会报「lockfile 需要更新」。
function Invoke-PyprojectRewrite {
    param([string]$PyprojectPath, [string]$GhPrefix)
    if (-not (Test-Path -LiteralPath $PyprojectPath)) { return $false }
    if (-not $GhPrefix) { return $true }

    $bak = $PyprojectPath + $Script:BackupSuffix
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $PyprojectPath -Destination $bak -Force
    }
    $text = [System.IO.File]::ReadAllText($PyprojectPath)
    $text = $text.Replace('https://github.com/', ($GhPrefix + '/'))
    $Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($PyprojectPath, $text, $Utf8NoBom)
    return $true
}

function Restore-FromBackup {
    param([string]$Path)
    $bak = $Path + $Script:BackupSuffix
    if (-not (Test-Path -LiteralPath $bak)) { return $false }
    Copy-Item -LiteralPath $bak -Destination $Path -Force
    Remove-Item -LiteralPath $bak -Force
    return $true
}

function Test-LockRewritten {
    param([string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
    $text = [System.IO.File]::ReadAllText($LockPath)
    return (-not $text.Contains('files.pythonhosted.org'))
}

# 用 uv 自检锁文件是否自洽
function Test-LockSelfConsistent {
    param([string]$Dir)
    if (-not (Test-CommandExists 'uv')) { return 2 }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'uv.lock'))) { return 2 }
    $old = $env:UV_NATIVE_TLS
    $env:UV_NATIVE_TLS = '1'
    $r = Invoke-Process -FilePath 'uv' -Arguments @('lock', '--check') -WorkingDirectory $Dir -TimeoutSec 600
    if ($null -eq $old) { Remove-Item env:UV_NATIVE_TLS -ErrorAction SilentlyContinue } else { $env:UV_NATIVE_TLS = $old }
    if ($r.Code -eq 0) { return 0 }
    return 1
}

# ---------------------------------------------------------------- Git 处理

function Test-OriginOfficial {
    param([string]$Repo)
    $r = Invoke-GitCommand -Arguments @('-C', $Repo, 'config', '--get', 'remote.origin.url') -TimeoutSec 30
    if ($r.Code -ne 0) { return $false }
    $origin = $r.Output.Trim()
    if (-not $origin) { return $false }
    $official = @(
        'https://github.com/NousResearch/hermes-agent.git',
        'https://github.com/NousResearch/hermes-agent',
        'git@github.com:NousResearch/hermes-agent.git',
        'ssh://git@github.com/NousResearch/hermes-agent.git'
    )
    foreach ($o in $official) {
        if ($origin -eq $o) { return $true }
    }
    return $false
}

function Get-OriginUrl {
    param([string]$Repo)
    $r = Invoke-GitCommand -Arguments @('-C', $Repo, 'config', '--get', 'remote.origin.url') -TimeoutSec 30
    if ($r.Code -ne 0) { return '' }
    return $r.Output.Trim()
}

# 只改写 Hermes 官方仓库这一条地址，不做站点级改写，
# 否则用户自己的其它 GitHub 仓库（尤其是私有的）会全部被带偏。
function Set-LocalInsteadOf {
    param([string]$Repo, [string]$Upstream, [string]$Mirror)
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return $false }
    $r = Invoke-GitCommand -Arguments @('-C', $Repo, 'config', '--local', ("url." + $Mirror + ".insteadOf"), $Upstream) -TimeoutSec 30
    return ($r.Code -eq 0)
}

function Set-GlobalInsteadOf {
    param([string]$Upstream, [string]$Mirror)
    $r = Invoke-GitCommand -Arguments @('config', '--global', ("url." + $Mirror + ".insteadOf"), $Upstream) -TimeoutSec 30
    return ($r.Code -eq 0)
}

function Remove-InsteadOf {
    param([string]$Repo, [string]$Mirror)
    if ($Repo -and (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
        $null = Invoke-GitCommand -Arguments @('-C', $Repo, 'config', '--local', '--unset-all', ("url." + $Mirror + ".insteadOf")) -TimeoutSec 30
    }
    $null = Invoke-GitCommand -Arguments @('config', '--global', '--unset-all', ("url." + $Mirror + ".insteadOf")) -TimeoutSec 30
    return $true
}

# 在 Hermes 那种隔离环境里验证镜像是否真的生效
function Test-InsteadOfEffective {
    param([string]$Repo)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = 'ls-remote origin HEAD'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Repo
    # Windows 的空设备是 NUL，别的系统是 /dev/null
    $NullDevice = '/dev/null'
    if ($env:OS -eq 'Windows_NT') { $NullDevice = 'NUL' }
    $psi.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = $NullDevice
    $psi.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = $NullDevice
    $psi.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try { $null = $proc.Start() } catch { return $false }
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $null = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($Script:ProbeGitTimeout * 1000)) {
        try { $proc.Kill() } catch { }
        return $false
    }
    $proc.WaitForExit()
    $out = $stdout.Result
    if ([string]::IsNullOrWhiteSpace($out)) { return $false }
    if ($out -match '<html' -or $out -match '<!DOCTYPE') { return $false }
    return $true
}

# ---------------------------------------------------------------- 环境变量

function Get-EnvMap {
    $map = [ordered]@{}
    if ($Script:PypiIndex) {
        $map['UV_DEFAULT_INDEX'] = $Script:PypiIndex
        $map['UV_INDEX_URL'] = $Script:PypiIndex
        $map['UV_INDEX_STRATEGY'] = 'first-index'
        $map['UV_NATIVE_TLS'] = '1'
    }
    if ($Script:RawPrefix) { $map['HERMES_RAW_BASE'] = $Script:RawPrefix }
    $map['NODEJS_ORG_MIRROR'] = $Script:NodeMirror
    $map['NVM_NODEJS_ORG_MIRROR'] = $Script:NodeMirror
    $map['NVM_DOWNLOAD_URL'] = $Script:NodeMirror
    $map['npm_config_registry'] = $Script:NpmRegistry
    $map['UV_PYTHON_INSTALL_MIRROR'] = $Script:PythonMirror
    $map['UV_INSTALL_MIRROR'] = $Script:UvMirror
    $map['PLAYWRIGHT_DOWNLOAD_HOST'] = $Script:NpmRegistry
    $map['HERMES_CN_ENABLED'] = '1'
    $map['HERMES_CN_PYPI_MIRROR'] = $Script:PypiName
    $map['HERMES_CN_GIT_MIRROR'] = $Script:GitName
    # 给外部脚本用的 Git 地址改写。Hermes 内部的 git 不认这些环境变量，
    # 它那部分靠仓库内的配置，详见 lib/git.sh。
    if ($Script:GitUrl) {
        $map['GIT_CONFIG_COUNT'] = '1'
        $map['GIT_CONFIG_KEY_0'] = ('url.' + $Script:GitUrl + '/.insteadOf')
        $map['GIT_CONFIG_VALUE_0'] = $Script:OfficialOrigin
    }
    return $map
}

function Set-EnvInProcess {
    $map = Get-EnvMap
    foreach ($key in $map.Keys) {
        Set-Item -Path ("env:" + $key) -Value $map[$key]
    }
}

# 打印环境变量。默认给 PowerShell 用，--cmd 给命令提示符用。
function Write-EnvLines {
    param([switch]$CmdFormat)
    $map = Get-EnvMap
    foreach ($key in $map.Keys) {
        if ($CmdFormat) {
            Write-Output ("set `"$key=$($map[$key])`"")
        } else {
            Write-Output ("`$env:$key='$($map[$key])'")
        }
    }
}

# ---------------------------------------------------------------- 选源

function Resolve-Sources {
    if ($Script:ForcePypi) {
        $hit = $PypiCandidates | Where-Object { $_.Name -eq $Script:ForcePypi -or $_.Alias -eq $Script:ForcePypi.ToLower() } | Select-Object -First 1
        if (-not $hit) {
            Write-ErrMsg "未知的 PyPI 镜像名：$($Script:ForcePypi)"
            Write-ErrMsg "可选：$($PypiCandidates | ForEach-Object { $_.Name + '/' + $_.Alias })"
            return $false
        }
        $Script:PypiMirror = $hit
        $Script:PypiName = $hit.Name
        $Script:PypiIndex = $hit.Index
        $Script:PypiPkg = $hit.Pkg
        Write-Info "强制使用 PyPI 镜像：$($hit.Name)"
    } elseif ($Script:NoProbe) {
        $hit = $PypiCandidates[0]
        $Script:PypiMirror = $hit
        $Script:PypiName = $hit.Name
        $Script:PypiIndex = $hit.Index
        $Script:PypiPkg = $hit.Pkg
        Write-Info "跳过探测，使用默认 PyPI 镜像：$($hit.Name)"
    } else {
        Write-Step '选择 PyPI 镜像'
        $hit = Select-PypiMirror
        if (-not $hit) {
            Write-ErrMsg '没有可用的 PyPI 镜像，请检查网络'
            return $false
        }
        $Script:PypiMirror = $hit
        $Script:PypiName = $hit.Name
        $Script:PypiIndex = $hit.Index
        $Script:PypiPkg = $hit.Pkg
    }

    if ($Script:ForceGit) {
        $Script:GitName = '自定义'
        $Script:GitUrl = $Script:ForceGit
    } elseif ($Script:NoProbe) {
        $Script:GitName = $GitCandidates[0].Name
        $Script:GitUrl = $GitCandidates[0].Url
    } else {
        Write-Step '选择 GitHub 镜像'
        $hit = Select-GitMirror
        if ($hit) {
            $Script:GitName = $hit.Name
            $Script:GitUrl = $hit.Url
        } else {
            Write-WarnMsg '没有可用的 GitHub 镜像，Git 操作将走官方地址'
            $Script:GitName = ''
            $Script:GitUrl = ''
        }
    }

    $hit = Select-GhProxy
    if ($hit) {
        $Script:GhProxyName = $hit.Name
        $Script:GhProxyPrefix = $hit.Prefix
    } else {
        Write-WarnMsg '没有可用的 GitHub 下载代理，部分依赖可能拉取失败'
        $Script:GhProxyName = ''
        $Script:GhProxyPrefix = ''
    }

    if ($Script:NoProbe) {
        $Script:RawName = $RawCandidates[0].Name
        $Script:RawPrefix = $RawCandidates[0].Prefix
    } else {
        $hit = Select-RawProxy
        if ($hit) {
            $Script:RawName = $hit.Name
            $Script:RawPrefix = $hit.Prefix
        } else {
            $Script:RawName = ''
            $Script:RawPrefix = ''
        }
    }
    return $true
}

# ---------------------------------------------------------------- 自检

$Script:DoctorFail = 0
$Script:DoctorWarn = 0

function Write-DocHead { param([string]$Message) Write-Host "" -ForegroundColor White; Write-Host $Message -ForegroundColor White }

function Test-PypiSection {
    Write-DocHead 'PyPI 镜像'
    $hit = Select-PypiMirror
    if (-not $hit) {
        Write-DocFail '没有可用的 PyPI 镜像'
        return
    }
    Write-DocOk "可用镜像：$($hit.Name)  ($($hit.Index))"

    $hermes = Get-HermesHome
    if ($hermes -and (Test-Path -LiteralPath (Join-Path $hermes 'uv.lock'))) {
        $rel = Get-LockSampleArtifact -LockPath (Join-Path $hermes 'uv.lock')
        if ($rel) {
            if (Test-PypiArtifact -PkgPrefix $hit.Pkg -RelativePath $rel) {
                Write-DocOk "包含 Hermes 需要的安装包：$([System.IO.Path]::GetFileName($rel))"
                $expected = Get-LockExpectedHash -LockPath (Join-Path $hermes 'uv.lock') -RelativePath $rel
                if ($expected) {
                    $dir = New-TempDir
                    try {
                        $file = Join-Path $dir 'artifact'
                        $actual = Get-RemoteFileSha256 -Url ($hit.Pkg + $rel) -OutFile $file -TimeoutSec 90
                    } finally {
                        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    if ($actual -and $actual -eq $expected) {
                        Write-DocOk '内容与官方完全一致（逐字节相同）'
                    } else {
                        Write-DocWarn '内容与官方不一致，这个镜像可能有问题'
                        $Script:DoctorFail = 1
                    }
                }
            } else {
                Write-DocFail "该镜像缺少 Hermes 需要的安装包：$([System.IO.Path]::GetFileName($rel))"
            }
        }
    } else {
        Write-DocWarn '未找到 Hermes 安装目录，跳过安装包检查'
    }
}

function Test-LockSection {
    Write-DocHead '依赖清单状态'
    $hermes = Get-HermesHome
    if (-not $hermes) {
        Write-DocWarn '未找到 Hermes 安装目录，跳过'
        return
    }
    $lock = Join-Path $hermes 'uv.lock'
    if (-not (Test-Path -LiteralPath $lock)) {
        Write-DocWarn "未找到 $lock"
        return
    }
    if (Test-LockRewritten -LockPath $lock) {
        Write-DocOk '依赖清单已指向国内镜像'
        $text = [System.IO.File]::ReadAllText($lock)
        $m = [regex]::Match($text, 'registry = "([^"]*)"')
        if ($m.Success) { Write-DocOk "依赖清单里记录的下载源：$($m.Groups[1].Value)" }
    } else {
        Write-DocWarn '依赖清单还是官方地址（执行 hermes-cn apply 可改写）'
    }

    $code = Test-LockSelfConsistent -Dir $hermes
    if ($code -eq 0) {
        Write-DocOk '依赖清单自检通过'
    } elseif ($code -eq 1) {
        Write-DocFail '依赖清单自检不通过'
    } else {
        Write-DocWarn '未找到 uv，跳过依赖清单自检'
    }
}

function Test-GitSection {
    Write-DocHead 'GitHub 镜像'
    $hit = Select-GitMirror
    if (-not $hit) {
        Write-DocFail '没有可用的 GitHub 镜像'
        return
    }
    Write-DocOk "可用镜像：$($hit.Name)  ($($hit.Url))"
}

function Test-OriginSection {
    Write-DocHead '更新通道'
    $hermes = Get-HermesHome
    if (-not $hermes) {
        Write-DocWarn '未找到 Hermes 安装目录，跳过'
        return
    }
    if (Test-OriginOfficial -Repo $hermes) {
        Write-DocOk '仓库来源地址仍是官方 GitHub（更新通道不受影响）'
    } else {
        $origin = Get-OriginUrl -Repo $hermes
        if (-not $origin) {
            Write-DocWarn '这个目录不是 Git 仓库，或者没有记录来源地址'
        } else {
            Write-DocFail "仓库来源地址已被改过：$origin"
        }
    }
}

function Test-InsteadOfSection {
    Write-DocHead 'Git 下载镜像'
    $hermes = Get-HermesHome
    if (-not $hermes) {
        Write-DocWarn '未找到 Hermes 安装目录，跳过'
        return
    }
    # 来源地址不是官方 GitHub 时，这次检查说明不了问题：
    # 拉取走的是本地路径，根本没经过镜像。
    if (-not (Test-OriginOfficial -Repo $hermes)) {
        Write-DocWarn '仓库来源地址不是官方 GitHub，这次没法验证镜像是否生效'
        Write-DocWarn "  恢复办法： git remote set-url origin $($Script:OfficialOrigin)"
        return
    }
    if (Test-InsteadOfEffective -Repo $hermes) {
        Write-DocOk 'Git 下载镜像已生效'
    } else {
        Write-DocWarn 'Git 下载镜像还没配置（执行 hermes-cn apply 可配置）'
    }
}

function Test-RawSection {
    Write-DocHead '文件代理 / 版本信息 / 二进制'
    $hit = Select-RawProxy
    if ($hit) {
        Write-DocOk "文件下载代理可用：$($hit.Name)"
    } else {
        Write-DocFail '没有可用的文件下载代理'
    }

    $hit = Select-GhProxy
    if ($hit) {
        Write-DocOk "GitHub 下载代理可用：$($hit.Name)（下载内容和 git 拉取都验证过）"
    } else {
        Write-DocFail '没有可用的 GitHub 下载代理，部分依赖会拉取失败'
    }

    if ((Get-HttpStatus -Url ($Script:OfficialAssets + '/releases/stable/release-candidates.json')) -eq 200) {
        Write-DocOk '官方版本信息可用（留作最后的备用）'
    } else {
        Write-DocWarn '官方版本信息连不上'
    }

    if ((Get-HttpStatus -Url ($Script:NpmRegistry + '/')) -eq 200) {
        Write-DocOk 'npm 镜像可用（npmmirror）'
    } else {
        Write-DocWarn 'npm 镜像不可达'
    }
    if ((Get-HttpStatus -Url ($Script:UvMirror + '/0.13.5/uv-aarch64-pc-windows-msvc.zip')) -eq 200) {
        Write-DocOk 'uv 二进制镜像可用（华为云）'
    } else {
        Write-DocWarn 'uv 二进制镜像连不上（install.sh 自带官方地址兜底）'
    }
}

function Write-DocOk { param([string]$Message) Write-Ok $Message }
function Write-DocWarn { param([string]$Message) Write-WarnMsg $Message; $Script:DoctorWarn = $Script:DoctorWarn + 1 }
function Write-DocFail { param([string]$Message) Write-ErrMsg $Message; $Script:DoctorFail = 1 }

function Invoke-Doctor {
    $Script:DoctorFail = 0
    $Script:DoctorWarn = 0

    Write-Host 'hermes-cn 自检' -ForegroundColor White

    Write-DocHead '基础环境'
    if (Test-CommandExists 'curl') { Write-DocOk 'curl 可用' } else { Write-DocWarn '未找到 curl（可选，用它做网络探测）' }
    if (Test-CommandExists 'git') { Write-DocOk 'git 可用' } else { Write-DocFail '缺少 git' }
    if (Test-CommandExists 'uv') { Write-DocOk 'uv 可用' } else { Write-DocWarn '未找到 uv（Hermes 自带托管的 uv，不一定在 PATH）' }
    $psVersion = $PSVersionTable.PSVersion.ToString()
    Write-DocOk "PowerShell $psVersion"

    Test-PypiSection
    Test-LockSection
    Test-GitSection
    Test-OriginSection
    Test-InsteadOfSection
    Test-RawSection

    Write-Host ""
    if ($Script:DoctorFail -eq 0) {
        if ($Script:DoctorWarn -gt 0) {
            Write-Host "没有发现失败项。带 ! 的 $($Script:DoctorWarn) 项需要留意。" -ForegroundColor Green
        } else {
            Write-Host '全部检查通过。' -ForegroundColor Green
        }
        return 0
    }
    Write-Host '有检查项没通过，见上方 ✗ 标记。' -ForegroundColor Yellow
    return 1
}

# ---------------------------------------------------------------- 子命令

function Start-AcceleratedShell {
    Write-Step '加速环境已就绪'
    Write-Host "  PyPI 镜像 : $($Script:PypiName) ($($Script:PypiIndex))"
    if ($Script:GitName) { Write-Host "  Git 镜像  : $($Script:GitName) ($($Script:GitUrl))" }
    if ($Script:RawName) { Write-Host "  文件代理  : $($Script:RawName)" }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        Write-Host "  提示：直接运行 hermes update 或任意联网命令即可。"
    } else {
        Write-Host "  提示：直接运行 hermes update、bash scripts/install.sh 或任意联网命令即可。"
    }
    Write-Host ""

    Set-EnvInProcess
    $psExe = ''
    foreach ($candidate in @((Join-Path $PSHOME 'powershell.exe'), 'powershell.exe', 'pwsh.exe', 'pwsh')) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $psExe = $candidate; break }
    }
    if (-not $psExe) { $psExe = 'powershell.exe' }
    try {
        Start-Process -FilePath $psExe -NoLogo -NoExit | Out-Null
    } catch {
        Write-ErrMsg "无法启动新的 PowerShell 窗口：$($_.Exception.Message)"
        return 1
    }
    return 0
}

function Invoke-InAcceleratedEnv {
    param([string[]]$Command)
    if (-not $Command -or $Command.Count -eq 0) {
        Write-ErrMsg 'run 需要一条命令'
        $Script:ExitCode = 2
        return
    }
    Set-EnvInProcess
    $exe = $Command[0]
    # 数组展开必须用 @变量 的写法，@(...) 只是数组表达式，不会展开。
    if ($Command.Count -gt 1) {
        $Rest = $Command[1..($Command.Count - 1)]
        & $exe @Rest
    } else {
        & $exe
    }
    # 命令自身的输出留在标准输出里，退出码单独记一份。
    $Script:ExitCode = 0
    if ($null -ne $LASTEXITCODE) { $Script:ExitCode = $LASTEXITCODE }
}

function Invoke-Apply {
    if (-not (Resolve-Sources)) { return 1 }

    $hermes = Get-HermesHome
    if (-not $hermes) {
        Write-ErrMsg '未找到 Hermes 安装目录。请先安装 Hermes，或用 HERMES_HOME 指定路径。'
        return 1
    }

    Write-Step "把依赖清单指向 $($Script:PypiName) 镜像"
    foreach ($lock in @((Join-Path $hermes 'uv.lock'), (Join-Path $hermes 'pm/uv.lock'))) {
        if (-not (Test-Path -LiteralPath $lock)) { continue }
        if (Invoke-LockRewrite -LockPath $lock -PkgPrefix $Script:PypiPkg -Index $Script:PypiIndex -GhPrefix $Script:GhProxyPrefix) {
            Write-Ok "已改写：$lock"
        } else {
            Write-ErrMsg "改写失败：$lock"
            return 1
        }
    }

    Write-Step '把依赖声明里的 GitHub 地址一起改掉'
    foreach ($pp in @((Join-Path $hermes 'pyproject.toml'), (Join-Path $hermes 'pm/pyproject.toml'))) {
        if (-not (Test-Path -LiteralPath $pp)) { continue }
        if (Invoke-PyprojectRewrite -PyprojectPath $pp -GhPrefix $Script:GhProxyPrefix) {
            Write-Ok "已改写：$pp"
        } else {
            Write-WarnMsg "改写失败：$pp"
        }
    }

    Write-Info '检查依赖清单是否自洽 ...'
    $code = Test-LockSelfConsistent -Dir $hermes
    if ($code -eq 0) {
        Write-Ok '依赖清单自检通过'
    } elseif ($code -eq 1) {
        Write-WarnMsg '依赖清单自检没通过，请执行 hermes-cn doctor 查看详情'
    }

    if ($Script:GitUrl) {
        Write-Step "让 Git 下载走 $($Script:GitName) 镜像"
        if (Set-LocalInsteadOf -Repo $hermes -Upstream $Script:OfficialOrigin -Mirror $Script:GitUrl) {
            Write-Ok '已为这个仓库单独设置镜像（不影响你其它仓库）'
        } else {
            Write-WarnMsg '为这个仓库设置镜像失败'
        }
        if (Set-GlobalInsteadOf -Upstream $Script:OfficialOrigin -Mirror $Script:GitUrl) {
            Write-Ok '已为 Hermes 官方仓库设置全局镜像（不影响你其它仓库）'
        }
    }

    Write-Step '检查仓库来源地址'
    if (Test-OriginOfficial -Repo $hermes) {
        Write-Ok '仓库来源地址仍是官方 GitHub（更新通道不受影响）'
    } else {
        Write-WarnMsg "仓库来源地址不是官方地址：$(Get-OriginUrl -Repo $hermes)"
        Write-WarnMsg "  恢复办法： git remote set-url origin $($Script:OfficialOrigin)"
    }

    Write-Host ''
    Write-Host '加速配置已生效。' -ForegroundColor Green
    Write-Host '  现在可以直接运行： hermes update'
    Write-Host '  撤销请执行： hermes-cn restore'
    return 0
}

function Invoke-Restore {
    $hermes = Get-HermesHome
    if (-not $hermes) {
        Write-ErrMsg '未找到 Hermes 安装目录。'
        return 1
    }

    Write-Step '还原依赖清单'
    $restored = $false
    foreach ($lock in @((Join-Path $hermes 'uv.lock'), (Join-Path $hermes 'pm/uv.lock'))) {
        if (Restore-FromBackup -Path $lock) {
            Write-Ok "已还原：$lock"
            $restored = $true
        }
    }
    foreach ($pp in @((Join-Path $hermes 'pyproject.toml'), (Join-Path $hermes 'pm/pyproject.toml'))) {
        if (Restore-FromBackup -Path $pp) {
            Write-Ok "已还原：$pp"
            $restored = $true
        }
    }
    if (-not $restored) { Write-WarnMsg '没有需要还原的备份' }

    Write-Step '移除 Git 镜像设置'
    $mirror = $Script:GitUrl
    if (-not $mirror) {
        $r = Invoke-GitCommand -Arguments @('config', '--global', '--get-regexp', 'url\..*\.insteadOf') -TimeoutSec 30
        if ($r.Code -eq 0) {
            foreach ($line in ($r.Output -split "`n")) {
                if ($line -match '^url\.(.+)\.insteadOf\s+\S*hermes-agent\.git\s*$') { $mirror = $Matches[1] }
            }
        }
    }
    if ($mirror) {
        Remove-InsteadOf -Repo $hermes -Mirror $mirror | Out-Null
    }
    Write-Ok '已移除 Git 镜像设置'

    Write-Host ''
    Write-Host '已恢复到官方直连状态。' -ForegroundColor Green
    return 0
}

function Invoke-Install {
    if (-not (Resolve-Sources)) { return 1 }

    $target = $Script:InstallTarget
    if (-not $target) {
        $target = Join-Path $env:USERPROFILE '.hermes/hermes-agent'
    }
    Write-Step "从 $($Script:GitName) 安装 Hermes → $target"

    if (Test-Path -LiteralPath $target) {
        Write-WarnMsg "目标目录已存在：$target"
        if (-not $Script:AssumeYes) {
            $answer = Read-Host '是否继续？（会覆盖）[y/N]'
            if ($answer -notmatch '^(y|yes|Y|YES)$') {
                Write-ErrMsg '已取消'
                return 1
            }
        }
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }

    $cloneUrl = $Script:GitUrl
    if (-not $cloneUrl) { $cloneUrl = $Script:OfficialOrigin }
    Write-Info "正在下载：$cloneUrl"
    $r = Invoke-GitCommand -Arguments @('clone', '--filter=blob:none', $cloneUrl, $target) -TimeoutSec 1800
    if ($r.Code -ne 0) {
        Write-ErrMsg "下载失败：$cloneUrl"
        if ($r.Error) { Write-ErrMsg $r.Error.Trim() }
        return 1
    }
    Write-Ok "已下载到 $target"

    # 来源地址必须是官方地址，否则更新通道会掉成非官方
    $null = Invoke-GitCommand -Arguments @('-C', $target, 'remote', 'set-url', 'origin', $Script:OfficialOrigin) -TimeoutSec 30
    Write-Ok '仓库来源已设为官方地址（更新通道保持官方）'

    if ($Script:GitUrl) {
        if (Set-LocalInsteadOf -Repo $target -Upstream $Script:OfficialOrigin -Mirror $Script:GitUrl) {
            Write-Ok '已为这个仓库单独设置镜像（不影响你其它仓库）'
        }
    }

    Write-Step "把依赖清单指向 $($Script:PypiName) 镜像"
    foreach ($lock in @((Join-Path $target 'uv.lock'), (Join-Path $target 'pm/uv.lock'))) {
        if (-not (Test-Path -LiteralPath $lock)) { continue }
        if (Invoke-LockRewrite -LockPath $lock -PkgPrefix $Script:PypiPkg -Index $Script:PypiIndex -GhPrefix $Script:GhProxyPrefix) {
            Write-Ok "已改写：$lock"
        }
    }
    foreach ($pp in @((Join-Path $target 'pyproject.toml'), (Join-Path $target 'pm/pyproject.toml'))) {
        if (-not (Test-Path -LiteralPath $pp)) { continue }
        if (Invoke-PyprojectRewrite -PyprojectPath $pp -GhPrefix $Script:GhProxyPrefix) {
            Write-Ok "已改写：$pp"
        }
    }

    Write-Host ''
    Write-Host '安装完成。' -ForegroundColor Green
    Write-Host "  下一步： cd $target 然后运行 hermes update"
    return 0
}

function Show-Help {
    Write-Host @'
hermes-cn —— Hermes 大陆网络加速（Windows 版）

用法：
  hermes-cn.cmd [命令] [参数...]

命令：
  (无)              进入加速环境（新的 PowerShell 窗口），退出即恢复
  run <命令>        在加速环境里执行一条命令，原样返回它的退出码
  env               打印可导入的环境变量（--cmd 输出命令提示符格式）
  doctor            自检：镜像是否可用、依赖清单是否正常、更新通道是否完好
  apply             把依赖清单指向国内镜像，并让 Git 下载走镜像（长期生效）
  restore           撤销 apply 的所有改动，还原依赖清单和 Git 配置
  install           用镜像全新安装 Hermes 到 %USERPROFILE%\.hermes\hermes-agent
  help              显示本帮助

选项：
  --pypi-mirror <名>   跳过探测，强制使用指定的 PyPI 镜像
                       可用名称：清华/tuna、中科大/ustc、阿里云/aliyun、
                       腾讯云/tencent、北京外国语/bfsu、华为云/huawei
  --git-mirror <地址>  跳过探测，强制使用指定的 Git 镜像地址
  --no-probe           不做探测，直接用默认的首选源
  --yes, -y            不询问，直接执行
  --version, -v        显示版本

示例：
  hermes-cn.cmd doctor
  hermes-cn.cmd run hermes update
  hermes-cn.cmd --pypi-mirror tuna run hermes update
'@
}

# ---------------------------------------------------------------- 参数解析

$Script:ForcePypi = ''
$Script:ForceGit = ''
$Script:NoProbe = $false
$Script:AssumeYes = $false
$Script:PypiMirror = $null
$Script:PypiName = ''
$Script:PypiIndex = ''
$Script:PypiPkg = ''
$Script:GitName = ''
$Script:GitUrl = ''
$Script:RawName = ''
$Script:RawPrefix = ''
$Script:GhProxyName = ''
$Script:GhProxyPrefix = ''
$Script:InstallTarget = ''

$Command = 'shell'
$CommandArgs = @()
$ArgList = @($args)

while ($ArgList.Count -gt 0) {
    $current = $ArgList[0]
    switch ($current) {
        '--pypi-mirror' {
            $ArgList = @($ArgList | Select-Object -Skip 1)
            if ($ArgList.Count -gt 0) { $Script:ForcePypi = $ArgList[0]; $ArgList = @($ArgList | Select-Object -Skip 1) }
            else { Write-ErrMsg '--pypi-mirror 后面要跟镜像名'; exit 2 }
        }
        '--git-mirror' {
            $ArgList = @($ArgList | Select-Object -Skip 1)
            if ($ArgList.Count -gt 0) { $Script:ForceGit = $ArgList[0]; $ArgList = @($ArgList | Select-Object -Skip 1) }
            else { Write-ErrMsg '--git-mirror 后面要跟地址'; exit 2 }
        }
        '--no-probe' { $Script:NoProbe = $true; $ArgList = @($ArgList | Select-Object -Skip 1) }
        '--yes' { $Script:AssumeYes = $true; $ArgList = @($ArgList | Select-Object -Skip 1) }
        '-y' { $Script:AssumeYes = $true; $ArgList = @($ArgList | Select-Object -Skip 1) }
        '--version' { Write-Host "hermes-cn $($Script:Version)"; exit 0 }
        '-v' { Write-Host "hermes-cn $($Script:Version)"; exit 0 }
        'help' { Show-Help; exit 0 }
        '-h' { Show-Help; exit 0 }
        '--help' { Show-Help; exit 0 }
        '--' { $ArgList = @($ArgList | Select-Object -Skip 1); break }
        default {
            if ($current.StartsWith('-')) {
                Write-ErrMsg "未知选项：$current"
                Show-Help
                exit 2
            }
            $Command = $current
            $ArgList = @($ArgList | Select-Object -Skip 1)
            $CommandArgs = @($ArgList)
            $ArgList = @()
        }
    }
    if ($ArgList.Count -eq 0) { break }
}

$Script:ExitCode = 0

function Invoke-Main {
switch ($Command) {
    'shell' { $Script:ExitCode = Start-AcceleratedShell }
    'run' { Invoke-InAcceleratedEnv -Command $CommandArgs }
    'env' {
        if (-not (Resolve-Sources)) { $Script:ExitCode = 1 }
        elseif ($CommandArgs -contains '--cmd') { Write-EnvLines -CmdFormat }
        else { Write-EnvLines }
    }
    'doctor' { $Script:ExitCode = Invoke-Doctor }
    'apply' { $Script:ExitCode = Invoke-Apply }
    'restore' { $Script:ExitCode = Invoke-Restore }
    'install' {
        if ($CommandArgs.Count -gt 0) { $Script:InstallTarget = $CommandArgs[0] }
        $Script:ExitCode = Invoke-Install
    }
    default {
        Write-ErrMsg "未知命令：$Command"
        Show-Help
        $Script:ExitCode = 2
    }
}

exit $Script:ExitCode
}

# 设了 HERMES_CN_NO_MAIN=1 就只加载函数不执行，供自检脚本调用。
if ($env:HERMES_CN_NO_MAIN -ne '1') {
    Invoke-Main
}
