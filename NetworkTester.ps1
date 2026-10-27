# NetworkTester - Windows 7/10/11, PowerShell 2.0+ compatible
$script:StopRequested = $false
$script:Running = $false
$script:LogLines = New-Object System.Collections.ArrayList
$script:Results = New-Object System.Collections.ArrayList
$script:FormsLoaded = $false
$script:RichLog = $null
$script:StatusLabel = $null
$script:PingHistory = New-Object System.Collections.ArrayList
$script:GraphBox = $null

$script:SettingsDir = Join-Path $env:APPDATA "NetworkTester"
$script:SettingsFile = Join-Path $script:SettingsDir "settings.txt"

function Write-Log {
    param([string]$Text, [string]$Level)
    if ($Level -eq $null -or $Level -eq "") { $Level = "Info" }
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[" + $ts + "] " + $Text
    [void]$script:LogLines.Add($line)
    if ($script:RichLog -ne $null) {
        $color = [System.Drawing.Color]::Black
        $bold = $false
        switch ($Level) {
            "OK"     { $color = [System.Drawing.Color]::Green }
            "Warn"   { $color = [System.Drawing.Color]::DarkOrange }
            "Fail"   { $color = [System.Drawing.Color]::Red }
            "Header" { $color = [System.Drawing.Color]::DarkBlue; $bold = $true }
        }
        $rtb = $script:RichLog
        $rtb.SelectionStart = $rtb.TextLength
        $rtb.SelectionLength = 0
        $rtb.SelectionColor = $color
        if ($bold) {
            $rtb.SelectionFont = New-Object System.Drawing.Font($rtb.Font, [System.Drawing.FontStyle]::Bold)
        } else {
            $rtb.SelectionFont = $rtb.Font
        }
        $rtb.AppendText($line + "`r`n")
        $rtb.SelectionColor = $rtb.ForeColor
        $rtb.ScrollToCaret()
    } else {
        Write-Host $line
    }
}

function Do-Events {
    if ($script:FormsLoaded) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-Status {
    param([string]$Text)
    if ($script:StatusLabel -ne $null) {
        $script:StatusLabel.Text = $Text
    }
    Do-Events
}

$script:StopLogged = $false
function Stop-Check {
    if ($script:StopRequested) {
        if (-not $script:StopLogged) {
            $script:StopLogged = $true
            Write-Log "Прекратено от потребителя." "Warn"
        }
        return $true
    }
    return $false
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $r = New-Object PSObject -Property @{ Name = $Name; Status = $Status; Detail = $Detail }
    [void]$script:Results.Add($r)
}

function Add-PingSample {
    param([double]$Rtt, [bool]$Lost)
    if ($Lost) {
        [void]$script:PingHistory.Add(-1.0)
    } else {
        [void]$script:PingHistory.Add($Rtt)
    }
    while ($script:PingHistory.Count -gt 300) {
        $script:PingHistory.RemoveAt(0)
    }
    if ($script:GraphBox -ne $null) {
        try { $script:GraphBox.Invalidate() } catch { }
    }
}

function Load-Settings {
    $s = @{}
    if (Test-Path $script:SettingsFile) {
        foreach ($line in (Get-Content $script:SettingsFile)) {
            $i = $line.IndexOf("=")
            if ($i -gt 0) {
                $s[$line.Substring(0, $i)] = $line.Substring($i + 1)
            }
        }
    }
    return $s
}

function Save-Settings {
    param([string]$Router, [string]$Server, [string]$Ports, [int]$PingCount, [int]$StabSec,
          [int]$LoadConnections, [int]$LoadSeconds, [string]$LoadFile,
          [int]$MonitorInterval, [int]$BeepOnProblem)
    try {
        if (-not (Test-Path $script:SettingsDir)) {
            [void](New-Item -ItemType Directory -Path $script:SettingsDir -Force)
        }
        $text = "RouterIP=" + $Router + "`r`n" +
                "ServerIP=" + $Server + "`r`n" +
                "ServerPorts=" + $Ports + "`r`n" +
                "PingCount=" + $PingCount + "`r`n" +
                "StabilitySeconds=" + $StabSec + "`r`n" +
                "LoadConnections=" + $LoadConnections + "`r`n" +
                "LoadSeconds=" + $LoadSeconds + "`r`n" +
                "LoadFile=" + $LoadFile + "`r`n" +
                "MonitorInterval=" + $MonitorInterval + "`r`n" +
                "BeepOnProblem=" + $BeepOnProblem + "`r`n"
        [System.IO.File]::WriteAllText($script:SettingsFile, $text, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Get-DefaultGateway {
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $props = $ni.GetIPProperties()
            foreach ($gw in $props.GatewayAddresses) {
                if ($gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    return $gw.Address.ToString()
                }
            }
        }
    } catch { }
    return ""
}

function Resolve-Target {
    param([string]$Target, [ref]$ResolvedName)
    $addr = $null
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$addr)) {
        return $addr
    }
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Target)
        foreach ($a in $addrs) {
            if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $ResolvedName.Value = $Target
                return $a
            }
        }
        if ($addrs.Count -gt 0) { $ResolvedName.Value = $Target; return $addrs[0] }
    } catch { }
    return $null
}

function Test-NetworkInfo {
    Write-Log "=== Информация за мрежата ===" "Header"
    $found = $false
    $hasGw = $false
    $hasWifi = $false
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $found = $true
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { $hasWifi = $true }
            $type = $ni.NetworkInterfaceType.ToString()
            $speedMbps = [int]($ni.Speed / 1000000)
            Write-Log ("Адаптер: " + $ni.Name)
            Write-Log ("  Описание: " + $ni.Description)
            Write-Log ("  Тип: " + $type + "   Скорост: " + $speedMbps + " Mbps")
            $props = $ni.GetIPProperties()
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $mask = ""
                    if ($ua.IPv4Mask -ne $null) { $mask = $ua.IPv4Mask.ToString() }
                    Write-Log ("  IPv4: " + $ua.Address.ToString() + "  Маска: " + $mask)
                }
            }
            foreach ($gw in $props.GatewayAddresses) {
                if ($gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $hasGw = $true
                    Write-Log ("  Шлюз: " + $gw.Address.ToString())
                }
            }
            foreach ($d in $props.DnsAddresses) {
                Write-Log ("  DNS: " + $d.ToString())
            }
            Do-Events
        }
    } catch {
        Write-Log ("Грешка при четене на мрежовата информация: " + $_.Exception.Message) "Fail"
        Add-Result "Информация за мрежата" "Fail" $_.Exception.Message
        return
    }
    if ($hasWifi) {
        try {
            $wlanLines = netsh wlan show interfaces
            if ($wlanLines -ne $null) {
                Write-Log "  --- Wi-Fi диагностика ---"
                $sigFound = $false
                foreach ($wl in $wlanLines) {
                    if (-not $sigFound -and $wl -match ":\s*(\d+)\s*%") {
                        $sigFound = $true
                        $sig = [int]$matches[1]
                        Write-Log ("  Wi-Fi сигнал: " + $sig + "%")
                        if ($sig -lt 50) {
                            Write-Log "  ВНИМАНИЕ: слаб Wi-Fi сигнал - честа причина за прекъсвания." "Warn"
                        }
                    }
                    if ($wl -match "Mbps|Мб") {
                        Write-Log ("  " + $wl.Trim())
                    } elseif ($wl -match "канал|hannel") {
                        Write-Log ("  " + $wl.Trim())
                    }
                }
            }
        } catch { }
    }
    if (-not $found) {
        Write-Log "Не са открити активни мрежови адаптери." "Fail"
        Add-Result "Информация за мрежата" "Fail" "Няма активен адаптер"
    } elseif (-not $hasGw) {
        Write-Log "ВНИМАНИЕ: не е открит шлюз по подразбиране." "Warn"
        Add-Result "Информация за мрежата" "Warn" "Няма шлюз"
    } else {
        Write-Log "Резултат: OK - открити са активни адаптери със шлюз." "OK"
        Add-Result "Информация за мрежата" "OK" "Адаптерите са активни"
    }
}

function Invoke-PingTest {
    param(
        [string]$Target,
        [int]$Count,
        [string]$Label,
        [double]$OkAvg,
        [double]$WarnAvg,
        [double]$WarnLoss
    )
    Write-Log ("=== " + $Label + " (" + $Target + ") ===") "Header"
    $resName = $null
    $addr = Resolve-Target $Target ([ref]$resName)
    if ($addr -eq $null) {
        Write-Log ("Не може да се разреши адресът: " + $Target) "Fail"
        Add-Result $Label "Fail" "DNS разрешаване неуспешно"
        return $null
    }
    if ($resName -ne $null -and $resName -ne "") {
        Write-Log ($Target + " -> " + $addr.ToString())
    }
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $sent = 0; $recv = 0; $lost = 0
    $rtts = New-Object System.Collections.ArrayList
    $chars = ""
    for ($i = 1; $i -le $Count; $i++) {
        if (Stop-Check) { return $null }
        $sent++
        try {
            $reply = $pinger.Send($addr, 1000)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $recv++
                [void]$rtts.Add([double]$reply.RoundtripTime)
                $chars += "."
            } else {
                $lost++
                $chars += "x"
            }
        } catch {
            $lost++
            $chars += "x"
        }
        if (($i % 10) -eq 0) { Write-Log ("  " + $chars); $chars = "" }
        Do-Events
        if ($i -lt $Count) { Start-Sleep -Milliseconds 200 }
    }
    if ($chars -ne "") { Write-Log ("  " + $chars) }
    $lossPct = 0.0
    if ($sent -gt 0) { $lossPct = [math]::Round(($lost * 100.0) / $sent, 1) }
    $status = "Fail"; $detail = ""
    if ($recv -gt 0) {
        $min = [double]$rtts[0]; $max = [double]$rtts[0]; $sum = 0.0
        foreach ($r in $rtts) {
            if ($r -lt $min) { $min = $r }
            if ($r -gt $max) { $max = $r }
            $sum += $r
        }
        $avg = $sum / $recv
        $jit = 0.0
        if ($rtts.Count -gt 1) {
            $jsum = 0.0
            for ($j = 1; $j -lt $rtts.Count; $j++) {
                $jsum += [math]::Abs($rtts[$j] - $rtts[$j - 1])
            }
            $jit = $jsum / ($rtts.Count - 1)
        }
        Write-Log ("Изпратени: " + $sent + "  Получени: " + $recv + "  Загубени: " + $lost + " (" + $lossPct + "%)")
        Write-Log ("RTT min/avg/max: " + [math]::Round($min,1) + " / " + [math]::Round($avg,1) + " / " + [math]::Round($max,1) + " ms   Джитър: " + [math]::Round($jit,1) + " ms")
        if ($lost -eq 0 -and $avg -lt $OkAvg) { $status = "OK" }
        elseif ($lossPct -le $WarnLoss -or $avg -lt $WarnAvg) { $status = "Warn" }
        else { $status = "Fail" }
        $detail = "загуби " + $lossPct + "%, avg " + [math]::Round($avg,1) + " ms"
    } else {
        Write-Log ("Изпратени: " + $sent + "  Получени: 0  Загубени: " + $lost + " (100%)")
        $detail = "няма отговор"
    }
    $verdictBg = @{ "OK" = "OK"; "Warn" = "ВНИМАНИЕ"; "Fail" = "ПРОБЛЕМ" }
    Write-Log ("Резултат: " + $verdictBg[$status] + " - " + $detail) $status
    Add-Result $Label $status $detail
    $r = New-Object PSObject -Property @{ Status = $status; LossPct = $lossPct }
    return $r
}

function Test-InternetPing {
    param([int]$Count, [bool]$RouterOk)
    $targets = @("8.8.8.8", "1.1.1.1")
    $allDead = $true
    foreach ($t in $targets) {
        if (Stop-Check) { return }
        $res = Invoke-PingTest -Target $t -Count $Count -Label ("Ping до интернет " + $t) -OkAvg 80 -WarnAvg 200 -WarnLoss 10
        if ($res -ne $null -and $res.Status -ne "Fail") { $allDead = $false }
        if ($res -ne $null -and $res.LossPct -lt 100) { $allDead = $false }
    }
    if ($allDead -and $RouterOk) {
        Write-Log "Рутерът отговаря, но няма интернет – проблем при доставчика или рутера." "Warn"
    }
}

