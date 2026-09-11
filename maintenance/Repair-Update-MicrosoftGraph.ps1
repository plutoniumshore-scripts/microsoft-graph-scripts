<#
.SYNOPSIS
    Installs, updates, validates, cleans, and repairs the Microsoft Graph PowerShell SDK.

.DESCRIPTION
    Consolidates the behavior of older Graph bootstrap/update and repair scripts into one tool.

    Default behavior:
      - Prefers PowerShell 7, but supports Windows PowerShell 5.1.
      - Bootstraps Microsoft.PowerShell.PSResourceGet when possible.
      - Ensures PSGallery is available.
      - Installs or updates the Microsoft.Graph SDK to the latest stable release.
      - Removes loaded Graph modules before maintenance to avoid DLL/version conflicts.
      - Optionally removes stale side-by-side Graph module versions after validation.
      - Validates key Graph submodules individually instead of importing the entire SDK at once.
      - Automatically performs a clean repair if the normal update/install path fails validation.
      - Reports deprecated/legacy modules without removing them unless explicitly requested.
      - Displays top-level and nested Write-Progress status throughout the maintenance run.

    No tenant connection is made. The script validates Connect-MgGraph and module loading only.

.PARAMETER Scope
    Installation scope. CurrentUser is the default. AllUsers requires elevation.

.PARAMETER InstallBeta
    Also install/update Microsoft.Graph.Beta. Beta is not recommended for production scripts.

.PARAMETER PurgeOldVersions
    Remove older Microsoft.Graph* versions after a healthy current version is installed.
    Defaults to $true. Use -PurgeOldVersions:$false to retain side-by-side versions.

.PARAMETER AutoRepair
    If validation fails after normal installation/update, perform a clean Graph repair.
    Defaults to $true. Use -AutoRepair:$false to disable automatic repair.

.PARAMETER RemoveLegacyModules
    Also remove legacy AzureAD, AzureADPreview, MSOnline, and Microsoft.Graph.Intune modules.
    This is OFF by default because existing scripts may still depend on them.

.EXAMPLE
    .\Repair-Update-MicrosoftGraph.ps1

.EXAMPLE
    .\Repair-Update-MicrosoftGraph.ps1 -Scope AllUsers

.EXAMPLE
    .\Repair-Update-MicrosoftGraph.ps1 -InstallBeta -PurgeOldVersions:$false

.EXAMPLE
    .\Repair-Update-MicrosoftGraph.ps1 -RemoveLegacyModules
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [switch]$InstallBeta,

    [bool]$PurgeOldVersions = $true,

    [bool]$AutoRepair = $true,

    [switch]$RemoveLegacyModules
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:PackageManager = $null
$script:RepairPerformed = $false
$script:BetaWasInstalled = $false
$script:MainProgressId = 1
$script:ValidationProgressId = 2
$script:LogPath = Join-Path $env:TEMP ("MicrosoftGraph-Maintenance-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

$script:ValidationModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Teams',
    'Microsoft.Graph.DeviceManagement.Administration'
)

$script:LegacyModules = @(
    'AzureAD',
    'AzureADPreview',
    'MSOnline',
    'Microsoft.Graph.Intune'
)

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8

    switch ($Level) {
        'Success' { Write-Host $Message -ForegroundColor Green }
        'Warning' { Write-Host $Message -ForegroundColor Yellow }
        'Error'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Host $Message -ForegroundColor Cyan }
    }
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor White
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Add-Content -LiteralPath $script:LogPath -Value "`n=== $Title ===" -Encoding UTF8
}

function Set-MainProgress {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][ValidateRange(0,100)][int]$PercentComplete
    )

    Write-Progress `
        -Id $script:MainProgressId `
        -Activity 'Microsoft Graph PowerShell maintenance' `
        -Status $Status `
        -PercentComplete $PercentComplete
}

function Complete-ProgressDisplay {
    Write-Progress -Id $script:ValidationProgressId -Activity 'Microsoft Graph health validation' -Completed -ErrorAction SilentlyContinue
    Write-Progress -Id $script:MainProgressId -Activity 'Microsoft Graph PowerShell maintenance' -Completed -ErrorAction SilentlyContinue
}

