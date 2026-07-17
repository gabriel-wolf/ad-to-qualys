# Automated Active Directory-to-Qualys Patch Management Onboarding

> **Author:** Gabriel Wolf

Enterprise security automation for maintaining coordinated patch-management scope across Active Directory and Qualys.

The workflow discovers eligible workstation or server computers from configured Active Directory organizational units, resolves recent matching Qualys Host Asset records, applies the correct Qualys Patch Management tag, verifies final Qualys membership, and then synchronizes a dedicated Active Directory GPO group to devices with confirmed Qualys coverage.

> [!NOTE]
> This repository contains sanitized configuration values and excludes production credentials, domains, hosts, group names, directory structures, service accounts, and organization-specific identifiers.

---

## Overview

A computer can exist in Active Directory without being ready for Qualys-managed patching. It may not yet exist in Qualys, its Cloud Agent may not have checked in recently, or its patch-management tag assignment may fail.

That distinction matters when an Active Directory group changes update policy. A device must not be placed into a group that exempts it from standard updates until Qualys patch coverage has actually been confirmed.

This automation therefore treats the configured OU inventory as the authoritative candidate scope while treating the Active Directory GPO group as the final representation of verified Qualys patch coverage.

![Workflow diagram](/imgs/update-ad-to-qualys-diagram-3.drawio.png)

The same script supports separate workstation and server profiles with independent:

- Active Directory groups
- Qualys Patch Management tags
- OU configuration files
- Operating-system filters
- Execution results

---

## Current Workflow

### 1. Load the encrypted Qualys credential

`Initialize-QualysPassword.ps1` prompts for the Qualys API password as a PowerShell `SecureString` and stores an encrypted representation at the configured secret path.

Example sanitized path:

```text
C:\ProgramData\QualysAutomation\qualys_password.enc
```

On Windows, `ConvertFrom-SecureString` without a custom encryption key uses Windows Data Protection API protection associated with the current Windows user context.

The initialization script must therefore be run under the same Windows account and profile that will execute the automation.

The password is decrypted only into process memory when needed for Qualys API authentication. It is not hardcoded in the scripts or stored in plaintext configuration.

### 2. Build the authoritative Active Directory candidate scope

`Automation.ps1` runs in either `Workstation` or `Server` mode.

It:

1. Reads the corresponding OU configuration file.
2. Resolves each configured OU beneath the configured search base.
3. Recursively enumerates computer objects.
4. Filters workstation and server systems according to the selected mode.
5. Builds the authoritative set of OU-eligible computers.
6. Identifies current Active Directory group members that have left the configured OU scope.

New OU-eligible computers are **not immediately added** to the Active Directory GPO group. They first have to pass Qualys resolution, freshness, tag assignment, and verification.

### 3. Remove existing group members that left OU scope

Current Active Directory GPO-group members that are no longer in the authoritative OU scope are removed when Active Directory removals are enabled.

A removal safety lock prevents scope-based removals when any configured OU cannot be resolved or fully queried.

Computers successfully removed for leaving OU scope can also have the Qualys Patch Management tag removed from their resolved Qualys assets.

### 4. Exclude server-classified assets from workstation scope

In `Workstation` mode, the script checks an editable list of Qualys tags that identify server assets. Devices found in any of those tags are excluded from the workstation Qualys Patch Management tag and the workstation Active Directory GPO group.

This check applies only to workstation processing.

### 5. Search department Qualys tags

For each configured department or OU name, the automation searches both capitalization variants of the related dynamic Qualys tag:

```text
MSAD - DEPARTMENT
MSAD - department
```

The script retrieves all paginated Qualys Host Asset records assigned to the matching department tag and normalizes each returned hostname.

A matching Qualys asset is eligible only when:

- Its normalized hostname appears in the authoritative OU candidate set.
- Its `lastCheckedIn` value is available.
- Its last check-in occurred within the configured freshness window (default 30 days).

A device found in a department tag but stale is recorded as stale and excluded from both Qualys patch tagging and final Active Directory GPO-group membership.

### 6. Resolve true hostname fallback devices

Hostname fallback is performed only for authoritative OU candidates that were **not found in any department Qualys tag**.

Devices already found in a department tag but rejected as stale are not searched again.

Each true fallback device is searched using four hostname variants:

```text
hostname.example.com
HOSTNAME.example.com
hostname
HOSTNAME
```

Returned Qualys Host Asset IDs are deduplicated.

