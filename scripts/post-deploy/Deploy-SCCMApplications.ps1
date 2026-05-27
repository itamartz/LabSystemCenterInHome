<#
.SYNOPSIS
    Downloads the latest 7-Zip + Notepad++, creates SCCM Applications with script
    deployment types, distributes content to the DP, and deploys them as REQUIRED to
    the 'All Servers' collection. Idempotent (check-exists). Run AFTER roles + collection.

.DESCRIPTION
    DSC GAP / EXCEPTION: ConfigMgrCBDsc has NO application resource, so application
    creation/deployment is the one part of SADAB SCCM config that is cmdlet-based rather
    than DSC-backed. It is still made idempotent here (Get-CM* checks before create), and
    is the documented exception to the "all SCCM config is DSC-backed" convention.

    Steps per app:
      1. Download the latest installer to a content source on A-SCCM (C:\Sources\Apps,
         shared as \\A-SCCM\Sources). 7-Zip = highest x64 EXE on 7-zip.org; Notepad++ =
         latest x64 Installer.exe from the GitHub releases API.
      2. New-CMApplication + Add-CMScriptDeploymentType (silent '/S', file-existence
         detection in C:\Program Files\...). ContentLocation MUST be UNC.
      3. Start-CMContentDistribution to the DP (A-MPDP).
      4. New-CMApplicationDeployment -DeployPurpose Required -CollectionName 'All Servers'.

    INSTALL GOTCHA (2026-05-24): on freshly-pushed clients the app auto-evaluation can
    stall (CCM_Application stays InstallState=Unknown, EvaluationState=0, no
    AppIntentEval.log) even though policy + assignment are present. Forcing the install
    via the client CCM_Application SDK 'Install' method reliably kicks it. See
    Invoke-SCCMAppInstallKick in the comment block at the bottom.

.NOTES
    Author  : SADAB Lab
    Version : 1.0 (cmdlet-based, idempotent; documented DSC exception).
    Run from the Hyper-V host. PS 5.1 only. Needs internet on A-SCCM (NAT switch).
#>
[CmdletBinding()]
param(
    [string]$SiteCode       = 'PR1',
    [string]$SiteServer     = 'A-SCCM.sadab.pri',
    [string]$CollectionName = 'All Servers',
    [string]$DistributionPoint = 'A-MPDP.sadab.pri',

    [string]$AdminPassword       = '',
    [string]$DomainAdminPassword = '',
    [string]$DSRMPassword        = '',
    [System.Management.Automation.PSCredential]$LocalCred  = $null,
    [System.Management.Automation.PSCredential]$DomainCred = $null
)

Import-Module "$PSScriptRoot\LabHelpers.psm1" -Force
$SccmAIP = '10.10.0.3'
if (-not $DomainCred) {
    if (-not $DomainAdminPassword) { throw "Provide -DomainCred or -DomainAdminPassword." }
    $DomainCred = New-Object System.Management.Automation.PSCredential('SADAB\Administrator',
        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force))
}

