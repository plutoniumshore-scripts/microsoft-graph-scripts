# Microsoft Graph Scripts

A focused collection of PowerShell scripts for Microsoft Graph administration, automation, troubleshooting, SDK maintenance, and operational reporting.

This repository is intentionally more specialized than the general `Scripts` repository. The goal is to keep Graph-related tools together with enough documentation to explain what each script changes, what permissions it may require, how it authenticates, and how it should be used safely in an administrative environment.

## Current Script

### [`Repair-Update-MicrosoftGraph.ps1`](./maintenance/Repair-Update-MicrosoftGraph.ps1)

Installs, updates, validates, cleans, and repairs the Microsoft Graph PowerShell SDK.

The script is designed to handle several common Graph PowerShell maintenance problems in one run:

* Detects the installed PowerShell and Graph SDK state.
* Prefers `Microsoft.PowerShell.PSResourceGet` while retaining a PowerShellGet fallback.
* Ensures PSGallery and the NuGet provider are available when needed.
* Installs the current stable `Microsoft.Graph` SDK when it is missing.
* Updates an older Graph SDK to the current PSGallery release.
* Unloads existing Graph modules before maintenance to reduce DLL and version conflicts.
* Validates important Graph modules and core authentication commands.
* Automatically performs a clean repair if normal installation or updating fails validation.
* Removes stale side-by-side Graph module versions after successful validation by default.
* Detects legacy AzureAD, AzureADPreview, MSOnline, and Microsoft.Graph.Intune modules without removing them unless explicitly requested.
* Supports optional installation and maintenance of `Microsoft.Graph.Beta`.
* Displays top-level and nested PowerShell progress indicators during execution.
* Writes a timestamped maintenance log to the current user's temporary directory.

The script does **not** connect to a Microsoft 365 tenant, request Graph permissions, or make changes to users, groups, devices, applications, or other tenant resources. It maintains the local Graph PowerShell environment only.

## Usage

Run from PowerShell 7 when possible:

```powershell
.\maintenance\Repair-Update-MicrosoftGraph.ps1
```

Install or maintain Graph for all users from an elevated PowerShell session:

```powershell
.\maintenance\Repair-Update-MicrosoftGraph.ps1 -Scope AllUsers
```

Keep older side-by-side Graph module versions:

```powershell
.\maintenance\Repair-Update-MicrosoftGraph.ps1 -PurgeOldVersions:$false
```

Install or update the Beta SDK as well:

```powershell
.\maintenance\Repair-Update-MicrosoftGraph.ps1 -InstallBeta
```

Remove detected legacy Microsoft cloud modules only after verifying that existing scripts do not depend on them:

```powershell
.\maintenance\Repair-Update-MicrosoftGraph.ps1 -RemoveLegacyModules
```

Because the script supports PowerShell `ShouldProcess`, potentially destructive operations can also be reviewed with `-WhatIf` where supported by the invoked operation.

## Repository Organization

The repository is intended to grow by Graph function rather than becoming a miscellaneous script dump. Expected areas include:

* `maintenance` - Graph SDK installation, updating, validation, repair, and local environment health.
* `identity` - Users, groups, directory objects, authentication methods, and identity administration.
* `devices` - Intune and Graph device inventory, ownership, compliance, and administration.
* `applications` - Enterprise applications, app registrations, service principals, permissions, and consent reporting.
* `teams` - Microsoft Teams configuration, membership, and reporting through Graph.
* `reports` - Graph-based inventory, audit, licensing, and operational reporting.
* `utilities` - Reusable Graph helpers that do not fit a single workload.

Folders will be added as scripts are published rather than created empty in advance.

## Requirements

Requirements vary by script. In general:

* PowerShell 7 is preferred for current Microsoft Graph PowerShell work.
* Windows PowerShell 5.1 may be supported where practical.
* Internet access to PowerShell Gallery is required for scripts that install or update modules.
* Tenant-facing scripts may require Microsoft Graph delegated or application permissions appropriate to the operation being performed.
* Scripts that require authentication or Graph permissions should document those requirements individually.

## Safety and Security

Scripts in this repository are intended for administrative use and may eventually include operations capable of changing Microsoft 365 tenant resources. Review a script and its documented permissions before using it in production.

Repository scripts should not contain hardcoded credentials, access tokens, private keys, tenant-specific secrets, personal identifiers, private hostnames, or other environment-specific sensitive values. Tenant IDs, application IDs, scopes, paths, and similar values should be supplied dynamically or through parameters when required.

The first published maintenance script performs local PowerShell module maintenance only and does not authenticate to or modify a tenant.

## Attribution and AI Assistance

Scripts may be created, adapted, reviewed, troubleshot, documented, or refined with assistance from AI tools and may incorporate patterns derived from Microsoft documentation or common PowerShell administrative practices. Where a specific external source materially contributes to a script, it should be identified when practical.

Microsoft Graph, Microsoft 365, PowerShell, and related product names are trademarks of Microsoft Corporation. This repository is an independent collection of administrative scripts and is not affiliated with or endorsed by Microsoft.

**If you find anything here useful, please consider donating:**

https://paypal.me/plutoniumshore
