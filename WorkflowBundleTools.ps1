Set-StrictMode -Version Latest

function Resolve-WorkflowBundlePath {
    param(
        [string] $BundlePath,
        [string] $Version,
        [string] $BundleRootPath = (Join-Path $env:USERPROFILE '.azure-functions-core-tools\Functions\ExtensionBundles\Microsoft.Azure.Functions.ExtensionBundle.Workflows')
    )

    if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid bundle version '$Version'. Use a three-part version such as 1.170.91."
    }

    if (-not $BundlePath) {
        if ($Version) {
            $BundlePath = Join-Path $BundleRootPath $Version
        }
        else {
            if (-not (Test-Path -LiteralPath $BundleRootPath -PathType Container)) {
                throw "Bundle cache does not exist: '$BundleRootPath'. Start the Logic Apps host to download a bundle."
            }
            $versions = @(Get-ChildItem -LiteralPath $BundleRootPath -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
                Sort-Object { [version] $_.Name } -Descending)
            if ($versions.Count -eq 0) {
                throw "No installed workflow bundle versions were found in '$BundleRootPath'."
            }
            $BundlePath = $versions[0].FullName
        }
    }

    if (-not (Test-Path -LiteralPath $BundlePath -PathType Container)) {
        throw "Workflow bundle version directory does not exist: '$BundlePath'. Start the Logic Apps host to download that version."
    }
    $resolved = (Get-Item -LiteralPath $BundlePath).FullName
    $installedVersion = Split-Path $resolved -Leaf
    if ($installedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "BundlePath must point to a version directory (for example ...\1.170.91), not its bin directory: '$resolved'."
    }
    if ($Version -and $installedVersion -cne $Version) {
        throw "Local bundle version '$installedVersion' does not match requested version '$Version'. Build and install against the requested version first."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'bin') -PathType Container)) {
        throw "Workflow bundle bin directory does not exist in '$resolved'."
    }
    return $resolved
}

function Read-WorkflowExtensions {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Workflow bundle extensions.json was not found: '$Path'."
    }
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $document -or -not ($document.PSObject.Properties.Name -contains 'extensions') -or
        $document.extensions -isnot [System.Array]) {
        throw "Expected an 'extensions' JSON array in '$Path'."
    }
    $names = @{}
    foreach ($extension in $document.extensions) {
        if ($null -eq $extension -or -not ($extension.PSObject.Properties.Name -contains 'name') -or
            -not ($extension.PSObject.Properties.Name -contains 'typeName') -or
            $extension.name -isnot [string] -or [string]::IsNullOrWhiteSpace($extension.name) -or
            $extension.typeName -isnot [string] -or [string]::IsNullOrWhiteSpace($extension.typeName)) {
            throw "An extension registration is missing a valid name or typeName in '$Path'."
        }
        if ($names.ContainsKey($extension.name)) {
            throw "Duplicate extension registration '$($extension.name)' in '$Path'. Remove duplicates before continuing."
        }
        $names[$extension.name] = $true
    }
    return $document
}

function Get-WorkflowFileHash {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function New-WorkflowBundleArchive {
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $root = (Get-Item -LiteralPath $SourcePath).FullName.TrimEnd('\') + '\'
    $archive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
            # .NET Framework's CreateFromDirectory can write backslashes; ZIP entry names require slashes.
            $entryName = $file.FullName.Substring($root.Length).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
        foreach ($directory in Get-ChildItem -LiteralPath $root -Recurse -Directory -Force) {
            if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
                $entryName = $directory.FullName.Substring($root.Length).Replace('\', '/') + '/'
                $archive.CreateEntry($entryName) | Out-Null
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Write-WorkflowBundleReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)][string] $Path
    )

    $Report['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($fullPath)) | Out-Null
    $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fullPath -Encoding UTF8
    Write-Host "Report: $fullPath"
}