Write-LabLog "Downloading installers + creating/deploying 7-Zip & Notepad++ (Required -> $CollectionName)..." -Step 'Apps'
$results = Invoke-LabRemote -IPAddress $SccmAIP -Credential $DomainCred -ScriptBlock {
    param($SiteCode,$SiteServer,$CollectionName,$DistributionPoint)
    $ErrorActionPreference = 'Stop'; $CMPSSuppressFastNotUsedCheck = $true
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # 1. Download latest installers to the content source + share it
    $z='C:\Sources\Apps\7Zip'; $n='C:\Sources\Apps\NotepadPlusPlus'
    New-Item -ItemType Directory -Force -Path $z,$n | Out-Null
    if (-not (Get-SmbShare -Name 'Sources' -ErrorAction SilentlyContinue)) { New-SmbShare -Name 'Sources' -Path 'C:\Sources' -ReadAccess 'Everyone' | Out-Null }

    $dl = Invoke-WebRequest -UseBasicParsing 'https://www.7-zip.org/download.html'
    $zver = ([regex]::Matches($dl.Content,'a/7z(\d+)-x64\.exe') | ForEach-Object {[int]$_.Groups[1].Value} | Sort-Object -Descending -Unique)[0]
    $zfile = Join-Path $z "7z$zver-x64.exe"
    if (-not (Test-Path $zfile)) { Invoke-WebRequest -UseBasicParsing "https://www.7-zip.org/a/7z$zver-x64.exe" -OutFile $zfile }

    $rel = Invoke-RestMethod -UseBasicParsing -Headers @{'User-Agent'='sadab-lab'} 'https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -match 'Installer\.x64\.exe$' } | Select-Object -First 1
    $nfile = Join-Path $n $asset.name
    if (-not (Test-Path $nfile)) { Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $nfile }

    # 2-4. Apps, deployment types, distribution, deployment (idempotent)
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1')
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null }
    Set-Location "$($SiteCode):"

    $apps = @(
        @{ Name='7-Zip';    Pub='Igor Pavlov';    Ver=("{0}.{1:00}" -f [int]($zver/100),($zver%100)); Content='\\A-SCCM.sadab.pri\Sources\Apps\7Zip';            Cmd="`"$([IO.Path]::GetFileName($zfile))`" /S"; DetFile='7z.exe';        DetPath='C:\Program Files\7-Zip' }
        @{ Name='Notepad++'; Pub='Notepad++ Team'; Ver=($rel.tag_name -replace '^v','');               Content='\\A-SCCM.sadab.pri\Sources\Apps\NotepadPlusPlus'; Cmd="`"$($asset.name)`" /S";              DetFile='notepad++.exe'; DetPath='C:\Program Files\Notepad++' }
    )
    $out=@()
    foreach ($a in $apps) {
        $log=[ordered]@{App=$a.Name; Version=$a.Ver}
        if (-not (Get-CMApplication -Name $a.Name -ErrorAction SilentlyContinue)) { New-CMApplication -Name $a.Name -Publisher $a.Pub -SoftwareVersion $a.Ver | Out-Null; $log.App='created' } else { $log.App='exists' }
        if (-not (Get-CMDeploymentType -ApplicationName $a.Name -ErrorAction SilentlyContinue)) {
            $c = New-CMDetectionClauseFile -FileName $a.DetFile -Path $a.DetPath -Existence
            Add-CMScriptDeploymentType -ApplicationName $a.Name -DeploymentTypeName "$($a.Name) Script" -InstallCommand $a.Cmd -ContentLocation $a.Content -AddDetectionClause $c -InstallationBehaviorType InstallForSystem -LogonRequirementType WhetherOrNotUserLoggedOn | Out-Null
            $log.DT='created'
        } else { $log.DT='exists' }
        try { Start-CMContentDistribution -ApplicationName $a.Name -DistributionPointName $DistributionPoint -ErrorAction Stop; $log.Dist='started' } catch { $log.Dist='already/pending' }
        if (-not (Get-CMApplicationDeployment -Name $a.Name -CollectionName $CollectionName -ErrorAction SilentlyContinue)) {
            New-CMApplicationDeployment -Name $a.Name -CollectionName $CollectionName -DeployAction Install -DeployPurpose Required -UserNotification DisplaySoftwareCenterOnly -AvailableDateTime (Get-Date).AddDays(-1) -DeadlineDateTime (Get-Date).AddDays(-1) | Out-Null
            $log.Deploy='created'
        } else { $log.Deploy='exists' }
        $out += [pscustomobject]$log
    }
    $out
} -ArgumentList $SiteCode,$SiteServer,$CollectionName,$DistributionPoint

$results | Format-Table -AutoSize
Write-LabLog "Apps created + deployed Required to $CollectionName. Clients install on policy/eval." -Level SUCCESS -Step 'Apps'

<#
  --- Invoke-SCCMAppInstallKick (run inside each client if auto-eval stalls) ---
  After client install, app evaluation can stall (CCM_Application = Unknown). Force it:

      foreach ($g in '{00000000-0000-0000-0000-000000000021}','{00000000-0000-0000-0000-000000000121}') {
          Invoke-WmiMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList $g
      }
      Get-CimInstance -Namespace root\ccm\clientsdk -ClassName CCM_Application | Where-Object Id | ForEach-Object {
          Invoke-CimMethod -Namespace root\ccm\clientsdk -ClassName CCM_Application -MethodName Install -Arguments @{
              Id=$_.Id; Revision=$_.Revision; IsMachineTarget=[bool]$_.IsMachineTarget
              EnforcePreference=[uint32]0; Priority='High'; IsRebootIfNeeded=$false }
      }
#>