function Test-IsAdministrator {
    $isWindowsPlatform = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $env:OS -eq 'Windows_NT' }

    if (-not $isWindowsPlatform) {
        try { return ((id -u) -eq 0) } catch { return $false }
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Assert-Prerequisites {
    Write-Section 'Environment'

    Write-Status "PowerShell version: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Status "Requested install scope: $Scope"
    Write-Status "Log file: $script:LogPath"

    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw 'Microsoft Graph PowerShell requires PowerShell 5.1 or later.'
    }

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Status 'PowerShell 7 or later is recommended by Microsoft for the Graph PowerShell SDK.' 'Warning'

        # PowerShell Gallery requires TLS 1.2 on older Windows PowerShell environments.
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Status 'TLS 1.2 enabled for this Windows PowerShell session.'
        }
        catch {
            Write-Status "Could not explicitly enable TLS 1.2: $($_.Exception.Message)" 'Warning'
        }
    }

    if ($Scope -eq 'AllUsers' -and -not (Test-IsAdministrator)) {
        throw 'Scope AllUsers requires an elevated PowerShell session.'
    }
}

function Initialize-PSResourceGet {
    Write-Section 'PowerShell package manager'

    $psr = Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $psr) {
        Write-Status 'Microsoft.PowerShell.PSResourceGet is not installed. Bootstrapping it with PowerShellGet...' 'Warning'

        $installModule = Get-Command Install-Module -ErrorAction SilentlyContinue
        if ($installModule) {
            try {
                if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
                    Register-PSRepository -Default
                }

                # Older Windows PowerShell/PowerShellGet installations may prompt interactively
                # for the NuGet package provider. Install it up front so this maintenance script
                # can run unattended.
                $nugetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
                    Where-Object { $_.Version -ge [version]'2.8.5.201' } |
                    Sort-Object Version -Descending |
                    Select-Object -First 1

                if (-not $nugetProvider) {
                    Write-Status 'NuGet package provider 2.8.5.201 or later is required. Installing it now...'
                    Install-PackageProvider -Name NuGet `
                        -MinimumVersion '2.8.5.201' `
                        -Scope CurrentUser `
                        -Force | Out-Null
                }

                Install-Module -Name Microsoft.PowerShell.PSResourceGet `
                    -Repository PSGallery `
                    -Scope CurrentUser `
                    -Force `
                    -AllowClobber `
                    -Confirm:$false
            }
            catch {
                Write-Status "PSResourceGet bootstrap failed: $($_.Exception.Message)" 'Warning'
            }
        }
    }

    $psr = Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($psr) {
        Import-Module Microsoft.PowerShell.PSResourceGet -MinimumVersion $psr.Version -Force
        $script:PackageManager = 'PSResourceGet'
        Write-Status "Using Microsoft.PowerShell.PSResourceGet $($psr.Version)." 'Success'

        try {
            if (-not (Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
                Reset-PSResourceRepository
            }
        }
        catch {
            Write-Status "Could not validate/reset the PSResourceGet PSGallery registration: $($_.Exception.Message)" 'Warning'
        }

        return
    }

    if (Get-Command Install-Module -ErrorAction SilentlyContinue) {
        $script:PackageManager = 'PowerShellGet'
        Write-Status 'Falling back to PowerShellGet (Install-Module/Update-Module).' 'Warning'

        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default
        }

        return
    }

    throw 'No supported PowerShell package manager is available.'
}

function Disconnect-And-UnloadGraph {
    Write-Section 'Unload existing Graph session'

    $connectCmd = Get-Command Get-MgContext -ErrorAction SilentlyContinue
    if ($connectCmd) {
        try {
            $ctx = Get-MgContext -ErrorAction SilentlyContinue
            if ($ctx -and $ctx.Account) {
                Write-Status "Disconnecting existing Graph session for $($ctx.Account)..."
                Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            }
        }
        catch {
            Write-Status "Graph disconnect was skipped: $($_.Exception.Message)" 'Warning'
        }
    }

    $loaded = Get-Module -Name 'Microsoft.Graph*'
    if ($loaded) {
        foreach ($module in ($loaded | Sort-Object Name -Descending)) {
            try {
                Remove-Module -Name $module.Name -Force -ErrorAction Stop
                Write-Status "Unloaded $($module.Name) $($module.Version)."
            }
            catch {
                Write-Status "Could not unload $($module.Name): $($_.Exception.Message)" 'Warning'
            }
        }
    }
    else {
        Write-Status 'No Microsoft.Graph modules are currently loaded.'
    }
}

