[CmdletBinding()]
param(
    [ValidateSet("ARM64", "x64", "All")]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'ARM64' } else { 'x64' }),

    [string]$Configuration = "Release",

    [string]$Version = "2.0.0.4",

    [string]$OutputDir = "release"
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
Set-Location $RepoRoot

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Building BrowserPicker Local Release" -ForegroundColor Cyan
Write-Host " Configuration : $Configuration" -ForegroundColor Cyan
Write-Host " Architecture  : $Architecture" -ForegroundColor Cyan
Write-Host " Version       : $Version" -ForegroundColor Cyan
Write-Host " Output Dir    : $OutputDir" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$Targets = if ($Architecture -eq "All") { @("ARM64", "x64") } else { @($Architecture) }

# 1. Generate settings schema
Write-Host "`n[1/4] Generating settings schema..." -ForegroundColor Yellow
dotnet run --project tools/BrowserPicker.SchemaGen/BrowserPicker.SchemaGen.csproj -c $Configuration -- schemas/browserpicker-settings.schema.json
if ($LASTEXITCODE -ne 0) { throw "Schema generation failed." }

# 2. Run unit tests
Write-Host "`n[2/4] Running tests..." -ForegroundColor Yellow
$hostIsArm64 = $env:PROCESSOR_ARCHITECTURE -match 'ARM64'
foreach ($arch in $Targets) {
    if ($arch -eq "ARM64" -and -not $hostIsArm64) {
        Write-Host "Verifying test project build for $arch (skipping execution on x64 host)..." -ForegroundColor Gray
        dotnet build tests/BrowserPicker.Common.Tests/BrowserPicker.Common.Tests.csproj -c $Configuration -p:Platform=$arch
        if ($LASTEXITCODE -ne 0) { throw "Test project build failed for $arch." }
    } else {
        Write-Host "Testing platform: $arch..." -ForegroundColor Gray
        dotnet test tests/BrowserPicker.Common.Tests/BrowserPicker.Common.Tests.csproj -c $Configuration -p:Platform=$arch
        if ($LASTEXITCODE -ne 0) { throw "Tests failed for $arch." }
    }
}

$ResolvedOutputDir = Join-Path $RepoRoot $OutputDir
if (-not (Test-Path $ResolvedOutputDir)) {
    New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null
}

# Copy schema to output
Copy-Item schemas/browserpicker-settings.schema.json $ResolvedOutputDir -Force