function Test-Dns {
    Write-Log "=== DNS разрешаване ===" "Header"
    $names = @("google.com", "microsoft.com", "bg.wikipedia.org")
    $fail = 0; $maxMs = 0
    foreach ($n in $names) {
        if (Stop-Check) { return }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $false
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($n)
            $sw.Stop()
            if ($addrs.Count -gt 0) {
                $ok = $true
                Write-Log ("  " + $n + " -> " + $addrs[0].ToString() + "  (" + $sw.ElapsedMilliseconds + " ms)")
            } else {
                $sw.Stop()
                Write-Log ("  " + $n + " - няма отговор (" + $sw.ElapsedMilliseconds + " ms)") "Warn"
            }
        } catch {
            $sw.Stop()
            Write-Log ("  " + $n + " - ГРЕШКА: " + $_.Exception.Message) "Fail"
        }
        if (-not $ok) { $fail++ }
        if ($sw.ElapsedMilliseconds -gt $maxMs) { $maxMs = $sw.ElapsedMilliseconds }
        Do-Events
    }
    if ($fail -gt 0) {
        Write-Log "Резултат: ПРОБЛЕМ - има неуспешни DNS заявки." "Fail"
        Add-Result "DNS" "Fail" ("" + $fail + " неуспешни заявки")
    } elseif ($maxMs -gt 1000) {
        Write-Log ("Резултат: ВНИМАНИЕ - DNS е бавен (макс. " + $maxMs + " ms).") "Warn"
        Add-Result "DNS" "Warn" ("бавен отговор " + $maxMs + " ms")
    } else {
        Write-Log "Резултат: OK - всички имена се разрешават." "OK"
        Add-Result "DNS" "OK" "разрешаването работи"
    }
}

function Test-Http {
    Write-Log "=== HTTP достъп ===" "Header"
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 768
    } catch { }
    $urls = @("http://www.msftconnecttest.com/connecttest.txt", "https://www.google.com/generate_204")
    $ok = 0
    $tlsIssue = $false
    foreach ($u in $urls) {
        if (Stop-Check) { return }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $done = $false
        foreach ($m in @("HEAD", "GET")) {
            if ($done) { break }
            try {
                $req = [System.Net.WebRequest]::Create($u)
                $req.Method = $m
                $req.Timeout = 8000
                $resp = $req.GetResponse()
                $sw.Stop()
                $code = [int]$resp.StatusCode
                Write-Log ("  " + $u + " -> HTTP " + $code + "  (" + $sw.ElapsedMilliseconds + " ms)") "OK"
                $resp.Close()
                $ok++
                $done = $true
            } catch [System.Net.WebException] {
                $sw.Stop()
                $we = $_.Exception
                if ($we.Response -ne $null -and $m -eq "HEAD") { continue }
                if ($we.Response -ne $null) {
                    $code = [int]$we.Response.StatusCode
                    Write-Log ("  " + $u + " -> HTTP " + $code + "  (" + $sw.ElapsedMilliseconds + " ms)") "Warn"
                    $ok++
                } else {
                    $msg = $we.Message
                    if ($msg -match "SSL|TLS|secure channel|защитен канал") {
                        $tlsIssue = $true
                        Write-Log ("  " + $u + " - TLS грешка: " + $msg) "Warn"
                        Write-Log "  Старата версия на Windows/.NET не поддържа TLS 1.2 – това не е непременно проблем с връзката." "Warn"
                    } else {
                        Write-Log ("  " + $u + " - ГРЕШКА: " + $msg) "Fail"
                    }
                }
                $done = $true
            } catch {
                $sw.Stop()
                Write-Log ("  " + $u + " - ГРЕШКА: " + $_.Exception.Message) "Fail"
                $done = $true
            }
        }
        Do-Events
    }
    if ($ok -eq 0) {
        Write-Log "Резултат: ПРОБЛЕМ - няма HTTP достъп до интернет." "Fail"
        Add-Result "HTTP достъп" "Fail" "няма връзка"
    } elseif ($ok -eq 1 -and $tlsIssue) {
        Write-Log "Резултат: OK - HTTP достъпът е нормален (HTTPS е ограничен от старата TLS поддръжка на системата)." "OK"
        Add-Result "HTTP достъп" "OK" "работи (HTTPS ограничен от TLS)"
    } elseif ($ok -lt $urls.Count) {
        Write-Log "Резултат: ВНИМАНИЕ - частичен HTTP достъп." "Warn"
        Add-Result "HTTP достъп" "Warn" "част от заявките неуспешни"
    } else {
        Write-Log "Резултат: OK - HTTP достъпът е нормален." "OK"
        Add-Result "HTTP достъп" "OK" "достъпът работи"
    }
}

function Test-TcpPort {
    param([string]$Target, [int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ms = -1
    $open = $false
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $iar = $tcp.BeginConnect($Target, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000)) {
            try {
                $tcp.EndConnect($iar)
                $open = $true
                $sw.Stop()
                $ms = $sw.ElapsedMilliseconds
            } catch {
                $sw.Stop()
            }
        }
    } catch { }
    try { $tcp.Close() } catch { }
    $r = New-Object PSObject -Property @{ Open = $open; Ms = $ms }
    return $r
}

function Test-Ports {
    param([string]$Target, [string]$PortsCsv)
    Write-Log "=== Портове на сървъра ===" "Header"
    $ports = @()
    foreach ($p in ($PortsCsv -split ",")) {
        $p = $p.Trim()
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le 65535) {
            $ports += $n
        }
    }
    if ($ports.Count -eq 0) {
        Write-Log "Няма зададени валидни портове - тестът се пропуска." "Warn"
        return
    }
    $openCount = 0
    foreach ($port in $ports) {
        if (Stop-Check) { return }
        $r = Test-TcpPort $Target $port
        if ($r.Open) {
            $openCount++
            Write-Log ("  Порт " + $port + ": ОТВОРЕН  (" + $r.Ms + " ms)") "OK"
        } else {
            Write-Log ("  Порт " + $port + ": затворен/без отговор")
        }
        Do-Events
    }
    if ($openCount -gt 0) {
        Write-Log ("Резултат: OK - " + $openCount + " от " + $ports.Count + " порта са отворени.") "OK"
        Add-Result "Портове на сървъра" "OK" ("" + $openCount + "/" + $ports.Count + " отворени")
    } else {
        Write-Log "Резултат: ВНИМАНИЕ - всички портове са затворени. Възможно е сървърът просто да не предлага тези услуги." "Warn"
        Add-Result "Портове на сървъра" "Warn" "всички портове затворени"
    }
}

function Invoke-TraceRoute {
    param([string]$Target, [string]$Label)
    Write-Log ("=== " + $Label + " (" + $Target + ") ===") "Header"
    $resName = $null
    $addr = Resolve-Target $Target ([ref]$resName)
    if ($addr -eq $null) {
        Write-Log ("Не може да се разреши адресът: " + $Target) "Fail"
        Add-Result $Label "Fail" "DNS разрешаване неуспешно"
        return
    }
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $reached = $false
    for ($ttl = 1; $ttl -le 20; $ttl++) {
        if (Stop-Check) { return }
        $opts = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
        $msText = "*"
        $hopIp = "*"
        try {
            $reply = $pinger.Send($addr, 1500, (New-Object byte[] 32), $opts)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success -or
                $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired) {
                $hopIp = $reply.Address.ToString()
                $msText = $reply.RoundtripTime.ToString() + " ms"
            }
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $reached = $true }
        } catch { }
        Write-Log ("  " + ("{0,3}" -f $ttl) + "  " + ("{0,-18}" -f $hopIp) + "  " + $msText)
        Do-Events
        if ($reached) { break }
    }
    if ($reached) {
        Write-Log "Резултат: OK - целта е достигната." "OK"
        Add-Result $Label "OK" "целта достигната"
    } else {
        Write-Log "Резултат: ВНИМАНИЕ - целта не е достигната в рамките на 20 скока." "Warn"
        Add-Result $Label "Warn" "не е достигната за 20 скока"
    }
}

function Test-Stability {
    param([int]$Seconds, [string]$RouterIp, [string]$ServerTarget)
    Write-Log ("=== Тест за стабилност (" + $Seconds + " сек.) ===") "Header"
    $targets = New-Object System.Collections.ArrayList
    if ($RouterIp -ne "") { [void]$targets.Add($RouterIp) }
    if ($ServerTarget -ne "") { [void]$targets.Add($ServerTarget) }
    [void]$targets.Add("8.8.8.8")
    $resolved = @{}
    foreach ($t in $targets) {
        $resName = $null
        $a = Resolve-Target $t ([ref]$resName)
        if ($a -ne $null) { $resolved[$t] = $a }
    }
    $stats = @{}
    foreach ($t in $targets) {
        $stats[$t] = New-Object PSObject -Property @{
            Sent = 0; Lost = 0; MaxRtt = 0.0; SumRtt = 0.0; RttCount = 0;
            Spikes = 0; Streak = 0; MaxStreak = 0
        }
    }
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $startTime = [DateTime]::Now
    $end = $startTime.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $end) {
        if (Stop-Check) { return }
        $remaining = [int](($end - [DateTime]::Now).TotalSeconds)
        Set-Status ("Тест за стабилност... остават " + $remaining + " сек.")
        foreach ($t in $targets) {
            if ($script:StopRequested) { break }
            if (-not $resolved.ContainsKey($t)) { continue }
            $s = $stats[$t]
            $s.Sent++
            $rtt = $null
            try {
                $reply = $pinger.Send($resolved[$t], 1000)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $rtt = [double]$reply.RoundtripTime
                }
            } catch { }
            if ($rtt -eq $null) {
                $s.Lost++
                $s.Streak++
                if ($s.Streak -gt $s.MaxStreak) { $s.MaxStreak = $s.Streak }
            } else {
                $s.Streak = 0
                if ($rtt -gt $s.MaxRtt) { $s.MaxRtt = $rtt }
                if ($s.RttCount -gt 0) {
                    $runAvg = $s.SumRtt / $s.RttCount
                    if ($rtt -gt ($runAvg * 3) -and $rtt -gt 50) { $s.Spikes++ }
                }
                $s.SumRtt += $rtt
                $s.RttCount++
            }
            Do-Events
        }
        Start-Sleep -Milliseconds 500
    }
    $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
    foreach ($t in $targets) {
        $s = $stats[$t]
        $lossPct = 0.0
        if ($s.Sent -gt 0) { $lossPct = [math]::Round(($s.Lost * 100.0) / $s.Sent, 1) }
        $interval = 0.5
        if ($s.Sent -gt 0 -and $elapsed -gt 0) { $interval = $elapsed / $s.Sent }
        $streakSec = [math]::Round($s.MaxStreak * $interval, 1)
        $avg = 0.0
        if ($s.RttCount -gt 0) { $avg = $s.SumRtt / $s.RttCount }
        Write-Log ("  " + $t + ": изпратени " + $s.Sent + ", загубени " + $s.Lost + " (" + $lossPct + "%), avg " + [math]::Round($avg,1) + " ms, max " + [math]::Round($s.MaxRtt,1) + " ms, пикове " + $s.Spikes + ", най-дълго прекъсване ~" + $streakSec + " сек.")
        if ($s.Lost -eq 0 -and $s.MaxStreak -eq 0) {
            Add-Result ("Стабилност " + $t) "OK" "без загуби"
        } elseif ($lossPct -lt 2 -and $streakSec -lt 2) {
            Add-Result ("Стабилност " + $t) "Warn" ("загуби " + $lossPct + "%")
        } else {
            Write-Log ("  ПРОБЛЕМ при " + $t + " - прекъсвания на връзката.") "Fail"
            Add-Result ("Стабилност " + $t) "Fail" "прекъсвания на връзката"
        }
    }
}

function Save-LogToFile {
    param([string]$Path)
    try {
        $text = ($script:LogLines -join "`r`n")
        [System.IO.File]::WriteAllText($Path, $text, [System.Text.Encoding]::UTF8)
        return $true
    } catch {
        Write-Log ("Неуспешен запис на лога: " + $_.Exception.Message) "Fail"
        return $false
    }
}

function Write-Summary {
    Write-Log "=== ОБЩА ОЦЕНКА ===" "Header"
    $hasFail = $false; $hasWarn = $false
    foreach ($r in $script:Results) {
        $v = @{ "OK" = "OK"; "Warn" = "ВНИМАНИЕ"; "Fail" = "ПРОБЛЕМ" }[$r.Status]
        Write-Log ("  " + ("{0,-28}" -f $r.Name) + " " + ("{0,-10}" -f $v) + " " + $r.Detail) $r.Status
        if ($r.Status -eq "Fail") { $hasFail = $true }
        if ($r.Status -eq "Warn") { $hasWarn = $true }
    }
    if ($hasFail) {
        Write-Log "ОБЩА ОЦЕНКА: ПРОБЛЕМ - има открити проблеми в мрежовата връзка." "Fail"
    } elseif ($hasWarn) {
        Write-Log "ОБЩА ОЦЕНКА: ВНИМАНИЕ - връзката работи, но има отклонения." "Warn"
    } else {
        Write-Log "ОБЩА ОЦЕНКА: Връзката е стабилна." "OK"
    }
}