function Get-LatestGalleryVersion {
    param([Parameter(Mandatory)][string]$Name)

    if ($script:PackageManager -eq 'PSResourceGet') {
        $resource = Find-PSResource -Name $Name -Repository PSGallery |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (-not $resource) {
            throw "Could not find $Name in PSGallery."
        }

        return [version]$resource.Version
    }

    $module = Find-Module -Name $Name -Repository PSGallery
    if (-not $module) {
        throw "Could not find $Name in PSGallery."
    }

    return [version]$module.Version
}

function Get-HighestInstalledVersion {
    param([Parameter(Mandatory)][string]$Name)

    $module = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($module) { return [version]$module.Version }
    return $null
}

function Install-OrUpdateGraphPackage {
    param([Parameter(Mandatory)][string]$Name)

    $latest = Get-LatestGalleryVersion -Name $Name
    $installed = Get-HighestInstalledVersion -Name $Name

    Write-Status "$Name latest PSGallery version: $latest"

    if (-not $installed) {
        Write-Status "$Name is not installed. Installing..."

        if ($PSCmdlet.ShouldProcess($Name, "Install $latest in scope $Scope")) {
            if ($script:PackageManager -eq 'PSResourceGet') {
                Install-PSResource -Name $Name `
                    -Repository PSGallery `
                    -Scope $Scope `
                    -TrustRepository `
                    -AcceptLicense `
                    -Quiet
            }
            else {
                Install-Module -Name $Name `
                    -Repository PSGallery `
                    -Scope $Scope `
                    -Force `
                    -AllowClobber `
                    -AcceptLicense `
                    -Confirm:$false
            }
        }
    }
    elseif ($installed -lt $latest) {
        Write-Status "$Name installed version $installed is older than $latest. Updating..."

        if ($PSCmdlet.ShouldProcess($Name, "Update $installed to $latest in scope $Scope")) {
            if ($script:PackageManager -eq 'PSResourceGet') {
                Update-PSResource -Name $Name `
                    -Repository PSGallery `
                    -Scope $Scope `
                    -TrustRepository `
                    -AcceptLicense `
                    -Force `
                    -Quiet
            }
            else {
                Update-Module -Name $Name `
                    -Scope $Scope `
                    -Force `
                    -AcceptLicense `
                    -Confirm:$false
            }
        }
    }
    else {
        Write-Status "$Name $installed is already current." 'Success'
    }

    $after = Get-HighestInstalledVersion -Name $Name
    if (-not $after) {
        throw "$Name was not detected after installation/update."
    }

    if ($after -lt $latest) {
        throw "$Name remains at $after; expected at least $latest."
    }

    Write-Status "$Name installed version: $after" 'Success'
}

function Get-ScopeModuleRoots {
    $isWindowsPlatform = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $env:OS -eq 'Windows_NT' }

    if ($isWindowsPlatform) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if (-not $documents) {
            $documents = Join-Path $HOME 'Documents'
        }

        if ($PSVersionTable.PSVersion.Major -ge 6) {
            if ($Scope -eq 'CurrentUser') {
                return ,(Join-Path $documents 'PowerShell\Modules')
            }
            return ,(Join-Path $env:ProgramFiles 'PowerShell\Modules')
        }

        if ($Scope -eq 'CurrentUser') {
            return ,(Join-Path $documents 'WindowsPowerShell\Modules')
        }
        return ,(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
    }

    if ($Scope -eq 'CurrentUser') {
        return ,(Join-Path $HOME '.local/share/powershell/Modules')
    }

    return ,'/usr/local/share/powershell/Modules'
}

function Test-PathWithinRoots {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Roots
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($root in $Roots) {
        $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Remove-GraphPackageCleanly {
    param([Parameter(Mandatory)][string]$Pattern)

    Write-Status "Removing installed resources matching $Pattern in scope $Scope..." 'Warning'

    if ($script:PackageManager -eq 'PSResourceGet') {
        $resources = Get-InstalledPSResource -Scope $Scope -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $Pattern -and ($RemoveLegacyModules -or $_.Name -ne 'Microsoft.Graph.Intune') } |
            Sort-Object Name, Version -Descending

        foreach ($resource in $resources) {
            if ($PSCmdlet.ShouldProcess("$($resource.Name) $($resource.Version)", 'Uninstall')) {
                try {
                    Uninstall-PSResource -Name $resource.Name `
                        -Version ([string]$resource.Version) `
                        -Scope $Scope `
                        -SkipDependencyCheck `
                        -Confirm:$false
                    Write-Status "Uninstalled $($resource.Name) $($resource.Version)."
                }
                catch {
                    Write-Status "Package uninstall failed for $($resource.Name) $($resource.Version): $($_.Exception.Message)" 'Warning'
                }
            }
        }
    }
    else {
        $resources = Get-InstalledModule -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $Pattern -and ($RemoveLegacyModules -or $_.Name -ne 'Microsoft.Graph.Intune') } |
            Sort-Object Name, Version -Descending

        foreach ($resource in $resources) {
            if ($PSCmdlet.ShouldProcess("$($resource.Name) $($resource.Version)", 'Uninstall')) {
                try {
                    Uninstall-Module -Name $resource.Name `
                        -RequiredVersion $resource.Version `
                        -Force `
                        -Confirm:$false
                    Write-Status "Uninstalled $($resource.Name) $($resource.Version)."
                }
                catch {
                    Write-Status "Package uninstall failed for $($resource.Name) $($resource.Version): $($_.Exception.Message)" 'Warning'
                }
            }
        }
    }
}