# 3. Build releases for each architecture
foreach ($arch in $Targets) {
    $rid = if ($arch -eq "ARM64") { "win-arm64" } else { "win-x64" }
    Write-Host "`n[3/4] Building binaries and installers for $arch ($rid)..." -ForegroundColor Yellow

    $versionParts = $Version -split '-', 2
    $numericVersion = $versionParts[0]

    # A. Dependent build
    Write-Host "  -> Publishing Dependent ($arch)..." -ForegroundColor Gray
    dotnet publish src/BrowserPicker.UI/BrowserPicker.UI.csproj `
        -c $Configuration `
        -p:Platform=$arch `
        -p:Version=$Version `
        -p:VersionPrefix=$numericVersion
    if ($LASTEXITCODE -ne 0) { throw "Dependent publish failed for $arch." }

    Write-Host "  -> Building Dependent MSI ($arch)..." -ForegroundColor Gray
    dotnet build dist/Dependent/Dependent.wixproj `
        --no-dependencies `
        -c $Configuration `
        -p:Platform=$arch `
        -p:Version=$numericVersion
    if ($LASTEXITCODE -ne 0) { throw "Dependent MSI build failed for $arch." }

    # B. Portable build
    Write-Host "  -> Publishing Portable ($arch / $rid)..." -ForegroundColor Gray
    dotnet publish src/BrowserPicker.UI/BrowserPicker.UI.csproj `
        -c $Configuration `
        -r $rid `
        -p:Platform=$arch `
        -p:PublishSingleFile=true `
        -p:EnableCompressionInSingleFile=true `
        -p:Version=$Version `
        -p:VersionPrefix=$numericVersion
    if ($LASTEXITCODE -ne 0) { throw "Portable publish failed for $arch." }

    Write-Host "  -> Building Portable MSI ($arch)..." -ForegroundColor Gray
    dotnet build dist/Portable/Portable.wixproj `
        --no-dependencies `
        -c $Configuration `
        -p:Platform=$arch `
        -p:Version=$numericVersion
    if ($LASTEXITCODE -ne 0) { throw "Portable MSI build failed for $arch." }

    # 4. Packaging into output directory
    Write-Host "`n[4/4] Packaging release artifacts for $arch..." -ForegroundColor Yellow
    $ArchOutputDir = Join-Path $ResolvedOutputDir $arch.ToLower()
    if (-not (Test-Path $ArchOutputDir)) {
        New-Item -ItemType Directory -Path $ArchOutputDir -Force | Out-Null
    }

    $dependentPublishDir = "src/BrowserPicker.UI/bin/$arch/$Configuration/net10.0-windows/publish"
    $portablePublishDir  = "src/BrowserPicker.UI/bin/$arch/$Configuration/net10.0-windows/$rid/publish"
    $dependentMsi = if (Test-Path "dist/Dependent/bin/$arch/$Configuration/BrowserPicker.msi") {
        "dist/Dependent/bin/$arch/$Configuration/BrowserPicker.msi"
    } else {
        "dist/Dependent/bin/$Configuration/BrowserPicker.msi"
    }
    $portableMsi = if (Test-Path "dist/Portable/bin/$arch/$Configuration/BrowserPicker-Portable.msi") {
        "dist/Portable/bin/$arch/$Configuration/BrowserPicker-Portable.msi"
    } else {
        "dist/Portable/bin/$Configuration/BrowserPicker-Portable.msi"
    }

    # Zip bundles
    Compress-Archive -Path "$dependentPublishDir/*" -DestinationPath (Join-Path $ArchOutputDir "Dependent.zip") -Force
    Compress-Archive -Path "$portablePublishDir/*" -DestinationPath (Join-Path $ArchOutputDir "Portable.zip") -Force

    # Copy MSIs
    Copy-Item $dependentMsi (Join-Path $ArchOutputDir "BrowserPicker.msi") -Force
    Copy-Item $portableMsi (Join-Path $ArchOutputDir "BrowserPicker-Portable.msi") -Force

    # Also place arch-qualified files in top-level output folder
    Copy-Item $dependentMsi (Join-Path $ResolvedOutputDir "BrowserPicker-$arch.msi") -Force
    Copy-Item $portableMsi (Join-Path $ResolvedOutputDir "BrowserPicker-Portable-$arch.msi") -Force
    Copy-Item (Join-Path $ArchOutputDir "Dependent.zip") (Join-Path $ResolvedOutputDir "Dependent-$arch.zip") -Force
    Copy-Item (Join-Path $ArchOutputDir "Portable.zip") (Join-Path $ResolvedOutputDir "Portable-$arch.zip") -Force
    
    # Also provide top-level non-prefixed artifacts for default architecture (x64 or single target)
    if ($Targets.Count -eq 1 -or $arch -eq "x64") {
        Copy-Item $dependentMsi (Join-Path $ResolvedOutputDir "BrowserPicker.msi") -Force
        Copy-Item $portableMsi (Join-Path $ResolvedOutputDir "BrowserPicker-Portable.msi") -Force
        Copy-Item (Join-Path $ArchOutputDir "Dependent.zip") (Join-Path $ResolvedOutputDir "Dependent.zip") -Force
        Copy-Item (Join-Path $ArchOutputDir "Portable.zip") (Join-Path $ResolvedOutputDir "Portable.zip") -Force
    }
}

Write-Host "`nRelease build completed successfully! Artifacts located in: $ResolvedOutputDir" -ForegroundColor Green
Get-ChildItem -Recurse $ResolvedOutputDir | Select-Object FullName, Length
