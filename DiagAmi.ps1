# Diag-Ami : fenêtre d'aide au diagnostic de plantages (tutos + diagnostic + journal de surveillance).
# Se relance toute seule en administrateur. À lancer via Lancer.bat.

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$base      = $PSScriptRoot
$stateDir  = Join-Path $env:APPDATA 'DiagAmi'
$stateFile = Join-Path $stateDir 'etat.json'
$progDir   = 'C:\ProgramData\DiagAmi'
$hbScript  = Join-Path $progDir 'heartbeat.ps1'
$hbLog     = Join-Path $progDir 'heartbeat.csv'
$taskName  = 'DiagAmi-Journal'
$repoUrl   = 'https://github.com/Tryne-graphik/Diag-Ami'   # dépôt public : retours et rapports (tickets)
$githubUrl = "$repoUrl/issues"                              # page ouverte par le bouton « Retour / GitHub »
$script:lastAnalysis = ''

# ---------- Script du journal (écrit sur disque, lancé au démarrage par une tâche planifiée) ----------
$heartbeatCode = @'
$dir = 'C:\ProgramData\DiagAmi'; $log = "$dir\heartbeat.csv"
New-Item -ItemType Directory -Force $dir | Out-Null
$smi = @('C:\Windows\System32\nvidia-smi.exe', 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe') | Where-Object { Test-Path $PSItem } | Select-Object -First 1
function Write-Line($l) {
    $fs = New-Object IO.FileStream($log, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::WriteThrough)
    $sw = New-Object IO.StreamWriter($fs)
    $sw.WriteLine($l); $sw.Flush(); $fs.Flush($true); $sw.Dispose()
}
if (-not (Test-Path $log)) { Write-Line 'time,cpu,ram,topproc,topcpu,gpu_temp,gpu_util,gpu_power,gpu_mem' }
Write-Line ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ',BOOT,,,,,,,')
while ($true) {
    try {
        $cpu = [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        $os  = Get-CimInstance Win32_OperatingSystem
        $ram = [int](100 - 100 * $os.FreePhysicalMemory / $os.TotalVisibleMemorySize)
        $top = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $PSItem.Name -notin '_Total', 'Idle' } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 1
        $g = ',,,'
        if ($smi) { $r = & $smi --query-gpu=temperature.gpu,utilization.gpu,power.draw,memory.used --format=csv,noheader,nounits 2>$null; if ($r) { $g = ($r -replace '\s', '') } }
        Write-Line ('{0},{1},{2},{3},{4},{5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $cpu, $ram, ($top.Name -replace ',', ''), $top.PercentProcessorTime, $g)
    } catch {}
    if ((Get-Item $log).Length -gt 3MB) {
        $h = Get-Content $log -TotalCount 1; $keep = Get-Content $log -Tail 20000
        Set-Content $log (@($h) + $keep) -Encoding ASCII
    }
    Start-Sleep -Seconds 30
}
'@

# ---------- Fonctions ----------
function Test-Journal { [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) }

function Enable-Journal {
    New-Item -ItemType Directory -Force $progDir | Out-Null
    Set-Content -Path $hbScript -Value $heartbeatCode -Encoding UTF8
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hbScript`""
    $t = New-ScheduledTaskTrigger -AtStartup
    $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
}

function Disable-Journal {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

function Get-ReportPath {
    $d = [Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path $d)) { $d = $env:TEMP }
    Join-Path $d 'rapport-diag.txt'
}

function ConvertTo-Num($v) {
    $x = 0.0
    if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { $x } else { 0 }
}

function Get-Analyse {
    if (-not (Test-Path $hbLog)) { return "Le journal n'a pas encore de données.`nActive-le à l'étape 2, puis utilise le PC normalement (jeu compris) jusqu'au prochain plantage." }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $rows = @(Import-Csv $hbLog | Where-Object { $PSItem.time -match '^\d{4}-\d\d-\d\d' } | ForEach-Object {
            $PSItem | Add-Member -NotePropertyName t -NotePropertyValue ([datetime]::ParseExact($PSItem.time, 'yyyy-MM-dd HH:mm:ss', $inv)) -PassThru })
    if ($rows.Count -lt 2) { return "Journal encore trop court : laisse tourner le PC quelques minutes au moins." }
    $ev = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | ForEach-Object { $PSItem.TimeCreated })

    $lines = New-Object System.Collections.Generic.List[string]
    $nBrutal = 0; $nCharge = 0; $nRepos = 0; $nBoot = 0; $nNormal = 0
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $gap = ($rows[$i].t - $rows[$i - 1].t).TotalSeconds
        if ($gap -le 120) { continue }
        $a = $rows[$i - 1]; $end = $rows[$i].t
        $brutal = @($ev | Where-Object { $PSItem -gt $a.t -and $PSItem -lt $end.AddMinutes(3) }).Count -gt 0
        $mins = [math]::Round($gap / 60, 1)
        if (-not $brutal) { $nNormal++; continue }
        $nBrutal++
        if ($a.cpu -eq 'BOOT') {
            $nBoot++
            $detail = 'coupure dans les 30 premières secondes après le démarrage'
        } else {
            $detail = "CPU $($a.cpu)% | RAM $($a.ram)% | plus gourmand : $($a.topproc) ($($a.topcpu)%)"
            if ($a.gpu_temp) { $detail += " | GPU $($a.gpu_temp)°C, $($a.gpu_util)%, $($a.gpu_power) W" }
            if ((ConvertTo-Num $a.cpu) -ge 60 -or (ConvertTo-Num $a.gpu_util) -ge 60) { $nCharge++ } else { $nRepos++ }
        }
        $lines.Add("[COUPURE BRUTALE] dernier signe de vie $($a.t.ToString('yyyy-MM-dd HH:mm:ss')) (PC éteint $mins min)")
        $lines.Add("    $detail")
    }
    $head = @(
        "Journal du $($rows[0].t.ToString('yyyy-MM-dd HH:mm')) au $($rows[-1].t.ToString('yyyy-MM-dd HH:mm'))",
        "Coupures brutales : $nBrutal   (sous charge : $nCharge, au repos : $nRepos, juste après le démarrage : $nBoot)",
        "Arrêts / veilles normaux : $nNormal", '')
    $tail = @('')
    if ($nBrutal -eq 0) {
        $tail += "Aucune coupure brutale dans la période couverte par le journal. Bon signe si le PC a tourné longtemps et en jeu."
    } elseif (($nRepos + $nBoot) -gt $nCharge) {
        $tail += "Piste : les coupures arrivent surtout au repos ou au démarrage -> BIOS / mémoire (EXPO) / alimentation de la carte mère."
    } else {
        $tail += "Piste : les coupures arrivent surtout sous charge -> alimentation, câble de la carte graphique, températures."
    }
    ($head + $lines + $tail) -join "`r`n"
}