Transient `503 Server Unavailable` responses are retried silently using the configured delay schedule. When retries are exhausted, coverage is marked as unknown rather than missing.

When recent matching assets are found, those asset IDs become eligible for the target Qualys Patch Management tag.

### 7. Apply Qualys Patch Management tags

Eligible Qualys Host Asset IDs are submitted in primary batches of up to 200.

When a 200-asset request fails, that failed batch is retried as groups of up to 25.

If a 25-asset group also fails, only that failed group is retried one asset at a time.

Successful 25-asset groups are not retried again.

This isolates the exact Qualys asset IDs that are rejected without allowing one bad asset to cause the other valid assets in the same 25-device group to be excluded.

Successful and failed asset IDs are tracked separately, and only individually rejected asset IDs remain failed.

### 8. Verify final Qualys membership

After all Qualys tag updates, the automation re-queries the target Patch Management tag.

The script compares the actual final tag membership against the asset IDs expected to receive Qualys patching.

An accepted update response is not treated as final proof of coverage. Final membership must be confirmed by the verification query.

### 9. Synchronize the Active Directory GPO group

Only after successful Qualys verification does the script synchronize the Active Directory GPO group.

It:

- Adds OU-eligible computers that have at least one recent, verified Qualys asset in the target Patch Management tag.
- Leaves stale, unresolved, server-classified workstation candidates, and unverified devices outside the GPO group.
- Removes existing GPO-group members that remain OU-eligible but no longer have verified recent Qualys coverage.
- Leaves existing group members unchanged when coverage cannot be determined because Qualys API retries were exhausted.
- Records failed Active Directory additions and removals.

This ordering prevents a new device from being exempted from standard update policy before Qualys patch coverage has been confirmed.

If final Qualys verification fails, coverage-based Active Directory additions and removals are blocked for that run.

## Successful Execution Example

> [!NOTE]
> This is a real production output. All example outputs have been sanitized. Output depends on the selected mode, configuration toggles, asset inventory, and current Qualys state.

<img src="./imgs/ad-to-qualys-sanitized-full.svg"
     alt="Sanitized Active Directory-to-Qualys automation console output"
     width="100%">

---

## Project Files

### [`Automation.ps1`](Automation.ps1)

The main automation script.

Run workstation mode:

```powershell
.\Automation.ps1 -TargetMode Workstation
```

Run server mode:

```powershell
.\Automation.ps1 -TargetMode Server
```

The script performs:

- OU-based authoritative inventory discovery
- Workstation or server filtering
- Workstation exclusion based on configurable Qualys server-classification tags
- Active Directory scope reconciliation
- Department-tag asset collection
- Qualys check-in freshness enforcement
- True hostname fallback resolution with silent 503 retries
- Optional target-tag clearing
- Batched Qualys tag updates
- Safe failed-batch isolation using 200, then 25, then individual retry only for failed 25-asset groups
- Final Qualys membership verification
- Verified-coverage-based Active Directory group synchronization
- CSV failure and action reporting
- Condensed operational logging
- Final Active Directory and Qualys result summaries

### [`Initialize-QualysPassword.ps1`](Initialize-QualysPassword.ps1)

Creates the encrypted Qualys API credential used by the automation and diagnostic scripts.

The script must be run under the same Windows execution identity and profile that will run the scheduled automation unless the credential is regenerated for a different context.

The encrypted credential file and its containing directory should be protected with appropriate filesystem permissions.

### [`Get-QualysAsset.ps1`](Get-QualysAsset.ps1)

A diagnostic utility for validating Qualys API connectivity and testing an individual hostname search.

It:

- Loads the encrypted Qualys credential
- Searches for an exact Host Asset name
- Displays the returned Host Asset ID
- Displays the asset name
- Displays additional returned asset details when available

<img src="./imgs/getqualysasset-1.svg"
     alt="Sanitized individual Qualys asset lookup"
     width="100%">

### [`Schedule-Task.ps1`](Schedule-Task.ps1)

Registers workstation and server automation runs in Windows Task Scheduler.

The scheduled-task execution account may need the following local or policy-delivered user right:

```text
Log on as a batch job
```

It must not be included in:

```text
Deny log on as a batch job
```

The account must:

- Be able to decrypt the encrypted Qualys credential
- Have the required Active Directory permissions
- Have the required Qualys API permissions
- Be allowed to run as a batch job
- Have network access to Active Directory and Qualys

