# 为 ClashForAndroid 构建 Go 内核 libclash.so（4 个 ABI）
# 用法: pwsh scripts/build-clash-core.ps1 [-Flavor foss] [-BuildType Debug]
param(
    [ValidateSet('foss', 'premium')]
    [string]$Flavor = 'foss',
    [ValidateSet('Debug', 'Release')]
    [string]$BuildType = 'Debug',
    [string]$NdkVersion = '23.0.7599858',
    [string]$GoHome = ''
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$CoreDir = Join-Path $ProjectRoot 'core'
$ModuleDir = Join-Path $CoreDir "src\$Flavor\golang"
$OutputDir = Join-Path $ProjectRoot "build\golang\$Flavor$BuildType"

if (-not (Test-Path (Join-Path $ModuleDir 'clash\go.mod'))) {
    throw "未找到 $Flavor 内核源码: $ModuleDir\clash"
}

# 从 local.properties 读取 sdk.dir（形如 F\:\\AndroidSDK）
$sdkDir = $env:ANDROID_SDK_ROOT
$localProps = Join-Path $ProjectRoot 'local.properties'
if (-not $sdkDir -and (Test-Path $localProps)) {
    $match = Select-String -Path $localProps -Pattern '^sdk\.dir=(.+)$' | Select-Object -First 1
    if ($match) { $sdkDir = $match.Matches[0].Groups[1].Value.Replace('\:', ':').Replace('\\', '\') }
}
if (-not $sdkDir) { throw '未找到 Android SDK，请设置 ANDROID_SDK_ROOT 或在 local.properties 配置 sdk.dir' }

$NdkDir = Join-Path $sdkDir "ndk\$NdkVersion"
$ToolchainDir = Join-Path $NdkDir 'toolchains\llvm\prebuilt\windows-x86_64'
if (-not (Test-Path (Join-Path $ToolchainDir 'bin\clang.exe'))) {
    throw "未找到 NDK ${NdkVersion}: $NdkDir"
}

# geoip blob 模块（cfa/blob）
$BlobDir = Join-Path $CoreDir 'build\intermediates\golang_blob'
New-Item -ItemType Directory -Force $BlobDir | Out-Null
$BlobMod = Join-Path $BlobDir 'go.mod'
$BlobSrc = Join-Path $BlobDir 'blob.go'
$BlobMmdb = Join-Path $BlobDir 'Country.mmdb'
if (-not (Test-Path $BlobMod)) { Set-Content -Path $BlobMod -Value 'module "cfa/blob"' -Encoding utf8NoBOM }
if (-not (Test-Path $BlobSrc)) {
    Set-Content -Path $BlobSrc -Encoding utf8NoBOM -Value @(
        'package blob',
        '',
        'import _ "embed"',
        '',
        '//go:embed Country.mmdb',
        'var GeoipDatabase []byte'
    )
}
if (-not (Test-Path $BlobMmdb)) {
    Write-Host '下载 Country.mmdb ...'
    Invoke-WebRequest -UseBasicParsing 'https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb' -OutFile $BlobMmdb
}

# Go 1.23+ 对旧版 x/net 的 syscall linkname 有检查，需要关闭；
# premium 使用的 Clash.Meta(2023) 依赖 quic-go，只支持 Go <= 1.20
if ($Flavor -eq 'premium' -and -not $GoHome) {
    throw 'premium 内核需要 Go 1.20 工具链，请通过 -GoHome 指定（如 D:\...\_tools\go1.20.14）'
}

$goExe = if ($GoHome) { Join-Path $GoHome 'bin\go.exe' } else { 'go' }
if ($GoHome) {
    $env:GOROOT = $GoHome
    $env:PATH = (Join-Path $GoHome 'bin') + ';' + $env:PATH
}

$goVersion = (& $goExe env GOVERSION).Trim()
$goMinor = if ($goVersion -match '^go1\.(\d+)') { [int]$Matches[1] } else { 0 }
$checkLinkname = $goMinor -ge 23

$tags = if ($Flavor -eq 'premium') { 'premium,without_gvisor,without_system' } else { 'foss' }
$targets = @(
    @{ Abi = 'arm64-v8a';   Arch = 'arm64'; GoArm = $null; Triple = 'aarch64-linux-android21' },
    @{ Abi = 'armeabi-v7a'; Arch = 'arm';   GoArm = '7';   Triple = 'armv7a-linux-androideabi21' },
    @{ Abi = 'x86';         Arch = '386';   GoArm = $null; Triple = 'i686-linux-android21' },
    @{ Abi = 'x86_64';      Arch = 'amd64'; GoArm = $null; Triple = 'x86_64-linux-android21' }
)

$env:GOOS = 'android'
$env:CGO_ENABLED = '1'
$env:CC = Join-Path $ToolchainDir 'bin\clang.exe'
$env:GOFLAGS = '-mod=mod'
# 允许 --target/--sysroot 等 NDK 交叉编译参数通过 Go 的 cgo flag 校验
$env:CGO_CFLAGS_ALLOW = '.*'
$env:CGO_LDFLAGS_ALLOW = '.*'

foreach ($t in $targets) {
    $abiDir = Join-Path $OutputDir $t.Abi
    New-Item -ItemType Directory -Force $abiDir | Out-Null
    $env:GOARCH = $t.Arch
    if ($t.GoArm) { $env:GOARM = $t.GoArm } else { Remove-Item Env:GOARM -ErrorAction SilentlyContinue }
    $env:CGO_CFLAGS = "--target=$($t.Triple) --gcc-toolchain=$ToolchainDir --sysroot=$ToolchainDir/sysroot"
    $env:CGO_LDFLAGS = $env:CGO_CFLAGS

    $args = @('build', '-tags', $tags, '-buildmode=c-shared')
    if ($checkLinkname) { $args += '-ldflags=-checklinkname=0' }
    $args += @('-o', (Join-Path $abiDir 'libclash.so'), 'cfa/native')

    Write-Host "构建 $Flavor/$($t.Abi) ..."
    Push-Location $ModuleDir
    try {
        & $goExe @args
        if ($LASTEXITCODE -ne 0) { throw "go build 失败: $Flavor/$($t.Abi)" }
    } finally {
        Pop-Location
    }
}

Write-Host "完成: $OutputDir"
Get-ChildItem -Recurse -File $OutputDir | Select-Object FullName, Length