function Send-Report {
    $f = Join-Path $base 'diagnostic.ps1'
    if (-not (Test-Path $f)) { throw 'diagnostic.ps1 est introuvable à côté de DiagAmi.ps1.' }
    $ok = [Windows.Forms.MessageBox]::Show(
        "Le rapport (matériel, versions, erreurs Windows, journal) va être préparé puis copié.`n`nEnsuite, une page GitHub s'ouvre : tu colles le rapport (Ctrl+V) et tu valides. Il faut un compte GitHub gratuit.`n`nATTENTION : la page est PUBLIQUE, tout le monde pourra lire le rapport. Ton nom d'utilisateur Windows et le nom du PC sont remplacés automatiquement.`n`nContinuer ?",
        'Envoyer le rapport', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }

    Say 'Collecte en cours (1 à 2 minutes)...'
    $form.Cursor = 'WaitCursor'; $btn.Enabled = $false
    try {
        $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$f`"", '-Silent' -WindowStyle Hidden -PassThru
        while (-not $p.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
        $rp = Get-ReportPath
        $txt = if (Test-Path $rp) { Get-Content $rp -Raw } else { '(rapport-diag.txt introuvable)' }
        $script:lastAnalysis = Get-Analyse
        $txt += "`r`n===== ANALYSE DU JOURNAL =====`r`n" + $script:lastAnalysis
        foreach ($n in @($env:USERNAME, $env:COMPUTERNAME)) {
            if ($n -and $n.Length -ge 3) { $txt = $txt -replace [regex]::Escape($n), '<masqué>' }
        }
        if ($txt.Length -gt 60000) { $txt = $txt.Substring(0, 60000) + "`r`n[... tronqué ...]" }
        Set-Clipboard -Value $txt
        $copie = Join-Path (Split-Path $rp) 'rapport-a-envoyer.txt'
        Set-Content $copie $txt -Encoding UTF8
        $titre = [uri]::EscapeDataString("Rapport de diagnostic $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
        $corps = [uri]::EscapeDataString("Remplace cette ligne par le rapport : clique ici, Ctrl+V.")
        Start-Process "$repoUrl/issues/new?title=$titre&body=$corps"
        Say 'Rapport copié. Colle-le dans la page GitHub (Ctrl+V) puis « Submit new issue ».'
        [Windows.Forms.MessageBox]::Show("Rapport copié dans le presse-papiers.`n`nDans la page GitHub qui vient de s'ouvrir :`n1. Clique dans la grande zone de texte`n2. Ctrl+A puis Ctrl+V`n3. Clique « Submit new issue »`n`nUne copie est aussi sur le Bureau : $copie", 'Presque fini', 'OK', 'Information') | Out-Null
    } finally { $form.Cursor = 'Default'; $btn.Enabled = $true }
}

