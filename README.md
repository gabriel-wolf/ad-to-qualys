# Automated AD-to-Qualys Patch Management Onboarding

Enterprise security automation for synchronizing Active Directory computer inventories with Qualys Patch Management.

This project discovers eligible workstation and server assets from designated Active Directory organizational units, adds missing computers to the appropriate security groups, resolves the corresponding assets in Qualys, and applies the Qualys tags used to place those systems into the correct patch-management scope.

> [!NOTE]
> This automation was developed for and is actively used in a large-scale enterprise environment. The public repository contains sanitized configuration values and does not include production credentials, internal infrastructure details, or organization-specific identifiers.

---

## Overview

Enterprise patch-management platforms depend on accurate asset scope.

A computer may exist in Active Directory and have the Qualys Cloud Agent installed, but it will not necessarily receive the intended patch jobs unless it is assigned to the correct Qualys tag or asset group.

This automation connects the two systems:

![Diagram](/imgs/bold-blue-ad-to-qualys-diagram-2.drawio.png)

The result is a repeatable onboarding process that reduces manual asset handling and helps ensure newly deployed systems are brought under enterprise patch-management controls.

---

## Patch-Management Workflow

The automation performs the following operations:

1. Runs in either `Workstation` or `Server` mode.
2. Reads a list of Active Directory organizational units from the corresponding configuration file.
3. Searches those OUs recursively for computer objects.
4. Uses the computer operating-system value to separate workstations from servers.
5. Builds an authoritative list of computers that should be included in the selected patch-management scope.
6. Compares that authoritative list against the appropriate Active Directory security group.
7. Adds eligible computers that are missing from the group.
8. Removes existing group members that are no longer located within the configured OU scope.
9. Prevents removals when one or more configured OUs cannot be successfully resolved or queried.
10. Compiles the reconciled group membership into a list of hostnames.
11. Resolves current group members against the Qualys Asset Management API.
12. Resolves computers removed from the AD group so their Qualys tag assignment can also be removed.
13. Tests four hostname formats for each device:
    * Lowercase fully qualified domain name
    * Uppercase fully qualified domain name
    * Lowercase short hostname
    * Uppercase short hostname
14. Collects and deduplicates the returned Qualys asset IDs.
15. Resolves the configured Qualys patch-management tag by name.
16. Applies the tag in bulk to assets that remain in the authoritative AD scope.
17. Removes the tag in bulk from assets that were successfully removed from the AD group.
18. Writes execution details, reconciliation results, API activity, and summary statistics to a local log.

This creates a two-way onboarding and offboarding workflow. Newly eligible systems are added to the appropriate Active Directory group and Qualys patch-management tag, while systems that leave the configured OU scope are removed from both.

Qualys patch jobs can target the workstation or server tag, allowing asset membership to remain aligned with the organization’s Active Directory structure without requiring an engineer to manually locate, tag, or untag each device.

---

## Project Files

### [`Automation.ps1`](Automation.ps1)

The main production automation script.

It supports two execution modes:

```powershell
.\Automation.ps1 -TargetMode Workstation
```

```powershell
.\Automation.ps1 -TargetMode Server
```

The script:

* Loads the encrypted Qualys credential
* Reads the appropriate OU configuration file
* Discovers computers recursively within the configured Active Directory OUs
* Filters computers by operating-system type
* Builds an authoritative workstation or server membership set
* Adds missing computers to the appropriate Active Directory group
* Removes computers that are no longer within the configured OU scope
* Enables a removal safety lock if an OU cannot be resolved or queried
* Exports the reconciled group membership to `hosts.txt`
* Resolves the configured Qualys tag by name
* Searches Qualys for each current and removed asset
* Tests four hostname formats for each device
* Deduplicates returned Qualys asset IDs
* Applies the patch-management tag in bulk to current group members
* Removes the patch-management tag from computers successfully removed from Active Directory
* Prevents an asset from being untagged if it is still part of the current authoritative target set
* Records Active Directory changes, Qualys API activity, errors, and execution statistics in `sync_log.txt`

---

### [`Get-QualysAsset.ps1`](Get-QualysAsset.ps1)

A diagnostic and validation utility used to search for an individual asset in Qualys by hostname.

The script:

* Loads the encrypted Qualys credential
* Submits an XML asset search request to the Qualys Asset Management API
* Searches for an exact asset-name match
* Extracts the returned asset ID
* Displays the asset name
* Displays the current tracking IP when available

This utility is useful when validating API connectivity, troubleshooting hostname mismatches, or confirming that a device is present in the Qualys asset inventory before running the full automation.

