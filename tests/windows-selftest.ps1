#Requires -Version 5.1
<#
    Windows 版自检。不联网，只验证改写 / 还原 / 参数解析这些逻辑。

    运行方式：
      pwsh -NoProfile -File tests/windows-selftest.ps1
#>

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptPath = Join-Path $RepoRoot 'hermes-cn.ps1'

$Script:Failures = 0
$Script:Checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $Script:Checks++
    if ($Condition) {
        Write-Host "  ✓ $Message" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $Message" -ForegroundColor Red
        $Script:Failures++
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    Assert-True ("$Expected" -eq "$Actual") "$Message（期望 $Expected，实际 $Actual）"
}

Write-Host 'hermes-cn Windows 版自检' -ForegroundColor White

# ---------------------------------------------------------------- 语法检查

Write-Host "`n语法检查" -ForegroundColor White
$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$ParseErrors)
Assert-True ($ParseErrors.Count -eq 0) ("hermes-cn.ps1 没有语法错误（发现 $($ParseErrors.Count) 个）")
foreach ($e in $ParseErrors) {
    Write-Host ("    {0} 行 {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 加载函数

$env:HERMES_CN_NO_MAIN = '1'
. $ScriptPath
$env:HERMES_CN_NO_MAIN = $null

# ---------------------------------------------------------------- 改写与还原

Write-Host "`n依赖清单改写与还原" -ForegroundColor White

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-cn-selftest-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $TempRoot -Force

$FakeLock = Join-Path $TempRoot 'uv.lock'
$FakeLockText = @'
version = 1

[[package]]
name = "addict"
version = "2.4.0"
source = { registry = "https://pypi.org/simple" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/ab/cd/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/addict-2.4.0-py3-none-any.whl", hash = "sha256:249bb56bbfd3cdc2a004ea0ff4c2b6ddc84d53bc2194761636eb314d5cfa5dfc" },
]

[[package]]
name = "psutil"
source = { git = "https://github.com/giampaolo/psutil.git?rev=android" }
'@
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
[System.IO.File]::WriteAllText($FakeLock, $FakeLockText, $Utf8NoBom)
$OriginalHash = (Get-FileHash -LiteralPath $FakeLock -Algorithm SHA256).Hash

$FakePyproject = Join-Path $TempRoot 'pyproject.toml'
[System.IO.File]::WriteAllText($FakePyproject, "dependencies = [`"kittentts @ https://github.com/KittenML/KittenTTS/releases/download/0.8.1/kittentts-0.8.1-py3-none-any.whl`"]`n", $Utf8NoBom)
$OriginalPyprojectHash = (Get-FileHash -LiteralPath $FakePyproject -Algorithm SHA256).Hash

$TestIndex = 'https://pypi.tuna.tsinghua.edu.cn/simple'
$TestPkg = 'https://pypi.tuna.tsinghua.edu.cn/packages/'
$TestGh = 'https://gh-proxy.cc/https://github.com'

$ok = Invoke-LockRewrite -LockPath $FakeLock -PkgPrefix $TestPkg -Index $TestIndex -GhPrefix $TestGh
Assert-True $ok '锁文件改写返回成功'
$Rewritten = [System.IO.File]::ReadAllText($FakeLock)
Assert-True (-not $Rewritten.Contains('files.pythonhosted.org')) '下载地址不再指向官方站点'
Assert-True $Rewritten.Contains($TestIndex) '索引地址换成镜像'
Assert-True $Rewritten.Contains('https://gh-proxy.cc/https://github.com/giampaolo/psutil.git') 'GitHub 地址换成代理'
Assert-True $Rewritten.Contains('sha256:249bb56bbfd3cdc2a004ea0ff4c2b6ddc84d53bc2194761636eb314d5cfa5dfc') '校验哈希原样保留'
Assert-True (Test-Path -LiteralPath ($FakeLock + '.hermes-cn.bak')) '备份文件已生成'
Assert-True (Test-LockRewritten -LockPath $FakeLock) '能识别出「已改写」状态'

$rel = Get-LockSampleArtifact -LockPath $FakeLock
Assert-Equal 'ab/cd/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/addict-2.4.0-py3-none-any.whl' $rel '取样到正确的安装包路径'
$expected = Get-LockExpectedHash -LockPath $FakeLock -RelativePath $rel
Assert-Equal '249bb56bbfd3cdc2a004ea0ff4c2b6ddc84d53bc2194761636eb314d5cfa5dfc' $expected '取样到正确的期望哈希'

$ok = Invoke-PyprojectRewrite -PyprojectPath $FakePyproject -GhPrefix $TestGh
Assert-True $ok '依赖声明改写返回成功'
$RewrittenPp = [System.IO.File]::ReadAllText($FakePyproject)
Assert-True $RewrittenPp.Contains('https://gh-proxy.cc/https://github.com/KittenML') '依赖声明里的 GitHub 地址换成代理'

$ok = Restore-FromBackup -Path $FakeLock
Assert-True $ok '还原锁文件返回成功'
Assert-Equal $OriginalHash ((Get-FileHash -LiteralPath $FakeLock -Algorithm SHA256).Hash) '锁文件字节级还原'
Assert-True (-not (Test-Path -LiteralPath ($FakeLock + '.hermes-cn.bak'))) '还原后备份已清除'

$ok = Restore-FromBackup -Path $FakePyproject
Assert-True $ok '还原依赖声明返回成功'
Assert-Equal $OriginalPyprojectHash ((Get-FileHash -LiteralPath $FakePyproject -Algorithm SHA256).Hash) '依赖声明字节级还原'

# 反复改写不会把备份覆盖成已改写的版本
[System.IO.File]::WriteAllText($FakeLock, $FakeLockText, $Utf8NoBom)
$null = Invoke-LockRewrite -LockPath $FakeLock -PkgPrefix $TestPkg -Index $TestIndex -GhPrefix $TestGh
$null = Invoke-LockRewrite -LockPath $FakeLock -PkgPrefix $TestPkg -Index $TestIndex -GhPrefix $TestGh
$null = Restore-FromBackup -Path $FakeLock
Assert-Equal $OriginalHash ((Get-FileHash -LiteralPath $FakeLock -Algorithm SHA256).Hash) '多次改写后仍能还原成原版'

# ---------------------------------------------------------------- 环境变量

Write-Host "`n环境变量" -ForegroundColor White
$Script:PypiName = '清华'
$Script:PypiIndex = $TestIndex
$Script:GitName = 'GitCode'
$Script:GitUrl = 'https://gitcode.com/GitHub_Trending/he/hermes-agent.git'
$Script:RawPrefix = 'https://fastly.jsdelivr.net/gh/NousResearch/hermes-agent@main'

$envLines = Write-EnvLines
Assert-True (($envLines -join "`n").Contains("`$env:UV_DEFAULT_INDEX='$TestIndex'")) '输出里带上了索引地址'
Assert-True (($envLines -join "`n").Contains("`$env:UV_NATIVE_TLS='1'")) '输出里带上了证书设置'

Assert-True (($envLines -join "`n").Contains("`$env:GIT_CONFIG_VALUE_0='https://github.com/NousResearch/hermes-agent.git'")) '输出里带上了 Git 地址改写'
Assert-True (($envLines -join "`n").Contains("`$env:GIT_CONFIG_KEY_0='url.https://gitcode.com/GitHub_Trending/he/hermes-agent.git/.insteadOf'")) '输出里带上了 Git 镜像地址'

$cmdLines = Write-EnvLines -CmdFormat
Assert-True (($cmdLines -join "`n").Contains('set "UV_DEFAULT_INDEX=' + $TestIndex + '"')) '命令提示符格式也正确'

# ---------------------------------------------------------------- 来源地址判定

Write-Host "`n仓库来源地址判定" -ForegroundColor White
if (Test-CommandExists 'git') {
    Assert-True (Test-OriginOfficial -Repo $RepoRoot) '官方地址能被认出来'
    Assert-True (-not (Test-OriginOfficial -Repo $TempRoot)) '非官方地址不会被误认'
} else {
    Write-Host '  ! 环境里没有 git，跳过这一项' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 参数解析

Write-Host "`n参数解析" -ForegroundColor White
$pwsh = (Get-Process -Id $PID).Path
function Invoke-Script {
    param([string[]]$ScriptArgs)
    $quoted = ($ScriptArgs | ForEach-Object { "'" + $_ + "'" }) -join ' '
    return (& $pwsh -NoProfile -ExecutionPolicy Bypass -Command "& `"$ScriptPath`" $quoted" 2>&1)
}

$verOut = Invoke-Script @('--version')
Assert-True (("$verOut" -join "`n").Contains('hermes-cn')) '--version 能输出版本号'

$helpOut = Invoke-Script @('help')
Assert-True (("$helpOut" -join "`n").Contains('hermes-cn.cmd')) 'help 里写了 Windows 的用法'

$badOut = Invoke-Script @('--pypi-mirror', 'nosuchmirror', 'env')
Assert-True ($LASTEXITCODE -ne 0) '未知镜像名会报错退出'
Assert-True (("$badOut" -join "`n").Contains('tuna')) '报错时列出了可用的镜像名'

# ---------------------------------------------------------------- 收尾

Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($Script:Failures -eq 0) {
    Write-Host "全部通过（$($Script:Checks) 项）。" -ForegroundColor Green
    exit 0
}
Write-Host "有 $Script:Failures 项没通过（共 $($Script:Checks) 项）。" -ForegroundColor Red
exit 1