function Complete-TestRun {
    param($Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon)
    if ($script:LogLines.Count -gt 0) {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $stamp = [DateTime]::Now.ToString("yyyy-MM-dd_HH-mm-ss")
        $logPath = Join-Path $desktop ("NetworkTester_" + $stamp + ".txt")
        if (Save-LogToFile $logPath) {
            Write-Log ("Логът е запазен в: " + $logPath) "OK"
        }
    }
    $script:Running = $false
    $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
    $Progress.Value = 0
    $BtnStart.Enabled = $true
    if ($BtnLoad -ne $null) { $BtnLoad.Enabled = $true }
    if ($BtnQuick -ne $null) { $BtnQuick.Enabled = $true }
    if ($BtnScan -ne $null) { $BtnScan.Enabled = $true }
    if ($BtnMon -ne $null) { $BtnMon.Enabled = $true }
    $BtnStop.Enabled = $false
    Set-Status "Готово."
}

function Test-MtuPing {
    param([string]$Target)
    Write-Log "=== Големи пакети / MTU ===" "Header"
    $resName = $null
    $addr = Resolve-Target $Target ([ref]$resName)
    if ($addr -eq $null) {
        Write-Log ("Не може да се разреши адресът: " + $Target) "Fail"
        Add-Result "Големи пакети / MTU" "Fail" "DNS разрешаване неуспешно"
        return
    }
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $totalSent = 0
    $totalLost = 0
    $plain1472recv = 0
    foreach ($size in @(1472, 4000, 16000, 32000)) {
        if (Stop-Check) { return }
        $buf = New-Object byte[] $size
        $opts = New-Object System.Net.NetworkInformation.PingOptions(128, $false)
        $recv = 0
        $sum = 0.0
        for ($i = 0; $i -lt 5; $i++) {
            if (Stop-Check) { return }
            $totalSent++
            try {
                $reply = $pinger.Send($addr, 1200, $buf, $opts)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $recv++
                    $sum += [double]$reply.RoundtripTime
                } else {
                    $totalLost++
                }
            } catch {
                $totalLost++
            }
            Do-Events
        }
        if ($size -eq 1472) { $plain1472recv = $recv }
        $avg = 0.0
        if ($recv -gt 0) { $avg = $sum / $recv }
        Write-Log ("  Размер " + $size + " байта: получени " + $recv + "/5, avg " + [math]::Round($avg,1) + " ms")
    }
    # Проверка за MTU проблем - пакети със забранена фрагментация (DF)
    $dfOk = 0
    $tooBig = $false
    $buf = New-Object byte[] 1472
    $opts = New-Object System.Net.NetworkInformation.PingOptions(128, $true)
    for ($i = 0; $i -lt 3; $i++) {
        if (Stop-Check) { return }
        try {
            $reply = $pinger.Send($addr, 1200, $buf, $opts)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $dfOk++
            } elseif ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::PacketTooBig) {
                $tooBig = $true
            }
        } catch { }
        Do-Events
    }
    $mtuIssue = $false
    if ($tooBig -or ($dfOk -eq 0 -and $plain1472recv -gt 0)) { $mtuIssue = $true }
    if ($mtuIssue) {
        Write-Log "  ВНИМАНИЕ: пакети със забранена фрагментация не минават - вероятен MTU проблем" "Warn"
    }
    $lossPct = 0.0
    if ($totalSent -gt 0) { $lossPct = [math]::Round(($totalLost * 100.0) / $totalSent, 1) }
    $status = "OK"
    if ($lossPct -ge 20) { $status = "Fail" }
    elseif ($lossPct -gt 0) { $status = "Warn" }
    if ($mtuIssue -and $status -eq "OK") { $status = "Warn" }
    $detail = "загуби " + $lossPct + "%"
    if ($mtuIssue) { $detail = $detail + ", MTU проблем" }
    $verdictBg = @{ "OK" = "OK"; "Warn" = "ВНИМАНИЕ"; "Fail" = "ПРОБЛЕМ" }
    Write-Log ("Резултат: " + $verdictBg[$status] + " - " + $detail) $status
    Add-Result "Големи пакети / MTU" $status $detail
}

function Test-TcpBurst {
    param([string]$Target, [string]$PortsCsv, [int]$Connections)
    Write-Log "=== Паралелни TCP връзки ===" "Header"
    Write-Log ("  Симулира " + $Connections + " работни станции, свързващи се едновременно.")
    $ports = @()
    foreach ($p in ($PortsCsv -split ",")) {
        $p = $p.Trim()
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le 65535) {
            $ports += $n
        }
    }
    $openPorts = @()
    foreach ($port in $ports) {
        if (Stop-Check) { return }
        $r = Test-TcpPort $Target $port
        if ($r.Open) { $openPorts += $port }
        Do-Events
    }
    if ($openPorts.Count -eq 0) {
        Write-Log "  Няма отворени портове - тестът се пропуска." "Warn"
        return
    }
    $port = $openPorts[0]
    $clients = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Connections; $i++) {
        if (Stop-Check) {
            foreach ($e in $clients) { if ($e.Tcp -ne $null) { try { $e.Tcp.Close() } catch { } } }
            return
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        $entry = $null
        try {
            $iar = $tcp.BeginConnect($Target, $port, $null, $null)
            $entry = New-Object PSObject -Property @{ Tcp = $tcp; Iar = $iar; Done = $false; Ok = $false; Ms = 0 }
        } catch {
            try { $tcp.Close() } catch { }
            $entry = New-Object PSObject -Property @{ Tcp = $null; Iar = $null; Done = $true; Ok = $false; Ms = 0 }
        }
        [void]$clients.Add($entry)
        Do-Events
    }
    $deadline = [DateTime]::Now.AddMilliseconds(8000)
    $pending = 0
    foreach ($e in $clients) { if (-not $e.Done) { $pending++ } }
    while ($pending -gt 0 -and [DateTime]::Now -lt $deadline) {
        if (Stop-Check) {
            foreach ($e in $clients) { if ($e.Tcp -ne $null) { try { $e.Tcp.Close() } catch { } } }
            return
        }
        foreach ($e in $clients) {
            if ($e.Done) { continue }
            $finished = $false
            try { if ($e.Iar.AsyncWaitHandle.WaitOne(0)) { $finished = $true } } catch { $finished = $true }
            if ($finished) {
                $e.Done = $true
                $e.Ms = [int]$sw.ElapsedMilliseconds
                try {
                    $e.Tcp.EndConnect($e.Iar)
                    $e.Ok = $true
                } catch { }
                $pending--
            }
        }
        Do-Events
        Start-Sleep -Milliseconds 5
    }
    foreach ($e in $clients) {
        if ($e.Tcp -ne $null) { try { $e.Tcp.Close() } catch { } }
    }
    $ok = 0; $fail = 0; $min = 0; $max = 0; $sum = 0.0
    $first = $true
    foreach ($e in $clients) {
        if ($e.Ok) {
            $ok++
            if ($first -or $e.Ms -lt $min) { $min = $e.Ms }
            if ($first -or $e.Ms -gt $max) { $max = $e.Ms }
            $sum += $e.Ms
            $first = $false
        } else {
            $fail++
        }
    }
    $total = $clients.Count
    $avg = 0.0
    if ($ok -gt 0) { $avg = $sum / $ok }
    Write-Log ("  Порт " + $port + ": успешни " + $ok + "/" + $total + ", отхвърлени/таймаут " + $fail + ", connect време " + $min + "/" + [math]::Round($avg,0) + "/" + $max + " ms")
    $failPct = 0.0
    if ($total -gt 0) { $failPct = ($fail * 100.0) / $total }
    if ($fail -eq 0 -and $avg -lt 50) {
        Write-Log "Резултат: OK - всички едновременни връзки са успешни и бързи." "OK"
        Add-Result "Паралелни TCP връзки" "OK" ("" + $ok + "/" + $total + " успешни")
    } elseif ($failPct -le 10 -or $avg -lt 200) {
        Write-Log ("Резултат: ВНИМАНИЕ - " + $fail + " неуспешни или забавени връзки.") "Warn"
        Add-Result "Паралелни TCP връзки" "Warn" ("" + $fail + " неуспешни, avg " + [math]::Round($avg,0) + " ms")
    } else {
        Write-Log "Резултат: ПРОБЛЕМ - сървърът не издържа едновременни връзки." "Fail"
        Add-Result "Паралелни TCP връзки" "Fail" ("" + $fail + "/" + $total + " неуспешни")
    }
}