---

### [`Initialize-QualysPassword.ps1`](Initialize-QualysPassword.ps1)

Initializes the encrypted Qualys API credential used by the other scripts.

The script prompts for the Qualys password or API credential as a PowerShell `SecureString` and stores an encrypted representation at:

```text
C:\ProgramData\QualysAutomation\qualys_password.enc
```

When `ConvertFrom-SecureString` is used without a custom encryption key on Windows, PowerShell uses Windows Data Protection API protection associated with the current Windows user context.

The initialization script must therefore be run under the same Windows account that will execute the scheduled automation.

This approach prevents the Qualys credential from being:

* Hardcoded in the PowerShell scripts
* Stored in a plaintext configuration file
* Committed to source control
* Exposed through ordinary repository access

The credential is decrypted into process memory when required for API authentication. It should therefore be protected through appropriate service-account security, host hardening, filesystem permissions, and least-privilege access.

---

## Required Configuration Files

The automation expects additional text files in the same directory as `Automation.ps1`.

### `<list-of-workstation-ous.txt>`

Contains the names of Active Directory organizational units that should be evaluated when the script runs in workstation mode.

Example:

```text
Finance Workstations
Engineering Workstations
Administrative Workstations
```

Each non-empty line represents one OU name.

The script searches for these OUs beneath the configured Active Directory search base and recursively evaluates the computer objects inside them.

---

### `<list-of-server-ous.txt>`

Contains the names of Active Directory organizational units that should be evaluated when the script runs in server mode.

Example:

```text
Application Servers
Infrastructure Servers
Database Servers
```

Each non-empty line represents one OU name.

---

## Generated Files

The following files are created or updated automatically during execution.

### `hosts.txt`

Contains the final list of computer names compiled from the selected Active Directory group.

This file provides a simple record of the hostnames included in the Qualys resolution phase.

It is overwritten during each run.

---

### `sync_log.txt`

Contains timestamped operational logs, including:

* Selected execution mode
* Active Directory group membership counts
* OU discovery results
* Computers added to the AD group
* Active Directory errors
* Qualys hostname search attempts
* Successful Qualys asset matches
* Unmatched devices
* Bulk tag-assignment results
* Final execution statistics

This file is appended to rather than overwritten, providing a historical execution trail.

---

### `<secret-directory>/<secret-file-name.enc>`

Generated by `Initialize-QualysPassword.ps1`.

This file must not be committed to the repository.

Add it to `.gitignore` if the credential path is ever changed to a location inside the project directory.

---

## Repository Structure

```text
.
├── Automation.ps1
├── Get-QualysAsset.ps1
├── Initialize-QualysPassword.ps1
├── <list-of-workstation-ous.txt>
├── <list-of-server-ous.txt>
├── README.md
└── imgs
```

The following files may appear after execution:

```text
hosts.txt
sync_log.txt
```

---

## Successful Execution Examples

### Qualys Asset Lookup

The following example shows `Get-QualysAsset.ps1` successfully resolving a hostname to a Qualys asset record.

![Successful Qualys asset lookup](imgs/get-asset-run-1.png)

### Automated AD-to-Qualys Synchronization

The following example shows `Automation.ps1` successfully processing Active Directory targets, resolving Qualys assets, and applying the configured patch-management tag.

![Successful AD-to-Qualys automation run](imgs/main-script-2.png)
![Successful AD-to-Qualys automation run](imgs/main-script-3.png)

---

## Requirements

### PowerShell and Windows

* Windows PowerShell 5.1 or a compatible PowerShell environment
* Windows host joined to or able to query the target Active Directory domain
* Active Directory PowerShell module
* TLS 1.2 connectivity to the Qualys API

The Active Directory module can be verified with:

```powershell
Get-Module -ListAvailable ActiveDirectory
```

---

### Active Directory Permissions

The execution account requires permission to:

* Read the configured organizational units
* Read computer objects and operating-system attributes
* Read the target Active Directory groups
* Enumerate group membership
* Add computer objects to the target groups

The account does not need unrestricted domain-administrator access.

Only the permissions required for the designated OUs and groups should be delegated.

---

### Qualys Permissions

The Qualys account requires sufficient API permissions to:

* Search Asset Management records
* Search tags
* Update host-asset tag assignments

The exact Qualys role and API permissions should be limited to the functions required by this automation.

---

### Network Access

The execution host must be able to reach:

* Active Directory domain controllers
* DNS services required for the environment
* The configured Qualys API platform over HTTPS

---

## Initial Setup

### 1. Configure the environment variables

Update the configuration values in `Automation.ps1`:

