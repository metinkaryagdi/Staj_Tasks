# Gün 26 script'lerinin ortak yardımcıları. Gün 25'in _common.ps1'ini yükler. Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun25\_common.ps1"

$OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\gun26'
New-Item -ItemType Directory -Force $OutputDir | Out-Null
