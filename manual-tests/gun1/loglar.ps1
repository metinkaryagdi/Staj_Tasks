# Simülatörün loglarını gösterir. Her POST için seçilen davranış burada görünür.
#   .\manual-tests\gun1\loglar.ps1           -> canlı takip (durdurmak için Ctrl+C)
#   .\manual-tests\gun1\loglar.ps1 -Tail 50  -> son 50 satırı gösterip çıkar
param([int]$Tail = 0)
. "$PSScriptRoot\_common.ps1"

Push-Location $RepoRoot
try {
    if ($Tail -gt 0) { & docker compose logs erp-simulator --no-log-prefix --tail $Tail }
    else { & docker compose logs erp-simulator --no-log-prefix -f }
}
finally { Pop-Location }
