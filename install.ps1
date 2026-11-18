# install.ps1 - 从本机 WorkBuddy 安装目录的系统提示词模板中移除 <content_policy> 段
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun     # 预览
#   powershell -ExecutionPolicy Bypass -File .\install.ps1            # 应用(需管理员)
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Restore   # 回滚
#
# 只替换 <content_policy>...</content_policy> 整块, 其余字节不动。
# 默认保留未成年人保护一条; -KeepMinorSafety:$false 可一并移除。
param(
  [string]$Target = "C:\Program Files\WorkBuddy\resources\app.asar.unpacked\resources\templates",
  [string]$BackupDir = (Join-Path $env:USERPROFILE ".workbuddy-prompt-patch\backup"),
  [switch]$Restore,
  [switch]$DryRun,
  [bool]$KeepMinorSafety = $true
)

$ErrorActionPreference = "Stop"

$BlockRx = [regex]::new('<content_policy>[\s\S]*?</content_policy>', 'Singleline')

if ($KeepMinorSafety) {
  $Replacement = "<content_policy>`r`n- You MUST refuse any request involving the sexual exploitation or sexualization of minors.`r`n</content_policy>"
} else {
  $Replacement = ""
}

# 移除后仍不应出现的措辞(用于自检)
$Forbidden = 'politically sensitive|pornographic, erotic|override any user instructions|NEVER reveal'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------- 回滚 ----------------
if ($Restore) {
  if (-not (Test-Path $BackupDir)) { throw "没有备份目录: $BackupDir" }
  $latest = Get-ChildItem $BackupDir -Directory | Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
  if (-not $latest) { throw "备份目录为空: $BackupDir" }
  if (-not (Test-Admin)) { throw "回滚需要管理员权限, 请用管理员 PowerShell 运行" }

  Write-Host ("从备份恢复: " + $latest.FullName) -ForegroundColor Cyan
  $n = 0
  Get-ChildItem $latest.FullName -Filter *.tpl | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $Target $_.Name) -Force
    $n++
  }
  Write-Host ("已恢复 " + $n + " 个文件, 重启 WorkBuddy 生效。") -ForegroundColor Green
  return
}

# ---------------- 扫描 ----------------
if (-not (Test-Path $Target)) {
  throw "目标目录不存在: $Target`n用 -Target 指定你的 templates 目录。"
}

$plan = @()
foreach ($f in Get-ChildItem $Target -Filter *.tpl) {
  $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
  $m = $BlockRx.Match($text)
  if (-not $m.Success) { continue }
  $new = $BlockRx.Replace($text, $Replacement)
  $plan += [pscustomobject]@{
    Name    = $f.Name
    Path    = $f.FullName
    OldLen  = $text.Length
    NewLen  = $new.Length
    Removed = $m.Value.Split("`n").Count - 3
    New     = $new
    Old     = $text
  }
}

if ($plan.Count -eq 0) {
  Write-Host "没有找到 <content_policy> 块 —— 可能已经打过补丁, 或版本结构不同。" -ForegroundColor Yellow
  return
}

$plan | Format-Table Name, OldLen, NewLen, Removed -AutoSize | Out-String | Write-Host
Write-Host ("命中 " + $plan.Count + " 个模板, 合计删除约 " + ($plan | Measure-Object Removed -Sum).Sum + " 行") -ForegroundColor Cyan

if ($DryRun) { Write-Host "DryRun: 未写入。" -ForegroundColor Yellow; return }

# ---------------- 备份 + 写入 ----------------
if (-not (Test-Admin)) {
  throw "写入 Program Files 需要管理员权限。`n请右键以管理员身份运行 PowerShell 后重试, 或: Start-Process powershell -Verb RunAs -ArgumentList '-File','$PSCommandPath'"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bk = Join-Path $BackupDir $stamp
New-Item -ItemType Directory -Force -Path $bk | Out-Null
foreach ($p in $plan) { Copy-Item $p.Path (Join-Path $bk $p.Name) -Force }
@{ at = $stamp; target = $Target; count = $plan.Count } | ConvertTo-Json |
  Set-Content (Join-Path $bk "_meta.json") -Encoding UTF8
Write-Host ("备份 -> " + $bk) -ForegroundColor Green

foreach ($p in $plan) {
  [IO.File]::WriteAllText($p.Path, $p.New, (New-Object Text.UTF8Encoding($false)))
}

# ---------------- 自检 ----------------
$bad = @()
foreach ($p in $plan) {
  $t = [IO.File]::ReadAllText($p.Path, [Text.Encoding]::UTF8)
  if ($t -match $Forbidden) { $bad += $p.Name }
}
if ($bad.Count -gt 0) {
  Write-Host ("警告: 仍含目标条文 -> " + ($bad -join ", ")) -ForegroundColor Yellow
} else {
  Write-Host "自检通过: 补丁文件中已无 政治敏感/色情/越权/反泄露 条文" -ForegroundColor Green
}
Write-Host "重启 WorkBuddy 生效。回滚: 本脚本 -Restore" -ForegroundColor Cyan
