# Diag-Ami

Petite fenêtre Windows pour diagnostiquer un PC qui plante : tutos pas à pas, diagnostic en un clic,
journal de surveillance (charge, température et puissance du GPU) et envoi du rapport.

## Installer et lancer (PowerShell, une seule ligne)

```powershell
mkdir $env:USERPROFILE\Diag-Ami -Force; irm https://raw.githubusercontent.com/Tryne-graphik/Diag-Ami/main/Lancer.bat -OutFile $env:USERPROFILE\Diag-Ami\Lancer.bat; & $env:USERPROFILE\Diag-Ami\Lancer.bat
```

`Lancer.bat` demande l'administrateur, se met à jour depuis ce dépôt, puis ouvre la fenêtre.
Ensuite, il suffit de double-cliquer sur `%USERPROFILE%\Diag-Ami\Lancer.bat`.

## Envoyer un rapport

Dans la fenêtre : étape **10. Envoyer le rapport**. Le rapport est copié, puis une page
[nouveau ticket](../../issues/new) s'ouvre : coller (Ctrl+V) et valider.
**Les tickets sont publics.** Le nom d'utilisateur Windows et le nom du PC sont masqués automatiquement.

## Contenu

| Fichier | Rôle |
|---|---|
| `Lancer.bat` | Droits admin, mise à jour, lancement |
| `DiagAmi.ps1` | La fenêtre (tutos, boutons) |
| `diagnostic.ps1` | Génère `rapport-diag.txt` (lecture seule, rien n'est modifié) |

Le journal de surveillance est une tâche planifiée (`DiagAmi-Journal`) qui écrit dans
`C:\ProgramData\DiagAmi\heartbeat.csv`. Elle se désactive depuis l'étape 2.
