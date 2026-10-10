#Requires -Version 5.1
<#
.SYNOPSIS
    为当前仓库应用 MiniReel 的「主干开发 + 标签发布」Git 工作流配置。

.DESCRIPTION
    只写入本仓库（git config --local），不会修改全局或系统级配置，可重复执行。
    各配置项的含义见 docs/GIT_WORKFLOW.md。

.PARAMETER UserName
    提交者显示名（写入 user.name）。

.PARAMETER UserEmail
    提交者邮箱（写入 user.email）。建议使用 GitHub 账号邮箱或 noreply 邮箱。

.EXAMPLE
    pwsh -File tool/setup-git-workflow.ps1 -UserName "Zhang San" -UserEmail "zhangsan@example.com"

.EXAMPLE
    pwsh -File tool/setup-git-workflow.ps1
#>
[CmdletBinding()]
param(
    [Parameter()][string]$UserName,
    [Parameter()][string]$UserEmail
)

$ErrorActionPreference = 'Stop'

$root = git rev-parse --show-toplevel 2>$null
if (-not $root) {
    throw '当前目录不是 Git 仓库，请在仓库内运行此脚本。'
}
Set-Location $root

$settings = [ordered]@{
    'init.defaultBranch'   = 'main'
    'pull.rebase'          = 'true'
    'fetch.prune'          = 'true'
    'push.default'         = 'simple'
    'push.autoSetupRemote' = 'true'
    'core.autocrlf'        = 'false'
    'commit.template'      = '.gitmessage'
    'merge.ff'             = 'only'
    'rerere.enabled'       = 'true'
    'tag.sort'             = '-version:refname'
}

foreach ($key in $settings.Keys) {
    git config --local $key $settings[$key]
    if ($LASTEXITCODE -ne 0) { throw "设置 $key 失败。" }
}

if ($UserName) {
    git config --local user.name $UserName
    if ($LASTEXITCODE -ne 0) { throw '设置 user.name 失败。' }
}
if ($UserEmail) {
    git config --local user.email $UserEmail
    if ($LASTEXITCODE -ne 0) { throw '设置 user.email 失败。' }
}

Write-Host '已应用本地 Git 工作流配置：' -ForegroundColor Green
git config --local --list | Sort-Object

$name = git config --local user.name
$email = git config --local user.email
if (-not $name -or -not $email) {
    Write-Host ''
    Write-Warning '尚未配置提交身份。请补充运行：pwsh -File tool/setup-git-workflow.ps1 -UserName "你的名字" -UserEmail "你的邮箱"'
}