Regenerate the encrypted credential whenever the execution account, Windows profile, host, or Qualys credential changes.


---

## Required Configuration Files

The OU configuration files must be stored in the same directory as `Automation.ps1`.

### `<list-of-workstation-ous.txt>`

Contains the department or top-level OU names evaluated in workstation mode.

```text
IT
FINANCE
HR
```

### `<list-of-server-ous.txt>`

Contains the department or top-level OU names evaluated in server mode.

```text
APPLICATIONS
INFRASTRUCTURE
DATABASES
```

Each non-empty line represents one OU name. Blank lines are ignored.

Each configured value must align with:

- An OU beneath the configured Active Directory search base
- A related Qualys dynamic tag following the `MSAD - <department>` convention

---

## Generated Files

### `hosts.txt`

Contains the final computer names in the Active Directory GPO group after verified Qualys coverage enforcement.

The file is overwritten during each run.

### `sync_log.txt`

Contains timestamped operational logs for:

- Execution mode and enabled features
- OU discovery and validation
- Active Directory scope changes
- Qualys department-tag searches and pagination
- Stale-asset exclusions
- Hostname fallback processing
- Target-tag clearing
- Batched Qualys updates
- Failed-batch retries
- Final Qualys verification
- Active Directory coverage enforcement
- Errors and final summaries

The file is appended to preserve an execution history.

When condensed output is enabled, repetitive per-device and per-batch console messages are suppressed. The underlying results continue to be tracked for reporting.

### `qualys_tag_failures.csv`

Contains devices that were not fully verified for the intended Qualys and Active Directory patch scope.

The CSV includes fields such as:

- Device name
- Associated department
- Resolved Qualys Host Asset IDs
- Verification status
- Active Directory group action
- Failure description

Possible statuses and reasons include:

- No matching Qualys Host Asset
- Matching Qualys assets were stale
- Qualys API lookup errors and coverage-unknown results after retries
- Failed tag-update batches
- Resolved asset IDs missing from the final target tag
- Active Directory addition failure
- Removed from Active Directory because verified Qualys coverage was missing
- Active Directory removal failure

Fully verified devices with no failure condition are excluded from the failure CSV.

The file is overwritten during each run.

### `<secret-directory>/<secret-file-name.enc>`

Contains the encrypted Qualys credential created by `Initialize-QualysPassword.ps1`.

This file must not be committed to source control.

---

## Final Console Summary

The final output is divided into three sections.

### Active Directory GPO group

The heading dynamically displays the resolved Active Directory group name.

Reported values include nonzero changes and the final membership count:

- Devices added after Qualys coverage was verified
- Devices that failed to be added
- Devices removed after leaving OU scope
- Devices removed because verified Qualys coverage was missing
- Devices that failed to be removed
- Existing members left unchanged because Qualys coverage was unknown
- Final devices in the Active Directory GPO group

Zero-value change lines may be omitted to keep the summary focused.

### Qualys Patch Management tag

The heading dynamically displays the selected Qualys tag name.

Reported values include:

- Qualys asset IDs added during the run
- Qualys asset IDs removed during the run
- Final verified Qualys asset IDs in the tag
- Final Qualys verification result

### Coverage checks

Reported values include:

- OU-eligible devices evaluated
- Devices with recent coverage found through department tags
- Stale Qualys devices excluded
- Server-classified devices excluded from workstation scope
- Devices checked through hostname fallback
- Devices with recent coverage found through hostname fallback
- Devices with unknown coverage after Qualys API retries
- Failure rows written to the CSV

---

## Repository Structure

```text
.
├── Automation.ps1
├── Get-QualysAsset.ps1
├── Initialize-QualysPassword.ps1
├── Schedule-Task.ps1
├── <list-of-workstation-ous.txt>
├── <list-of-server-ous.txt>
├── README.md
└── imgs
```

Generated at runtime:

```text
hosts.txt
sync_log.txt
qualys_tag_failures.csv
```

---

## Requirements

### PowerShell and Windows

- Windows PowerShell 5.1 or a compatible PowerShell environment
- Windows host joined to or able to query the target Active Directory domain
- Active Directory PowerShell module
- TLS 1.2 connectivity to the Qualys API

Verify the Active Directory module:

```powershell
Get-Module -ListAvailable ActiveDirectory
```

### Active Directory permissions

The execution account requires permission to:

- Read configured organizational units
- Read computer objects and operating-system attributes
- Read the managed Active Directory groups
- Enumerate group membership
- Add computer objects to the managed groups
- Remove computer objects from the managed groups

Unrestricted domain-administrator access is not required. Delegate only the permissions required for the configured OUs and groups.

### Qualys permissions

The Qualys API account requires permission to:

- Search Host Asset records
- Search and read tags
- Read paginated Host Assets assigned to tags
- Add Host Asset tag assignments
- Remove Host Asset tag assignments

Use the least-privileged Qualys role that supports these operations.

### Network access

The execution host must be able to reach:

- Active Directory domain controllers
- Required DNS services
- The configured Qualys API platform over HTTPS

---

## Initial Setup

<details>
  <summary>Click to expand</summary>

### 1. Configure the environment

Update the sanitized configuration variables in `Automation.ps1`:

```powershell
$QualysUsername = "<your-api-username>"
$QualysPlatform = "<qualys-api-platform>"
$SecretPath     = "<path-to-encrypted-secret>"

$DnsSuffix        = "<example.com>"
$OUMenuSearchBase = "<DC=example,DC=com>"

$WorkstationADGroupDN = "<workstation-gpo-group-distinguished-name>"
$ServerADGroupDN      = "<server-gpo-group-distinguished-name>"

$WorkstationQualysTag = "<workstation-patch-management-tag>"
$ServerQualysTag      = "<server-patch-management-tag>"

$QualysServerClassificationTags = @(
    "<server-classification-tag-1>"
    "<server-classification-tag-2>"
)

$WorkstationOUFileName = "<list-of-workstation-ous.txt>"
$ServerOUFileName      = "<list-of-server-ous.txt>"

$QualysLastSeenDays = 30
```

Operational toggles include:

```powershell
$ClearTargetQualysTagBeforeAdd
$EnableADGroupAdditions
$EnableADGroupRemovals
$EnableDepartmentTagResolution
$EnableStragglerResolution
$EnableQualysTagAdditions
$EnableQualysTagRemovals
$CondensedOutput
$RemoveUnverifiedDevicesFromAD
```

Retry and verification settings include:

```powershell
$QualysFallbackBatchSize
$QualysVerificationAttempts
$QualysVerificationDelaySeconds
$Qualys503RetryDelaysSeconds
```

### 2. Create the OU configuration files

Create the workstation and server OU lists using names expected by both Active Directory and the Qualys department tags.

Blank lines are ignored. Duplicate names are deduplicated.

### 3. Create the Qualys department dynamic tags

The `MSAD - <department>` naming convention is specific to this workflow and is not created automatically by Qualys.

Create one dynamic tag for each configured department.

```text
Tag name: MSAD - <department>
Tag type: Dynamic
Dynamic tag source: Asset Inventory
Query: customAttributes:(value:'OU=<DEPARTMENT>,DC=<EXAMPLE>,DC=<COM>')
```

Example:

```text
Tag name: MSAD - finance
Query: customAttributes:(value:'OU=FINANCE,DC=EXAMPLE,DC=COM')
```

The script checks both uppercase and lowercase department-name variants. Only one consistent variant needs to exist.

### 4. Initialize the Qualys credential

Run the initialization script under the same account that will execute the automation:

```powershell
.\Initialize-QualysPassword.ps1
```

Confirm that the encrypted credential file was created at the configured secret path.

### 5. Test an individual Qualys asset

Set a sanitized test hostname inside `Get-QualysAsset.ps1` and run:

```powershell
.\Get-QualysAsset.ps1
```

Confirm that the expected Host Asset record is returned.

### 6. Test workstation mode

```powershell
.\Automation.ps1 -TargetMode Workstation
```

Review:

```text
sync_log.txt
hosts.txt
qualys_tag_failures.csv
```

Confirm that the expected workstation OU file, Active Directory GPO group, and Qualys Patch Management tag were selected.

### 7. Test server mode

```powershell
.\Automation.ps1 -TargetMode Server
```

Repeat the same validation for the server profile.

  
</details>


---

## Design and Safety

<details>
  <summary>Click to expand</summary>

### OU inventory is authoritative

The configured OU list determines which computers are candidates for the selected workstation or server patch scope.

The existing Active Directory GPO group is not used as the sole source of candidates. This allows newly created or newly moved OU devices to be evaluated before they are members of the GPO group.

### The Active Directory group represents verified coverage

