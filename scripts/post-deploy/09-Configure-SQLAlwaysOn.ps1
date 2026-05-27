<#
.SYNOPSIS
    Configures a clusterless SQL Always On Availability Group (CLUSTER_TYPE = NONE)
    between A-SQLSCCM (primary) and B-SQLSCCM (secondary).

.DESCRIPTION
    This script runs AFTER Step 8 (SCCM Primary install).
    The SCCM database (CM_PR1) must exist on A-SQLSCCM before the AG can be created.

.NOTES
    Author  : SADAB Lab
    Version : 2.0
#>
[CmdletBinding()]
param(
    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force

$SqlAIP       = '10.10.0.4'
$SqlBIP       = '10.20.0.4'
$SqlAFQDN     = 'A-SQLSCCM.sadab.pri'
$SqlBFQDN     = 'B-SQLSCCM.sadab.pri'
$AgName       = 'SCCM-AG'
$DbName       = 'CM_PR1'
$EndpointPort = 5022
$gMSAGroup    = 'SADAB\SQLgMSAs'

# ── Step 1: Verify SCCM database exists on A-SQLSCCM ────────────────────────────
Write-LabLog "Verifying SCCM database '$DbName' exists on A-SQLSCCM..." -Step 'AG'

$dbExists = Invoke-LabRemote -IPAddress $SqlAIP -Credential $DomainCred -ScriptBlock {
    param($DbName)
    $db = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name = '$DbName'" `
                        -ServerInstance 'localhost' -ErrorAction SilentlyContinue
    return ($null -ne $db)
} -ArgumentList $DbName

if (-not $dbExists) {
    Write-LabLog "Database '$DbName' not found on A-SQLSCCM." -Level ERROR -Step 'AG'
    Write-LabLog "Run Step 8 (SCCM Primary install) first, then re-run Step 9." -Level WARN -Step 'AG'
    throw "Prerequisite not met: SCCM database must exist before configuring AG."
}
Write-LabLog "Database '$DbName' confirmed on A-SQLSCCM." -Level SUCCESS -Step 'AG'

# ── Step 2: Create hadrEndpoint on A-SQLSCCM ─────────────────────────────────────
Write-LabLog "Creating AG endpoint on A-SQLSCCM (port $EndpointPort)..." -Step 'AG'

Invoke-LabRemote -IPAddress $SqlAIP -Credential $DomainCred -ScriptBlock {
    param($Port, $GroupName)

    $existing = Invoke-Sqlcmd -Query "SELECT name FROM sys.endpoints WHERE type = 4" `
                               -ServerInstance 'localhost'
    if (-not $existing) {
        Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
CREATE ENDPOINT [hadrEndpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = $Port)
    FOR DATA_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
"@
    } else {
        Invoke-Sqlcmd -ServerInstance 'localhost' -Query "ALTER ENDPOINT [hadrEndpoint] STATE = STARTED"
    }

    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$GroupName')
    CREATE LOGIN [$GroupName] FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::[hadrEndpoint] TO [$GroupName];
"@
} -ArgumentList $EndpointPort, $gMSAGroup

Write-LabLog "Endpoint ready on A-SQLSCCM." -Level SUCCESS -Step 'AG'

# ── Step 3: Create hadrEndpoint on B-SQLSCCM ─────────────────────────────────────
Write-LabLog "Creating AG endpoint on B-SQLSCCM (port $EndpointPort)..." -Step 'AG'

Invoke-LabRemote -IPAddress $SqlBIP -Credential $DomainCred -ScriptBlock {
    param($Port, $GroupName)

    $existing = Invoke-Sqlcmd -Query "SELECT name FROM sys.endpoints WHERE type = 4" `
                               -ServerInstance 'localhost'
    if (-not $existing) {
        Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
CREATE ENDPOINT [hadrEndpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = $Port)
    FOR DATA_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
"@
    } else {
        Invoke-Sqlcmd -ServerInstance 'localhost' -Query "ALTER ENDPOINT [hadrEndpoint] STATE = STARTED"
    }

    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$GroupName')
    CREATE LOGIN [$GroupName] FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::[hadrEndpoint] TO [$GroupName];
"@
} -ArgumentList $EndpointPort, $gMSAGroup

Write-LabLog "Endpoint ready on B-SQLSCCM." -Level SUCCESS -Step 'AG'

# ── Step 4: Set SCCM DB to FULL recovery on A-SQLSCCM ───────────────────────────
Write-LabLog "Setting '$DbName' to FULL recovery model on A-SQLSCCM..." -Step 'AG'

Invoke-LabRemote -IPAddress $SqlAIP -Credential $DomainCred -ScriptBlock {
    param($DbName)
    New-Item -ItemType Directory -Path 'C:\SQLBackup' -Force | Out-Null
    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
ALTER DATABASE [$DbName] SET RECOVERY FULL;
BACKUP DATABASE [$DbName]
    TO DISK = N'C:\SQLBackup\$DbName-AGSeed.bak'
    WITH FORMAT, INIT, STATS = 10;
BACKUP LOG [$DbName]
    TO DISK = N'C:\SQLBackup\$DbName-AGSeed.trn'
    WITH FORMAT, INIT;
"@
} -ArgumentList $DbName

Write-LabLog "Recovery model set and seed backup taken." -Level SUCCESS -Step 'AG'

# ── Step 5: Restore seed backup on B-SQLSCCM (NORECOVERY) ───────────────────────
Write-LabLog "Restoring seed backup on B-SQLSCCM (NORECOVERY)..." -Step 'AG'

Invoke-LabRemote -IPAddress $SqlBIP -Credential $DomainCred -ScriptBlock {
    param($DbName, $SqlAFQDN)

    New-Item -ItemType Directory -Path 'C:\SQLBackup' -Force | Out-Null
    Copy-Item "\\$SqlAFQDN\C$\SQLBackup\$DbName-AGSeed.bak" 'C:\SQLBackup\' -Force
    Copy-Item "\\$SqlAFQDN\C$\SQLBackup\$DbName-AGSeed.trn" 'C:\SQLBackup\' -Force

    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
RESTORE DATABASE [$DbName]
    FROM DISK = N'C:\SQLBackup\$DbName-AGSeed.bak'
    WITH NORECOVERY, REPLACE, STATS = 10;
RESTORE LOG [$DbName]
    FROM DISK = N'C:\SQLBackup\$DbName-AGSeed.trn'
    WITH NORECOVERY;
"@
} -ArgumentList $DbName, $SqlAFQDN

Write-LabLog "Seed restore complete on B-SQLSCCM." -Level SUCCESS -Step 'AG'

# ── Step 6: Create AG on A-SQLSCCM ──────────────────────────────────────────────
Write-LabLog "Creating Availability Group '$AgName' (CLUSTER_TYPE = NONE)..." -Step 'AG'

Invoke-LabRemote -IPAddress $SqlAIP -Credential $DomainCred -ScriptBlock {
    param($AgName, $DbName, $SqlAFQDN, $SqlBFQDN, $Port)

    $agExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.availability_groups WHERE name = '$AgName'" `
                               -ServerInstance 'localhost'
    if ($agExists) {
        Write-Host "AG '$AgName' already exists — skipping creation."
        return
    }

    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
CREATE AVAILABILITY GROUP [$AgName]
WITH (
    CLUSTER_TYPE = NONE,
    AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE
)
FOR DATABASE [$DbName]
REPLICA ON
    N'$SqlAFQDN' WITH (
        ENDPOINT_URL     = N'TCP://$($SqlAFQDN):$Port',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE    = MANUAL,
        SEEDING_MODE     = MANUAL,
        SECONDARY_ROLE   (ALLOW_CONNECTIONS = NO)
    ),
    N'$SqlBFQDN' WITH (
        ENDPOINT_URL     = N'TCP://$($SqlBFQDN):$Port',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE    = MANUAL,
        SEEDING_MODE     = MANUAL,
        SECONDARY_ROLE   (ALLOW_CONNECTIONS = READ_ONLY)
    );
"@
} -ArgumentList $AgName, $DbName, $SqlAFQDN, $SqlBFQDN, $EndpointPort

Write-LabLog "AG '$AgName' created." -Level SUCCESS -Step 'AG'

# ── Step 7: Join B-SQLSCCM to the AG ────────────────────────────────────────────
Write-LabLog "Joining B-SQLSCCM to AG '$AgName'..." -Step 'AG'

Invoke-LabRemote -IPAddress $SqlBIP -Credential $DomainCred -ScriptBlock {
    param($AgName, $DbName)

    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
ALTER AVAILABILITY GROUP [$AgName] JOIN WITH (CLUSTER_TYPE = NONE);
"@

    Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName];
"@
} -ArgumentList $AgName, $DbName

Write-LabLog "B-SQLSCCM joined AG." -Level SUCCESS -Step 'AG'

# ── Step 8: Verify AG health ───────────────────────────────────────────────
Write-LabLog "Verifying AG health..." -Step 'AG'
Start-Sleep -Seconds 15

Invoke-LabRemote -IPAddress $SqlAIP -Credential $DomainCred -ScriptBlock {
    param($AgName)
    $health = Invoke-Sqlcmd -ServerInstance 'localhost' -Query @"
SELECT
    ag.name                         AS AGName,
    ars.role_desc                   AS Role,
    ars.operational_state_desc      AS OperationalState,
    ars.connected_state_desc        AS ConnectedState,
    ars.synchronization_health_desc AS SyncHealth,
    ar.availability_mode_desc       AS AvailMode,
    ar.failover_mode_desc           AS FailoverMode
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$AgName'
"@
    $health | Format-Table -AutoSize
} -ArgumentList $AgName

Write-LabLog "AG '$AgName' configured successfully." -Level SUCCESS -Step 'AG'
Write-LabLog "Mode: CLUSTER_TYPE = NONE | ASYNCHRONOUS | MANUAL failover" -Level INFO -Step 'AG'
