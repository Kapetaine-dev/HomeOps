<#
.SYNOPSIS
  Synchronise le depot HomeOps entre PC via git : commit, pull --rebase, push.
.DESCRIPTION
  A lancer en arrivant (recuperer le travail de l'autre PC) et en partant
  (pousser le travail local). Garde-fou : refuse de committer si un fichier
  Office est ouvert (fichier de verrou ~$...).
.PARAMETER Message
  Message de commit personnalise. Par defaut : "sync <date heure>".
.PARAMETER Force
  Ignore l'avertissement sur les fichiers Office ouverts.
.EXAMPLE
  .\homeops-sync.ps1
.EXAMPLE
  .\homeops-sync.ps1 -Message "Ajout schema reseau"
#>
param(
    [string]$Message = "sync $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

Write-Host "== HomeOps sync ==" -ForegroundColor Cyan

# 1. Garde-fou : fichiers Office ouverts (verrou ~$...)
$locks = Get-ChildItem -Path . -Recurse -Filter '~$*' -Force -ErrorAction SilentlyContinue
if ($locks -and -not $Force) {
    Write-Host "ATTENTION : fichiers Office ouverts detectes :" -ForegroundColor Yellow
    $locks | ForEach-Object { Write-Host "  - $($_.FullName)" -ForegroundColor Yellow }
    Write-Host "Ferme-les puis relance, ou force avec : .\homeops-sync.ps1 -Force" -ForegroundColor Yellow
    exit 1
}

# 2. Committer d'abord le travail local (checkpoint avant de toucher au distant).
#    Indispensable : git pull --rebase refuse de tourner sur un arbre non commite.
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "-> commit : $Message" -ForegroundColor DarkGray
    git commit -m $Message | Out-Null
} else {
    Write-Host "Rien a committer en local." -ForegroundColor DarkGray
}

# 3. Recuperer le distant et rejouer le commit local par-dessus.
#    --autostash : filet de securite si un fichier non suivi subsiste.
Write-Host "-> git pull --rebase --autostash" -ForegroundColor DarkGray
git pull --rebase --autostash
if ($LASTEXITCODE -ne 0) {
    Write-Host "Conflit au rebase. Resous-le (git status), puis :" -ForegroundColor Red
    Write-Host "  git rebase --continue ; git push   (ou  git rebase --abort  pour annuler)" -ForegroundColor Red
    exit 1
}

# 4. Pousser (no-op si deja a jour)
Write-Host "-> git push" -ForegroundColor DarkGray
git push
if ($LASTEXITCODE -ne 0) {
    Write-Host "Echec du push." -ForegroundColor Red
    exit 1
}

Write-Host "Synchro terminee. A jour avec origin/main." -ForegroundColor Green
