# Diagnostic plantages PC - cree le fichier rapport-diag.txt sur le Bureau.
# Se relance tout seul en administrateur. Fichier volontairement en ASCII (pas d'accents).

param([switch]$Silent)   # -Silent : pas de Bloc-notes ni de pause (utilise par la fenetre Diag-Ami)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$(if ($Silent) { ' -Silent' })"
    exit
}

$dir = [Environment]::GetFolderPath('Desktop')
if (-not (Test-Path $dir)) { $dir = $env:TEMP }
$out = Join-Path $dir 'rapport-diag.txt'

function Msg($m) { $s = ($m -replace '\s+', ' '); if ($s.Length -gt 170) { $s.Substring(0, 170) } else { $s } }
function Section($titre, [scriptblock]$code) {
    "`n===== $titre ====="
    try { & $code | Out-String -Width 220 } catch { "ERREUR: $($PSItem.Exception.Message)" }
}
function Ev($filter, $max = 40) {
    Get-WinEvent -FilterHashtable $filter -MaxEvents $max -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, @{n = 'Message'; e = { Msg $PSItem.Message } }
}

Write-Host "Diagnostic en cours (1 a 2 minutes)..." -ForegroundColor Cyan

& {
    "Rapport genere le $(Get-Date)"

    Section 'MATERIEL' {
        Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, MaxClockSpeed
        Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product
        Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate
        Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate
    }
    Section 'RAM (Speed = base, ConfiguredClockSpeed = profil EXPO/XMP actif si superieur)' {
        Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, @{n = 'GB'; e = { $PSItem.Capacity / 1GB } }, Speed, ConfiguredClockSpeed
    }
    Section 'WINDOWS' {
        Get-ComputerInfo -Property OsName, OsVersion, OsInstallDate, OsLastBootUpTime
        Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn
        powercfg /getactivescheme
    }
    Section 'DISQUES (sante)' {
        Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus
        Get-PhysicalDisk | Get-StorageReliabilityCounter | Select-Object DeviceId, Temperature, Wear, ReadErrorsTotal, WriteErrorsTotal, PowerOnHours
    }
    Section 'TEMPERATURES (zones ACPI, souvent vide : utiliser HWiNFO)' {
        Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue |
            Select-Object InstanceName, @{n = 'Celsius'; e = { [math]::Round(($PSItem.CurrentTemperature / 10) - 273.15, 1) } }
    }
    Section 'ARRETS BRUTAUX (Kernel-Power 41) par jour sur 60 jours' {
        Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 41; StartTime = (Get-Date).AddDays(-60) } -ErrorAction SilentlyContinue |
            Group-Object { $PSItem.TimeCreated.ToString('yyyy-MM-dd') } | Select-Object Count, Name
    }
    Section 'DETAIL DES 10 DERNIERS ARRETS (BugcheckCode 0 = coupure sans ecran bleu)' {
        Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 41 } -MaxEvents 10 -ErrorAction SilentlyContinue | ForEach-Object {
            $d = @{}; ([xml]$PSItem.ToXml()).Event.EventData.Data | ForEach-Object { $d[$PSItem.Name] = $PSItem.'#text' }
            '{0}  BugcheckCode={1}  PowerButton={2}' -f $PSItem.TimeCreated, $d.BugcheckCode, $d.PowerButtonTimestamp
        }
    }
    Section 'ECRANS BLEUS enregistres (WER 1001)' {
        Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } 10
    }
    Section 'ERREURS MATERIELLES WHEA (CPU/RAM/PCIe) 60 jours' {
        Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-60) } 20
    }
    Section 'PLANTAGES PILOTE GRAPHIQUE (TDR) 30 jours' {
        # Display 4125 = message HDR sans importance : on ne garde que les vrais timeouts (4101 et voisins)
        Ev @{LogName = 'System'; ProviderName = 'Display'; Id = 4101, 4102, 4103, 4116, 4117, 4118, 4119; StartTime = (Get-Date).AddDays(-60) } 20
        Ev @{LogName = 'System'; ProviderName = 'nvlddmkm', 'amdkmdag', 'amdwddmg'; StartTime = (Get-Date).AddDays(-60) } 20
    }
    Section 'RESULTAT DU TEST MEMOIRE WINDOWS' {
        Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } 5
    }
    Section 'ERREURS DISQUE / SYSTEME DE FICHIERS 30 jours' {
        Ev @{LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci', 'volmgr'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-30) } 20
    }
    Section 'PLANTAGES DE PROGRAMMES / JEUX (journal Application) 30 jours' {
        Get-WinEvent -FilterHashtable @{LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 40 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id,
                @{n = 'Programme'; e = { $PSItem.Properties[0].Value } },
                @{n = 'ModuleFautif'; e = { if ($PSItem.Id -eq 1000) { $PSItem.Properties[3].Value } } },
                @{n = 'CodeException'; e = { if ($PSItem.Id -eq 1000) { $PSItem.Properties[6].Value } } }
    }
    Section 'RAPPORTS D ERREUR WINDOWS (WER) 30 jours : jeux, pilotes, GPU' {
        Get-WinEvent -FilterHashtable @{LogName = 'Application'; ProviderName = 'Windows Error Reporting'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 15 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, @{n = 'Message'; e = { Msg $PSItem.Message } }
    }
    Section 'DUMPS MEMOIRE PRESENTS' {
        Get-ChildItem C:\Windows\Minidump, C:\Windows\MEMORY.DMP, C:\Windows\LiveKernelReports -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $PSItem.PSIsContainer } | Select-Object FullName, Length, LastWriteTime
        'Config dump :'
        Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' | Select-Object CrashDumpEnabled, AutoReboot
    }
    Section 'ERREURS SYSTEME 7 jours (regroupees, sans le bruit DCOM 10010)' {
        Get-WinEvent -FilterHashtable @{LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
            Where-Object { -not ($PSItem.ProviderName -like '*DistributedCOM*' -and $PSItem.Id -eq 10010) } |
            Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 20 Count, Name
    }
    Section 'DRIVERS INSTALLES CES 30 DERNIERS JOURS' {
        Get-CimInstance Win32_PnPSignedDriver | Where-Object { $PSItem.DriverDate -gt (Get-Date).AddDays(-30) } |
            Sort-Object DriverDate -Descending | Select-Object -First 15 DeviceName, DriverVersion, DriverDate
    }
} *> $out

Write-Host "Termine. Rapport : $out" -ForegroundColor Green
if (-not $Silent) {
    Write-Host "Envoie ce fichier (ou colle son contenu dans la conversation)."
    notepad $out
    Read-Host "Appuie sur Entree pour fermer"
}