function Test-LoadLatency {
    param([string]$Target, [string]$PortsCsv, [int]$Connections, [int]$Seconds, [string]$LoadFile)
    Write-Log ("=== Натоварване и латентност (" + $Seconds + " сек.) ===") "Header"
    $resName = $null
    $addr = Resolve-Target $Target ([ref]$resName)
    if ($addr -eq $null) {
        Write-Log ("Не може да се разреши адресът: " + $Target) "Fail"
        Add-Result "Натоварване/латентност" "Fail" "DNS разрешаване неуспешно"
        return
    }
    $pinger = New-Object System.Net.NetworkInformation.Ping

    # --- Стъпка A: базова линия ---
    $baseSum = 0.0; $baseMax = 0.0; $baseRecv = 0
    for ($i = 0; $i -lt 10; $i++) {
        if (Stop-Check) { return }
        try {
            $reply = $pinger.Send($addr, 800)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $rtt = [double]$reply.RoundtripTime
                $baseSum += $rtt
                if ($rtt -gt $baseMax) { $baseMax = $rtt }
                $baseRecv++
            }
        } catch { }
        Do-Events
        if ($i -lt 9) { Start-Sleep -Milliseconds 150 }
    }
    if ($baseRecv -eq 0) {
        Write-Log "  Сървърът не отговаря на ping - тестът се пропуска." "Warn"
        return
    }
    $baseAvg = $baseSum / $baseRecv
    Write-Log ("  Базова линия: avg " + [math]::Round($baseAvg,1) + " ms, max " + [math]::Round($baseMax,1) + " ms")

    # --- Стъпка B: подготовка на източниците на натоварване ---
    $workers = New-Object System.Collections.ArrayList
    if ($LoadFile -ne $null -and $LoadFile -match "^https?://") {
        try { [System.Net.ServicePointManager]::DefaultConnectionLimit = 100 } catch { }
        $maxW = $Connections
        if ($maxW -gt 10) { $maxW = 10 }
        for ($i = 0; $i -lt $maxW; $i++) {
            $w = New-Object PSObject -Property @{
                Kind = "http"; State = "idle"; Req = $null; Iar = $null
                Resp = $null; Stream = $null; Buf = (New-Object byte[] 65536)
                ReadIar = $null; Bytes = 0L; Fails = 0; Retired = $false
            }
            [void]$workers.Add($w)
        }
        Write-Log ("  HTTP натоварване: " + $maxW + " паралелни сваляния на " + $LoadFile)
    } elseif ($LoadFile -ne $null -and $LoadFile.StartsWith("\\")) {
        $maxW = $Connections
        if ($maxW -gt 6) { $maxW = 6 }
        for ($i = 0; $i -lt $maxW; $i++) {
            $w = New-Object PSObject -Property @{
                Kind = "unc"; State = "idle"; Fs = $null
                Buf = (New-Object byte[] 65536); ReadIar = $null
                Bytes = 0L; Fails = 0; Retired = $false; SyncMode = $false
            }
            [void]$workers.Add($w)
        }
        Write-Log ("  Файлово натоварване: " + $maxW + " паралелни четения на " + $LoadFile)
    } elseif ($LoadFile -ne $null -and $LoadFile.Trim() -ne "") {
        Write-Log "  Тестовият файл не започва с http://, https:// или \\ - ще се ползва само TCP/ping натоварване." "Warn"
    } else {
        Write-Log "  Не е зададен тестов файл - натоварването е от TCP връзки и големи ping пакети."
    }

    $churnPort = 0
    $openPorts = @()
    foreach ($p in ($PortsCsv -split ",")) {
        if (Stop-Check) { break }
        $p = $p.Trim()
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le 65535) {
            $r = Test-TcpPort $Target $n
            if ($r.Open) { $openPorts += $n }
            Do-Events
        }
    }
    if ($openPorts.Count -gt 0) { $churnPort = $openPorts[0] }
    $churn = New-Object System.Collections.ArrayList
    $churnMax = $Connections
    if ($churnMax -gt 20) { $churnMax = 20 }
    $churnDone = 0
    $churnFail = 0

    $jumboBuf = New-Object byte[] 32000
    $jumboOpts = New-Object System.Net.NetworkInformation.PingOptions(128, $false)
    $jumboSent = 0
    $jumboLost = 0

    # --- Стъпка C: цикъл на натоварване и измерване ---
    $loadRtts = New-Object System.Collections.ArrayList
    $loadSent = 0
    $loadLost = 0
    $spikes = 0
    $workerErrors = 0
    $stopped = $false
    $startTime = [DateTime]::Now
    $end = $startTime.AddSeconds($Seconds)
    $nextPing = $startTime
    $iter = 0
    while ([DateTime]::Now -lt $end) {
        if (Stop-Check) { $stopped = $true; break }
        $iter++

        # поддръжка на файловите работници
        foreach ($w in $workers) {
            if ($w.Retired) { continue }
            if ($w.Fails -ge 3) {
                $w.Retired = $true
                Write-Log ("  Работник (" + $w.Kind + ") е спрян след 3 поредни грешки.") "Warn"
                continue
            }
            if ($w.Kind -eq "http") {
                if ($w.State -eq "idle") {
                    $w.Req = $null; $w.Iar = $null; $w.Resp = $null; $w.Stream = $null; $w.ReadIar = $null
                    try {
                        $req = [System.Net.WebRequest]::Create($LoadFile)
                        $req.Timeout = 8000
                        $req.ReadWriteTimeout = 4000
                        $req.Method = "GET"
                        $w.Req = $req
                        $w.Iar = $req.BeginGetResponse($null, $null)
                        $w.State = "connecting"
                    } catch {
                        $w.Fails++
                        $workerErrors++
                    }
                } elseif ($w.State -eq "connecting") {
                    $connDone = $false
                    try { $connDone = $w.Iar.IsCompleted } catch { $connDone = $true }
                    if ($connDone) {
                        try {
                            $w.Resp = $w.Req.EndGetResponse($w.Iar)
                            $w.Stream = $w.Resp.GetResponseStream()
                            $w.ReadIar = $w.Stream.BeginRead($w.Buf, 0, 65536, $null, $null)
                            $w.State = "reading"
                            $w.Fails = 0
                        } catch {
                            $w.Fails++
                            $workerErrors++
                            try { if ($w.Resp -ne $null) { $w.Resp.Close() } } catch { }
                            $w.Resp = $null
                            $w.State = "idle"
                        }
                    }
                } elseif ($w.State -eq "reading") {
                    $rDone = $false
                    try { $rDone = $w.ReadIar.IsCompleted } catch { $rDone = $true }
                    if ($rDone) {
                        try {
                            $n = $w.Stream.EndRead($w.ReadIar)
                            $w.Bytes += $n
                            if ($n -gt 0) {
                                $w.Fails = 0
                                $w.ReadIar = $w.Stream.BeginRead($w.Buf, 0, 65536, $null, $null)
                            } else {
                                try { $w.Stream.Close() } catch { }
                                try { $w.Resp.Close() } catch { }
                                $w.Stream = $null; $w.Resp = $null
                                $w.Fails = 0
                                $w.State = "idle"
                            }
                        } catch {
                            $w.Fails++
                            $workerErrors++
                            try { if ($w.Stream -ne $null) { $w.Stream.Close() } } catch { }
                            try { if ($w.Resp -ne $null) { $w.Resp.Close() } } catch { }
                            $w.Stream = $null; $w.Resp = $null
                            $w.State = "idle"
                        }
                    }
                }
            } elseif ($w.Kind -eq "unc") {
                if ($w.State -eq "idle") {
                    try {
                        $fs = $null
                        try {
                            $fs = New-Object System.IO.FileStream($LoadFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 65536, $true)
                        } catch { $fs = $null }
                        if ($fs -ne $null) {
                            $w.SyncMode = $false
                        } else {
                            $fs = New-Object System.IO.FileStream($LoadFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                            $w.SyncMode = $true
                        }
                        $w.Fs = $fs
                        $w.State = "reading"
                        if ($w.SyncMode) {
                            $n = $w.Fs.Read($w.Buf, 0, 65536)
                            $w.Bytes += $n
                            if ($n -le 0) { [void]$w.Fs.Seek(0, [System.IO.SeekOrigin]::Begin) }
                        } else {
                            $w.ReadIar = $w.Fs.BeginRead($w.Buf, 0, 65536, $null, $null)
                        }
                    } catch {
                        $w.Fails++
                        $workerErrors++
                        try { if ($w.Fs -ne $null) { $w.Fs.Close() } } catch { }
                        $w.Fs = $null
                    }
                } elseif ($w.State -eq "reading") {
                    if ($w.SyncMode) {
                        try {
                            $n = $w.Fs.Read($w.Buf, 0, 65536)
                            $w.Bytes += $n
                            if ($n -le 0) { [void]$w.Fs.Seek(0, [System.IO.SeekOrigin]::Begin) } else { $w.Fails = 0 }
                        } catch {
                            $w.Fails++
                            $workerErrors++
                            try { $w.Fs.Close() } catch { }
                            $w.Fs = $null
                            $w.State = "idle"
                        }
                    } else {
                        $rDone = $false
                        try { $rDone = $w.ReadIar.IsCompleted } catch { $rDone = $true }
                        if ($rDone) {
                            try {
                                $n = $w.Fs.EndRead($w.ReadIar)
                                $w.Bytes += $n
                                if ($n -gt 0) {
                                    $w.Fails = 0
                                    $w.ReadIar = $w.Fs.BeginRead($w.Buf, 0, 65536, $null, $null)
                                } else {
                                    [void]$w.Fs.Seek(0, [System.IO.SeekOrigin]::Begin)
                                    $w.ReadIar = $w.Fs.BeginRead($w.Buf, 0, 65536, $null, $null)
                                }
                            } catch {
                                $w.Fails++
                                $workerErrors++
                                try { $w.Fs.Close() } catch { }
                                $w.Fs = $null
                                $w.State = "idle"
                            }
                        }
                    }
                }
            }
        }

        # TCP churn - непрекъснати нови връзки към първия отворен порт
        if ($churnPort -gt 0) {
            $toRemove = New-Object System.Collections.ArrayList
            foreach ($c in $churn) {
                $fin = $false
                try { if ($c.Iar.AsyncWaitHandle.WaitOne(0)) { $fin = $true } } catch { $fin = $true }
                if ($fin) {
                    try { $c.Tcp.EndConnect($c.Iar); $churnDone++ } catch { $churnFail++ }
                    try { $c.Tcp.Close() } catch { }
                    [void]$toRemove.Add($c)
                }
            }
            foreach ($c in $toRemove) { [void]$churn.Remove($c) }
            while ($churn.Count -lt $churnMax) {
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    $iar = $tcp.BeginConnect($Target, $churnPort, $null, $null)
                    $entry = New-Object PSObject -Property @{ Tcp = $tcp; Iar = $iar }
                    [void]$churn.Add($entry)
                } catch {
                    try { $tcp.Close() } catch { }
                    $churnFail++
                    break
                }
            }
        }

        # един голям ping на всеки ~2 прохода - реален ICMP трафик
        if (($iter % 2) -eq 0) {
            $jumboSent++
            try {
                $reply = $pinger.Send($addr, 500, $jumboBuf, $jumboOpts)
                if ($reply.Status -ne [System.Net.NetworkInformation.IPStatus]::Success) { $jumboLost++ }
            } catch { $jumboLost++ }
        }

        # измервателен ping на всеки ~400 ms
        $now = [DateTime]::Now
        if ($now -ge $nextPing) {
            $nextPing = $now.AddMilliseconds(400)
            $loadSent++
            try {
                $reply = $pinger.Send($addr, 500)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $rtt = [double]$reply.RoundtripTime
                    [void]$loadRtts.Add($rtt)
                    if ($rtt -gt ($baseAvg * 3) -and $rtt -gt 50) { $spikes++ }
                    Add-PingSample -Rtt $rtt -Lost $false
                } else {
                    $loadLost++
                    Add-PingSample -Rtt 0 -Lost $true
                }
            } catch { $loadLost++; Add-PingSample -Rtt 0 -Lost $true }
        }

        $remaining = [int](($end - [DateTime]::Now).TotalSeconds) + 1
        $liveAvg = 0.0
        if ($loadRtts.Count -gt 0) {
            $s = 0.0
            foreach ($r in $loadRtts) { $s += $r }
            $liveAvg = $s / $loadRtts.Count
        }
        Set-Status ("Натоварване... остават " + $remaining + " сек., латентност avg " + [math]::Round($liveAvg,1) + " ms")
        Do-Events
        Start-Sleep -Milliseconds 20
    }

    $elapsed = ([DateTime]::Now - $startTime).TotalSeconds

    # освобождаване на ресурсите
    foreach ($w in $workers) {
        try { if ($w.Stream -ne $null) { $w.Stream.Close() } } catch { }
        try { if ($w.Resp -ne $null) { $w.Resp.Close() } } catch { }
        try { if ($w.Fs -ne $null) { $w.Fs.Close() } } catch { }
    }
    foreach ($c in $churn) {
        try { $c.Tcp.Close() } catch { }
    }
    if ($stopped) { return }

    # --- Стъпка D: отчет ---
    $loadedAvg = 0.0; $loadedMax = 0.0
    if ($loadRtts.Count -gt 0) {
        $s = 0.0
        foreach ($r in $loadRtts) {
            $s += $r
            if ($r -gt $loadedMax) { $loadedMax = $r }
        }
        $loadedAvg = $s / $loadRtts.Count
    }
    $loadLossPct = 0.0
    if ($loadSent -gt 0) { $loadLossPct = [math]::Round(($loadLost * 100.0) / $loadSent, 1) }
    Write-Log ("  Под товар: avg " + [math]::Round($loadedAvg,1) + " ms, max " + [math]::Round($loadedMax,1) + " ms, загуби " + $loadLost + "/" + $loadSent + " (" + $loadLossPct + "%), пикове " + $spikes)
    $totalBytes = 0L
    foreach ($w in $workers) { $totalBytes += $w.Bytes }
    if ($totalBytes -gt 0 -and $elapsed -gt 0) {
        $mb = [math]::Round($totalBytes / 1048576.0, 1)
        $mbps = [math]::Round(($totalBytes * 8.0) / $elapsed / 1000000.0, 1)
        Write-Log ("  Свалено " + $mb + " MB за " + [math]::Round($elapsed,0) + " сек (" + $mbps + " Mbps)")
    }
    if ($churnDone -gt 0 -or $churnFail -gt 0) {
        Write-Log ("  TCP churn: " + $churnDone + " успешни връзки, " + $churnFail + " неуспешни")
    }
    Write-Log ("  Jumbo ping трафик: " + $jumboSent + " изпратени, " + $jumboLost + " загубени")
    if ($workerErrors -gt 0) {
        Write-Log ("  Грешки в работниците: " + $workerErrors) "Warn"
    }

    if ($loadSent -eq 0) {
        Write-Log "Резултат: ВНИМАНИЕ - няма измервания." "Warn"
        Add-Result "Натоварване/латентност" "Warn" "няма измервания"
    } elseif ($loadLost -eq 0 -and $loadedAvg -le ($baseAvg * 3 + 10)) {
        Write-Log "Резултат: OK - латентността под товар е стабилна." "OK"
        Add-Result "Натоварване/латентност" "OK" ("avg " + [math]::Round($baseAvg,1) + " -> " + [math]::Round($loadedAvg,1) + " ms")
    } elseif ($loadLossPct -le 2 -or $loadedAvg -le ($baseAvg * 5 + 30)) {
        Write-Log "Резултат: ВНИМАНИЕ - латентността расте или има загуби под товар." "Warn"
        Add-Result "Натоварване/латентност" "Warn" ("avg " + [math]::Round($baseAvg,1) + " -> " + [math]::Round($loadedAvg,1) + " ms, загуби " + $loadLossPct + "%")
    } else {
        Write-Log "Резултат: ПРОБЛЕМ - връзката се влошава сериозно под товар." "Fail"
        Add-Result "Натоварване/латентност" "Fail" ("avg " + [math]::Round($baseAvg,1) + " -> " + [math]::Round($loadedAvg,1) + " ms, загуби " + $loadLossPct + "%")
    }
    Write-Log "Съвет: за да възпроизведете натоварването в пикови часове, стартирайте този тест едновременно от 2-3 компютъра."
}