A device is added to the Active Directory GPO group only after a recent Qualys Host Asset is found, the target Qualys tag is applied, and final tag membership is verified.

This prevents the GPO group from exempting a device from standard updates before Qualys patching is available.

### Stale assets are not hostname fallback devices

A device found through its department tag but older than the configured check-in threshold is classified as stale.

It is not searched again through the four hostname variants.

### Hostname fallback is limited to true misses

Individual hostname searches are used only when the OU-eligible computer was not found in any department tag.

This avoids thousands of unnecessary API requests for stale devices already identified through department tags.

### Workstation scope excludes server-classified assets

In workstation mode, devices found in any configured Qualys server-classification tag are excluded from both workstation patch-management scopes.

### Temporary Qualys failures do not trigger AD removal

Hostname lookups retry transient 503 responses. When all retries fail, new devices are not added, but existing Active Directory group members are left unchanged because coverage could not be determined.

### Final verification controls Active Directory synchronization

Coverage-based Active Directory additions and removals occur only after successful final Qualys verification.

When verification fails, the script activates a safety lock and does not make coverage-based GPO-group changes.

### Failed Qualys batches preserve valid assets

A failed batch of 200 is retried as groups of up to 25.

Successful 25-asset groups are accepted immediately.

Only a failed 25-asset group is retried one asset at a time. This identifies the exact rejected Qualys asset IDs and prevents one unsupported or invalid asset from causing the other valid assets in that group to be excluded.

The script does not use the slower recursive `200 → 25 → 5 → 1` pattern.

### Optional full tag rebuild

The target Qualys tag can be cleared before additions.

This can provide deterministic rebuilding but increases API calls and execution time. The toggle should be chosen intentionally for scheduled operation.

### Scope-removal safety lock

When a configured OU cannot be resolved or queried, scope-based removal operations are blocked for that run.

This protects against accidental mass removal caused by an incomplete authoritative inventory.

### Duplicate Qualys asset IDs

Multiple name variants or department tags can resolve to the same Qualys Host Asset ID.

All collected IDs are deduplicated before tag updates.

A single Active Directory computer can also correspond to more than one Qualys Host Asset ID. Final Active Directory membership counts and final Qualys asset-ID counts therefore do not have to be identical.

  </details>

---

## Security Considerations

- Never hardcode credentials.
- Never commit encrypted credentials.
- Keep public configuration values sanitized.
- Run the workflow under a dedicated execution account.
- Delegate only the required Active Directory permissions.
- Limit the Qualys account to required Host Asset and tag operations.
- Restrict filesystem access to scripts, credentials, logs, and reports.
- Protect scheduled-task definitions and execution-account credentials.
- Rotate the Qualys credential according to organizational policy.
- Regenerate the encrypted credential after changing the execution identity or environment.
- Treat the Active Directory GPO groups as automation-controlled.
- Keep OU configuration names aligned with the related `MSAD - <department>` dynamic tags.
- Validate full-tag clearing and removal behavior in a controlled environment.
- Treat logs, hostnames, Qualys asset IDs, and failure reports as internal operational data.

---

## Recommended `.gitignore`

```gitignore
# Generated operational data
hosts.txt
sync_log.txt
qualys_tag_failures.csv
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

The automation stops, skips processing, or activates a safety lock when needed to protect the managed scope.

Handled conditions include:

- Missing encrypted credential
- Credential decryption failure
- Missing or empty OU configuration file
- Missing Active Directory group
- Failed group-membership enumeration
- Unresolvable or ambiguous OU
- Failed OU computer enumeration
- Failed Active Directory addition or removal
- Qualys API communication failure, including bounded 503 retries
- Missing target Qualys Patch Management tag
- Missing department-tag variants
- Failed Host Asset pagination
- Missing pagination metadata
- Stale, missing, or temporarily indeterminate Qualys assets
- Failed Qualys tag-update batches
- Failed final Qualys tag verification
- Asset IDs protected from tag removal because they remain in the current target set

Errors and warnings are written to the console and `sync_log.txt`.

---

## Disclaimer

This repository demonstrates an enterprise security automation pattern.

Names, credentials, paths, domains, organizational units, departments, groups, tags, service accounts, and other environment-specific values shown in the public version are placeholders or sanitized examples.

Review and test all scripts, permissions, dynamic-tag queries, update-policy behavior, and removal controls before using the workflow in another environment.