function Remove-RemainingGraphFolders {
    param([switch]$KeepHighestVersion)

    $roots = @(Get-ScopeModuleRoots)
    if (-not $roots) {
        Write-Status "No module roots were identified for scope $Scope; folder cleanup skipped." 'Warning'
        return
    }

    $modules = Get-Module -ListAvailable -Name 'Microsoft.Graph*' |
        Where-Object { ($RemoveLegacyModules -or $_.Name -ne 'Microsoft.Graph.Intune') -and (Test-PathWithinRoots -Path $_.ModuleBase -Roots $roots) }

    if (-not $modules) {
        return
    }

    $groups = $modules | Group-Object Name

    foreach ($group in $groups) {
        $ordered = $group.Group | Sort-Object Version -Descending
        $keep = if ($KeepHighestVersion) { $ordered | Select-Object -First 1 } else { $null }

        foreach ($module in $ordered) {
            if ($keep -and $module.ModuleBase -eq $keep.ModuleBase) {
                continue
            }

            $versionPath = $module.ModuleBase
            if (-not (Test-PathWithinRoots -Path $versionPath -Roots $roots)) {
                continue
            }

            if ($PSCmdlet.ShouldProcess($versionPath, 'Delete stale Microsoft.Graph module folder')) {
                try {
                    Remove-Item -LiteralPath $versionPath -Recurse -Force -ErrorAction Stop
                    Write-Status "Removed stale module folder: $versionPath"
                }
                catch {
                    Write-Status "Could not remove $versionPath. Another PowerShell process may have the module locked. $($_.Exception.Message)" 'Warning'
                }
            }
        }
    }
}