function Test-Throughput {
    param([string]$LoadFile)
    Write-Log "=== Пропускателна способност ===" "Header"
    if ($LoadFile -eq $null -or $LoadFile.Trim() -eq "") {
        Write-Log "  Не е зададен тестов файл - тестът се пропуска."
        return
    }
    $LoadFile = $LoadFile.Trim()
    $best = 0.0
    if ($LoadFile -match "^https?://") {
        $sizeBytes = 0L
        try {
            $req = [System.Net.WebRequest]::Create($LoadFile)
            $req.Method = "HEAD"
            $req.Timeout = 8000
            $resp = $req.GetResponse()
            $sizeBytes = $resp.ContentLength
            $resp.Close()
        } catch { $sizeBytes = 0 }
        if ($sizeBytes -gt 0) {
            Write-Log ("  Файл: " + $LoadFile + " (" + [math]::Round($sizeBytes / 1048576.0,1) + " MB)")
        } else {
            Write-Log ("  Файл: " + $LoadFile)
        }
        for ($run = 1; $run -le 3; $run++) {
            if (Stop-Check) { return }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $total = 0L
            $runOk = $false
            try {
                $req = [System.Net.WebRequest]::Create($LoadFile)
                $req.Method = "GET"
                $req.Timeout = 15000
                $req.ReadWriteTimeout = 5000
                $resp = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $buf = New-Object byte[] 65536
                $lastEvt = [DateTime]::Now
                while ($true) {
                    $n = $stream.Read($buf, 0, 65536)
                    if ($n -le 0) { break }
                    $total += $n
                    if (([DateTime]::Now - $lastEvt).TotalMilliseconds -gt 200) {
                        if ($script:StopRequested) { break }
                        Do-Events
                        $lastEvt = [DateTime]::Now
                    }
                }
                $sw.Stop()
                try { $stream.Close() } catch { }
                try { $resp.Close() } catch { }
                if (-not $script:StopRequested) { $runOk = $true }
            } catch {
                $sw.Stop()
                Write-Log ("  Опит " + $run + ": грешка - " + $_.Exception.Message) "Warn"
            }
            if ($runOk -and $sw.Elapsed.TotalSeconds -gt 0) {
                $speed = ($total / 1048576.0) / $sw.Elapsed.TotalSeconds
                Write-Log ("  Опит " + $run + ": " + [math]::Round($total / 1048576.0,1) + " MB за " + [math]::Round($sw.Elapsed.TotalSeconds,1) + " сек = " + [math]::Round($speed,1) + " MB/s")
                if ($speed -gt $best) { $best = $speed }
            }
            Do-Events
        }
    } elseif ($LoadFile.StartsWith("\\")) {
        try {
            $fi = New-Object System.IO.FileInfo($LoadFile)
            Write-Log ("  Файл: " + $LoadFile + " (" + [math]::Round($fi.Length / 1048576.0,1) + " MB)")
        } catch {
            Write-Log ("  Файл: " + $LoadFile)
        }
        $tmp = Join-Path $env:TEMP "nt_load_test.tmp"
        for ($run = 1; $run -le 3; $run++) {
            if (Stop-Check) { return }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                [System.IO.File]::Copy($LoadFile, $tmp, $true)
                $sw.Stop()
                $fi2 = New-Object System.IO.FileInfo($tmp)
                $sec = $sw.Elapsed.TotalSeconds
                if ($sec -le 0) { $sec = 0.001 }
                $speed = ($fi2.Length / 1048576.0) / $sec
                Write-Log ("  Опит " + $run + ": " + [math]::Round($fi2.Length / 1048576.0,1) + " MB за " + [math]::Round($sec,1) + " сек = " + [math]::Round($speed,1) + " MB/s")
                if ($speed -gt $best) { $best = $speed }
            } catch {
                $sw.Stop()
                Write-Log ("  Опит " + $run + ": грешка - " + $_.Exception.Message) "Warn"
            }
            Do-Events
        }
        try { if (Test-Path $tmp) { Remove-Item $tmp -Force } } catch { }
    } else {
        Write-Log "  Файлът трябва да започва с http://, https:// или \\ - тестът се пропуска." "Warn"
        return
    }
    if ($best -ge 20) {
        Write-Log ("Резултат: OK - до " + [math]::Round($best,1) + " MB/s.") "OK"
        Add-Result "Пропускателна способност" "OK" ("до " + [math]::Round($best,1) + " MB/s")
    } elseif ($best -ge 5) {
        Write-Log ("Резултат: ВНИМАНИЕ - до " + [math]::Round($best,1) + " MB/s.") "Warn"
        Add-Result "Пропускателна способност" "Warn" ("до " + [math]::Round($best,1) + " MB/s")
    } else {
        Write-Log "Резултат: ПРОБЛЕМ - много ниска скорост или неуспешно сваляне." "Fail"
        Add-Result "Пропускателна способност" "Fail" ("до " + [math]::Round($best,1) + " MB/s")
    }
}

function Start-LoadTests {
    param(
        [string]$ServerTarget, [string]$PortsCsv,
        [int]$Connections, [int]$Seconds, [string]$LoadFile,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Тестът с натоварване работи..."

        Write-Log "=== ТЕСТ С НАТОВАРВАНЕ КЪМ СЪРВЪРА ===" "Header"
        Write-Log ("Сървър: " + $ServerTarget + " | Паралелни връзки: " + $Connections + " | Продължителност: " + $Seconds + " сек.")

        $resName = $null
        $addr = Resolve-Target $ServerTarget ([ref]$resName)
        if ($addr -eq $null) {
            Write-Log ("Не може да се разреши адресът: " + $ServerTarget) "Fail"
            Add-Result "Достъпност на сървъра" "Fail" "DNS разрешаване неуспешно"
        } else {
            $pinger = New-Object System.Net.NetworkInformation.Ping
            $recv = 0
            for ($i = 0; $i -lt 5; $i++) {
                if (Stop-Check) { return }
                try {
                    $reply = $pinger.Send($addr, 1000)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $recv++ }
                } catch { }
                Do-Events
                if ($i -lt 4) { Start-Sleep -Milliseconds 100 }
            }
            if ($recv -eq 0) {
                Write-Log ("Сървърът " + $ServerTarget + " не отговаря на ping - тестът се прекратява.") "Fail"
                Add-Result "Достъпност на сървъра" "Fail" "сървърът не отговаря"
            } else {
                Write-Log ("Сървърът отговаря (" + $recv + "/5 ping).") "OK"
                Add-Result "Достъпност на сървъра" "OK" ("" + $recv + "/5 отговора")

                Test-MtuPing -Target $ServerTarget
                if (Stop-Check) { return }
                Test-TcpBurst -Target $ServerTarget -PortsCsv $PortsCsv -Connections $Connections
                if (Stop-Check) { return }
                Test-LoadLatency -Target $ServerTarget -PortsCsv $PortsCsv -Connections $Connections -Seconds $Seconds -LoadFile $LoadFile
                if (Stop-Check) { return }
                Test-Throughput -LoadFile $LoadFile
                if (Stop-Check) { return }
            }
        }

        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon
    }
}

function Start-AllTests {
    param(
        [string]$RouterIp, [string]$ServerTarget, [string]$PortsCsv,
        [int]$PingCount, [int]$StabSec,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    $routerOk = $false
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Тестът работи..."

        Test-NetworkInfo
        if (Stop-Check) { return }

        if ($RouterIp -ne "") {
            $res = Invoke-PingTest -Target $RouterIp -Count $PingCount -Label "Ping до рутера" -OkAvg 10 -WarnAvg 50 -WarnLoss 5
            if ($res -ne $null -and $res.Status -eq "OK") { $routerOk = $true }
            if (Stop-Check) { return }
        } else {
            Write-Log "Не е зададен IP адрес на рутера - тестът към рутера се пропуска." "Warn"
        }

        $serverIp = ""
        if ($ServerTarget -ne "") {
            $res = Invoke-PingTest -Target $ServerTarget -Count $PingCount -Label "Ping до сървъра" -OkAvg 20 -WarnAvg 100 -WarnLoss 5
            if (Stop-Check) { return }
            $serverIp = $ServerTarget
        } else {
            Write-Log "Не е зададен сървър - тестовете към сървъра се пропускат." "Warn"
        }

        $inetCount = [int]($PingCount / 2)
        if ($inetCount -lt 5) { $inetCount = 5 }
        Test-InternetPing -Count $inetCount -RouterOk $routerOk
        if (Stop-Check) { return }

        Test-Dns
        if (Stop-Check) { return }

        Test-Http
        if (Stop-Check) { return }

        if ($serverIp -ne "") {
            Test-Ports -Target $serverIp -PortsCsv $PortsCsv
            if (Stop-Check) { return }
            Invoke-TraceRoute -Target $serverIp -Label "Трасиране към сървъра"
            if (Stop-Check) { return }
        }
        Invoke-TraceRoute -Target "8.8.8.8" -Label "Трасиране към интернет"
        if (Stop-Check) { return }

        if ($StabSec -gt 0) {
            Test-Stability -Seconds $StabSec -RouterIp $RouterIp -ServerTarget $serverIp
            if (Stop-Check) { return }
        }

        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon
    }
}

function Start-QuickTest {
    param(
        [string]$RouterIp, [string]$ServerTarget,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $quickPing = {
        param([string]$Target, [string]$Label)
        $resName = $null
        $addr = Resolve-Target $Target ([ref]$resName)
        if ($addr -eq $null) {
            Write-Log ("  " + $Label + ": не може да се разреши адресът") "Fail"
            Add-Result $Label "Fail" "DNS разрешаване неуспешно"
            return
        }
        $sent = 0; $recv = 0; $sum = 0.0
        for ($i = 0; $i -lt 5; $i++) {
            if (Stop-Check) { return }
            $sent++
            $ok = $false
            $rtt = 0.0
            try {
                $reply = $pinger.Send($addr, 700)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $ok = $true
                    $rtt = [double]$reply.RoundtripTime
                }
            } catch { }
            Add-PingSample -Rtt $rtt -Lost (-not $ok)
            if ($ok) { $recv++; $sum += $rtt }
            Do-Events
            if ($i -lt 4) { Start-Sleep -Milliseconds 700 }
        }
        $avg = 0.0
        if ($recv -gt 0) { $avg = $sum / $recv }
        $status = "OK"
        if ($recv -eq 0) { $status = "Fail" }
        elseif ($recv -lt $sent) { $status = "Warn" }
        Write-Log ("  " + $Label + ": " + $recv + "/" + $sent + ", avg " + [math]::Round($avg,1) + " ms") $status
        Add-Result $Label $status ("" + $recv + "/" + $sent + ", avg " + [math]::Round($avg,1) + " ms")
    }
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Бърз тест..."
        Write-Log "=== БЪРЗ ТЕСТ ===" "Header"

        if ($RouterIp -ne "") {
            & $quickPing $RouterIp ("Рутер " + $RouterIp)
            if (Stop-Check) { return }
        }
        if ($ServerTarget -ne "") {
            & $quickPing $ServerTarget ("Сървър " + $ServerTarget)
            if (Stop-Check) { return }
        }
        & $quickPing "8.8.8.8" "Интернет 8.8.8.8"
        if (Stop-Check) { return }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses("google.com")
            $sw.Stop()
            if ($addrs.Count -gt 0) {
                Write-Log ("  DNS google.com -> " + $addrs[0].ToString() + "  (" + $sw.ElapsedMilliseconds + " ms)") "OK"
                Add-Result "DNS" "OK" "разрешаването работи"
            } else {
                Write-Log "  DNS google.com - няма отговор" "Warn"
                Add-Result "DNS" "Warn" "няма отговор"
            }
        } catch {
            $sw.Stop()
            Write-Log ("  DNS google.com - ГРЕШКА: " + $_.Exception.Message) "Fail"
            Add-Result "DNS" "Fail" "грешка при разрешаване"
        }

        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon
    }
}

