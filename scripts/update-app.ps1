# Booth360 一键取最新安装包
# 用法：右键此文件 → 使用 PowerShell 运行（或在终端执行）
# 前提：本机 gh 已登录（当前电脑已配置好）
# 结果：最新云端构建的 Booth360-unsigned.ipa 出现在项目的 ipa\ 文件夹
#       然后打开 Sideloadly，把它拖进去装机即可

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

New-Item -ItemType Directory -Force "$projectRoot\ipa" | Out-Null

Write-Host "正在从 GitHub Releases 下载最新构建..." -ForegroundColor Cyan
gh release download latest --repo hugoteoh/Booth360 --pattern "*.ipa" --dir "$projectRoot\ipa" --clobber

$ipa = Get-Item "$projectRoot\ipa\Booth360-unsigned.ipa"
Write-Host ""
Write-Host "完成！" -ForegroundColor Green
Write-Host "文件: $($ipa.FullName)"
Write-Host "大小: $([Math]::Round($ipa.Length/1KB)) KB · 时间: $($ipa.LastWriteTime)"
Write-Host ""
Write-Host "下一步: 打开 Sideloadly -> USB 连 iPhone -> 拖入上面这个文件 -> Start"