function Invoke-CleanGraphRepair {
    Write-Section 'Clean Graph repair'
    $script:RepairPerformed = $true

    Disconnect-And-UnloadGraph

    $script:BetaWasInstalled = [bool](Get-Module -ListAvailable -Name 'Microsoft.Graph.Beta')
    Remove-GraphPackageCleanly -Pattern 'Microsoft.Graph*'

    # Remove any leftovers that PowerShellGet/PSResourceGet cannot uninstall because metadata is damaged.
    Remove-RemainingGraphFolders

    $remaining = Get-Module -ListAvailable -Name 'Microsoft.Graph*'
    $scopeRoots = @(Get-ScopeModuleRoots)
    $remainingInScope = $remaining | Where-Object {
        $scopeRoots -and (Test-PathWithinRoots -Path $_.ModuleBase -Roots $scopeRoots)
    }

    if ($remainingInScope) {
        Write-Status 'Some Microsoft.Graph module folders remain in the target scope. They may be locked by another PowerShell process.' 'Warning'
        $remainingInScope | Sort-Object Name, Version | ForEach-Object {
            Write-Status "Remaining: $($_.Name) $($_.Version) -> $($_.ModuleBase)" 'Warning'
        }
        throw 'Graph repair cannot continue until locked Microsoft.Graph module files are released. Close other PowerShell/ISE/VS Code sessions and rerun the script.'
    }

    Install-OrUpdateGraphPackage -Name 'Microsoft.Graph'
    if ($InstallBeta -or $script:BetaWasInstalled) {
        Install-OrUpdateGraphPackage -Name 'Microsoft.Graph.Beta'
    }
}