function Start-Monitor {
    param(
        [string]$RouterIp, [string]$ServerTarget, [int]$IntervalSec, [bool]$Beep,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Write-Log ("=== МОНИТОРИНГ — стартиран в " + [DateTime]::Now.ToString("HH:mm:ss") + " ===") "Header"

        $targets = New-Object System.Collections.ArrayList
        if ($RouterIp -ne "") { [void]$targets.Add($RouterIp) }
        if ($ServerTarget -ne "") { [void]$targets.Add($ServerTarget) }
        [void]$targets.Add("8.8.8.8")
        Write-Log ("Спиране: бутон 'Стоп'. Цели: " + ($targets -join ", "))

        $primary = "8.8.8.8"
        if ($RouterIp -ne "") { $primary = $RouterIp }
        if ($ServerTarget -ne "") { $primary = $ServerTarget }

        $stats = @{}
        $resolved = @{}
        $pinger = New-Object System.Net.NetworkInformation.Ping
        foreach ($t in $targets) {
            $stats[$t] = New-Object PSObject -Property @{
                Sent = 0; Lost = 0; Consec = 0; RttSum = 0.0; RttCount = 0
                MaxRtt = 0.0; Down = $false; DownSince = [DateTime]::Now
                SpikeCount = 0; Spiking = $false; Outages = 0; LastRtt = -1.0
            }
            $resName = $null
            $a = Resolve-Target $t ([ref]$resName)
            if ($a -ne $null) {
                $resolved[$t] = $a
            } else {
                Write-Log ("  " + $t + " не може да се разреши - ще се отчита като загуба.") "Warn"
            }
        }

        $logStats = {
            foreach ($t in $targets) {
                $s = $stats[$t]
                $lossPct = 0.0
                if ($s.Sent -gt 0) { $lossPct = [math]::Round(($s.Lost * 100.0) / $s.Sent, 1) }
                $avg = 0.0
                if ($s.RttCount -gt 0) { $avg = $s.RttSum / $s.RttCount }
                Write-Log ("  " + $t + ": изпратени " + $s.Sent + ", загубени " + $s.Lost + " (" + $lossPct + "%), avg " + [math]::Round($avg,1) + " ms, max " + [math]::Round($s.MaxRtt,1) + " ms, прекъсвания " + $s.Outages)
            }
        }

        $startTime = [DateTime]::Now
        $lastStats = $startTime
        $nextCycle = $startTime
        while ($true) {
            if (Stop-Check) { break }
            $nextCycle = $nextCycle.AddSeconds($IntervalSec)
            foreach ($t in $targets) {
                if ($script:StopRequested) { break }
                $s = $stats[$t]
                $s.Sent++
                $rtt = -1.0
                if ($resolved.ContainsKey($t)) {
                    try {
                        $reply = $pinger.Send($resolved[$t], 800)
                        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                            $rtt = [double]$reply.RoundtripTime
                        }
                    } catch { }
                }
                if ($t -eq $primary) { Add-PingSample -Rtt $rtt -Lost ($rtt -lt 0) }
                if ($rtt -lt 0) {
                    $s.Lost++
                    $s.Consec++
                    $s.LastRtt = -1.0
                    if (-not $s.Down) {
                        $s.Down = $true
                        $s.DownSince = [DateTime]::Now
                        $s.Outages++
                        Write-Log ("!!!! " + $t + " НЕ ОТГОВАРЯ (от " + $s.DownSince.ToString("HH:mm:ss") + ")") "Fail"
                        if ($Beep) {
                            try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
                        }
                    }
                } else {
                    $s.LastRtt = $rtt
                    if ($s.Down) {
                        $s.Down = $false
                        $downSec = [int](([DateTime]::Now - $s.DownSince).TotalSeconds)
                        Write-Log ("OK: " + $t + " възстанови връзката (прекъсване ~" + $downSec + " сек)") "OK"
                    }
                    $s.Consec = 0
                    if ($rtt -gt $s.MaxRtt) { $s.MaxRtt = $rtt }
                    if ($s.RttCount -gt 4) {
                        $runAvg = $s.RttSum / $s.RttCount
                        if ($rtt -gt ($runAvg * 3) -and $rtt -gt 50) {
                            $s.SpikeCount++
                            if (-not $s.Spiking) {
                                $s.Spiking = $true
                                Write-Log ("  " + $t + ": пик на латентността " + [math]::Round($rtt,1) + " ms (норма " + [math]::Round($runAvg,1) + " ms)") "Warn"
                            }
                        } elseif ($s.Spiking) {
                            $s.Spiking = $false
                            Write-Log ("  " + $t + ": латентността се нормализира (" + [math]::Round($rtt,1) + " ms)")
                        }
                    }
                    $s.RttSum += $rtt
                    $s.RttCount++
                }
                Do-Events
            }

            $elapsedMin = [int](([DateTime]::Now - $startTime).TotalMinutes)
            $ps = $stats[$primary]
            $lastTxt = "---"
            if ($ps.LastRtt -ge 0) { $lastTxt = ("" + [math]::Round($ps.LastRtt,1) + " ms") }
            Set-Status ("Мониторинг работи: " + $elapsedMin + " мин | " + $primary + ": " + $lastTxt + " | загуби " + $ps.Lost)

            if (([DateTime]::Now - $lastStats).TotalMinutes -ge 10) {
                $lastStats = [DateTime]::Now
                Write-Log "--- Междинна статистика ---" "Header"
                & $logStats
            }

            while ([DateTime]::Now -lt $nextCycle) {
                if (Stop-Check) { break }
                Do-Events
                $msLeft = ($nextCycle - [DateTime]::Now).TotalMilliseconds
                if ($msLeft -le 0) { break }
                $sleepMs = 200
                if ($msLeft -lt 200) { $sleepMs = [int]$msLeft }
                Start-Sleep -Milliseconds $sleepMs
            }
        }

        Write-Log "=== МОНИТОРИНГ — спрян ===" "Header"
        & $logStats
        foreach ($t in $targets) {
            $s = $stats[$t]
            $lossPct = 0.0
            if ($s.Sent -gt 0) { $lossPct = [math]::Round(($s.Lost * 100.0) / $s.Sent, 1) }
            if ($s.Lost -eq 0) {
                Add-Result ("Мониторинг " + $t) "OK" "без загуби"
            } elseif ($lossPct -lt 2) {
                Add-Result ("Мониторинг " + $t) "Warn" ("загуби " + $lossPct + "%")
            } else {
                Add-Result ("Мониторинг " + $t) "Fail" ("загуби " + $lossPct + "%")
            }
        }
        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon
    }
}

function Invoke-NetworkScan {
    param(
        [string]$ServerTarget,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Сканиране на мрежата..."

        # локален IPv4 адрес и маска на адаптера с шлюз по подразбиране
        $ownIp = $null
        $maskBytes = $null
        try {
            foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
                if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
                $props = $ni.GetIPProperties()
                $hasGw = $false
                foreach ($gw in $props.GatewayAddresses) {
                    if ($gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $hasGw = $true }
                }
                if (-not $hasGw) { continue }
                foreach ($ua in $props.UnicastAddresses) {
                    if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                        $ownIp = $ua.Address
                        if ($ua.IPv4Mask -ne $null) { $maskBytes = $ua.IPv4Mask.GetAddressBytes() }
                        break
                    }
                }
                if ($ownIp -ne $null) { break }
            }
        } catch { }
        if ($ownIp -eq $null) {
            Write-Log "Не е открит локален IPv4 адрес със шлюз - сканирането се прекратява." "Fail"
            Add-Result "Сканиране на мрежата" "Fail" "няма локален IP адрес"
            return
        }

        $ipBytes = $ownIp.GetAddressBytes()
        $netBytes = @($ipBytes[0], $ipBytes[1], $ipBytes[2], 0)
        $hostBits = 8
        if ($maskBytes -ne $null) {
            $hostBits = 0
            for ($i = 0; $i -lt 4; $i++) {
                $netBytes[$i] = $ipBytes[$i] -band $maskBytes[$i]
                $b = [int]$maskBytes[$i]
                for ($bit = 0; $bit -lt 8; $bit++) {
                    if (($b -band [int]([math]::Pow(2, $bit))) -eq 0) { $hostBits++ }
                }
            }
        }
        $hostCount = [int]([math]::Pow(2, $hostBits)) - 2
        if ($hostCount -gt 254) { $hostCount = 254 }
        if ($hostCount -lt 1) { $hostCount = 1 }
        $netInt = 0.0
        for ($i = 0; $i -lt 4; $i++) { $netInt = $netInt * 256 + [int]$netBytes[$i] }
        $prefix = 32 - $hostBits
        $netText = "" + $netBytes[0] + "." + $netBytes[1] + "." + $netBytes[2] + "." + $netBytes[3] + "/" + $prefix
        Write-Log ("=== Сканиране на мрежата " + $netText + " ===") "Header"

        $pinger = New-Object System.Net.NetworkInformation.Ping
        $alive = New-Object System.Collections.ArrayList
        for ($h = 1; $h -le $hostCount; $h++) {
            if (Stop-Check) { return }
            $ipInt = $netInt + $h
            $b0 = [int][math]::Floor($ipInt / 16777216) % 256
            $b1 = [int][math]::Floor($ipInt / 65536) % 256
            $b2 = [int][math]::Floor($ipInt / 256) % 256
            $b3 = [int]($ipInt % 256)
            $ipText = "" + $b0 + "." + $b1 + "." + $b2 + "." + $b3
            try {
                $reply = $pinger.Send($ipText, 200)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    [void]$alive.Add($ipText)
                    $note = ""
                    if ($ipText -eq $ownIp.ToString()) { $note = "  (този компютър)" }
                    Write-Log ("  " + $ipText + "  (" + $reply.RoundtripTime + " ms)" + $note)
                }
            } catch { }
            if (($h % 16) -eq 0) {
                Set-Status ("Сканиране: " + $h + "/" + $hostCount + ", намерени: " + $alive.Count)
            }
            Do-Events
        }

        # ARP таблица - устройства, които не отговарят на ping, но са в кеша
        $arpMap = @{}
        try {
            $arpLines = arp -a
            foreach ($al in $arpLines) {
                if ($al -match "(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})") {
                    $aip = $matches[1]
                    $amac = $matches[2].ToLower()
                    $firstOctet = [int]($aip.Split(".")[0])
                    if ($firstOctet -ge 224) { continue }
                    if ($amac -eq "ff-ff-ff-ff-ff-ff") { continue }
                    $arpMap[$aip] = $amac
                }
            }
        } catch { }

        $devices = @{}
        foreach ($a in $alive) { $devices[$a] = $true }
        foreach ($k in $arpMap.Keys) { $devices[$k] = $true }
        Write-Log ("  Открити устройства: " + $devices.Count)
        $shown = 0
        foreach ($k in $devices.Keys) {
            if ($shown -ge 50) {
                Write-Log "  ... (списъкът е съкратен до 50 реда)"
                break
            }
            $macTxt = ""
            if ($arpMap.ContainsKey($k)) { $macTxt = "  MAC " + $arpMap[$k] }
            Write-Log ("    " + $k + $macTxt)
            $shown++
        }

        # Проверка за IP конфликт - различен MAC преди/след нов ping
        $conflict = $false
        $checkIps = New-Object System.Collections.ArrayList
        $gwIp = Get-DefaultGateway
        if ($gwIp -ne "") { [void]$checkIps.Add($gwIp) }
        if ($ServerTarget -ne $null -and $ServerTarget -ne "") {
            $resName = $null
            $sAddr = Resolve-Target $ServerTarget ([ref]$resName)
            if ($sAddr -ne $null) { [void]$checkIps.Add($sAddr.ToString()) }
        }
        foreach ($cip in $checkIps) {
            if (Stop-Check) { return }
            $mac1 = ""
            if ($arpMap.ContainsKey($cip)) { $mac1 = $arpMap[$cip] }
            try { [void]$pinger.Send($cip, 500) } catch { }
            Do-Events
            Start-Sleep -Seconds 2
            $mac2 = ""
            try {
                $arpLines2 = arp -a
                foreach ($al in $arpLines2) {
                    if ($al -match "(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})") {
                        if ($matches[1] -eq $cip) { $mac2 = $matches[2].ToLower() }
                    }
                }
            } catch { }
            if ($mac1 -ne "" -and $mac2 -ne "" -and $mac1 -ne $mac2) {
                Write-Log ("  ПРОБЛЕМ: " + $cip + " отговаря от различни MAC адреси - вероятен IP конфликт!") "Fail"
                Write-Log ("    първо: " + $mac1 + "  след повторен ping: " + $mac2) "Fail"
                Add-Result ("IP конфликт " + $cip) "Fail" "различни MAC адреси"
                $conflict = $true
            }
        }

        # един и същ MAC на различни IP адреса
        $macToIps = @{}
        foreach ($k in $arpMap.Keys) {
            $m = $arpMap[$k]
            if (-not $macToIps.ContainsKey($m)) { $macToIps[$m] = New-Object System.Collections.ArrayList }
            [void]$macToIps[$m].Add($k)
        }
        foreach ($m in $macToIps.Keys) {
            $ips = $macToIps[$m]
            if ($ips.Count -gt 1) {
                $isCritical = $false
                foreach ($ip in $ips) { if ($checkIps.Contains($ip)) { $isCritical = $true } }
                if ($isCritical) {
                    Write-Log ("  ВНИМАНИЕ: MAC " + $m + " отговаря на няколко IP адреса: " + ($ips -join ", ")) "Warn"
                } else {
                    Write-Log ("  MAC " + $m + " отговаря на няколко IP адреса: " + ($ips -join ", ") + " (често е нормално - виртуални интерфейси)")
                }
            }
        }

        $ownText = $ownIp.ToString()
        $otherCount = 0
        foreach ($k in $devices.Keys) { if ($k -ne $ownText) { $otherCount++ } }
        if ($conflict) {
            Write-Log "Резултат: ПРОБЛЕМ - открит е вероятен IP конфликт в мрежата." "Fail"
            Add-Result "Сканиране на мрежата" "Fail" ("" + $otherCount + " устройства, IP конфликт")
        } elseif ($otherCount -ge 1) {
            Write-Log ("Резултат: OK - открити са " + $otherCount + " устройства в мрежата.") "OK"
            Add-Result "Сканиране на мрежата" "OK" ("" + $otherCount + " устройства")
        } else {
            Write-Log "Резултат: ВНИМАНИЕ - не са открити други устройства в мрежата." "Warn"
            Add-Result "Сканиране на мрежата" "Warn" "няма други устройства"
        }

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon
    }
}