```powershell
$QualysUsername = "<your-api-username>"
$QualysPlatform = "<qualysapi.qualys.com>"
$SecretPath     = "<path-to-secret-enc>"

$DnsSuffix       = "<foo.bar>"
$OUMenuSearchBase = "<DC=foo,DC=bar>"

$WorkstationADGroupDN = "<CN=workstations-group-name,OU=xyz,OU=abc,DC=foo,DC=bar>"
$ServerADGroupDN      = "<CN=servers-group-name,OU=xyz,OU=abc,DC=foo,DC=bar>"

$WorkstationQualysTag = "<qualys-workstations-tag-group>"
$ServerQualysTag      = "<qualys-servers-tag-group>"

$WorkstationOUFileName = "<list-of-workstation-ous.txt>"
$ServerOUFileName      = "<list-of-server-ous.txt>"
```

The values in this public repository should remain sanitized and should not identify production domains, service accounts, computer names, or internal directory structures.

---

### 2. Create the OU configuration files

Populate `<list-of-workstation-ous.txt>` and `<list-of-server-ous.txt>` with the OU names that should be evaluated.

Blank lines are ignored.

---

### 3. Initialize the Qualys credential

Run the initialization script under the same account that will execute the automation:

```powershell
.\Initialize-QualysPassword.ps1
```

Enter the Qualys API credential when prompted.

Confirm that the encrypted file was created at the configured secret path.

---

### 4. Test a single Qualys asset

Set the test hostname inside `Get-QualysAsset.ps1`, and then run:

```powershell
.\Get-QualysAsset.ps1
```

Confirm that the expected asset ID and hostname are returned.

---

### 5. Test workstation mode

```powershell
.\Automation.ps1 -TargetMode Workstation
```

Review:

```text
sync_log.txt
hosts.txt
```

Confirm that the correct Active Directory group and Qualys tag were selected.

---

### 6. Test server mode

```powershell
.\Automation.ps1 -TargetMode Server
```

Again, confirm that the correct group, tag, and OU configuration file were selected.

---

## Scheduled Execution

The script can be run through Windows Task Scheduler under a dedicated service account.

A typical scheduled-task configuration includes:

* **Program:** `powershell.exe`
* **Arguments:**

```text
-NoProfile -ExecutionPolicy Bypass -File "<path>\Automation.ps1" -TargetMode Workstation
```

A separate task can run server mode:

```text
-NoProfile -ExecutionPolicy Bypass -File "<path>\Automation.ps1" -TargetMode Server
```

The scheduled-task account must be the same account that ran `Initialize-QualysPassword.ps1`, unless the encrypted credential is regenerated under the new execution identity.

---

## Design Considerations

### Separate Workstation and Server Profiles

A single script supports both asset classes while retaining separate:

* Active Directory groups
* Qualys tags
* OU configuration files
* Operating-system selection behavior
* Reconciliation results
* Execution logs and statistics

This reduces duplicated code while preserving distinct workstation and server patch-management scopes.

---

### Configured OUs as the Authoritative Source

The configured OU list defines which systems should belong to each patch-management scope.

During each run, the script recursively discovers eligible computers within those OUs, filters them by operating-system type, and builds an authoritative membership set.

That set is then compared against the corresponding Active Directory group:

* Eligible computers missing from the group are added.
* Existing group members no longer present in the configured OU scope are removed.
* Devices successfully removed from the AD group are also processed for Qualys tag removal.

This makes the Active Directory group a synchronized and auditable representation of the systems currently intended for patch management.

---

### Removal Safety Lock

Removing systems from patch-management scope is more sensitive than adding them.

To reduce the risk of accidental mass removal, the script disables all removal operations if any configured OU cannot be successfully resolved or queried.

Possible causes include:

* An incorrect OU name
* An unavailable domain controller
* Insufficient Active Directory permissions
* A transient directory-service failure

When the safety lock is enabled, the script may continue processing valid additions, but it does not remove computers from the Active Directory group or remove their Qualys tags.

---

### Hostname Normalization

Enterprise asset inventories frequently contain inconsistent hostname capitalization or a mixture of short names and fully qualified domain names.

For that reason, the automation performs four separate Qualys queries for each device:

```text
hostname.example.com
HOSTNAME.example.com
hostname
HOSTNAME
```

The four variants are intentionally preserved as separate queries because Qualys asset records may use different naming formats.

All returned asset IDs are deduplicated before tag changes are submitted.

---

### Two-Way Qualys Tag Reconciliation

The automation manages both entry into and removal from the Qualys patch-management scope.

For current Active Directory group members, the script:

1. Resolves their Qualys asset IDs.
2. Deduplicates the returned IDs.
3. Applies the configured Qualys tag in bulk.

For computers successfully removed from the Active Directory group, the script:

1. Resolves their Qualys asset IDs using the same four hostname variants.
2. Deduplicates the returned IDs.
3. Removes the configured Qualys tag in bulk.

Before tag removal, the script excludes any asset ID that is also present in the current authoritative target set. This prevents an active in-scope asset from being untagged because of duplicate or overlapping Qualys records.

---

### Bulk Qualys Tag Updates

Rather than sending a separate tag update for every asset, the script compiles unique Qualys asset IDs and submits bulk requests.

Separate bulk requests are used for:

* Adding the patch-management tag to current assets
* Removing the patch-management tag from former assets

This reduces API traffic and makes the automation more efficient for large enterprise inventories.

---

## Logging and Operational Visibility

The automation records detailed information to support routine operational review, troubleshooting, and auditability.

Examples include:

```text
[AD ADD SUCCESS]
[AD ADD FAILED]
[AD REMOVE SUCCESS]
[AD REMOVE FAILED]
[TRYING ASSET NAME QUERY]
[SUCCESS MATCH]
[DUPLICATE MATCH]
[QUALYS ASSET NOT FOUND]
[API EXCEPTION]
SAFETY LOCK
CRITICAL ERROR
ACTIVE DIRECTORY RECONCILIATION SUMMARY
FINAL AUTOMATION SUMMARY
```

The log includes:

* Initial and final Active Directory group membership
* Authoritative OU-scope totals
* Computers added to the AD group
* Computers removed from the AD group
* Active Directory operation failures
* Qualys hostname queries
* Matched and unmatched assets
* Unique asset IDs collected
* Qualys tag-addition results
* Qualys tag-removal results
* Safety-lock activation

Because logs may contain internal hostnames, directory names, tag names, asset IDs, or error details, production log files should not be committed to a public repository.

---

## Security Considerations

* Do not hardcode credentials in the scripts.
* Do not commit `qualys_password.enc`.
* Run the automation through a dedicated service account.
* Delegate only the required Active Directory permissions.
* Ensure the service account has permission to both add and remove members from the managed AD groups.
* Limit the Qualys API account to the required asset-search and tag-update operations.
* Restrict filesystem access to the script and credential directories.
* Protect scheduled-task definitions and service-account credentials.
* Treat generated logs and hostname exports as internal operational data.
* Rotate the Qualys credential according to organizational policy.
* Regenerate the encrypted secret after changing the execution account, host, Windows profile, or Qualys credential.
* Treat the configured AD groups as automation-managed groups.
* Avoid manually adding devices to those groups unless they also belong to the configured OU scope.
* Review OU configuration changes carefully because they directly affect both AD group membership and Qualys patch scope.
* Test removal behavior in a controlled environment before enabling scheduled production execution.

---

## Recommended `.gitignore`

```gitignore
# Generated operational data
hosts.txt
sync_log.txt
*.log

# Credentials and encrypted secret material
*.enc
qualys_password.enc

# Local test files
*.local.ps1
test-output/
```

---

## Error Handling

The automation stops, skips processing, or enables a safety lock when it encounters conditions such as:

* Missing encrypted credential
* Credential decryption failure
* Missing OU configuration file
* Empty OU configuration file
* Missing Active Directory group
* Failed AD group membership enumeration
* Unresolvable OU name
* Multiple OUs matching the same configured name
* Failed OU computer enumeration
* Failed Active Directory group addition
* Failed Active Directory group removal
* Qualys API communication failure
* Missing Qualys tag
* Unmatched hostname
* Failed Qualys tag addition
* Failed Qualys tag removal
* An asset scheduled for removal also appearing in the current authoritative target set

If any configured OU cannot be fully validated, the script enables the removal safety lock and prevents both AD group removal and Qualys tag removal for that run.

Errors and warnings are written to both the console and `sync_log.txt`.

---

### Useful Links

* [Qualys PM API Docs](https://gateway.qg1.apps.qualys.com/apidocs/pm/v1#/Patch%20Report%20Resource/submitAssetsTabReportUsingGET) – Direct link to the Qualys Patch Management (v1) reference for submitting Asset Tab reports.

---

## Disclaimer

This repository is intended to demonstrate an enterprise security automation pattern.

Names, credentials, paths, domains, organizational units, groups, tags, and other environment-specific values shown in the public version are placeholders or sanitized examples. The scripts should be reviewed, tested, and adapted to the security requirements of the target environment before use.
