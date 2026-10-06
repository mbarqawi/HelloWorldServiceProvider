[CmdletBinding()]
param(
    [string] $AssemblyPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $AssemblyPath) {
    $AssemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net8.0\HelloWorldServiceProvider.dll'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectPath = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectPath 'WorkflowBundleTools.ps1')
$installer = Join-Path $projectPath 'Install-WorkflowBundleExtension.ps1'
$publisher = Join-Path $projectPath 'Publish-WorkflowBundle.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "workflow-bundle-tests-$([Guid]::NewGuid().ToString('N'))"
$script:passed = 0
$testState = [pscustomobject]@{
    DownloadFailure = $false
    LastDownloadUri = ''
    PromptCount = 0
    FixtureZip = ''
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern, [string] $Message)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_.Exception.Message }
    Assert-True -Condition ($null -ne $caught -and $caught -like $Pattern) -Message "$Message (error: $caught)"
}

${function:Invoke-WebRequest} = {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
    $testState.LastDownloadUri = $Uri
    if ($testState.DownloadFailure) { throw 'Simulated CDN HTTP 404: version not found.' }
    Copy-Item -LiteralPath $testState.FixtureZip -Destination $OutFile
}.GetNewClosure()

${function:Read-Host} = {
    param([string] $Prompt)
    $testState.PromptCount++
    return '1.170.91'
}.GetNewClosure()

