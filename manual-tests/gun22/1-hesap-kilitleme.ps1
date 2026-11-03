# O11: kullanıcı adını bilen biri, şifreyi bilmeden, dakikada birkaç yanlış şifreyle bir hesabı sürekli kilitli tutabiliyor mu?
# Saldırgan yalnız token adresini kullanır (fatura-test client'ı, kullanıcı adı + yanlış şifre). Gerçek kullanıcı aynı
# süre boyunca doğru şifreyle giriş dener. Yönetim API'si yalnız gözlem içindir (kilit durumu), saldırıda kullanılmaz.
# Geçici kullanıcı gun22-kilit ile yapılır ve sonunda silinir. ~5,5 dk.
#   .\manual-tests\gun22\1-hesap-kilitleme.ps1
param([string]$Etiket = 'a-hesap-kilitleme', [int]$Dakika = 5)
. "$PSScriptRoot\_common.ps1"

New-Report $Etiket
Write-Title 'O11: hesap kilitleme ile girişin engellenmesi'
Start-Stack
Write-Line "Koşu: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$form = 'application/x-www-form-urlencoded'
function Get-Field([string]$Body, [string]$Name) { try { ($Body | ConvertFrom-Json).$Name } catch { $null } }

& "$PSScriptRoot\..\keycloak\test-client-ekle.ps1" -KeycloakUrl $KeycloakUrl | Out-Null
$realm = Get-Admin ''
Write-Line "Realm: bruteForceProtected=$($realm.bruteForceProtected), failureFactor=$($realm.failureFactor), waitIncrementSeconds=$($realm.waitIncrementSeconds), maxFailureWaitSeconds=$($realm.maxFailureWaitSeconds), permanentLockout=$($realm.permanentLockout)"

$name = 'gun22-kilit'
foreach ($u in @(Get-Admin "/users?username=$name&exact=true")) { if ($u.id) { [void](Send-Admin DELETE "/users/$($u.id)") } }
$password = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$created = Send-Admin POST '/users' (@{ username = $name; enabled = $true; email = "$name@fatura.test"; emailVerified = $true
    firstName = 'Gun22'; lastName = 'Kilit'; credentials = @(@{ type = 'password'; value = $password; temporary = $false }) } | ConvertTo-Json -Depth 4)
$userId = (Get-Admin "/users?username=$name&exact=true")[0].id
Write-Line "Geçici kullanıcı $name oluşturuldu: HTTP $($created.Status)"
$login = { param($Secret) Send-Http POST $TokenUrl @{} "grant_type=password&client_id=fatura-test&username=$name&password=$Secret" $form }

$before = & $login $password
Check ($before.Status -eq 200) "Saldırıdan önce doğru şifre: HTTP $($before.Status)"

# Saldırgan kilit süresini (waitIncrementSeconds, 60 sn) bilir: 5 yanlış şifre gönderir (1,5 sn arayla, Keycloak'ın 1 sn
# içindeki art arda denemeler için ayrı kuralına girmeden), 5.'den 60 sn sonra kilit açılınca yine 5 gönderir. Kilitliyken
# gönderilen yanlış şifre sayılmadığı ve başarılı giriş sayacı sıfırladığı için (ilk düzenin çıktısı,
# a-hesap-kilitleme-ilk-duzen.txt) saldırganın denemeleri kilidin açıldığı ana denk gelmeli. Gerçek kullanıcı her 10 sn'de
# doğru şifreyle dener.
Write-Line ''
Write-Line "$Dakika dk: saldırgan her kilit açılışında 5 yanlış şifre (1,5 sn arayla) gönderir; gerçek kullanıcı her 10 sn'de doğru şifreyle dener"
$started = Get-Date
$attackAt = 0.0; $burst = 0; $nextUser = 3.0
$attackerTries = 0; $userTries = 0; $userSuccess = 0
while (((Get-Date) - $started).TotalSeconds -lt $Dakika * 60) {
    $t = ((Get-Date) - $started).TotalSeconds
    if ($t -ge $attackAt) {
        [void](& $login 'yanlis-sifre'); $attackerTries++; $burst++
        if ($burst -eq 5) { $burst = 0; $attackAt = $t + 60; Write-Line ("  {0,5:0} sn  saldırgan 5. yanlış şifreyi gönderdi" -f $t) }
        else { $attackAt = $t + 1.5 }
    }
    elseif ($t -ge $nextUser) {
        $try = & $login $password
        $userTries++
        if ($try.Status -eq 200) { $userSuccess++ }
        $state = Get-Admin "/attack-detection/brute-force/users/$userId"
        Write-Line ("  {0,5:0} sn  gerçek kullanıcı: HTTP {1} {2,-14} kilit (gözlem): disabled={3}, numFailures={4}" -f `
            $t, $try.Status, (Get-Field $try.Body 'error'), $state.disabled, $state.numFailures)
        $nextUser += 10
    }
    Start-Sleep -Milliseconds 200
}

Write-Line ''
$minutes = ((Get-Date) - $started).TotalMinutes
Write-Line ("Saldırganın gönderdiği yanlış şifre: {0} ({1:0.0} dk'da, dakikada ~{2:0})" -f $attackerTries, $minutes, ($attackerTries / $minutes))
Check ($userSuccess -eq 0) "Gerçek kullanıcının doğru şifreyle girişi: $userTries denemenin $userSuccess'i başarılı"

[void](Send-Admin DELETE "/users/$userId")
Write-Line "Geçici kullanıcı silindi"
Save-Report
