[CmdletBinding()]
param(
    [string] $BundlePath,
    [string] $Version,
    [string] $BundleRootPath = (Join-Path $env:USERPROFILE '.azure-functions-core-tools\Functions\ExtensionBundles\Microsoft.Azure.Functions.ExtensionBundle.Workflows')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkflowBundleTools.ps1')
Resolve-WorkflowBundlePath -BundlePath $BundlePath -Version $Version -BundleRootPath $BundleRootPath
