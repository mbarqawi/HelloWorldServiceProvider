[CmdletBinding()]
param(
    [string] $Version,
    [string] $BundlePath,
    [string] $BundleRootPath = (Join-Path $env:USERPROFILE '.azure-functions-core-tools\Functions\ExtensionBundles\Microsoft.Azure.Functions.ExtensionBundle.Workflows'),
    [string] $OutputPath,
    [string] $ExtensionName = 'HelloWorldServiceProvider',
    [string] $AssemblyFileName = 'HelloWorldServiceProvider.dll',
    [string] $ReportPath,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkflowBundleTools.ps1')
if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'publish'
}
if (-not $ReportPath) {
    $ReportPath = Join-Path $PSScriptRoot 'reports\publish-bundle-report.json'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$report = [ordered]@{
    operation = 'Package customized workflow bundle for site hosting (no upload)'
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    status = 'Failed'
    steps = @()
}
$workingPath = $null

try {
    if (-not $Version) {
        $Version = Read-Host 'Enter workflow bundle version (for example 1.170.91)'
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid bundle version '$Version'. Use a three-part version such as 1.170.91."
    }
    if ([string]::IsNullOrWhiteSpace($AssemblyFileName) -or
        [System.IO.Path]::GetFileName($AssemblyFileName) -cne $AssemblyFileName -or
        [System.IO.Path]::GetExtension($AssemblyFileName) -ine '.dll') {
        throw 'AssemblyFileName must be a DLL filename without a directory.'
    }
    $BundlePath = Resolve-WorkflowBundlePath -BundlePath $BundlePath -Version $Version -BundleRootPath $BundleRootPath
    $localBin = Join-Path $BundlePath 'bin'
    $localManifest = Join-Path $localBin 'extensions.json'
    $localAssembly = Join-Path $localBin $AssemblyFileName
    if (-not (Test-Path -LiteralPath $localAssembly -PathType Leaf)) {
        throw "Installed provider DLL not found: '$localAssembly'. Build and run the local installer first."
    }
    $localDocument = Read-WorkflowExtensions -Path $localManifest
    $provider = @($localDocument.extensions | Where-Object { $_.name -eq $ExtensionName })
    $assemblyIdentity = [System.Reflection.AssemblyName]::GetAssemblyName($localAssembly).FullName
    if ($provider.Count -ne 1 -or -not $provider[0].typeName.EndsWith(", $assemblyIdentity", [StringComparison]::Ordinal)) {
        throw "Local manifest must register '$ExtensionName' exactly once with the installed DLL's full assembly identity."
    }

    $bundleId = 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
    $zipName = "$bundleId.${Version}_win-any.zip"
    $url = "https://functionscdn.azureedge.net/public/ExtensionBundles/$bundleId/$Version/$zipName"
    $destinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputPath)) "ExtensionBundles\$bundleId\$Version"
    $destinationZip = Join-Path $destinationDirectory $zipName
    if ((Test-Path -LiteralPath $destinationZip) -and -not $Force) {
        throw "Output already exists: '$destinationZip'. Use -Force to replace it."
    }
    $report['version'] = $Version
    $report['sourceBundlePath'] = $BundlePath
    $report['downloadUrl'] = $url
    $report['outputZip'] = $destinationZip
    $report.steps += 'Validated matching local version, unique provider registration, and DLL assembly identity.'

    $workingPath = Join-Path ([System.IO.Path]::GetTempPath()) "workflow-bundle-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workingPath | Out-Null
    $downloadPath = Join-Path $workingPath 'download.zip'
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing
    $report.steps += 'Downloaded the Windows workflow bundle from the official CDN.'
    $expandedPath = Join-Path $workingPath 'expanded'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($downloadPath, $expandedPath)
    $expandedBin = Join-Path $expandedPath 'bin'
    $downloadedManifest = Join-Path $expandedBin 'extensions.json'
    $downloadedDocument = Read-WorkflowExtensions -Path $downloadedManifest
    foreach ($entry in $downloadedDocument.extensions) {
        $localEntry = @($localDocument.extensions | Where-Object { $_.name -eq $entry.name })
        if ($localEntry.Count -ne 1 -or $localEntry[0].typeName -cne $entry.typeName -or
            (ConvertTo-Json -InputObject $localEntry[0] -Depth 100 -Compress) -cne
            (ConvertTo-Json -InputObject $entry -Depth 100 -Compress)) {
            throw "Local manifest differs from CDN registration '$($entry.name)'. Reinstall a clean matching bundle before packaging."
        }
    }
    $extraEntries = @($localDocument.extensions | Where-Object {
        $name = $_.name
        $name -ne $ExtensionName -and @($downloadedDocument.extensions | Where-Object { $_.name -eq $name }).Count -eq 0
    })
    if ($extraEntries.Count -gt 0) {
        throw "Local manifest contains additional custom extensions whose DLLs would not be packaged: $($extraEntries.name -join ', ')."
    }
    Copy-Item -LiteralPath $localManifest -Destination $downloadedManifest -Force
    Copy-Item -LiteralPath $localAssembly -Destination (Join-Path $expandedBin $AssemblyFileName) -Force
    $report.steps += "Preserved CDN registrations and files; injected local bin\extensions.json and bin\$AssemblyFileName."

    $stagedZip = Join-Path $workingPath $zipName
    New-WorkflowBundleArchive -SourcePath $expandedPath -DestinationPath $stagedZip
    $archive = [System.IO.Compression.ZipFile]::OpenRead($stagedZip)
    try {
        foreach ($relativePath in @('bin/extensions.json', "bin/$AssemblyFileName")) {
            $entry = $archive.GetEntry($relativePath)
            if ($null -eq $entry) {
                throw "Packaged ZIP is missing '$relativePath'."
            }
            $verifyPath = Join-Path $workingPath ([System.IO.Path]::GetFileName($relativePath))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $verifyPath)
            $sourcePath = Join-Path $localBin ([System.IO.Path]::GetFileName($relativePath))
            if ((Get-WorkflowFileHash -Path $verifyPath) -ne
                (Get-WorkflowFileHash -Path $sourcePath)) {
                throw "Packaged '$relativePath' does not match the local input."
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    Copy-Item -LiteralPath $stagedZip -Destination $destinationZip -Force
    $report['assemblySha256'] = Get-WorkflowFileHash -Path $localAssembly
    $report['manifestSha256'] = Get-WorkflowFileHash -Path $localManifest
    $report['zipSha256'] = Get-WorkflowFileHash -Path $destinationZip
    $report['zipSizeBytes'] = (Get-Item -LiteralPath $destinationZip).Length
    $report.steps += 'Verified injected files inside the ZIP by SHA256 and wrote the requested site directory layout.'
    $report['status'] = 'Succeeded'
    Write-Host "Bundle ready for hosting: $destinationZip"
}
catch {
    $report['error'] = $_.Exception.Message
    throw
}
finally {
    if ($workingPath -and (Test-Path -LiteralPath $workingPath -PathType Container)) {
        Remove-Item -LiteralPath $workingPath -Recurse -Force
    }
    Write-WorkflowBundleReport -Report $report -Path $ReportPath
}
