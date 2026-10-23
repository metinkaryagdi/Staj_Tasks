# Kontrol listesi 9 için: Keycloak'ı durdurur (bu sırada ekran açılır ve mesajın ekran görüntüsü alınır), -Baslat ile geri
# açar. Hiçbir container'ı yeniden yaratmaz. Açık yığında çalışır.
#   .\manual-tests\gun18\9-keycloak-durdur.ps1           (durdurur)
#   .\manual-tests\gun18\9-keycloak-durdur.ps1 -Baslat   (başlatır, realm'in yayımlanmasını bekler)
param([switch]$Baslat)
. "$PSScriptRoot\_common.ps1"

if (-not $Baslat) {
    Invoke-Compose @('stop', 'keycloak')
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Keycloak durduruldu. http://localhost:5100'ü açın ya da yenileyin, mesajın ekran görüntüsünü alın; sonra -Baslat ile çalıştırın."
}
else {
    Invoke-Compose @('start', 'keycloak')
    Wait-KeycloakAndService
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Keycloak açık, realm yayımlanıyor."
}