function Save-State {
    $done = @(for ($i = 0; $i -lt $list.Items.Count; $i++) { if ($list.GetItemChecked($i)) { $steps[$i].T } })
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    ConvertTo-Json -InputObject @($done) | Set-Content $stateFile -Encoding UTF8
}

function Say($m) { $lbl.Text = $m }

# ---------- Étapes (titre, tuto, bouton d'action) ----------
$steps = @(
    @{ T = '1. Lancer le diagnostic'; Btn = 'Lancer le diagnostic'
        Tuto = @'
Ce que ça fait : récupère le matériel, les versions (BIOS, pilotes), la santé des disques, les coups d'arrêt brutaux des 60 derniers jours, les erreurs matérielles et le résultat du test mémoire. Tout est écrit dans un fichier rapport-diag.txt sur le Bureau.

Comment faire :
1. Clique sur le bouton « Lancer le diagnostic » en bas.
2. Une fenêtre s'ouvre et travaille 1 à 2 minutes. Ne la ferme pas.
3. Le rapport s'ouvre tout seul dans le Bloc-notes à la fin.
4. Quand tu as fini les autres étapes, relance-le : on compare avant / après.

Rien n'est modifié sur ton PC : c'est de la lecture seule.
'@
        Do = {
            $f = Join-Path $base 'diagnostic.ps1'
            if (-not (Test-Path $f)) { throw 'diagnostic.ps1 est introuvable à côté de DiagAmi.ps1.' }
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$f`""
            Say 'Diagnostic lancé : le rapport s''ouvre dans le Bloc-notes dans 1 à 2 minutes.'
        } },

    @{ T = '2. Activer le journal de surveillance'
        Btn = { if (Test-Journal) { 'Désactiver le journal' } else { 'Activer le journal' } }
        Tuto = @'
Ce que ça fait : toutes les 30 secondes, le PC note discrètement la charge du processeur, la mémoire utilisée, le programme le plus gourmand et, pour la carte graphique NVIDIA, la température, la charge et la puissance.

Pourquoi : quand le PC se coupe d'un coup, la dernière ligne écrite avant la coupure montre ce qu'il faisait (jeu ? repos ?). Sans ça on devine.

Comment faire :
1. Clique sur « Activer le journal » en bas. (Il demande l'administrateur une seule fois.)
2. C'est tout : il se relance tout seul à chaque démarrage du PC, sans fenêtre, et ne ralentit rien.
3. Utilise le PC normalement, jeux compris, jusqu'au prochain plantage.
4. Étape 9 : « Analyser les plantages ».

Le journal est dans C:\ProgramData\DiagAmi\heartbeat.csv (3 Mo maximum). Pour l'arrêter, reviens sur cette étape et clique « Désactiver le journal ».

Limite : la température du processeur n'est pas lisible sans outil dédié, voir l'étape 8 (HWiNFO).
'@
        Do = {
            if (Test-Journal) { Disable-Journal; Say 'Journal désactivé.' } else { Enable-Journal; Say 'Journal activé : il enregistre toutes les 30 secondes, même après redémarrage.' }
        } },

    @{ T = '3. Vérifier le câble de la carte graphique'; Btn = $null
        Tuto = @'
La RTX 5080 consomme jusqu'à environ 360 W par un seul câble 12V-2x6. Un connecteur mal enfoncé suffit à couper le PC d'un coup, sans écran bleu : c'est exactement le symptôme.

Comment faire :
1. Éteins le PC, mets l'interrupteur du bloc d'alimentation sur 0 et débranche le cordon.
2. Ouvre le panneau latéral du boîtier.
3. Repère le câble qui va à la carte graphique (petit connecteur plat à 16 broches).
4. Débranche-le, regarde les broches (aucune trace de brûlé ni de plastique fondu), puis rebranche-le À FOND jusqu'au clic. Il ne doit laisser aucun jour entre le connecteur et la carte.
5. Ne plie pas le câble à moins de 3,5 cm du connecteur. Pas de coude serré.
6. Utilise le câble d'origine du bloc d'alimentation (pas l'adaptateur fourni avec la carte si tu as le choix).
7. Vérifie aussi les câbles 8 broches du processeur (en haut de la carte mère) : bien enfoncés.

Si tu vois une trace de brûlé ou de fusion sur un connecteur : n'utilise plus le PC et préviens-moi.
'@ },

    @{ T = '4. Brancher directement au mur'; Btn = $null
        Tuto = @'
Une multiprise, un onduleur usé ou un parasurtenseur fatigué peut couper le courant par à-coups.

Pour le test :
1. Branche le cordon du PC directement dans une prise murale (pas de multiprise, pas d'onduleur).
2. Vérifie que le cordon est bien enfoncé des deux côtés (prise et bloc d'alimentation).
3. Essaie une autre prise murale si possible, sur un autre circuit de la maison.

Si les coupures s'arrêtent, le problème venait de l'alimentation électrique, pas du PC.
'@ },

    @{ T = '5. Test de la mémoire (RAM)'; Btn = 'Lancer le test mémoire Windows'
        Tuto = @'
Ce que ça fait : Windows teste les barrettes de mémoire pendant quelques dizaines de minutes. Une RAM instable (surtout avec le profil EXPO 6000) peut couper le PC sans écran bleu.

Comment faire :
1. Ferme tes programmes et enregistre ton travail.
2. Clique sur « Lancer le test mémoire Windows » en bas, puis choisis « Redémarrer maintenant et rechercher d'éventuels problèmes ».
3. Le PC redémarre sur un écran bleu-gris de test. Laisse faire sans toucher (15 à 30 minutes). Il refait 2 passes par défaut.
4. Il redémarre ensuite seul et Windows affiche le résultat dans la zone de notification (en bas à droite). Si tu ne le vois pas, relance simplement le diagnostic (étape 1) : la section « Résultat du test mémoire » le contient.

Important : fais ce test AVANT de désactiver EXPO (étape 7), pour tester la configuration qui plante.
Pour un test encore plus sérieux : MemTest86 sur clé USB, toute une nuit.
'@
        Do = { Start-Process mdsched.exe; Say 'mdsched lancé : suis la fenêtre Windows qui s''ouvre.' } },

    @{ T = '6. Mettre à jour le BIOS MSI'; Btn = 'Ouvrir la page de support MSI'
        Tuto = @'
Ta version actuelle : 1.A20 (janvier 2025). C'est très vieux pour une carte X870E. Les mises à jour corrigent la stabilité de la mémoire et du processeur sur cette plateforme.

AVANT :
- Si le chiffrement BitLocker / chiffrement de l'appareil est activé, Windows peut demander une clé de récupération après la mise à jour. Récupère-la sur https://account.microsoft.com/devices/recoverykey ou suspends BitLocker avant, dans PowerShell (administrateur) :
    manage-bde -protectors -disable C:
- Ne fais pas la mise à jour pendant un orage ou si tu n'es pas sûr du courant.

1. Clique sur le bouton « Ouvrir la page de support MSI » et trouve la page de ta carte : MPG X870E EDGE TI WIFI, onglet BIOS.
2. Télécharge la version la plus récente (pas une version bêta).
3. Décompresse le fichier ZIP. Copie le fichier BIOS (pas le ZIP) à la racine d'une clé USB formatée en FAT32.
4. Redémarre le PC et appuie sur SUPPR pour entrer dans le BIOS.
5. Mode avancé (F7) -> M-FLASH. Il propose de redémarrer en mode flash : accepte, puis choisis le fichier BIOS sur la clé.
6. NE COUPE JAMAIS LE COURANT pendant la mise à jour. Le PC redémarre plusieurs fois, l'écran peut rester noir plusieurs minutes : c'est normal.
7. Après la mise à jour, retourne dans le BIOS (SUPPR), appuie sur F6 (Load Optimized Defaults), vérifie l'heure, puis F10 pour enregistrer.

Après ça, EXPO est désactivé par défaut : laisse-le comme ça (étape 7).
'@
        Do = { Start-Process 'https://www.google.com/search?q=MSI+MPG+X870E+EDGE+TI+WIFI+support+BIOS'; Say 'Recherche ouverte dans ton navigateur.' } },

    @{ T = '7. Désactiver EXPO (profil mémoire)'; Btn = $null
        Tuto = @'
Ta mémoire tourne à 6000 MHz grâce au profil EXPO au lieu de sa vitesse de base (4800 MHz). Sur les Ryzen 9000, ce profil est une cause fréquente de coupures sans écran bleu, surtout avec un vieux BIOS.

Comment faire :
1. Redémarre et appuie sur SUPPR pour entrer dans le BIOS.
2. Mode avancé (F7) -> onglet OC (ou « Overclocking »).
3. Cherche l'option « EXPO » (parfois « A-XMP ») et mets-la sur Disabled. À défaut, mets « DRAM Frequency » sur Auto.
4. F10 pour enregistrer et redémarrer.
5. Vérifie : relance le diagnostic (étape 1). Dans la section RAM, ConfiguredClockSpeed doit être 4800 (ou 5600).

Teste ensuite une journée complète. Si le PC ne plante plus, la cause était le profil mémoire. Tu pourras le réactiver plus tard, après la mise à jour du BIOS, et voir si ça tient.
'@ },

    @{ T = '8. Surveiller les températures (HWiNFO)'; Btn = 'Télécharger HWiNFO'
        Tuto = @'
Ce que ça fait : HWiNFO (gratuit) affiche en direct les températures et les tensions de tous les composants. On saura si quelque chose chauffe trop avant la coupure.

Comment faire :
1. Clique sur « Télécharger HWiNFO », installe-le (version 64 bits, Installer).
2. Lance-le et coche « Sensors-only » (uniquement les capteurs), puis Run.
3. Laisse la fenêtre ouverte en jouant (ou lance un jeu pendant 20 minutes).
4. Regarde ces valeurs et note les maximums :
   - CPU (Tctl/Tdie) : normal en jeu sous 85 °C, inquiétant au-dessus de 90 °C.
   - GPU Temperature : normal sous 80 °C. GPU Hot Spot sous 95 °C.
   - SSD (surtout le Samsung 9100 PRO) : inquiétant au-dessus de 75 °C.
   - Tensions 12V : doivent rester entre 11,8 et 12,2 V.
5. Pour garder une trace : clique l'icône « Start logging » en bas de la fenêtre des capteurs. Le fichier .CSV garde les dernières secondes avant une coupure : envoie-le moi.
'@
        Do = { Start-Process 'https://www.hwinfo.com/download/'; Say 'Page de téléchargement ouverte.' } },

    @{ T = '9. Analyser les plantages'; Btn = 'Analyser les plantages'
        Tuto = @'
À faire après au moins une journée d'utilisation normale avec le journal activé (étape 2).

Le bouton « Analyser les plantages » lit le journal et les événements Windows, et pour chaque coupure brutale te donne :
- l'heure du dernier signe de vie,
- la charge du processeur et de la mémoire à ce moment,
- le programme le plus gourmand,
- la température, la charge et la puissance de la carte graphique.

Il indique aussi si les coupures arrivent plutôt au repos ou sous charge, ce qui oriente la cause.

Quand tu as le résultat, clique sur « Copier le rapport + analyse » et colle-le dans la conversation avec Claude.
'@
        Do = {
            $script:lastAnalysis = Get-Analyse
            Show-Text '9. Analyse des plantages' $script:lastAnalysis
            Say 'Analyse terminée. Clique « Copier le rapport + analyse » pour l''envoyer.'
        } },

    @{ T = '10. Envoyer le rapport (tout automatique)'; Btn = 'Envoyer le rapport'
        Tuto = @'
Ce bouton fait tout :
1. il lance le diagnostic en arrière-plan (1 à 2 minutes),
2. il ajoute l'analyse du journal de surveillance,
3. il remplace ton nom d'utilisateur Windows et le nom du PC par « <masqué> »,
4. il copie le tout dans le presse-papiers,
5. il ouvre la page de dépôt de rapports sur GitHub.

Il te reste à faire, dans la page qui s'ouvre :
- cliquer dans la grande zone de texte, Ctrl+A puis Ctrl+V,
- cliquer sur le bouton vert « Submit new issue ».

Il faut un compte GitHub gratuit (github.com, « Sign up » si tu n'en as pas).

IMPORTANT : la page est publique, tout le monde peut lire le rapport (matériel, versions, erreurs Windows). Il ne contient ni mot de passe ni fichier personnel. Si ça te gêne, clique plutôt sur « Copier le rapport + analyse » et envoie-le en message privé.

Une copie du rapport est aussi enregistrée sur le Bureau (rapport-a-envoyer.txt).
'@
        Do = { Send-Report } }
)

# ---------- Fenêtre ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'Diag-Ami : aide au diagnostic de plantages'
$form.Size = New-Object Drawing.Size(1020, 700)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

$rtb = New-Object Windows.Forms.RichTextBox
$rtb.ReadOnly = $true; $rtb.BorderStyle = 'None'; $rtb.BackColor = [Drawing.Color]::White; $rtb.Dock = 'Fill'
$rtb.Font = New-Object Drawing.Font('Segoe UI', 11)
$pnl = New-Object Windows.Forms.Panel
$pnl.Dock = 'Fill'; $pnl.Padding = New-Object Windows.Forms.Padding(20, 16, 20, 8); $pnl.BackColor = [Drawing.Color]::White
$pnl.Controls.Add($rtb)

$list = New-Object Windows.Forms.CheckedListBox
$list.Dock = 'Left'; $list.Width = 330; $list.CheckOnClick = $true; $list.IntegralHeight = $false
$list.Font = New-Object Drawing.Font('Segoe UI', 11)
foreach ($s in $steps) { [void]$list.Items.Add($s.T) }

$bar = New-Object Windows.Forms.Panel
$bar.Dock = 'Bottom'; $bar.Height = 62; $bar.BackColor = [Drawing.Color]::FromArgb(240, 240, 240)
$btn = New-Object Windows.Forms.Button
$btn.Location = New-Object Drawing.Point(14, 12); $btn.Size = New-Object Drawing.Size(300, 38)
$btn.BackColor = [Drawing.Color]::FromArgb(0, 120, 212); $btn.ForeColor = [Drawing.Color]::White; $btn.FlatStyle = 'Flat'
$btnCopy = New-Object Windows.Forms.Button
$btnCopy.Location = New-Object Drawing.Point(326, 12); $btnCopy.Size = New-Object Drawing.Size(260, 38)
$btnCopy.Text = 'Copier le rapport + analyse'
$btnGit = New-Object Windows.Forms.Button
$btnGit.Location = New-Object Drawing.Point(598, 12); $btnGit.Size = New-Object Drawing.Size(170, 38)
$btnGit.Text = 'Retour / GitHub'
$lbl = New-Object Windows.Forms.Label
$lbl.Location = New-Object Drawing.Point(780, 6); $lbl.Size = New-Object Drawing.Size(215, 50)
$lbl.TextAlign = 'MiddleLeft'; $lbl.ForeColor = [Drawing.Color]::DimGray
$bar.Controls.AddRange(@($btn, $btnCopy, $btnGit, $lbl))

$form.Controls.Add($pnl)
$form.Controls.Add($list)
$form.Controls.Add($bar)

function Show-Text($titre, $corps) {
    $rtb.Clear()
    $rtb.SelectionFont = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
    $rtb.AppendText($titre + "`r`n`r`n")
    $rtb.SelectionFont = New-Object Drawing.Font('Segoe UI', 11)
    $rtb.AppendText($corps)
    $rtb.SelectionStart = 0
}

function Show-Step {
    $i = $list.SelectedIndex
    if ($i -lt 0) { return }
    $s = $steps[$i]
    Show-Text $s.T $s.Tuto
    if ($s.Btn) {
        $btn.Text = if ($s.Btn -is [scriptblock]) { & $s.Btn } else { $s.Btn }
        $btn.Visible = $true
    } else { $btn.Visible = $false }
}

$list.add_SelectedIndexChanged({ Show-Step })
$list.add_ItemCheck({
        param($sender, $e)
        $done = @(for ($i = 0; $i -lt $list.Items.Count; $i++) {
                $c = if ($i -eq $e.Index) { $e.NewValue -eq 'Checked' } else { $list.GetItemChecked($i) }
                if ($c) { $steps[$i].T }
            })
        try {
            New-Item -ItemType Directory -Force $stateDir | Out-Null
            ConvertTo-Json -InputObject @($done) | Set-Content $stateFile -Encoding UTF8
        } catch {}
        $form.Text = "Diag-Ami : $($done.Count)/$($steps.Count) étapes faites"
    })

$btn.add_Click({
        try {
            $s = $steps[$list.SelectedIndex]
            if ($s.Do) { & $s.Do }
            Show-Step
        } catch { [Windows.Forms.MessageBox]::Show($PSItem.Exception.Message, 'Erreur') | Out-Null }
    })

$btnCopy.add_Click({
        try {
            $txt = ''
            $rp = Get-ReportPath
            if (Test-Path $rp) { $txt += (Get-Content $rp -Raw) + "`r`n`r`n" } else { $txt += "(pas de rapport-diag.txt : lance l'étape 1)`r`n`r`n" }
            if (-not $script:lastAnalysis) { $script:lastAnalysis = Get-Analyse }
            $txt += "===== ANALYSE DU JOURNAL =====`r`n" + $script:lastAnalysis
            Set-Clipboard -Value $txt
            Say 'Copié. Colle-le (Ctrl+V) dans la conversation avec Claude.'
        } catch { [Windows.Forms.MessageBox]::Show($PSItem.Exception.Message, 'Erreur') | Out-Null }
    })

$btnGit.add_Click({
        try { Start-Process $githubUrl; Say 'GitHub ouvert dans ton navigateur.' }
        catch { [Windows.Forms.MessageBox]::Show($PSItem.Exception.Message, 'Erreur') | Out-Null }
    })

# État sauvegardé
try {
    if (Test-Path $stateFile) {
        $saved = @(Get-Content $stateFile -Raw | ConvertFrom-Json)
        for ($i = 0; $i -lt $steps.Count; $i++) { if ($saved -contains $steps[$i].T) { $list.SetItemChecked($i, $true) } }
    }
} catch {}
$list.SelectedIndex = 0
Show-Step
[void]$form.ShowDialog()