if (-not $env:NETWORKTESTER_NOGUI) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $script:FormsLoaded = $true

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "NetworkTester – Тест на мрежовата връзка"
        $form.Size = New-Object System.Drawing.Size(820, 700)
        $form.MinimumSize = New-Object System.Drawing.Size(760, 650)
        $form.StartPosition = "CenterScreen"

        # ---------- Settings group ----------
        $grp = New-Object System.Windows.Forms.GroupBox
        $grp.Text = "Настройки"
        $grp.Location = New-Object System.Drawing.Point(10, 10)
        $grp.Size = New-Object System.Drawing.Size(784, 170)
        $grp.Anchor = "Top, Left, Right"
        $form.Controls.Add($grp)

        $lblRouter = New-Object System.Windows.Forms.Label
        $lblRouter.Text = "IP на рутера:"
        $lblRouter.Location = New-Object System.Drawing.Point(15, 30)
        $lblRouter.AutoSize = $true
        $grp.Controls.Add($lblRouter)

        $txtRouter = New-Object System.Windows.Forms.TextBox
        $txtRouter.Location = New-Object System.Drawing.Point(160, 27)
        $txtRouter.Size = New-Object System.Drawing.Size(200, 23)
        $grp.Controls.Add($txtRouter)

        $lblServer = New-Object System.Windows.Forms.Label
        $lblServer.Text = "IP на сървъра:"
        $lblServer.Location = New-Object System.Drawing.Point(15, 60)
        $lblServer.AutoSize = $true
        $grp.Controls.Add($lblServer)

        $txtServer = New-Object System.Windows.Forms.TextBox
        $txtServer.Location = New-Object System.Drawing.Point(160, 57)
        $txtServer.Size = New-Object System.Drawing.Size(200, 23)
        $grp.Controls.Add($txtServer)

        $lblPorts = New-Object System.Windows.Forms.Label
        $lblPorts.Text = "Портове на сървъра:"
        $lblPorts.Location = New-Object System.Drawing.Point(15, 90)
        $lblPorts.AutoSize = $true
        $grp.Controls.Add($lblPorts)

        $txtPorts = New-Object System.Windows.Forms.TextBox
        $txtPorts.Location = New-Object System.Drawing.Point(160, 87)
        $txtPorts.Size = New-Object System.Drawing.Size(200, 23)
        $txtPorts.Text = "80,443,445,3389"
        $grp.Controls.Add($txtPorts)

        $lblPing = New-Object System.Windows.Forms.Label
        $lblPing.Text = "Брой ping пакети:"
        $lblPing.Location = New-Object System.Drawing.Point(420, 30)
        $lblPing.AutoSize = $true
        $grp.Controls.Add($lblPing)

        $numPing = New-Object System.Windows.Forms.NumericUpDown
        $numPing.Location = New-Object System.Drawing.Point(600, 27)
        $numPing.Size = New-Object System.Drawing.Size(80, 23)
        $numPing.Minimum = 5
        $numPing.Maximum = 200
        $numPing.Value = 20
        $grp.Controls.Add($numPing)

        $lblStab = New-Object System.Windows.Forms.Label
        $lblStab.Text = "Тест за стабилност (секунди):"
        $lblStab.Location = New-Object System.Drawing.Point(420, 60)
        $lblStab.AutoSize = $true
        $grp.Controls.Add($lblStab)

        $numStab = New-Object System.Windows.Forms.NumericUpDown
        $numStab.Location = New-Object System.Drawing.Point(600, 57)
        $numStab.Size = New-Object System.Drawing.Size(80, 23)
        $numStab.Minimum = 0
        $numStab.Maximum = 600
        $numStab.Value = 30
        $grp.Controls.Add($numStab)

        $btnStart = New-Object System.Windows.Forms.Button
        $btnStart.Text = "Старт"
        $btnStart.Location = New-Object System.Drawing.Point(420, 95)
        $btnStart.Size = New-Object System.Drawing.Size(120, 45)
        $btnStart.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
        $btnStart.Font = New-Object System.Drawing.Font($btnStart.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
        $grp.Controls.Add($btnStart)

        $btnStop = New-Object System.Windows.Forms.Button
        $btnStop.Text = "Стоп"
        $btnStop.Location = New-Object System.Drawing.Point(550, 95)
        $btnStop.Size = New-Object System.Drawing.Size(80, 45)
        $btnStop.Enabled = $false
        $grp.Controls.Add($btnStop)

        $btnQuick = New-Object System.Windows.Forms.Button
        $btnQuick.Text = "Бърз тест"
        $btnQuick.Location = New-Object System.Drawing.Point(640, 95)
        $btnQuick.Size = New-Object System.Drawing.Size(130, 45)
        $btnQuick.BackColor = [System.Drawing.Color]::FromArgb(200, 220, 255)
        $btnQuick.Font = New-Object System.Drawing.Font($btnQuick.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
        $grp.Controls.Add($btnQuick)

        # ---------- Load test group ----------
        $grpLoad = New-Object System.Windows.Forms.GroupBox
        $grpLoad.Text = "Натоварване и мониторинг"
        $grpLoad.Location = New-Object System.Drawing.Point(10, 185)
        $grpLoad.Size = New-Object System.Drawing.Size(784, 150)
        $grpLoad.Anchor = "Top, Left, Right"
        $form.Controls.Add($grpLoad)

        $lblLoadConns = New-Object System.Windows.Forms.Label
        $lblLoadConns.Text = "Паралелни връзки:"
        $lblLoadConns.Location = New-Object System.Drawing.Point(15, 28)
        $lblLoadConns.AutoSize = $true
        $grpLoad.Controls.Add($lblLoadConns)

        $numLoadConns = New-Object System.Windows.Forms.NumericUpDown
        $numLoadConns.Location = New-Object System.Drawing.Point(140, 25)
        $numLoadConns.Size = New-Object System.Drawing.Size(70, 23)
        $numLoadConns.Minimum = 2
        $numLoadConns.Maximum = 100
        $numLoadConns.Value = 20
        $grpLoad.Controls.Add($numLoadConns)

        $lblLoadSec = New-Object System.Windows.Forms.Label
        $lblLoadSec.Text = "Продължителност (сек):"
        $lblLoadSec.Location = New-Object System.Drawing.Point(240, 28)
        $lblLoadSec.AutoSize = $true
        $grpLoad.Controls.Add($lblLoadSec)

        $numLoadSec = New-Object System.Windows.Forms.NumericUpDown
        $numLoadSec.Location = New-Object System.Drawing.Point(400, 25)
        $numLoadSec.Size = New-Object System.Drawing.Size(70, 23)
        $numLoadSec.Minimum = 5
        $numLoadSec.Maximum = 300
        $numLoadSec.Value = 30
        $grpLoad.Controls.Add($numLoadSec)

        $btnLoad = New-Object System.Windows.Forms.Button
        $btnLoad.Text = "Старт натоварване"
        $btnLoad.Location = New-Object System.Drawing.Point(500, 20)
        $btnLoad.Size = New-Object System.Drawing.Size(270, 40)
        $btnLoad.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 200)
        $btnLoad.Font = New-Object System.Drawing.Font($btnLoad.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
        $grpLoad.Controls.Add($btnLoad)

        $lblLoadFile = New-Object System.Windows.Forms.Label
        $lblLoadFile.Text = "Файл за тест (по желание):"
        $lblLoadFile.Location = New-Object System.Drawing.Point(15, 65)
        $lblLoadFile.AutoSize = $true
        $grpLoad.Controls.Add($lblLoadFile)

        $txtLoadFile = New-Object System.Windows.Forms.TextBox
        $txtLoadFile.Location = New-Object System.Drawing.Point(200, 62)
        $txtLoadFile.Size = New-Object System.Drawing.Size(570, 23)
        $grpLoad.Controls.Add($txtLoadFile)

        $lblLoadHint = New-Object System.Windows.Forms.Label
        $lblLoadHint.Text = "напр. http://сървър/файл  или  \\сървър\споделено\файл"
        $lblLoadHint.Location = New-Object System.Drawing.Point(200, 88)
        $lblLoadHint.AutoSize = $true
        $lblLoadHint.ForeColor = [System.Drawing.Color]::Gray
        $grpLoad.Controls.Add($lblLoadHint)

        $lblMonInt = New-Object System.Windows.Forms.Label
        $lblMonInt.Text = "Мониторинг интервал (сек):"
        $lblMonInt.Location = New-Object System.Drawing.Point(15, 118)
        $lblMonInt.AutoSize = $true
        $grpLoad.Controls.Add($lblMonInt)

        $numMonInt = New-Object System.Windows.Forms.NumericUpDown
        $numMonInt.Location = New-Object System.Drawing.Point(185, 115)
        $numMonInt.Size = New-Object System.Drawing.Size(55, 23)
        $numMonInt.Minimum = 1
        $numMonInt.Maximum = 300
        $numMonInt.Value = 5
        $grpLoad.Controls.Add($numMonInt)

        $chkBeep = New-Object System.Windows.Forms.CheckBox
        $chkBeep.Text = "Звук при проблем"
        $chkBeep.Location = New-Object System.Drawing.Point(255, 117)
        $chkBeep.AutoSize = $true
        $grpLoad.Controls.Add($chkBeep)

        $btnMon = New-Object System.Windows.Forms.Button
        $btnMon.Text = "Старт мониторинг"
        $btnMon.Location = New-Object System.Drawing.Point(500, 108)
        $btnMon.Size = New-Object System.Drawing.Size(270, 32)
        $btnMon.BackColor = [System.Drawing.Color]::FromArgb(220, 235, 255)
        $btnMon.Font = New-Object System.Drawing.Font($btnMon.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
        $grpLoad.Controls.Add($btnMon)

        # ---------- Status + progress ----------
        $script:StatusLabel = New-Object System.Windows.Forms.Label
        $script:StatusLabel.Text = "Готово."
        $script:StatusLabel.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
        $script:StatusLabel.Location = New-Object System.Drawing.Point(12, 343)
        $script:StatusLabel.Size = New-Object System.Drawing.Size(560, 20)
        $script:StatusLabel.Anchor = "Top, Left, Right"
        $form.Controls.Add($script:StatusLabel)

        $progress = New-Object System.Windows.Forms.ProgressBar
        $progress.Location = New-Object System.Drawing.Point(580, 341)
        $progress.Size = New-Object System.Drawing.Size(214, 20)
        $progress.Anchor = "Top, Right"
        $form.Controls.Add($progress)

        # ---------- Latency graph ----------
        $script:GraphBox = New-Object System.Windows.Forms.PictureBox
        $script:GraphBox.Location = New-Object System.Drawing.Point(10, 366)
        $script:GraphBox.Size = New-Object System.Drawing.Size(782, 52)
        $script:GraphBox.Anchor = "Top, Left, Right"
        $script:GraphBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $script:GraphBox.BackColor = [System.Drawing.Color]::White
        $form.Controls.Add($script:GraphBox)

        $script:GraphBox.Add_Paint({
            try {
                $g = $args[1].Graphics
                $w = $script:GraphBox.Width
                $h = $script:GraphBox.Height
                $g.Clear([System.Drawing.Color]::White)
                if ($script:PingHistory.Count -eq 0) {
                    $font0 = New-Object System.Drawing.Font("Arial", 7)
                    $txt0 = "Няма данни - стартирайте тест или мониторинг"
                    $sz0 = $g.MeasureString($txt0, $font0)
                    $g.DrawString($txt0, $font0, [System.Drawing.Brushes]::Gray,
                        [float](($w - $sz0.Width) / 2), [float](($h - $sz0.Height) / 2))
                    $font0.Dispose()
                    return
                }
                $cnt = $script:PingHistory.Count
                $n = $cnt
                if ($n -gt 120) { $n = 120 }
                $startIdx = $cnt - $n
                $sum = 0.0; $maxV = 0.0; $rcv = 0
                for ($i = 0; $i -lt $n; $i++) {
                    $v = [double]$script:PingHistory[$startIdx + $i]
                    if ($v -ge 0) {
                        $sum += $v
                        if ($v -gt $maxV) { $maxV = $v }
                        $rcv++
                    }
                }
                $avg = 0.0
                if ($rcv -gt 0) { $avg = $sum / $rcv }
                $scaleMax = $maxV
                if ($scaleMax -lt 50) { $scaleMax = 50 }
                $step = [double]$w / 120.0
                $greenBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 170, 60))
                $redBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 60, 60))
                $orangeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 150, 40))
                for ($i = 0; $i -lt $n; $i++) {
                    $v = [double]$script:PingHistory[$startIdx + $i]
                    $x = [float]($i * $step)
                    $bw = [float]($step - 1)
                    if ($bw -lt 1) { $bw = 1 }
                    if ($v -lt 0) {
                        $g.FillRectangle($redBrush, $x, 0.0, $bw, [float]$h)
                    } else {
                        $bh = [double]$h * ($v / $scaleMax)
                        if ($bh -gt $h) { $bh = $h }
                        if ($bh -lt 1) { $bh = 1 }
                        $barBrush = $greenBrush
                        if ($v -gt ($avg * 3) -and $v -gt 50) { $barBrush = $orangeBrush }
                        $g.FillRectangle($barBrush, $x, [float]($h - $bh), $bw, [float]$bh)
                    }
                }
                if ($rcv -gt 0) {
                    $avgY = [double]$h * (1.0 - ($avg / $scaleMax))
                    if ($avgY -lt 0) { $avgY = 0 }
                    if ($avgY -gt ($h - 1)) { $avgY = $h - 1 }
                    $avgPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Gray, 1)
                    $g.DrawLine($avgPen, 0.0, [float]$avgY, [float]$w, [float]$avgY)
                    $avgPen.Dispose()
                    $font1 = New-Object System.Drawing.Font("Arial", 7)
                    $info = "avg " + [math]::Round($avg,1) + " ms / max " + [math]::Round($maxV,1) + " ms"
                    $isz = $g.MeasureString($info, $font1)
                    $g.DrawString($info, $font1, [System.Drawing.Brushes]::DarkSlateGray,
                        [float]($w - $isz.Width - 3), 1.0)
                    $font1.Dispose()
                }
                $greenBrush.Dispose()
                $redBrush.Dispose()
                $orangeBrush.Dispose()
            } catch { }
        })

        # ---------- Log ----------
        $script:RichLog = New-Object System.Windows.Forms.RichTextBox
        $script:RichLog.Location = New-Object System.Drawing.Point(10, 424)
        $script:RichLog.Size = New-Object System.Drawing.Size(784, 176)
        $script:RichLog.Anchor = "Top, Bottom, Left, Right"
        $script:RichLog.ReadOnly = $true
        $script:RichLog.BackColor = [System.Drawing.Color]::White
        $script:RichLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
        $script:RichLog.WordWrap = $false
        $script:RichLog.ScrollBars = "Both"
        $form.Controls.Add($script:RichLog)

        # ---------- Bottom buttons ----------
        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = "Запази лога"
        $btnSave.Location = New-Object System.Drawing.Point(10, 610)
        $btnSave.Size = New-Object System.Drawing.Size(120, 28)
        $btnSave.Anchor = "Bottom, Left"
        $form.Controls.Add($btnSave)

        $btnCopy = New-Object System.Windows.Forms.Button
        $btnCopy.Text = "Копирай лога"
        $btnCopy.Location = New-Object System.Drawing.Point(140, 610)
        $btnCopy.Size = New-Object System.Drawing.Size(120, 28)
        $btnCopy.Anchor = "Bottom, Left"
        $form.Controls.Add($btnCopy)

        $btnClear = New-Object System.Windows.Forms.Button
        $btnClear.Text = "Изчисти"
        $btnClear.Location = New-Object System.Drawing.Point(270, 610)
        $btnClear.Size = New-Object System.Drawing.Size(120, 28)
        $btnClear.Anchor = "Bottom, Left"
        $form.Controls.Add($btnClear)

        $btnScan = New-Object System.Windows.Forms.Button
        $btnScan.Text = "Сканирай LAN"
        $btnScan.Location = New-Object System.Drawing.Point(400, 610)
        $btnScan.Size = New-Object System.Drawing.Size(140, 28)
        $btnScan.Anchor = "Bottom, Left"
        $form.Controls.Add($btnScan)

        # ---------- Load settings ----------
        $gw = Get-DefaultGateway
        if ($gw -ne "") { $txtRouter.Text = $gw }
        $saved = Load-Settings
        if ($saved.ContainsKey("RouterIP") -and $saved["RouterIP"] -ne "") { $txtRouter.Text = $saved["RouterIP"] }
        if ($saved.ContainsKey("ServerIP")) { $txtServer.Text = $saved["ServerIP"] }
        if ($saved.ContainsKey("ServerPorts") -and $saved["ServerPorts"] -ne "") { $txtPorts.Text = $saved["ServerPorts"] }
        if ($saved.ContainsKey("PingCount")) {
            $n = 0
            if ([int]::TryParse($saved["PingCount"], [ref]$n) -and $n -ge 5 -and $n -le 200) { $numPing.Value = $n }
        }
        if ($saved.ContainsKey("StabilitySeconds")) {
            $n = 0
            if ([int]::TryParse($saved["StabilitySeconds"], [ref]$n) -and $n -ge 0 -and $n -le 600) { $numStab.Value = $n }
        }
        if ($saved.ContainsKey("LoadConnections")) {
            $n = 0
            if ([int]::TryParse($saved["LoadConnections"], [ref]$n) -and $n -ge 2 -and $n -le 100) { $numLoadConns.Value = $n }
        }
        if ($saved.ContainsKey("LoadSeconds")) {
            $n = 0
            if ([int]::TryParse($saved["LoadSeconds"], [ref]$n) -and $n -ge 5 -and $n -le 300) { $numLoadSec.Value = $n }
        }
        if ($saved.ContainsKey("LoadFile")) { $txtLoadFile.Text = $saved["LoadFile"] }
        if ($saved.ContainsKey("MonitorInterval")) {
            $n = 0
            if ([int]::TryParse($saved["MonitorInterval"], [ref]$n) -and $n -ge 1 -and $n -le 300) { $numMonInt.Value = $n }
        }
        if ($saved.ContainsKey("BeepOnProblem")) { $chkBeep.Checked = ($saved["BeepOnProblem"] -eq "1") }

        # ---------- Events ----------
        $btnStart.Add_Click({
            if ($script:Running) { return }
            $router = $txtRouter.Text.Trim()
            $server = $txtServer.Text.Trim()
            if ($router -eq "") {
                Write-Log "ВНИМАНИЕ: не е зададен IP адрес на рутера." "Warn"
            }
            if ($server -eq "") {
                Write-Log "Не е зададен сървър - тестовете към сървъра ще бъдат пропуснати." "Warn"
            } else {
                $tmp = $null
                if (-not [System.Net.IPAddress]::TryParse($server, [ref]$tmp)) {
                    $resName = $null
                    if ((Resolve-Target $server ([ref]$resName)) -eq $null) {
                        Write-Log ("Сървърът '" + $server + "' не е валиден IP адрес и не може да се разреши.") "Fail"
                        return
                    }
                }
            }
            Save-Settings $router $server $txtPorts.Text.Trim() ([int]$numPing.Value) ([int]$numStab.Value) `
                ([int]$numLoadConns.Value) ([int]$numLoadSec.Value) $txtLoadFile.Text.Trim() `
                ([int]$numMonInt.Value) ([int]$chkBeep.Checked)
            $btnStart.Enabled = $false
            $btnLoad.Enabled = $false
            $btnQuick.Enabled = $false
            $btnScan.Enabled = $false
            $btnMon.Enabled = $false
            $btnStop.Enabled = $true
            Start-AllTests -RouterIp $router -ServerTarget $server -PortsCsv $txtPorts.Text.Trim() `
                -PingCount ([int]$numPing.Value) -StabSec ([int]$numStab.Value) `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon
        })

        $btnLoad.Add_Click({
            if ($script:Running) { return }
            $router = $txtRouter.Text.Trim()
            $server = $txtServer.Text.Trim()
            if ($server -eq "") {
                Write-Log "Задайте IP на сървъра, за да стартирате теста с натоварване." "Warn"
                return
            }
            $tmp = $null
            if (-not [System.Net.IPAddress]::TryParse($server, [ref]$tmp)) {
                $resName = $null
                if ((Resolve-Target $server ([ref]$resName)) -eq $null) {
                    Write-Log ("Сървърът '" + $server + "' не е валиден IP адрес и не може да се разреши.") "Fail"
                    return
                }
            }
            Save-Settings $router $server $txtPorts.Text.Trim() ([int]$numPing.Value) ([int]$numStab.Value) `
                ([int]$numLoadConns.Value) ([int]$numLoadSec.Value) $txtLoadFile.Text.Trim() `
                ([int]$numMonInt.Value) ([int]$chkBeep.Checked)
            $btnStart.Enabled = $false
            $btnLoad.Enabled = $false
            $btnQuick.Enabled = $false
            $btnScan.Enabled = $false
            $btnMon.Enabled = $false
            $btnStop.Enabled = $true
            Start-LoadTests -ServerTarget $server -PortsCsv $txtPorts.Text.Trim() `
                -Connections ([int]$numLoadConns.Value) -Seconds ([int]$numLoadSec.Value) `
                -LoadFile $txtLoadFile.Text.Trim() `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon
        })

        $btnQuick.Add_Click({
            if ($script:Running) { return }
            $router = $txtRouter.Text.Trim()
            $server = $txtServer.Text.Trim()
            if ($server -ne "") {
                $tmp = $null
                if (-not [System.Net.IPAddress]::TryParse($server, [ref]$tmp)) {
                    $resName = $null
                    if ((Resolve-Target $server ([ref]$resName)) -eq $null) {
                        Write-Log ("Сървърът '" + $server + "' не е валиден IP адрес и не може да се разреши.") "Fail"
                        return
                    }
                }
            }
            Save-Settings $router $server $txtPorts.Text.Trim() ([int]$numPing.Value) ([int]$numStab.Value) `
                ([int]$numLoadConns.Value) ([int]$numLoadSec.Value) $txtLoadFile.Text.Trim() `
                ([int]$numMonInt.Value) ([int]$chkBeep.Checked)
            $btnStart.Enabled = $false
            $btnLoad.Enabled = $false
            $btnQuick.Enabled = $false
            $btnScan.Enabled = $false
            $btnMon.Enabled = $false
            $btnStop.Enabled = $true
            Start-QuickTest -RouterIp $router -ServerTarget $server `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon
        })

        $btnMon.Add_Click({
            if ($script:Running) { return }
            $router = $txtRouter.Text.Trim()
            $server = $txtServer.Text.Trim()
            if ($server -eq "") {
                Write-Log "Не е зададен сървър - мониторингът ще следи само рутера и интернет (8.8.8.8)." "Warn"
            } else {
                $tmp = $null
                if (-not [System.Net.IPAddress]::TryParse($server, [ref]$tmp)) {
                    $resName = $null
                    if ((Resolve-Target $server ([ref]$resName)) -eq $null) {
                        Write-Log ("Сървърът '" + $server + "' не е валиден IP адрес и не може да се разреши.") "Fail"
                        return
                    }
                }
            }
            Save-Settings $router $server $txtPorts.Text.Trim() ([int]$numPing.Value) ([int]$numStab.Value) `
                ([int]$numLoadConns.Value) ([int]$numLoadSec.Value) $txtLoadFile.Text.Trim() `
                ([int]$numMonInt.Value) ([int]$chkBeep.Checked)
            $btnStart.Enabled = $false
            $btnLoad.Enabled = $false
            $btnQuick.Enabled = $false
            $btnScan.Enabled = $false
            $btnMon.Enabled = $false
            $btnStop.Enabled = $true
            Start-Monitor -RouterIp $router -ServerTarget $server `
                -IntervalSec ([int]$numMonInt.Value) -Beep $chkBeep.Checked `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon
        })

        $btnScan.Add_Click({
            if ($script:Running) { return }
            $router = $txtRouter.Text.Trim()
            $server = $txtServer.Text.Trim()
            Save-Settings $router $server $txtPorts.Text.Trim() ([int]$numPing.Value) ([int]$numStab.Value) `
                ([int]$numLoadConns.Value) ([int]$numLoadSec.Value) $txtLoadFile.Text.Trim() `
                ([int]$numMonInt.Value) ([int]$chkBeep.Checked)
            $btnStart.Enabled = $false
            $btnLoad.Enabled = $false
            $btnQuick.Enabled = $false
            $btnScan.Enabled = $false
            $btnMon.Enabled = $false
            $btnStop.Enabled = $true
            Invoke-NetworkScan -ServerTarget $server `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon
        })

        $btnStop.Add_Click({
            $script:StopRequested = $true
            $btnStop.Enabled = $false
        })

        $btnSave.Add_Click({
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = "Текстови файлове (*.txt)|*.txt"
            $stamp = [DateTime]::Now.ToString("yyyy-MM-dd_HH-mm-ss")
            $dlg.FileName = "NetworkTester_" + $stamp + ".txt"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                if (Save-LogToFile $dlg.FileName) {
                    Write-Log ("Логът е запазен в: " + $dlg.FileName) "OK"
                }
            }
        })

        $btnCopy.Add_Click({
            if ($script:LogLines.Count -gt 0) {
                [System.Windows.Forms.Clipboard]::SetText(($script:LogLines -join "`r`n"))
                Write-Log "Логът е копиран в клипборда." "OK"
            }
        })

        $btnClear.Add_Click({
            $script:RichLog.Clear()
            [void]$script:LogLines.Clear()
        })

        Write-Log "NetworkTester е готов. Попълнете настройките и изберете: 'Старт', 'Бърз тест', 'Старт натоварване', 'Старт мониторинг' или 'Сканирай LAN'." "Header"
        [void]$form.ShowDialog()
    } catch {
        try { Add-Type -AssemblyName System.Windows.Forms } catch { }
        [System.Windows.Forms.MessageBox]::Show(
            "Възникна грешка: " + $_.Exception.Message,
            "NetworkTester",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Write-Host ("ERROR: " + $_.Exception.Message)
        exit 1
    }
}
