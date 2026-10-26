# Gün 19 script'lerinin ortak yardımcıları. Gün 18'in _common.ps1'ini yükler (token alma, API isteği, rapor dosyası,
# Keycloak yönetim API'si). Doğrudan çalıştırılmaz.
. "$PSScriptRoot\..\gun18\_common.ps1"

# Bu güne özel volume'ler (staj-tasks_*-db-data-gun19); eski volume'lere dokunulmaz.
Use-Gun10Volumes 'gun19'
