# Test yardımcısı: her isteğe sabit bir HTTP durum koduyla cevap veren geçici, yerel bir sahte ERP.
# Karşılaştırma script'inin simülatörden 200/404 dışında bir cevap aldığında ne yaptığını sınamak için kullanılır;
# uygulamalara ve docker ortamına dokunmaz. Doğrudan çalıştırılmaz: . "$PSScriptRoot\_fake-erp.ps1"
#   $fake = Start-FakeErp -StatusCode 500   ->  $fake.Url  (ör. http://127.0.0.1:53124)
#   $fake = Start-FakeErp -StatusCode 200 -Body '{'   ->  okunamayan (bozuk JSON) 200 cevabı
#   Stop-FakeErp $fake

function Start-FakeErp([int]$StatusCode = 500, [string]$Body) {
    if (-not $Body) { $Body = '{"title":"Sahte ERP: kontrollü hata","status":' + $StatusCode + '}' }
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port

    $runspace = [powershell]::Create()
    [void]$runspace.AddScript({
        param($listener, $code, $body)
        while ($true) {
            try { $client = $listener.AcceptTcpClient() } catch { break }
            try {
                $stream = $client.GetStream()
                $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') { }
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $head = "HTTP/1.1 $code Sahte`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            }
            catch { }
            finally { $client.Close() }
        }
    }).AddArgument($listener).AddArgument($StatusCode).AddArgument($Body)
    $handle = $runspace.BeginInvoke()

    [pscustomobject]@{ Url = "http://127.0.0.1:$port"; Listener = $listener; Runspace = $runspace; Handle = $handle }
}

function Stop-FakeErp($fake) {
    if (-not $fake) { return }
    try { $fake.Listener.Stop() } catch { }
    try { $fake.Runspace.Stop(); $fake.Runspace.Dispose() } catch { }
}
