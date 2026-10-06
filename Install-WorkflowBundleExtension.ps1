[CmdletBinding(DefaultParameterSetName = 'Bundle')]
param(
    [Parameter(ParameterSetName = 'Bundle')]
    [string] $BundlePath,

    [Parameter(Mandatory, ParameterSetName = 'LegacyBin')]
    [string] $BundleBinPath,

    [string] $Version,
    [string] $BundleRootPath = (Join-Path $env:USERPROFILE '.azure-functions-core-tools\Functions\ExtensionBundles\Microsoft.Azure.Functions.ExtensionBundle.Workflows'),

    [Parameter(Mandatory)][string] $AssemblyPath,
    [Parameter(Mandatory)][string] $StartupType,
    [Parameter(Mandatory)][string] $ExtensionName,
    [string] $ReportPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkflowBundleTools.ps1')
if (-not $ReportPath) {
    $ReportPath = Join-Path $PSScriptRoot 'reports\local-install-report.json'
}
$report = [ordered]@{
    operation = 'Local workflow bundle installation'
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    status = 'Failed'
    extensionName = $ExtensionName
    steps = @()
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'LegacyBin') {
        if ((Split-Path $BundleBinPath.TrimEnd('\') -Leaf) -ne 'bin') {
            throw 'BundleBinPath must end in bin. Prefer BundlePath pointing to the version directory.'
        }
        $BundlePath = Split-Path $BundleBinPath.TrimEnd('\') -Parent
    }
    $BundlePath = Resolve-WorkflowBundlePath -BundlePath $BundlePath -Version $Version -BundleRootPath $BundleRootPath
    $binPath = Join-Path $BundlePath 'bin'
    $extensionsPath = Join-Path $binPath 'extensions.json'
    $report['bundlePath'] = $BundlePath
    $report['version'] = Split-Path $BundlePath -Leaf
    if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
        throw "Build output assembly was not found: '$AssemblyPath'."
    }
    if ([string]::IsNullOrWhiteSpace($StartupType) -or [string]::IsNullOrWhiteSpace($ExtensionName)) {
        throw 'StartupType and ExtensionName cannot be blank.'
    }
    $AssemblyPath = (Get-Item -LiteralPath $AssemblyPath).FullName
    $assemblyFullName = [System.Reflection.AssemblyName]::GetAssemblyName($AssemblyPath).FullName
    $qualifiedStartupType = "$StartupType, $assemblyFullName"
    $document = Read-WorkflowExtensions -Path $extensionsPath
    $matching = @($document.extensions | Where-Object { $_.name -eq $ExtensionName })
    $otherNames = @($document.extensions | Where-Object { $_.name -ne $ExtensionName -and $_.typeName -eq $qualifiedStartupType })
    if ($otherNames.Count -gt 0) {
        throw "Startup type is already registered under another extension name: '$($otherNames[0].name)'."
    }
    $report.steps += 'Validated installed version, manifest schema, unique registrations, and managed assembly identity.'
    $registration = 'Unchanged'
    if ($matching.Count -eq 0) {
        $document.extensions = @($document.extensions) + [pscustomobject]@{
            name = $ExtensionName
            typeName = $qualifiedStartupType
            bindings = $null
        }
        $registration = 'Added'
    }
    elseif ($matching[0].typeName -cne $qualifiedStartupType -or
        -not ($matching[0].PSObject.Properties.Name -contains 'bindings') -or $null -ne $matching[0].bindings) {
        $matching[0].typeName = $qualifiedStartupType
        $matching[0] | Add-Member -NotePropertyName bindings -NotePropertyValue $null -Force
        $registration = 'Updated'
    }

    $destination = Join-Path $binPath ([System.IO.Path]::GetFileName($AssemblyPath))
    $sourceHash = Get-WorkflowFileHash -Path $AssemblyPath
    $copyNeeded = -not (Test-Path -LiteralPath $destination -PathType Leaf)
    if (-not $copyNeeded) {
        $copyNeeded = (Get-WorkflowFileHash -Path $destination) -ne $sourceHash
    }
    if ($registration -ne 'Unchanged') {
        $backupPath = "$extensionsPath.$([Guid]::NewGuid().ToString('N')).bak"
        Copy-Item -LiteralPath $extensionsPath -Destination $backupPath
        $report['manifestBackup'] = $backupPath
    }
    if ($copyNeeded) {
        Copy-Item -LiteralPath $AssemblyPath -Destination $destination -Force
    }
    if ($registration -ne 'Unchanged') {
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $extensionsPath -Encoding UTF8
    }
    $installed = Read-WorkflowExtensions -Path $extensionsPath
    $verified = @($installed.extensions | Where-Object { $_.name -eq $ExtensionName -and $_.typeName -ceq $qualifiedStartupType })
    if ($verified.Count -ne 1 -or (Get-WorkflowFileHash -Path $destination) -ne $sourceHash) {
        throw 'Post-install verification failed: registration or DLL differs from the requested input.'
    }
    $report['registration'] = $registration
    $report['dllCopied'] = $copyNeeded
    $report['assemblyPath'] = $destination
    $report['assemblySha256'] = $sourceHash
    $report['typeName'] = $qualifiedStartupType
    $report.steps += "$registration registration; DLL copied: $copyNeeded. Verified registration and DLL SHA256."
    $report['status'] = 'Succeeded'
    Write-Host "Installed '$ExtensionName' into '$BundlePath'. Registration: $registration; DLL copied: $copyNeeded."
}
catch {
    $report['error'] = $_.Exception.Message
    throw
}
finally {
    Write-WorkflowBundleReport -Report $report -Path $ReportPath
}