function Test-GraphHealth {
    Write-Section 'Graph health validation'

    Disconnect-And-UnloadGraph

    $results = [System.Collections.Generic.List[object]]::new()
    $healthy = $true
    $validationCount = $script:ValidationModules.Count + 1
    $validationIndex = 0

    foreach ($name in $script:ValidationModules) {
        $validationIndex++
        $validationPercent = [math]::Min(99, [math]::Floor((($validationIndex - 1) / $validationCount) * 100))
        Write-Progress `
            -Id $script:ValidationProgressId `
            -ParentId $script:MainProgressId `
            -Activity 'Microsoft Graph health validation' `
            -Status "Testing module $validationIndex of $($script:ValidationModules.Count): $name" `
            -PercentComplete $validationPercent
        $available = Get-Module -ListAvailable -Name $name |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (-not $available) {
            $healthy = $false
            $results.Add([pscustomobject]@{
                Module  = $name
                Version = $null
                Status  = 'MISSING'
                Detail  = 'Module not found'
            })
            continue
        }

        try {
            Import-Module -Name $name -RequiredVersion $available.Version -Force -ErrorAction Stop
            $results.Add([pscustomobject]@{
                Module  = $name
                Version = $available.Version
                Status  = 'OK'
                Detail  = 'Imported successfully'
            })
        }
        catch {
            $healthy = $false
            $results.Add([pscustomobject]@{
                Module  = $name
                Version = $available.Version
                Status  = 'FAILED'
                Detail  = $_.Exception.Message
            })
        }
        finally {
            Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
        }
    }

    $validationIndex++
    Write-Progress `
        -Id $script:ValidationProgressId `
        -ParentId $script:MainProgressId `
        -Activity 'Microsoft Graph health validation' `
        -Status 'Validating core Microsoft Graph commands' `
        -PercentComplete ([math]::Floor((($validationIndex - 1) / $validationCount) * 100))

    try {
        Import-Module Microsoft.Graph.Authentication -Force -ErrorAction Stop
        foreach ($command in @('Connect-MgGraph', 'Disconnect-MgGraph', 'Get-MgContext', 'Find-MgGraphCommand', 'Find-MgGraphPermission')) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
                $healthy = $false
                $results.Add([pscustomobject]@{
                    Module  = 'Microsoft.Graph.Authentication'
                    Version = (Get-Module Microsoft.Graph.Authentication).Version
                    Status  = 'FAILED'
                    Detail  = "Expected command not found: $command"
                })
            }
        }
    }
    catch {
        $healthy = $false
        $results.Add([pscustomobject]@{
            Module  = 'Microsoft.Graph.Authentication'
            Version = $null
            Status  = 'FAILED'
            Detail  = "Authentication command validation failed: $($_.Exception.Message)"
        })
    }
    finally {
        Remove-Module Microsoft.Graph.Authentication -Force -ErrorAction SilentlyContinue
    }

    Write-Progress `
        -Id $script:ValidationProgressId `
        -ParentId $script:MainProgressId `
        -Activity 'Microsoft Graph health validation' `
        -Status 'Validation complete' `
        -PercentComplete 100
    Write-Progress -Id $script:ValidationProgressId -Activity 'Microsoft Graph health validation' -Completed

    $results | Format-Table -AutoSize
    $results | Out-String | Add-Content -LiteralPath $script:LogPath -Encoding UTF8

    if ($healthy) {
        Write-Status 'Microsoft Graph PowerShell health validation passed.' 'Success'
    }
    else {
        Write-Status 'Microsoft Graph PowerShell health validation failed.' 'Error'
    }

    return $healthy
}

function Remove-OldGraphVersions {
    Write-Section 'Stale Graph version cleanup'

    if (-not $PurgeOldVersions) {
        Write-Status 'PurgeOldVersions is disabled; side-by-side versions will be retained.'
        return
    }

    Disconnect-And-UnloadGraph
    Remove-RemainingGraphFolders -KeepHighestVersion

    $duplicates = Get-Module -ListAvailable -Name 'Microsoft.Graph*' |
        Group-Object Name |
        Where-Object { @($_.Group.Version | Select-Object -Unique).Count -gt 1 }

    if ($duplicates) {
        Write-Status 'Multiple Graph versions still exist in one or more module paths outside the selected scope or are locked.' 'Warning'
        foreach ($group in $duplicates) {
            $versions = ($group.Group.Version | Sort-Object -Descending | Select-Object -Unique) -join ', '
            Write-Status "$($group.Name): $versions" 'Warning'
        }
    }
    else {
        Write-Status 'No stale side-by-side Microsoft.Graph versions were detected.' 'Success'
    }
}

function Show-LegacyModuleStatus {
    Write-Section 'Legacy Microsoft cloud modules'

    $found = @()
    foreach ($name in $script:LegacyModules) {
        $mods = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending
        if ($mods) {
            foreach ($mod in $mods) {
                $found += [pscustomobject]@{
                    Module  = $name
                    Version = $mod.Version
                    Path    = $mod.ModuleBase
                }
            }
        }
    }

    if (-not $found) {
        Write-Status 'No AzureAD, AzureADPreview, MSOnline, or legacy Microsoft.Graph.Intune modules were detected.' 'Success'
        return
    }

    $found | Format-Table -AutoSize
    $found | Out-String | Add-Content -LiteralPath $script:LogPath -Encoding UTF8

    if (-not $RemoveLegacyModules) {
        Write-Status 'Legacy modules were detected but left installed. Use -RemoveLegacyModules only after confirming no existing scripts depend on them.' 'Warning'
        return
    }

    foreach ($name in $script:LegacyModules) {
        $mods = Get-Module -ListAvailable -Name $name
        if (-not $mods) { continue }

        Write-Status "Removing legacy module $name..." 'Warning'
        Remove-Module -Name $name -Force -ErrorAction SilentlyContinue

        if ($script:PackageManager -eq 'PSResourceGet') {
            $resources = Get-InstalledPSResource -Scope $Scope -ErrorAction SilentlyContinue |
                Where-Object Name -eq $name
            foreach ($resource in $resources) {
                if ($PSCmdlet.ShouldProcess("$name $($resource.Version)", 'Uninstall legacy module')) {
                    try {
                        Uninstall-PSResource -Name $name -Version ([string]$resource.Version) -Scope $Scope -SkipDependencyCheck -Confirm:$false
                        Write-Status "Removed $name $($resource.Version)." 'Success'
                    }
                    catch {
                        Write-Status "Could not remove $name $($resource.Version): $($_.Exception.Message)" 'Warning'
                    }
                }
            }
        }
        else {
            $resources = Get-InstalledModule -Name $name -AllVersions -ErrorAction SilentlyContinue
            foreach ($resource in $resources) {
                if ($PSCmdlet.ShouldProcess("$name $($resource.Version)", 'Uninstall legacy module')) {
                    try {
                        Uninstall-Module -Name $name -RequiredVersion $resource.Version -Force -Confirm:$false
                        Write-Status "Removed $name $($resource.Version)." 'Success'
                    }
                    catch {
                        Write-Status "Could not remove $name $($resource.Version): $($_.Exception.Message)" 'Warning'
                    }
                }
            }
        }
    }
}

function Show-FinalInventory {
    Write-Section 'Final Graph inventory'

    $graph = Get-Module -ListAvailable -Name 'Microsoft.Graph*' |
        Sort-Object Name, Version -Descending |
        Select-Object Name, Version, ModuleBase

    if ($graph) {
        $graph | Format-Table -AutoSize
        $graph | Out-String | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
    }
    else {
        Write-Status 'No Microsoft.Graph modules were found.' 'Error'
    }

    $meta = Get-HighestInstalledVersion -Name 'Microsoft.Graph'
    if ($meta) {
        Write-Status "Microsoft.Graph SDK ready: $meta" 'Success'
    }

    if ($InstallBeta) {
        $beta = Get-HighestInstalledVersion -Name 'Microsoft.Graph.Beta'
        if ($beta) {
            Write-Status "Microsoft.Graph.Beta SDK ready: $beta" 'Success'
        }
    }

    if ($script:RepairPerformed) {
        Write-Status 'A clean repair was performed during this run.' 'Warning'
    }

    Write-Status "Maintenance complete. Log: $script:LogPath" 'Success'
    Write-Host ''
    Write-Host 'Use Connect-MgGraph for authentication. No tenant connection was made by this maintenance script.' -ForegroundColor White
}

try {
    Set-MainProgress -Status 'Checking PowerShell environment' -PercentComplete 5
    Assert-Prerequisites

    Set-MainProgress -Status 'Checking PowerShell package manager and PSGallery' -PercentComplete 15
    Initialize-PSResourceGet

    Set-MainProgress -Status 'Disconnecting and unloading existing Graph modules' -PercentComplete 25
    Disconnect-And-UnloadGraph

    Set-MainProgress -Status 'Installing or updating Microsoft Graph SDK' -PercentComplete 40
    Write-Section 'Microsoft Graph SDK install/update'
    Install-OrUpdateGraphPackage -Name 'Microsoft.Graph'

    if ($InstallBeta) {
        Set-MainProgress -Status 'Installing or updating Microsoft Graph Beta SDK' -PercentComplete 48
        Write-Status 'Beta SDK requested. Microsoft recommends v1.0 for production automation when possible.' 'Warning'
        Install-OrUpdateGraphPackage -Name 'Microsoft.Graph.Beta'
    }

    Set-MainProgress -Status 'Running initial Graph health validation' -PercentComplete 55
    $healthy = Test-GraphHealth

    if (-not $healthy -and $AutoRepair) {
        Set-MainProgress -Status 'Health check failed; performing clean Graph repair' -PercentComplete 65
        Write-Status 'Normal install/update did not pass validation. Starting automatic clean repair...' 'Warning'
        Invoke-CleanGraphRepair

        Set-MainProgress -Status 'Revalidating Graph after automatic repair' -PercentComplete 75
        $healthy = Test-GraphHealth
    }

    if (-not $healthy) {
        throw 'Microsoft Graph PowerShell failed health validation.'
    }

    Set-MainProgress -Status 'Cleaning stale Graph module versions' -PercentComplete 82
    Remove-OldGraphVersions

    # Revalidate after stale-version cleanup.
    Set-MainProgress -Status 'Running final Graph health validation' -PercentComplete 90
    $healthy = Test-GraphHealth
    if (-not $healthy) {
        throw 'Microsoft Graph PowerShell failed validation after stale-version cleanup.'
    }

    Set-MainProgress -Status 'Checking legacy Microsoft cloud modules' -PercentComplete 95
    Show-LegacyModuleStatus

    Set-MainProgress -Status 'Building final Graph inventory' -PercentComplete 98
    Show-FinalInventory

    Set-MainProgress -Status 'Microsoft Graph maintenance complete' -PercentComplete 100
    Start-Sleep -Milliseconds 250
    Complete-ProgressDisplay
}
catch {
    Complete-ProgressDisplay
    Write-Host ''
    Write-Status "FAILED: $($_.Exception.Message)" 'Error'
    Write-Status "Review the log at $script:LogPath" 'Error'
    exit 1
}