try {
    if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
        throw 'Build the provider with -p:InstallWorkflowBundleExtension=false before running these tests.'
    }
    $AssemblyPath = (Get-Item -LiteralPath $AssemblyPath).FullName
    $cache = Join-Path $root 'cache'
    $bundle = Join-Path $cache '1.170.91'
    $bin = Join-Path $bundle 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $manifestPath = Join-Path $bin 'extensions.json'
    $baseline = '{"extensions":[{"name":"BuiltIn","typeName":"BuiltIn.Startup, BuiltIn, Version=1.170.91.0","bindings":null}],"metadata":"preserve me"}'
    Set-Content -LiteralPath $manifestPath -Value $baseline -Encoding UTF8
    $localReport = Join-Path $root 'local-report.json'
    $publishReport = Join-Path $root 'publish-report.json'
    $installArgs = @{
        BundlePath = $bundle
        Version = '1.170.91'
        AssemblyPath = $AssemblyPath
        StartupType = 'HelloWorldServiceProvider.HelloWorldStartup'
        ExtensionName = 'HelloWorldServiceProvider'
        ReportPath = $localReport
    }

    & $installer @installArgs
    $document = Read-WorkflowExtensions -Path $manifestPath
    $report = Get-Content -LiteralPath $localReport -Raw | ConvertFrom-Json
    Assert-True ($report.status -eq 'Succeeded' -and $report.registration -eq 'Added') 'First install adds a registration and produces a success report'
    Assert-True ($document.extensions.Count -eq 2 -and $document.metadata -eq 'preserve me') 'Install preserves built-in entries and top-level metadata'
    Assert-True (Test-Path -LiteralPath $report.manifestBackup) 'Changed manifest has a backup'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $bin 'HelloWorldServiceProvider.dll')).Hash -eq
        (Get-FileHash -LiteralPath $AssemblyPath).Hash) 'Installed DLL hash matches build output'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
    & $installer @installArgs
    $report = Get-Content -LiteralPath $localReport -Raw | ConvertFrom-Json
    Assert-True ($report.registration -eq 'Unchanged' -and -not $report.dllCopied) 'Second installation is idempotent'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath).Hash -eq $manifestHash) 'Unchanged registration does not rewrite the manifest'

    $document.extensions[1].typeName = 'Old.Startup, OldAssembly'
    $document.extensions[1].PSObject.Properties.Remove('bindings')
    $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    & $installer @installArgs
    $report = Get-Content -LiteralPath $localReport -Raw | ConvertFrom-Json
    Assert-True ($report.registration -eq 'Updated') 'Stale registration without bindings is updated rather than duplicated'
    $goodManifest = Get-Content -LiteralPath $manifestPath -Raw
    $document = Read-WorkflowExtensions -Path $manifestPath
    $document.extensions = @($document.extensions) + $document.extensions[1]
    $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $duplicateHash = (Get-FileHash -LiteralPath $manifestPath).Hash
    Assert-Throws { & $installer @installArgs } '*Duplicate extension registration*' 'Duplicate registrations are rejected'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath).Hash -eq $duplicateHash) 'Rejected duplicates leave the manifest untouched'
    $report = Get-Content -LiteralPath $localReport -Raw | ConvertFrom-Json
    Assert-True ($report.status -eq 'Failed' -and $report.error -like '*Duplicate*') 'Installation failure is recorded with its error'
    Set-Content -LiteralPath $manifestPath -Value '{"extensions":{}}' -Encoding UTF8
    Assert-Throws { & $installer @installArgs } "*'extensions' JSON array*" 'Malformed manifest schema is rejected'
    Set-Content -LiteralPath $manifestPath -Value $goodManifest -Encoding UTF8
    $badArgs = $installArgs.Clone()
    $badArgs.Version = '1.170.43'
    Assert-Throws { & $installer @badArgs } '*does not match requested version*' 'Explicit bundle version mismatch is rejected'
    $badArgs = $installArgs.Clone()
    $badArgs.BundlePath = Join-Path $cache '1.999.0'
    Assert-Throws { & $installer @badArgs } '*does not exist*' 'Missing installed version is rejected'
    $badArgs = $installArgs.Clone()
    $badArgs.AssemblyPath = Join-Path $root 'missing.dll'
    Assert-Throws { & $installer @badArgs } '*assembly was not found*' 'Missing build DLL is rejected'
    $badArgs.AssemblyPath = Join-Path $root 'invalid.dll'
    Set-Content -LiteralPath $badArgs.AssemblyPath -Value 'not a managed assembly'
    Assert-Throws { & $installer @badArgs } '*GetAssemblyName*' 'Invalid managed DLL is rejected'

    $legacyArgs = $installArgs.Clone()
    $legacyArgs.Remove('BundlePath')
    $legacyArgs.BundleBinPath = $bin
    & $installer @legacyArgs
    Assert-True ((Read-WorkflowExtensions -Path $manifestPath).extensions.Count -eq 2) 'Legacy BundleBinPath remains supported'
    $numericCache = Join-Path $root 'numeric-cache'
    New-Item -ItemType Directory -Path (Join-Path $numericCache '1.9.0\bin'), (Join-Path $numericCache '1.10.0\bin') -Force | Out-Null
    Assert-True ((Split-Path (Resolve-WorkflowBundlePath -BundleRootPath $numericCache) -Leaf) -eq '1.10.0') 'Newest installed version uses numeric ordering'
    Assert-True ((Split-Path (Resolve-WorkflowBundlePath -BundleRootPath $numericCache -Version '1.9.0') -Leaf) -eq '1.9.0') 'Explicit version selection overrides newest'
    Assert-Throws { Resolve-WorkflowBundlePath -BundlePath $bin } '*not its bin directory*' 'BundlePath must point to the version root'
    Assert-Throws { Resolve-WorkflowBundlePath -Version '..\escape' -BundleRootPath $cache } '*Invalid bundle version*' 'Invalid version cannot escape the bundle root'
    New-Item -ItemType Directory -Path (Join-Path $numericCache '1.11.0') | Out-Null
    Assert-Throws { Resolve-WorkflowBundlePath -BundleRootPath $numericCache } '*bin directory does not exist*' 'Incomplete newest installation fails explicitly'

    $cdnRoot = Join-Path $root 'cdn-fixture'
    New-Item -ItemType Directory -Path (Join-Path $cdnRoot 'bin'), (Join-Path $cdnRoot 'content'), (Join-Path $cdnRoot 'empty') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cdnRoot 'bin\extensions.json') -Value $baseline -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $cdnRoot 'content\original.txt') -Value 'CDN payload'
    Set-Content -LiteralPath (Join-Path $cdnRoot '.hidden') -Value 'Preserve hidden files'
    (Get-Item -LiteralPath (Join-Path $cdnRoot '.hidden') -Force).Attributes = [System.IO.FileAttributes]::Hidden
    $testState.FixtureZip = Join-Path $root 'cdn.zip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($cdnRoot, $testState.FixtureZip)
    $output = Join-Path $root 'site'
    $publishArgs = @{
        Version = '1.170.91'
        BundlePath = $bundle
        OutputPath = $output
        ReportPath = $publishReport
    }
    & $publisher @publishArgs
    $report = Get-Content -LiteralPath $publishReport -Raw | ConvertFrom-Json
    $expectedZip = Join-Path $output 'ExtensionBundles\Microsoft.Azure.Functions.ExtensionBundle.Workflows\1.170.91\Microsoft.Azure.Functions.ExtensionBundle.Workflows.1.170.91_win-any.zip'
    Assert-True ($report.status -eq 'Succeeded' -and $report.outputZip -eq $expectedZip -and
        (Test-Path -LiteralPath $expectedZip)) 'Publisher creates the exact requested CDN directory and ZIP filename'
    Assert-True ($testState.LastDownloadUri -eq 'https://functionscdn.azureedge.net/public/ExtensionBundles/Microsoft.Azure.Functions.ExtensionBundle.Workflows/1.170.91/Microsoft.Azure.Functions.ExtensionBundle.Workflows.1.170.91_win-any.zip') 'CDN URL substitutes the supplied version in both positions'
    $verification = Join-Path $root 'verification'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($expectedZip, $verification)
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $verification 'bin\extensions.json')).Hash -eq
        (Get-FileHash -LiteralPath $manifestPath).Hash) 'ZIP contains the exact locally generated manifest'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $verification 'bin\HelloWorldServiceProvider.dll')).Hash -eq
        (Get-FileHash -LiteralPath $AssemblyPath).Hash) 'ZIP contains the exact provider DLL'
    Assert-True ((Test-Path -LiteralPath (Join-Path $verification 'content\original.txt')) -and
        (Test-Path -LiteralPath (Join-Path $verification '.hidden'))) 'ZIP retains unrelated CDN content including hidden files'
    Assert-True (Test-Path -LiteralPath (Join-Path $verification 'empty') -PathType Container) 'ZIP retains empty directories'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($expectedZip)
    try {
        Assert-True (@($archive.Entries | Where-Object { $_.FullName.Contains('\') }).Count -eq 0) 'ZIP entry paths use portable forward slashes on both PowerShell versions'
    }
    finally {
        $archive.Dispose()
    }
    Assert-True ($report.zipSha256 -eq (Get-FileHash -LiteralPath $expectedZip).Hash) 'Publish report records the final ZIP SHA256'
    $zipHash = (Get-FileHash -LiteralPath $expectedZip).Hash
    Assert-Throws { & $publisher @publishArgs } '*Output already exists*' 'Existing ZIP requires explicit Force'
    $publishArgs.Force = $true
    $publishArgs.Remove('Version')
    & $publisher @publishArgs
    Assert-True ($testState.PromptCount -eq 1) 'Omitted version prompts interactively'
    $publishArgs.Version = '1.170.43'
    Assert-Throws { & $publisher @publishArgs } '*does not match requested version*' 'Publisher rejects a local/downloaded version mismatch before download'
    $publishArgs.Version = '1.170.91'
    $testState.DownloadFailure = $true
    Assert-Throws { & $publisher @publishArgs } '*CDN HTTP 404*' 'Unavailable CDN version surfaces download failure'
    $testState.DownloadFailure = $false
    $report = Get-Content -LiteralPath $publishReport -Raw | ConvertFrom-Json
    Assert-True ($report.status -eq 'Failed' -and $report.error -like '*HTTP 404*') 'Publish failure is recorded in the report'
    $zipHash = (Get-FileHash -LiteralPath $expectedZip).Hash
    $document = Read-WorkflowExtensions -Path $manifestPath
    $document.extensions[0].typeName = 'Wrong.Version'
    $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Assert-Throws { & $publisher @publishArgs } '*differs from CDN registration*' 'Publisher rejects a mismatched built-in registration'
    Assert-True ((Get-FileHash -LiteralPath $expectedZip).Hash -eq $zipHash) 'Failed packaging preserves an existing output ZIP'
    Set-Content -LiteralPath $manifestPath -Value $goodManifest -Encoding UTF8
    $document = Read-WorkflowExtensions -Path $manifestPath
    $document.extensions += [pscustomobject]@{ name = 'OtherCustom'; typeName = 'Other.Startup, Other' }
    $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Assert-Throws { & $publisher @publishArgs } '*additional custom extensions*' 'Publisher does not package a manifest referencing uncopied custom DLLs'
    Set-Content -LiteralPath $manifestPath -Value $baseline -Encoding UTF8
    Assert-Throws { & $publisher @publishArgs } '*must register*exactly once*' 'Publisher requires prior local provider registration'
    Write-Host "All $script:passed assertions passed. No live CDN request or installed cache mutation was performed."
}
finally {
    if (Test-Path -LiteralPath $root -PathType Container) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
