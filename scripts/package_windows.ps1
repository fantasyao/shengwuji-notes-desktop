# 声物记电脑版：构建 + 运行库补齐 + zip 打包，一条命令完成。
#
# 用法（双击 scripts\package_windows.bat 即可，无需打开 PowerShell）：
#   .\scripts\package_windows.ps1
#   .\scripts\package_windows.ps1 -Version 0.1.1
#   .\scripts\package_windows.ps1 -VcRuntimeDir "D:\...\Microsoft.VC142.CRT"
#
# 退出码 0 表示成功、非 0 表示失败；失败原因会打印在最后，bat 会停在窗口里。

[CmdletBinding()]
param(
    # 不传则从 pubspec.yaml 的 version 读取（去掉 +build 部分）。
    [string]$Version = '',

    # VC++ 运行库所在目录（含 msvcp140.dll 等三个文件）；不传则自动查找。
    [string]$VcRuntimeDir = '',

    # 构建配置，一般不用改。
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 控制台不支持 UTF-8 时继续，只是输出可能显示为本地编码。
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$appName = 'shengwuji_desktop'
$dllNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$exitCode = 1

Push-Location $repoRoot
try {
    if (-not $Version) {
        $pubspec = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Raw
        $match = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+\S*)?\s*$')
        if (-not $match.Success) {
            throw '无法从 pubspec.yaml 解析 version（期望形如 0.1.0+1）。'
        }
        $Version = $match.Groups[1].Value
    }
    if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.\-]*$') {
        throw "版本号不合法：$Version"
    }

    $packageName = "$appName-v$Version-windows-x64"
    $releaseDir = Join-Path $repoRoot (Join-Path 'build\windows\x64\runner' $Configuration)
    $stageDir = Join-Path $repoRoot (Join-Path 'build\package' $packageName)
    $distDir = Join-Path $repoRoot 'dist'
    $zipPath = Join-Path $distDir "$packageName.zip"

    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutter) {
        throw '找不到 flutter 命令：请把 Flutter SDK 的 bin 目录加入 PATH，或从 Flutter 自带的终端里运行。'
    }

    Write-Host "==> [1/4] 构建 Windows $Configuration（版本 $Version）..." -ForegroundColor Cyan
    & $flutter.Source build windows "--$($Configuration.ToLower())"
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows 失败（退出码 $LASTEXITCODE）。上面的构建输出就是原因，修好编译错误后重试。"
    }

    $exePath = Join-Path $releaseDir "$appName.exe"
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "构建结束但找不到 $exePath；请确认 pubspec.yaml 里 name 仍是 $appName。"
    }

    Write-Host '==> [2/4] 查找 VC++ 运行库 ...' -ForegroundColor Cyan
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($VcRuntimeDir) { $candidates.Add($VcRuntimeDir) }
    if ($env:VC_RUNTIME_X64) { $candidates.Add($env:VC_RUNTIME_X64) }
    if ($env:VCToolsRedistDir) {
        $candidates.Add((Join-Path $env:VCToolsRedistDir 'x64'))
    }

    # vswhere 按注册表找已安装的 Visual Studio / Build Tools，自定义安装盘符也能找到。
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installPaths = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        foreach ($installPath in $installPaths) {
            if (-not $installPath) { continue }
            $redistRoot = Join-Path $installPath 'VC\Redist\MSVC'
            if (-not (Test-Path -LiteralPath $redistRoot)) { continue }
            Get-ChildItem -LiteralPath $redistRoot -Directory |
                Sort-Object Name -Descending |
                ForEach-Object {
                    $candidates.Add((Join-Path $_.FullName 'x64'))
                }
        }
    }

    $runtimeDir = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        # 允许直接传 ...\Microsoft.VC142.CRT 本身，也允许传它的上级 x64 目录。
        $directMissing = @($dllNames | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $candidate $_))
        })
        if ($directMissing.Count -eq 0) {
            $runtimeDir = $candidate
            break
        }
        $crtDirs = @()
        if (Test-Path -LiteralPath (Join-Path $candidate 'Microsoft.VC142.CRT')) {
            $crtDirs += (Join-Path $candidate 'Microsoft.VC142.CRT')
        }
        $crtDirs += @(Get-ChildItem -LiteralPath $candidate -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.VC*.CRT' } |
            ForEach-Object { $_.FullName })
        foreach ($crtDir in ($crtDirs | Select-Object -Unique)) {
            $missing = @($dllNames | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $crtDir $_))
            })
            if ($missing.Count -eq 0) {
                $runtimeDir = $crtDir
                break
            }
        }
        if ($runtimeDir) { break }
    }

    if (-not $runtimeDir) {
        throw ("找不到 VC++ 运行库（需要 $($dllNames -join '、')）。" +
            '请安装 Visual Studio 的「使用 C++ 的桌面开发」工作负载，' +
            '或用 -VcRuntimeDir 指定类似 ...\VC\Redist\MSVC\14.29.30133\x64\Microsoft.VC142.CRT 的目录。')
    }
    Write-Host "    使用：$runtimeDir" -ForegroundColor DarkGray

    Write-Host '==> [3/4] 组装发布目录 ...' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stageDir -Recurse -Force
    foreach ($dll in $dllNames) {
        Copy-Item -LiteralPath (Join-Path $runtimeDir $dll) -Destination $stageDir -Force
    }

    Write-Host '==> [4/4] 压缩 ...' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "压缩结束但找不到 $zipPath。"
    }
    $sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)

    Write-Host ''
    Write-Host '打包完成' -ForegroundColor Green
    Write-Host "  压缩包：$zipPath（$sizeMb MB）"
    Write-Host "  程序目录：$stageDir"
    Write-Host '  接收方不需要安装 Flutter / Visual Studio，解压后双击 shengwuji_desktop.exe 即可。'
    $exitCode = 0
} catch {
    Write-Host ''
    Write-Host '打包失败' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host '排查提示：' -ForegroundColor Yellow
    Write-Host '  - 编译错误：先单独运行 flutter build windows --release 查看完整报错'
    Write-Host '  - 运行库找不到：用 -VcRuntimeDir 指定 Microsoft.VC14x.CRT 目录，或设置环境变量 VC_RUNTIME_X64'
    Write-Host '  - 压缩包被占用：先关掉正在打开的 dist 压缩包再重试'
    $exitCode = 1
} finally {
    Pop-Location
}

exit $exitCode
