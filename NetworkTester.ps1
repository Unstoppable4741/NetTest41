# NetworkTester - Windows 7/10/11, PowerShell 2.0+ compatible
$script:StopRequested = $false
$script:Running = $false
$script:LogLines = New-Object System.Collections.ArrayList
$script:LogEntries = New-Object System.Collections.ArrayList
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
    [void]$script:LogEntries.Add((New-Object PSObject -Property @{ Text = $line; Level = $Level }))
    while ($script:LogEntries.Count -gt 20000) {
        $script:LogEntries.RemoveAt(0)
    }
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

function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Request-Elevation {
    # Връща $true само ако е стартирана нова инстанция с админ права (повикващият трябва да спре).
    if (Test-IsAdmin) { return $false }
    $ans = [System.Windows.Forms.DialogResult]::No
    try {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Тази функция изисква администраторски права.`r`nДа стартирам програмата като администратор?",
            "NetworkTester",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
    } catch { return $false }
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-Command','iex ((New-Object System.Net.WebClient).DownloadString(''https://raw.githubusercontent.com/Unstoppable4741/NetTest41/main/NetworkTester.ps1''))'
        return $true
    } catch {
        Write-Log ("Стартирането с администраторски права е отказано: " + $_.Exception.Message) "Warn"
        return $false
    }
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
    Compare-WithPrevious
    Save-LastResults
}

function Save-LastResults {
    try {
        if (-not (Test-Path $script:SettingsDir)) {
            [void](New-Item -ItemType Directory -Path $script:SettingsDir -Force)
        }
        $lrPath = Join-Path $script:SettingsDir "last_results.txt"
        $lrLines = New-Object System.Collections.ArrayList
        [void]$lrLines.Add("timestamp=" + [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))
        foreach ($r in $script:Results) {
            $nm = ("" + $r.Name) -replace "\|", "/"
            $dt = ("" + $r.Detail) -replace "\|", "/"
            $dt = $dt -replace "[`r`n]", " "
            [void]$lrLines.Add($nm + "|" + $r.Status + "|" + $dt)
        }
        [System.IO.File]::WriteAllText($lrPath, ($lrLines -join "`r`n"), [System.Text.Encoding]::UTF8)
    } catch { }
}

function Compare-WithPrevious {
    $lrPath = Join-Path $script:SettingsDir "last_results.txt"
    $prev = @{}
    $prevDate = ""
    $hasPrev = $false
    if (Test-Path $lrPath) {
        try {
            $fLines = @(Get-Content $lrPath -ErrorAction Stop)
            if ($fLines.Count -gt 0 -and ("" + $fLines[0]).StartsWith("timestamp=")) {
                $prevDate = ("" + $fLines[0]).Substring(10)
                for ($i = 1; $i -lt $fLines.Count; $i++) {
                    $parts = ("" + $fLines[$i]).Split("|")
                    if ($parts.Count -ge 2) { $prev[$parts[0]] = "" + $parts[1] }
                }
                $hasPrev = $true
            }
        } catch { }
    }
    if (-not $hasPrev) {
        Write-Log "Няма предишен тест за сравнение."
        return
    }
    Write-Log ("=== СРАВНЕНИЕ С ПРЕДИШЕН ТЕСТ (" + $prevDate + ") ===") "Header"
    $rank = @{ "OK" = 0; "Warn" = 1; "Fail" = 2 }
    $same = 0
    $better = 0
    $worse = 0
    foreach ($r in $script:Results) {
        $nm = "" + $r.Name
        if ($prev.ContainsKey($nm)) {
            $oldSt = "" + $prev[$nm]
            $newSt = "" + $r.Status
            if ($oldSt -eq $newSt) {
                $same++
            } else {
                $oldR = 1
                $newR = 1
                if ($rank.ContainsKey($oldSt)) { $oldR = $rank[$oldSt] }
                if ($rank.ContainsKey($newSt)) { $newR = $rank[$newSt] }
                if ($newR -gt $oldR) {
                    $worse++
                    Write-Log ("  " + $nm + ": " + $oldSt + " -> " + $newSt) "Warn"
                } else {
                    $better++
                    Write-Log ("  " + $nm + ": " + $oldSt + " -> " + $newSt) "OK"
                }
            }
        } else {
            Write-Log ("  " + $nm + ": нов тест")
        }
    }
    Write-Log ("Без промяна: " + $same + ", подобрени: " + $better + ", влошени: " + $worse)
}

function Export-HtmlReport {
    param([string]$Path)
    try {
        $esc = {
            param($s)
            return (("" + $s) -replace "&", "&amp;") -replace "<", "&lt;" -replace ">", "&gt;"
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("<!DOCTYPE html>")
        [void]$sb.AppendLine("<html lang=""bg"">")
        [void]$sb.AppendLine("<head>")
        [void]$sb.AppendLine("<meta charset=""utf-8"">")
        [void]$sb.AppendLine("<title>NetworkTester - отчет</title>")
        [void]$sb.AppendLine("<style>")
        [void]$sb.AppendLine("body{font-family:Consolas,'Courier New',monospace;background:#ffffff;color:#222;margin:24px;}")
        [void]$sb.AppendLine("h1{font-size:20px;margin-bottom:4px;}")
        [void]$sb.AppendLine(".meta{color:#555;margin-bottom:16px;}")
        [void]$sb.AppendLine("table{border-collapse:collapse;margin-bottom:20px;}")
        [void]$sb.AppendLine("th,td{border:1px solid #bbb;padding:3px 10px;text-align:left;font-size:13px;}")
        [void]$sb.AppendLine("th{background:#eeeeee;}")
        [void]$sb.AppendLine(".st-OK{background:#dff0d8;}")
        [void]$sb.AppendLine(".st-Warn{background:#fbe9c6;}")
        [void]$sb.AppendLine(".st-Fail{background:#f5d2d2;}")
        [void]$sb.AppendLine("pre{border:1px solid #cccccc;padding:10px;font-size:13px;white-space:pre-wrap;margin:0;}")
        [void]$sb.AppendLine("pre div{min-height:14px;}")
        [void]$sb.AppendLine(".l-OK{color:#187018;}")
        [void]$sb.AppendLine(".l-Warn{color:#b06000;}")
        [void]$sb.AppendLine(".l-Fail{color:#c00000;}")
        [void]$sb.AppendLine(".l-Header{color:#003a8c;font-weight:bold;}")
        [void]$sb.AppendLine("</style>")
        [void]$sb.AppendLine("</head>")
        [void]$sb.AppendLine("<body>")
        [void]$sb.AppendLine("<h1>NetworkTester - отчет</h1>")
        [void]$sb.AppendLine("<div class=""meta"">")
        [void]$sb.AppendLine(("Компютър: " + (& $esc $env:COMPUTERNAME) + " &nbsp;|&nbsp; Потребител: " + (& $esc ($env:USERDOMAIN + "\" + $env:USERNAME)) + "<br>"))
        [void]$sb.AppendLine(("Дата: " + [DateTime]::Now.ToString("dd.MM.yyyy HH:mm:ss") + " &nbsp;|&nbsp; Генерирано от NetworkTester - тест на мрежовата връзка"))
        [void]$sb.AppendLine("</div>")
        if ($script:Results.Count -gt 0) {
            [void]$sb.AppendLine("<table>")
            [void]$sb.AppendLine("<tr><th>Тест</th><th>Статус</th><th>Детайли</th></tr>")
            foreach ($r in $script:Results) {
                $cls = ""
                if ($r.Status -eq "OK") { $cls = " class=""st-OK""" }
                elseif ($r.Status -eq "Warn") { $cls = " class=""st-Warn""" }
                elseif ($r.Status -eq "Fail") { $cls = " class=""st-Fail""" }
                $v = @{ "OK" = "OK"; "Warn" = "ВНИМАНИЕ"; "Fail" = "ПРОБЛЕМ" }[$r.Status]
                if ($v -eq $null) { $v = "" + $r.Status }
                [void]$sb.AppendLine("<tr><td>" + (& $esc $r.Name) + "</td><td" + $cls + ">" + (& $esc $v) + "</td><td>" + (& $esc $r.Detail) + "</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }
        [void]$sb.AppendLine("<pre>")
        foreach ($e in $script:LogEntries) {
            $cls = ""
            switch ($e.Level) {
                "OK"     { $cls = "l-OK" }
                "Warn"   { $cls = "l-Warn" }
                "Fail"   { $cls = "l-Fail" }
                "Header" { $cls = "l-Header" }
            }
            if ($cls -ne "") {
                [void]$sb.AppendLine("<div class=""" + $cls + """>" + (& $esc $e.Text) + "</div>")
            } else {
                [void]$sb.AppendLine("<div>" + (& $esc $e.Text) + "</div>")
            }
        }
        [void]$sb.AppendLine("</pre>")
        [void]$sb.AppendLine("</body>")
        [void]$sb.AppendLine("</html>")
        [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.Encoding]::UTF8)
        return $true
    } catch {
        Write-Log ("Неуспешен запис на HTML отчета: " + $_.Exception.Message) "Fail"
        return $false
    }
}

function Complete-TestRun {
    param($Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml)
    if ($script:LogLines.Count -gt 0) {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $stamp = [DateTime]::Now.ToString("yyyy-MM-dd_HH-mm-ss")
        $logPath = Join-Path $desktop ("NetworkTester_" + $stamp + ".txt")
        if (Save-LogToFile $logPath) {
            Write-Log ("Логът е запазен в: " + $logPath) "OK"
        }
        $htmlPath = Join-Path $desktop ("NetworkTester_" + $stamp + ".html")
        if (Export-HtmlReport $htmlPath) {
            Write-Log ("HTML отчетът е запазен в: " + $htmlPath) "OK"
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
    if ($BtnInfo -ne $null) { $BtnInfo.Enabled = $true }
    if ($BtnDisk -ne $null) { $BtnDisk.Enabled = $true }
    if ($BtnRam -ne $null) { $BtnRam.Enabled = $true }
    if ($BtnSys -ne $null) { $BtnSys.Enabled = $true }
    if ($BtnProgs -ne $null) { $BtnProgs.Enabled = $true }
    if ($BtnHtml -ne $null) { $BtnHtml.Enabled = $true }
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
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
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
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Start-AllTests {
    param(
        [string]$RouterIp, [string]$ServerTarget, [string]$PortsCsv,
        [int]$PingCount, [int]$StabSec,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
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
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Start-QuickTest {
    param(
        [string]$RouterIp, [string]$ServerTarget,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
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
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Start-Monitor {
    param(
        [string]$RouterIp, [string]$ServerTarget, [int]$IntervalSec, [bool]$Beep,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
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
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Invoke-NetworkScan {
    param(
        [string]$ServerTarget,
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
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
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Convert-U16ArrayToText {
    param($Arr)
    if ($Arr -eq $null) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($v in $Arr) {
        $c = [int]$v
        if ($c -ne 0) { [void]$sb.Append([char]$c) }
    }
    return $sb.ToString().Trim()
}

function Show-SystemInventory {
    param(
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Събиране на информация за машината..."

        Write-Log "=== ИНВЕНТАРИЗАЦИЯ НА МАШИНАТА ===" "Header"
        $freeRamTxt = ""
        $invComp = ""
        $invUser = ""
        $invOs = ""
        $invCpu = ""
        $invRamGb = ""
        $invSerial = ""
        $invUuid = ""
        $invIp = ""
        $invMac = ""

        # --- Идентичност ---
        try {
            $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
            $invComp = "" + $cs.Name
            Write-Log (("  {0,-22}" -f "Компютър") + $cs.Name)
            if ($cs.PartOfDomain) {
                Write-Log (("  {0,-22}" -f "Домейн") + $cs.Domain)
            } else {
                Write-Log (("  {0,-22}" -f "Работна група") + $cs.Domain)
            }
        } catch {
            Write-Log ("  Грешка при четене на данните за компютъра: " + $_.Exception.Message) "Warn"
        }
        $invUser = $env:USERDOMAIN + "\" + $env:USERNAME
        Write-Log (("  {0,-22}" -f "Потребител") + $invUser)
        Do-Events

        # --- Операционна система ---
        try {
            $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
            $cap = "" + $os.Caption
            $cap = ($cap -replace "^Microsoft\s+", "").Trim()
            $build = 0
            try { $build = [int]$os.BuildNumber } catch { }
            if ($build -ge 22000) { $cap = $cap -replace "Windows 10", "Windows 11" }
            $archTxt = "32-бит"
            if ($os.OSArchitecture -ne $null) {
                if ($os.OSArchitecture -match "64") { $archTxt = "64-бит" }
            } elseif ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64" -or $env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
                $archTxt = "64-бит"
            }
            $cap = $cap + " (build " + $build + "), " + $archTxt
            $invOs = $cap
            Write-Log (("  {0,-22}" -f "Операционна система") + $cap)
            try {
                $inst = [System.Management.ManagementDateTimeConverter]::ToDateTime($os.InstallDate)
                Write-Log (("  {0,-22}" -f "Инсталирана") + $inst.ToString("dd.MM.yyyy"))
            } catch { }
            try {
                $boot = [System.Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
                $upDays = (New-TimeSpan -Start $boot -End ([DateTime]::Now)).Days
                Write-Log (("  {0,-22}" -f "Последно зареждане") + ($boot.ToString("dd.MM.yyyy HH:mm") + " (преди " + $upDays + " дни)"))
            } catch { }
            try {
                if ($os.FreePhysicalMemory -ne $null) {
                    $freeRamTxt = "" + [math]::Round([double]$os.FreePhysicalMemory / 1MB, 1) + " GB"
                }
            } catch { }
        } catch {
            Write-Log ("  Грешка при четене на данните за Windows: " + $_.Exception.Message) "Warn"
        }
        Do-Events

        # --- Хардуер ---
        try {
            $cs2 = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
            Write-Log (("  {0,-22}" -f "Производител/модел") + ($cs2.Manufacturer + " " + $cs2.Model))
        } catch {
            Write-Log ("  Грешка при четене на производител/модел: " + $_.Exception.Message) "Warn"
        }
        try {
            $bb = Get-WmiObject Win32_BaseBoard -ErrorAction Stop
            Write-Log (("  {0,-22}" -f "Дънна платка") + (($bb.Manufacturer + " " + $bb.Product).Trim()))
        } catch { }
        try {
            $bios = Get-WmiObject Win32_BIOS -ErrorAction Stop
            $invSerial = "" + $bios.SerialNumber
            Write-Log (("  {0,-22}" -f "Сериен номер") + $bios.SerialNumber)
        } catch { }
        try {
            $csp = Get-WmiObject Win32_ComputerSystemProduct -ErrorAction Stop
            $invUuid = "" + $csp.UUID
            Write-Log (("  {0,-22}" -f "UUID") + $csp.UUID)
        } catch { }
        Do-Events

        # --- Процесор ---
        try {
            $cpus = @(Get-WmiObject Win32_Processor -ErrorAction Stop)
            $cpuIdx = 0
            foreach ($cpu in $cpus) {
                $cpuIdx++
                $cpuName = ("" + $cpu.Name) -replace "\s+", " "
                $cpuName = $cpuName.Trim()
                if ($cpuIdx -eq 1) { $invCpu = $cpuName }
                $cpuTxt = $cpuName + " (" + ("" + $cpu.NumberOfCores) + " ядра / " + $cpu.NumberOfLogicalProcessors + " нишки)"
                $cpuLbl = "Процесор"
                if ($cpuIdx -gt 1) { $cpuLbl = "Процесор " + $cpuIdx }
                Write-Log (("  {0,-22}" -f $cpuLbl) + $cpuTxt)
            }
        } catch {
            Write-Log ("  Грешка при четене на данните за процесора: " + $_.Exception.Message) "Warn"
        }
        Do-Events

        # --- Памет (RAM) ---
        try {
            $totalBytes = 0.0
            $modCount = 0
            foreach ($pm in @(Get-WmiObject Win32_PhysicalMemory -ErrorAction Stop)) {
                if ($pm.Capacity -ne $null) { $totalBytes += [double]$pm.Capacity; $modCount++ }
            }
            if ($modCount -gt 0) {
                $invRamGb = "" + [math]::Round($totalBytes / 1GB, 1)
                $ramTxt = "" + [math]::Round($totalBytes / 1GB, 1) + " GB (" + $modCount + " модула)"
                if ($freeRamTxt -ne "") { $ramTxt = $ramTxt + ", свободни " + $freeRamTxt }
                Write-Log (("  {0,-22}" -f "Памет (RAM)") + $ramTxt)
            }
        } catch {
            Write-Log ("  Грешка при четене на данните за паметта: " + $_.Exception.Message) "Warn"
        }
        Do-Events

        # --- Видеокарта ---
        try {
            $vnames = New-Object System.Collections.ArrayList
            foreach ($vc in @(Get-WmiObject Win32_VideoController -ErrorAction Stop)) {
                if ($vc.Name -ne $null -and ("" + $vc.Name).Trim() -ne "") {
                    [void]$vnames.Add(("" + $vc.Name).Trim())
                }
            }
            if ($vnames.Count -gt 0) {
                Write-Log (("  {0,-22}" -f "Видеокарта") + ($vnames -join "; "))
            }
        } catch { }

        # --- Дискове ---
        try {
            foreach ($dd in @(Get-WmiObject Win32_DiskDrive -ErrorAction Stop)) {
                $sizeGb = [math]::Round([double]$dd.Size / 1GB, 1)
                Write-Log (("  {0,-22}" -f "Диск") + ($dd.Model + " - " + $sizeGb + " GB"))
            }
        } catch { }
        try {
            foreach ($ld in @(Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop)) {
                $totGb = [math]::Round([double]$ld.Size / 1GB, 1)
                $freeGb = [math]::Round([double]$ld.FreeSpace / 1GB, 1)
                Write-Log (("  {0,-22}" -f ("Дял " + $ld.DeviceID)) + ("" + $totGb + " GB общо / " + $freeGb + " GB свободни"))
            }
        } catch { }
        Do-Events

        # --- Монитор ---
        try {
            $mons = @(Get-WmiObject -Namespace root\wmi -Class WmiMonitorID -ErrorAction Stop)
            $monIdx = 0
            foreach ($mi in $mons) {
                $monIdx++
                $mName = Convert-U16ArrayToText $mi.UserFriendlyName
                $mMan = Convert-U16ArrayToText $mi.ManufacturerName
                $mSer = Convert-U16ArrayToText $mi.SerialNumberID
                $mTxt = $mName
                if ($mTxt -eq "") { $mTxt = $mMan }
                if ($mSer -ne "") { $mTxt = $mTxt + " (S/N " + $mSer + ")" }
                if ($mTxt.Trim() -ne "") {
                    $monLbl = "Монитор"
                    if ($monIdx -gt 1) { $monLbl = "Монитор " + $monIdx }
                    Write-Log (("  {0,-22}" -f $monLbl) + $mTxt.Trim())
                }
            }
        } catch { }
        Do-Events

        # --- Мрежови адаптери ---
        try {
            $adapters = @(Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" -ErrorAction Stop)
            if ($adapters.Count -gt 0) {
                Write-Log "  --- Мрежови адаптери ---"
                foreach ($na in $adapters) {
                    Write-Log ("    " + $na.Description)
                    Write-Log ("      MAC: " + $na.MACAddress)
                    if ($invMac -eq "") { $invMac = "" + $na.MACAddress }
                    $ipList = New-Object System.Collections.ArrayList
                    if ($na.IPAddress -ne $null) {
                        foreach ($ip in $na.IPAddress) {
                            if ($ip.IndexOf(".") -ge 0) { [void]$ipList.Add($ip) }
                        }
                    }
                    $maskList = New-Object System.Collections.ArrayList
                    if ($na.IPSubnet -ne $null) {
                        foreach ($sm in $na.IPSubnet) {
                            if ($sm.IndexOf(".") -ge 0) { [void]$maskList.Add($sm) }
                        }
                    }
                    if ($invIp -eq "" -and $ipList.Count -gt 0) { $invIp = "" + $ipList[0] }
                    Write-Log ("      IPv4: " + ($ipList -join ", ") + "   Маска: " + ($maskList -join ", "))
                    $gwTxt = ""
                    if ($na.DefaultIPGateway -ne $null) { $gwTxt = ($na.DefaultIPGateway -join ", ") }
                    Write-Log ("      Шлюз: " + $gwTxt)
                    if ($na.DHCPEnabled) {
                        Write-Log ("      DHCP: включен (сървър " + $na.DHCPServer + ")")
                    } else {
                        Write-Log "      DHCP: изключен (статична конфигурация)"
                    }
                    $dnsTxt = ""
                    if ($na.DNSServerSearchOrder -ne $null) { $dnsTxt = ($na.DNSServerSearchOrder -join ", ") }
                    Write-Log ("      DNS: " + $dnsTxt)
                    Do-Events
                }
            }
        } catch {
            Write-Log ("  Грешка при четене на мрежовата конфигурация: " + $_.Exception.Message) "Warn"
        }

        # --- Запис на реда в inventory.csv ---
        try {
            $csvPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "inventory.csv"
            $csvEsc = {
                param($v)
                $s = "" + $v
                if ($s.Contains(";") -or $s.Contains('"')) {
                    $s = '"' + ($s -replace '"', '""') + '"'
                }
                return $s
            }
            if (-not (Test-Path $csvPath)) {
                $csvHdr = "Дата;Компютър;Потребител;Windows;CPU;RAM_GB;Сериен_номер;UUID;IP;MAC"
                [System.IO.File]::WriteAllText($csvPath, $csvHdr + "`r`n", [System.Text.Encoding]::UTF8)
            }
            $csvRow = (& $csvEsc ([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))) + ";" +
                      (& $csvEsc $invComp) + ";" + (& $csvEsc $invUser) + ";" + (& $csvEsc $invOs) + ";" +
                      (& $csvEsc $invCpu) + ";" + (& $csvEsc $invRamGb) + ";" + (& $csvEsc $invSerial) + ";" +
                      (& $csvEsc $invUuid) + ";" + (& $csvEsc $invIp) + ";" + (& $csvEsc $invMac)
            [System.IO.File]::AppendAllText($csvPath, $csvRow + "`r`n", [System.Text.Encoding]::UTF8)
            Write-Log ("  Добавен ред в inventory.csv (" + $csvPath + ")") "OK"
        } catch {
            Write-Log ("  Неуспешен запис в inventory.csv: " + $_.Exception.Message) "Warn"
        }

        Add-Result "Инвентаризация" "OK" "данните са събрани"
        Write-Log "Данните са включени в лога - използвайте 'Запази лога' или файлът на Desktop." "OK"

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Invoke-ExternalLogged {
    param([string]$Exe, [string]$ArgsLine, [string]$OutFile, [string]$StatusText)
    try { if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue } } catch { }
    $p = $null
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $ArgsLine -RedirectStandardOutput $OutFile -NoNewWindow -PassThru -ErrorAction Stop
    } catch {
        Write-Log ("    Не може да се стартира " + $Exe + ": " + $_.Exception.Message) "Warn"
        return $null
    }
    while (-not $p.HasExited) {
        Set-Status $StatusText
        Do-Events
        if (Stop-Check) {
            try { $p.Kill() } catch { }
            return $null
        }
        Start-Sleep -Milliseconds 300
    }
    $code = $p.ExitCode
    $lines = @()
    try { $lines = @(Get-Content $OutFile -ErrorAction SilentlyContinue) } catch { }
    $shown = 0
    foreach ($ln in $lines) {
        $t = ("" + $ln).Trim()
        if ($t -eq "") { continue }
        Write-Log ("    " + $t)
        $shown++
        if ($shown -ge 8) { break }
    }
    try { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue } catch { }
    return $code
}

function Show-DiskMaintenance {
    param(
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Проверка на дисковете..."

        Write-Log "=== ДИСКОВЕ: здраве и поддръжка ===" "Header"
        $isAdmin = Test-IsAdmin
        $elevAsked = $false
        $build = 0
        try { $build = [int](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch { }
        if ($isAdmin) {
            Write-Log "  Работи с администраторски права - всички проверки са налични."
        } else {
            Write-Log "  БЕЗ администраторски права - SMART, TRIM и почистването ще са ограничени." "Warn"
        }

        # --- Стъпка 1: физически дискове ---
        $disks = @()
        try { $disks = @(Get-WmiObject Win32_DiskDrive -ErrorAction Stop) } catch { $disks = @() }
        if ($disks.Count -eq 0) {
            Write-Log "  Не са открити физически дискове." "Fail"
            Add-Result "Дискове" "Fail" "няма открити дискове"
        }
        $physSsd = @{}
        foreach ($dd in $disks) {
            if (Stop-Check) { return }
            $model = ("" + $dd.Model).Trim()
            $sizeGb = [math]::Round([double]$dd.Size / 1GB, 1)
            $isSsd = ($model -match "SSD|NVMe|Solid")
            $physSsd["" + $dd.Index] = $isSsd
            $kind = "HDD"
            if ($isSsd) { $kind = "SSD (вероятно)" }
            Write-Log ("  Диск " + $dd.Index + ": " + $model + " - " + $sizeGb + " GB, статус: " + $dd.Status + " [" + $kind + "]")
            if (("" + $dd.Status) -eq "OK") {
                Add-Result ("Диск " + $dd.Index + " " + $model) "OK" ("" + $sizeGb + " GB " + $kind)
            } else {
                Add-Result ("Диск " + $dd.Index + " " + $model) "Warn" ("статус: " + $dd.Status)
            }
            Do-Events
        }

        # --- Стъпка 2: SMART статус (изисква админ) ---
        $smartRows = @()
        $smartFailed = $false
        try { $smartRows = @(Get-WmiObject -Namespace "root\wmi" -Class MSStorageDriver_FailurePredictStatus -ErrorAction Stop) } catch { $smartRows = @() }
        if ($smartRows.Count -eq 0) {
            $smartFailed = $true
            Write-Log "  SMART статусът не е достъпен - изисква администраторски права (или драйверът не го поддържа)." "Warn"
        } else {
            foreach ($dd in $disks) {
                if (Stop-Check) { return }
                $model = ("" + $dd.Model).Trim()
                $mw = $model
                $sp = $mw.IndexOf(" ")
                if ($sp -gt 0) { $mw = $mw.Substring(0, $sp) }
                $sRow = $null
                foreach ($s in $smartRows) {
                    if ($mw -ne "" -and (("" + $s.InstanceName).ToUpper()).Contains($mw.ToUpper())) { $sRow = $s; break }
                }
                if ($sRow -eq $null) {
                    Write-Log ("    " + $model + ": няма SMART запис за този диск.")
                } elseif ($sRow.PredictFailure) {
                    Write-Log ("    " + $model + ": SMART АЛАРМА - дискът докладва предстоящ отказ!") "Fail"
                    Add-Result ("SMART " + $model) "Fail" "предстоящ отказ"
                } else {
                    Write-Log ("    " + $model + ": SMART статус OK.") "OK"
                    Add-Result ("SMART " + $model) "OK" "без предупреждения"
                }
            }
        }

        # --- Стъпка 3: SMART атрибути ---
        $smartDataRows = @()
        try { $smartDataRows = @(Get-WmiObject -Namespace "root\wmi" -Class MSStorageDriver_FailurePredictData -ErrorAction Stop) } catch { $smartDataRows = @() }
        if ($smartDataRows.Count -eq 0) {
            if (-not $smartFailed) {
                Write-Log "  SMART атрибутите не са достъпни." "Warn"
            }
        } else {
            $attrNames = @{
                5 = "Преразпределени сектори"; 9 = "Часове работа"; 10 = "Опити за завъртане"
                12 = "Цикли вкл/изкл"; 194 = "Температура (C)"; 197 = "Чакащи сектори"
                198 = "Некоригируеми"; 199 = "UDMA CRC грешки"; 231 = "Оставащ живот (%)"
            }
            $attrWarn = 0
            foreach ($sd in $smartDataRows) {
                if (Stop-Check) { return }
                $vs = $sd.VendorSpecific
                if ($vs -eq $null) { continue }
                $inst = "" + $sd.InstanceName
                $label = $inst
                foreach ($dd in $disks) {
                    $m2 = ("" + $dd.Model).Trim()
                    $sp2 = $m2.IndexOf(" ")
                    if ($sp2 -gt 0) { $m2 = $m2.Substring(0, $sp2) }
                    if ($m2 -ne "" -and $inst.ToUpper().Contains($m2.ToUpper())) { $label = ("" + $dd.Model).Trim(); break }
                }
                Write-Log ("    " + $label + ":")
                $foundAttr = $false
                $len = [int]$vs.Length
                $off = 2
                while (($off + 12) -le $len) {
                    $aid = [int]$vs[$off]
                    if ($aid -ne 0 -and $attrNames.ContainsKey($aid)) {
                        $foundAttr = $true
                        $aval = [int]$vs[$off + 3]
                        $aworst = [int]$vs[$off + 4]
                        $raw = 0L
                        $mult = 1L
                        for ($k = 0; $k -lt 6; $k++) {
                            $raw += [long]([int]$vs[$off + 5 + $k]) * $mult
                            $mult = $mult * 256
                        }
                        Write-Log ("      " + $attrNames[$aid] + " = " + $raw + " (value/worst " + $aval + "/" + $aworst + ")")
                        if (($aid -eq 5 -or $aid -eq 197 -or $aid -eq 198 -or $aid -eq 199) -and $raw -gt 0) {
                            Write-Log ("        ВНИМАНИЕ: " + $attrNames[$aid] + " е над 0 - признак за проблеми!") "Warn"
                            $attrWarn++
                        }
                    }
                    $off += 12
                }
                if (-not $foundAttr) {
                    Write-Log "      (няма отчетени познати атрибути)"
                }
                Do-Events
            }
            if ($attrWarn -gt 0) {
                Write-Log ("  Открити са " + $attrWarn + " тревожни SMART атрибута.") "Warn"
                Add-Result "SMART атрибути" "Warn" ("" + $attrWarn + " тревожни стойности")
            } else {
                Add-Result "SMART атрибути" "OK" "в норма"
            }
        }

        # --- Стъпка 4: TRIM ---
        Write-Log "  --- TRIM проверка ---"
        $trimDisabled = $false
        try {
            $fsOut = (fsutil behavior query DisableDeleteNotify | Out-String)
            Write-Log ("  " + $fsOut.Trim())
            if ($fsOut -match "=\s*0") {
                Write-Log "  TRIM е включен." "OK"
                Add-Result "TRIM" "OK" "включен"
            } elseif ($fsOut -match "=\s*1") {
                $trimDisabled = $true
            } else {
                Write-Log "  Не може да се определи TRIM състоянието (възможно е да трябват админ права)." "Warn"
            }
        } catch {
            Write-Log ("  TRIM проверката се провали: " + $_.Exception.Message) "Warn"
        }
        if ($trimDisabled) {
            if ($isAdmin) {
                try {
                    $fsSet = (fsutil behavior set DisableDeleteNotify 0 | Out-String)
                    Write-Log ("  " + $fsSet.Trim())
                    Write-Log "  TRIM беше изключен - сега е включен." "OK"
                    Add-Result "TRIM" "OK" "включен от програмата"
                } catch {
                    Write-Log "  Неуспешно включване на TRIM." "Warn"
                    Add-Result "TRIM" "Warn" "неуспешно включване"
                }
            } else {
                Write-Log "  TRIM е ИЗКЛЮЧЕН! Включването изисква администраторски права." "Warn"
                Add-Result "TRIM" "Warn" "изключен - нужен админ"
            }
        }

        # --- Стъпка 5: Оптимизация / дефрагментация ---
        Write-Log "  --- Оптимизация / дефрагментация ---"
        if (-not $isAdmin) {
            Write-Log "  Пропускам оптимизацията - изисква администратор." "Warn"
            Add-Result "Оптимизация на дисковете" "Warn" "пропуснато - нужен админ"
            $elevAsked = $true
            if (Request-Elevation) { return }
        } else {
            $optConfirm = [System.Windows.Forms.DialogResult]::No
            try {
                $optConfirm = [System.Windows.Forms.MessageBox]::Show(
                    "Да стартирам оптимизация/дефрагментация на дисковете?`r`nТова може да отнеме дълго време (до часове за големи HDD).`r`nSSD дисковете се оптимизират с retrim (бързо).",
                    "NetworkTester",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
            } catch { }
            if ($optConfirm -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "  Оптимизацията е пропусната по желание на потребителя."
                Add-Result "Оптимизация на дисковете" "OK" "пропуснато от потребителя"
            } else {
                Write-Log "  Стартирана оптимизация - може да отнеме дълго. 'Стоп' прекъсва текущата операция."
                # карта: логически дял -> физически диск
                $partPhys = @{}
                try {
                    foreach ($a in @(Get-WmiObject Win32_DiskDriveToDiskPartition -ErrorAction Stop)) {
                        $physIdx = $null; $partId = $null
                        if (("" + $a.Antecedent) -match "PHYSICALDRIVE(\d+)") { $physIdx = $matches[1] }
                        if (("" + $a.Dependent) -match 'DeviceID="([^"]+)"') { $partId = $matches[1] }
                        if ($physIdx -ne $null -and $partId -ne $null) { $partPhys[$partId] = $physIdx }
                    }
                } catch { }
                $logPhys = @{}
                try {
                    foreach ($a in @(Get-WmiObject Win32_LogicalDiskToPartition -ErrorAction Stop)) {
                        $partId = $null; $logId = $null
                        if (("" + $a.Antecedent) -match 'DeviceID="([^"]+)"') { $partId = $matches[1] }
                        if (("" + $a.Dependent) -match 'DeviceID="([^"]+)"') { $logId = $matches[1] }
                        if ($partId -ne $null -and $logId -ne $null -and $partPhys.ContainsKey($partId)) {
                            $logPhys[$logId] = $partPhys[$partId]
                        }
                    }
                } catch { }
                foreach ($ld in @(Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
                    if (Stop-Check) { return }
                    $letter = "" + $ld.DeviceID
                    $drvSsd = $false
                    if ($logPhys.ContainsKey($letter)) {
                        $pi = $logPhys[$letter]
                        if ($physSsd.ContainsKey($pi)) { $drvSsd = $physSsd[$pi] }
                    }
                    $drvKind = "HDD"
                    if ($drvSsd) { $drvKind = "SSD" }
                    Write-Log ("  Дял " + $letter + " (" + $drvKind + ")")
                    if ($drvSsd -and $build -gt 0 -and $build -lt 9200) {
                        Write-Log "    SSD на Windows 7 - TRIM проверен, дефрагментация не се изпълнява."
                        Add-Result ("Оптимизация " + $letter) "OK" "SSD - без дефраг"
                        continue
                    }
                    $lt = $letter.TrimEnd(":")
                    $of = Join-Path $env:TEMP ("nt_defrag_" + $lt + ".txt")
                    $exitCode = Invoke-ExternalLogged "defrag.exe" ($letter + " /O") $of ("Оптимизация на " + $letter + "... ('Стоп' за прекъсване)")
                    if ($script:StopRequested) { return }
                    if ($exitCode -eq $null) { continue }
                    if ($exitCode -ne 0) {
                        Write-Log "    /O не се поддържа - опитвам класическа дефрагментация (/U)."
                        $exitCode = Invoke-ExternalLogged "defrag.exe" ($letter + " /U") $of ("Дефрагментация на " + $letter + "... ('Стоп' за прекъсване)")
                        if ($script:StopRequested) { return }
                    }
                    if ($exitCode -eq $null) { continue }
                    if ($exitCode -eq 0) {
                        Write-Log ("    " + $letter + " оптимизиран успешно.") "OK"
                        Add-Result ("Оптимизация " + $letter) "OK" "завършена"
                    } else {
                        Write-Log ("    " + $letter + " завърши с код " + $exitCode + ".") "Warn"
                        Add-Result ("Оптимизация " + $letter) "Warn" ("код " + $exitCode)
                    }
                }
            }
        }

        # --- Стъпка 6: Стари файлове на апдейтите ---
        Write-Log "  --- Стари файлове на апдейтите ---"
        $sdPath = Join-Path $env:WINDIR "SoftwareDistribution\Download"
        $sdMb = 0.0
        if (Test-Path $sdPath) {
            Set-Status "Изчисляване на размера на кеша на апдейтите..."
            $sizeBytes = 0L
            $sizeSw = [System.Diagnostics.Stopwatch]::StartNew()
            Get-ChildItem $sdPath -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($sizeSw.Elapsed.TotalSeconds -gt 10) { $sizeSw.Stop(); break }
                if (-not $_.PSIsContainer) { $sizeBytes += [long]$_.Length }
            }
            $sdMb = [math]::Round($sizeBytes / 1MB, 1)
            Write-Log ("  Кеш на Windows Update: " + $sdMb + " MB (" + $sdPath + ")")
        } else {
            Write-Log "  Папката с кеша на апдейтите не е намерена."
        }
        if ($sdMb -ge 50) {
            if ($isAdmin) {
                $delAns = [System.Windows.Forms.DialogResult]::No
                try {
                    $delAns = [System.Windows.Forms.MessageBox]::Show(
                        ("Ще изтрия " + $sdMb + " MB стари файлове на апдейти (кеш на Windows Update). Продължавам?"),
                        "NetworkTester",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question)
                } catch { }
                if ($delAns -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        Remove-Item (Join-Path $sdPath "*") -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log ("  Изтрити ~" + $sdMb + " MB от кеша на апдейтите.") "OK"
                        Add-Result "Почистване на апдейт кеш" "OK" ("освободени ~" + $sdMb + " MB")
                    } catch {
                        Write-Log ("  Грешка при изтриване: " + $_.Exception.Message) "Warn"
                        Add-Result "Почистване на апдейт кеш" "Warn" "частично изтриване"
                    }
                } else {
                    Write-Log "  Изтриването на кеша е пропуснато от потребителя."
                }
            } else {
                Write-Log "  Изтриването изисква администраторски права - пропускам." "Warn"
            }
        } elseif ($sdMb -gt 0) {
            Write-Log "  Кешът е малък (под 50 MB) - няма нужда от чистене."
        }

        # DISM почистване на компонентите
        Write-Log "  --- Почистване на компонентите (DISM) ---"
        if (-not $isAdmin) {
            Write-Log "  DISM почистването изисква администраторски права - пропускам." "Warn"
            Add-Result "DISM почистване" "Warn" "пропуснато - нужен админ"
        } else {
            $dismArgs = "/online /Cleanup-Image /StartComponentCleanup"
            if ($build -gt 0 -and $build -lt 9200) {
                $dismArgs = "/online /Cleanup-Image /SPSuperseded"
                Write-Log "  Windows 7 - ще се ползва /SPSuperseded (премахва стари файлове от Service Pack)."
            }
            $dismAns = [System.Windows.Forms.DialogResult]::No
            try {
                $dismAns = [System.Windows.Forms.MessageBox]::Show(
                    "Почистването на компонентите с DISM може да отнеме до 30 минути. Стартирам?",
                    "NetworkTester",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
            } catch { }
            if ($dismAns -eq [System.Windows.Forms.DialogResult]::Yes) {
                $dismFile = Join-Path $env:TEMP "nt_dism.txt"
                Write-Log "  DISM работи - може да отнеме до 30 минути. 'Стоп' прекъсва."
                $dismExit = Invoke-ExternalLogged "dism.exe" $dismArgs $dismFile "DISM почистване на компонентите..."
                if ($script:StopRequested) { return }
                if ($dismExit -eq 0) {
                    Write-Log "  DISM почистването завърши успешно." "OK"
                    Add-Result "DISM почистване" "OK" "завършено"
                } elseif ($dismExit -ne $null) {
                    Write-Log ("  DISM завърши с код " + $dismExit + ".") "Warn"
                    Add-Result "DISM почистване" "Warn" ("код " + $dismExit)
                }
            } else {
                Write-Log "  DISM почистването е пропуснато от потребителя."
            }
        }

        if (-not $isAdmin -and $smartFailed -and -not $elevAsked) {
            Write-Log "  За пълна проверка (SMART, TRIM, дефрагментация, DISM) се нуждаете от администраторски права."
            if (Request-Elevation) { return }
        }

        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Test-Memory {
    param(
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    $chunks = $null
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Тест на паметта..."
        Write-Log "=== ТЕСТ НА ПАМЕТТА ===" "Header"

        $freeMb = 0
        try {
            $osObj = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
            $freeMb = [int]([double]$osObj.FreePhysicalMemory / 1024)
        } catch { $freeMb = 0 }
        if ($freeMb -gt 0) {
            Write-Log ("  Свободна памет: " + $freeMb + " MB")
        } else {
            Write-Log "  Не може да се определи свободната памет - ще се тестват 512 MB." "Warn"
        }
        $targetMb = 512
        if ($freeMb -gt 0) {
            $targetMb = [int]($freeMb / 2)
            if ($targetMb -gt 1536) { $targetMb = 1536 }
        }
        $chunkCount = [int]($targetMb / 64)
        if ($chunkCount -lt 1) { $chunkCount = 1 }
        Write-Log ("  Бърз тест в паметта: " + ($chunkCount * 64) + " MB (" + $chunkCount + " блока по 64 MB).")

        $chunks = New-Object System.Collections.ArrayList
        $memSw = [System.Diagnostics.Stopwatch]::StartNew()
        for ($c = 0; $c -lt $chunkCount; $c++) {
            if (Stop-Check) { return }
            Set-Status ("RAM: запис " + ($c + 1) + "/" + $chunkCount + " блока")
            $pattern = New-Object byte[] 65536
            for ($j = 0; $j -lt 65536; $j++) {
                $pattern[$j] = [byte](($j * 31 + $c) % 256)
            }
            $chunk = $null
            try {
                $chunk = New-Object byte[] (64 * 1024 * 1024)
            } catch {
                Write-Log ("  Заделени са само " + ($chunks.Count * 64) + " MB - паметта не стигна за повече.") "Warn"
                break
            }
            $dstOffset = 0
            while ($dstOffset -lt $chunk.Length) {
                [System.Buffer]::BlockCopy($pattern, 0, $chunk, $dstOffset, 65536)
                $dstOffset += 65536
            }
            [void]$chunks.Add($chunk)
            Do-Events
        }

        if ($chunks.Count -eq 0) {
            Write-Log "  Не може да се задели памет за теста." "Fail"
            Add-Result "RAM тест" "Fail" "няма достатъчно свободна памет"
        } else {
            $testedMb = $chunks.Count * 64
            Write-Log ("  Проверка на " + $testedMb + " MB - 3 прохода с MD5 контролна сума...")
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $errors = 0
            $baseHashes = New-Object System.Collections.ArrayList
            for ($pass = 1; $pass -le 3; $pass++) {
                if (Stop-Check) { return }
                for ($i = 0; $i -lt $chunks.Count; $i++) {
                    if (($i % 4) -eq 0) {
                        if (Stop-Check) { return }
                        Set-Status ("RAM: проход " + $pass + "/3, блок " + ($i + 1) + "/" + $chunks.Count)
                        Do-Events
                    }
                    $h = [System.BitConverter]::ToString($md5.ComputeHash($chunks[$i]))
                    if ($pass -eq 1) {
                        [void]$baseHashes.Add($h)
                    } elseif ($h -ne $baseHashes[$i]) {
                        $errors++
                        Write-Log ("    ГРЕШКА: блок " + $i + ", проход " + $pass + " - съдържанието е променено!") "Fail"
                    }
                }
            }
            $memSw.Stop()
            $sec = [math]::Round($memSw.Elapsed.TotalSeconds, 1)
            Write-Log ("  Тествани " + $testedMb + " MB, 3 прохода, " + $sec + " сек, грешки: " + $errors)
            if ($errors -eq 0) {
                Write-Log "Резултат: OK - паметта е стабилна при бързия тест." "OK"
                Add-Result "RAM тест" "OK" ("" + $testedMb + " MB без грешки")
            } else {
                Write-Log "Резултат: ПРОБЛЕМ - открити са грешки в паметта!" "Fail"
                Add-Result "RAM тест" "Fail" ("" + $errors + " грешки в " + $testedMb + " MB")
            }
        }

        Write-Summary

        # Предложение за пълен тест с рестарт
        $mdAns = [System.Windows.Forms.DialogResult]::No
        try {
            $mdAns = [System.Windows.Forms.MessageBox]::Show(
                "За пълен и надежден тест на паметта се препоръчва Windows Memory Diagnostic (mdsched).`r`nИзисква рестартиране на компютъра. Да го насроча ли?",
                "NetworkTester",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
        } catch { }
        if ($mdAns -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Start-Process "mdsched.exe"
                Write-Log "  Windows Memory Diagnostic е насрочен - рестартирайте, когато сте готови." "OK"
            } catch {
                Write-Log ("  Неуспешен старт на mdsched: " + $_.Exception.Message) "Warn"
            }
        }

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        $chunks = $null
        try { [GC]::Collect() } catch { }
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Show-SystemHealth {
    param(
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Проверка на здравето на системата..."
        Write-Log "=== ЗДРАВЕ НА СИСТЕМАТА ===" "Header"

        # --- Чакащ рестарт ---
        $rebootReasons = New-Object System.Collections.ArrayList
        try {
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
                [void]$rebootReasons.Add("чакащи компоненти (CBS)")
            }
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
                [void]$rebootReasons.Add("Windows Update")
            }
            $pfr = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue
            if ($pfr -ne $null -and $pfr.PendingFileRenameOperations -ne $null) {
                [void]$rebootReasons.Add("чакащи файлови операции")
            }
        } catch { }
        if ($rebootReasons.Count -gt 0) {
            Write-Log ("  ЧАКАЩ РЕСТАРТ: изисква се рестартиране (" + ($rebootReasons -join ", ") + ")") "Fail"
            Add-Result "Чакащ рестарт" "Fail" ("изисква се рестарт: " + ($rebootReasons -join ", "))
        } else {
            Write-Log "  Чакащ рестарт: не е открит." "OK"
            Add-Result "Чакащ рестарт" "OK" "не се изисква"
        }
        Do-Events

        # --- Дисково място ---
        try {
            $critDisks = New-Object System.Collections.ArrayList
            $warnDisks = New-Object System.Collections.ArrayList
            foreach ($ld in @(Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)) {
                if (Stop-Check) { return }
                $totGb = [math]::Round([double]$ld.Size / 1GB, 1)
                $freeGb = [math]::Round([double]$ld.FreeSpace / 1GB, 1)
                $freePct = 0.0
                if ([double]$ld.Size -gt 0) { $freePct = [double]$ld.FreeSpace * 100.0 / [double]$ld.Size }
                Write-Log ("  Дял " + $ld.DeviceID + ": свободни " + $freeGb + " GB от " + $totGb + " GB (" + [math]::Round($freePct,1) + "%)")
                if ($freePct -lt 3) {
                    [void]$critDisks.Add($ld.DeviceID)
                } elseif ($freePct -lt 10 -or $freeGb -lt 5) {
                    [void]$warnDisks.Add($ld.DeviceID)
                }
            }
            if ($critDisks.Count -gt 0) {
                Write-Log ("  ПРОБЛЕМ: критично малко свободно място на " + ($critDisks -join ", ")) "Fail"
                Add-Result "Дисково място" "Fail" ("критично малко на " + ($critDisks -join ", "))
            } elseif ($warnDisks.Count -gt 0) {
                Write-Log ("  ВНИМАНИЕ: малко свободно място на " + ($warnDisks -join ", ")) "Warn"
                Add-Result "Дисково място" "Warn" ("малко място на " + ($warnDisks -join ", "))
            } else {
                Write-Log "  Дисково място: достатъчно свободно място на всички дялове." "OK"
                Add-Result "Дисково място" "OK" "достатъчно свободно"
            }
        } catch {
            Write-Log ("  Грешка при проверка на дисковото място: " + $_.Exception.Message) "Warn"
        }
        Do-Events

        # --- Критични услуги ---
        $svcNames = @("wuauserv","Spooler","Dhcp","Dnscache","W32Time","LanmanWorkstation","Schedule","EventLog","Winmgmt")
        $svcBad = New-Object System.Collections.ArrayList
        foreach ($sn in $svcNames) {
            if (Stop-Check) { return }
            try {
                $svc = Get-Service -Name $sn -ErrorAction Stop
                if ("" + $svc.Status -ne "Running") {
                    [void]$svcBad.Add($sn + " (" + $svc.Status + ")")
                }
            } catch {
                [void]$svcBad.Add($sn + " (липсва)")
            }
        }
        if ($svcBad.Count -gt 0) {
            Write-Log ("  Критични услуги, които НЕ работят: " + ($svcBad -join ", ")) "Warn"
            Add-Result "Критични услуги" "Warn" ("" + $svcBad.Count + " спрени или липсващи")
        } else {
            Write-Log "  Критични услуги: всички работят." "OK"
            Add-Result "Критични услуги" "OK" "всички работят"
        }
        Do-Events

        # --- Процеси ---
        try {
            $allProcs = @(Get-Process -ErrorAction Stop)
            Write-Log ("  Общо процеси: " + $allProcs.Count)
            Write-Log "  Най-тежките 8 процеса (по заета памет):"
            $topProcs = @($allProcs | Sort-Object WorkingSet -Descending | Select-Object -First 8)
            foreach ($p in $topProcs) {
                $wsMb = [math]::Round([double]$p.WorkingSet / 1MB, 0)
                $cpuSec = 0
                try { $cpuSec = [math]::Round([double]$p.CPU, 0) } catch { }
                Write-Log ("    " + $p.ProcessName + "  -  " + $wsMb + " MB, CPU " + $cpuSec + " сек")
            }
            Add-Result "Процеси" "OK" ("" + $allProcs.Count + " процеса")
        } catch {
            Write-Log ("  Грешка при четене на процесите: " + $_.Exception.Message) "Warn"
        }
        Do-Events

        # --- Автостарт програми ---
        $runPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run"
        )
        $autoEntries = New-Object System.Collections.ArrayList
        foreach ($rp in $runPaths) {
            if (Stop-Check) { return }
            try {
                $item = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                if ($item -ne $null) {
                    foreach ($prop in $item.PSObject.Properties) {
                        $pn = "" + $prop.Name
                        if ($pn.StartsWith("PS")) { continue }
                        [void]$autoEntries.Add($pn)
                    }
                }
            } catch { }
            Do-Events
        }
        Write-Log ("  Автостарт записи: " + $autoEntries.Count)
        $shownA = 0
        foreach ($an in $autoEntries) {
            if ($shownA -ge 15) {
                Write-Log ("    ...още " + ($autoEntries.Count - 15) + " записа")
                break
            }
            Write-Log ("    " + $an)
            $shownA++
        }
        Add-Result "Автостарт" "OK" ("" + $autoEntries.Count + " записа")
        Do-Events

        # --- Сигурност ---
        Write-Log "  --- Сигурност ---"
        try {
            $avNames = New-Object System.Collections.ArrayList
            foreach ($av in @(Get-WmiObject -Namespace "root\SecurityCenter2" -Class AntiVirusProduct -ErrorAction Stop)) {
                $dn = ("" + $av.displayName).Trim()
                if ($dn -ne "") { [void]$avNames.Add($dn) }
            }
            if ($avNames.Count -gt 0) {
                Write-Log ("  Антивирусна: " + ($avNames -join ", ")) "OK"
                Add-Result "Антивирусна" "OK" ($avNames -join ", ")
            } else {
                Write-Log "  Не е открита антивирусна програма!" "Warn"
                Add-Result "Антивирусна" "Warn" "не е открита антивирусна"
            }
        } catch {
            Write-Log "  Няма данни за антивирусна (SecurityCenter2 е недостъпен)." "Warn"
            Add-Result "Антивирусна" "Warn" "няма данни"
        }
        Do-Events
        try {
            $fw = Get-Service -Name "MpsSvc" -ErrorAction Stop
            if ("" + $fw.Status -eq "Running") {
                Write-Log "  Защитна стена (MpsSvc): работи." "OK"
                Add-Result "Защитна стена" "OK" "работи"
            } else {
                Write-Log ("  Защитната стена е спряна (" + $fw.Status + ")!") "Warn"
                Add-Result "Защитна стена" "Warn" ("услугата е " + $fw.Status)
            }
        } catch {
            Write-Log "  Услугата на защитната стена (MpsSvc) не е открита." "Warn"
            Add-Result "Защитна стена" "Warn" "услугата липсва"
        }
        try {
            $uac = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction Stop
            if ($uac -ne $null -and $uac.EnableLUA -eq 1) {
                Write-Log "  UAC: включен." "OK"
                Add-Result "UAC" "OK" "включен"
            } else {
                Write-Log "  UAC е изключен - препоръчва се включване." "Warn"
                Add-Result "UAC" "Warn" "изключен"
            }
        } catch {
            Write-Log "  Не може да се прочете настройката за UAC." "Warn"
        }
        try {
            $activated = $false
            foreach ($lp in @(Get-WmiObject SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop)) {
                if ([int]$lp.LicenseStatus -eq 1) { $activated = $true }
            }
            if ($activated) {
                Write-Log "  Windows е активиран." "OK"
                Add-Result "Активация" "OK" "Windows е активиран"
            } else {
                Write-Log "  Windows НЕ е активиран." "Warn"
                Add-Result "Активация" "Warn" "не е активиран"
            }
        } catch {
            Write-Log "  Не може да се провери активацията на Windows." "Warn"
        }
        Do-Events
        if (Stop-Check) { return }

        # --- Hosts файл ---
        try {
            $hostsPath = Join-Path $env:WINDIR "System32\drivers\etc\hosts"
            $suspicious = New-Object System.Collections.ArrayList
            $hostsEntries = 0
            if (Test-Path $hostsPath) {
                foreach ($hl in @(Get-Content $hostsPath -ErrorAction SilentlyContinue)) {
                    $t = ("" + $hl).Trim()
                    if ($t -eq "") { continue }
                    if ($t.StartsWith("#")) { continue }
                    $hostsEntries++
                    $firstTok = ($t -split "\s+")[0]
                    if ($firstTok -eq "127.0.0.1" -or $firstTok -eq "::1" -or $firstTok -eq "localhost") { continue }
                    [void]$suspicious.Add($t)
                }
            }
            if ($suspicious.Count -gt 0) {
                Write-Log ("  Hosts файл: " + $suspicious.Count + " необичайни записа - често признак за зловреден софтуер или ръчни редиректи:") "Warn"
                foreach ($sl in $suspicious) { Write-Log ("    " + $sl) "Warn" }
                Add-Result "Hosts файл" "Warn" ("" + $suspicious.Count + " подозрителни записа")
            } else {
                Write-Log ("  Hosts файл: чист (" + $hostsEntries + " стандартни записа).") "OK"
                Add-Result "Hosts файл" "OK" "без подозрителни записи"
            }
        } catch {
            Write-Log ("  Грешка при четене на hosts файла: " + $_.Exception.Message) "Warn"
        }
        Do-Events

        # --- Прокси ---
        try {
            $iset = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
            $pxOn = 0
            $pxSrv = ""
            if ($iset.ProxyEnable -ne $null) { $pxOn = [int]$iset.ProxyEnable }
            if ($iset.ProxyServer -ne $null) { $pxSrv = "" + $iset.ProxyServer }
            if ($pxOn -eq 1 -and $pxSrv -ne "") {
                Write-Log ("  Прокси е ВКЛЮЧЕНО: " + $pxSrv + " - ако не е очаквано, проверете настройките!") "Warn"
                Add-Result "Прокси" "Warn" ("включено: " + $pxSrv)
            } else {
                Write-Log "  Прокси: изключено (директна връзка)." "OK"
                Add-Result "Прокси" "OK" "няма прокси"
            }
        } catch {
            Write-Log "  Не могат да се прочетат прокси настройките." "Warn"
        }
        Do-Events

        # --- Принтери ---
        try {
            $printers = @(Get-WmiObject Win32_Printer -ErrorAction Stop)
            if ($printers.Count -eq 0) {
                Write-Log "  Принтери: няма инсталирани."
            } else {
                Write-Log ("  Принтери: " + $printers.Count)
                foreach ($prn in $printers) {
                    $defTxt = ""
                    if ($prn.Default) { $defTxt = "  [по подразбиране]" }
                    Write-Log ("    " + $prn.Name + "  (порт: " + $prn.PortName + ")" + $defTxt)
                }
            }
            Add-Result "Принтери" "OK" ("" + $printers.Count + " принтера")
        } catch {
            Write-Log ("  Грешка при четене на принтерите: " + $_.Exception.Message) "Warn"
        }
        Do-Events
        if (Stop-Check) { return }

        # --- Локални администратори ---
        try {
            $admGroup = $null
            foreach ($g in @(Get-WmiObject Win32_Group -Filter "SID='S-1-5-32-544'" -ErrorAction Stop)) {
                $admGroup = $g
                break
            }
            if ($admGroup -eq $null) {
                Write-Log "  Групата 'Администратори' не е открита." "Warn"
            } else {
                $admMembers = New-Object System.Collections.ArrayList
                $gEsc = [regex]::Escape("" + $admGroup.Name)
                foreach ($gu in @(Get-WmiObject Win32_GroupUser -ErrorAction SilentlyContinue)) {
                    if (("" + $gu.GroupComponent) -match $gEsc) {
                        $part = "" + $gu.PartComponent
                        if ($part -match 'Domain="([^"]+)",Name="([^"]+)"') {
                            [void]$admMembers.Add($matches[1] + "\" + $matches[2])
                        }
                    }
                }
                Write-Log ("  Локални администратори (група '" + $admGroup.Name + "'): " + $admMembers.Count)
                $shownM = 0
                foreach ($mm in $admMembers) {
                    if ($shownM -ge 15) {
                        Write-Log ("    ...още " + ($admMembers.Count - 15))
                        break
                    }
                    Write-Log ("    " + $mm)
                    $shownM++
                }
                Add-Result "Локални админи" "OK" ("" + $admMembers.Count + " членове")
            }
        } catch {
            Write-Log ("  Грешка при четене на администраторите: " + $_.Exception.Message) "Warn"
        }
        Do-Events
        if (Stop-Check) { return }

        # --- Чакащи апдейти ---
        Write-Log "  Проверка за чакащи Windows апдейти - търсенето може да отнеме 1-2 минути и интерфейсът временно няма да отговаря..."
        Set-Status "Търсене на чакащи апдейти (може да отнеме 1-2 минути)..."
        Do-Events
        try {
            $uSession = New-Object -ComObject Microsoft.Update.Session
            $uSearcher = $uSession.CreateUpdateSearcher()
            $uResult = $uSearcher.Search("IsInstalled=0")
            $uCount = 0
            if ($uResult -ne $null -and $uResult.Updates -ne $null) { $uCount = [int]$uResult.Updates.Count }
            if ($uCount -gt 0) {
                Write-Log ("  ЧАКАЩИ АПДЕЙТИ: " + $uCount) "Warn"
                $shownU = 0
                foreach ($up in $uResult.Updates) {
                    if ($shownU -ge 10) {
                        Write-Log ("    ...още " + ($uCount - 10))
                        break
                    }
                    Write-Log ("    " + $up.Title)
                    $shownU++
                }
                Add-Result "Чакащи апдейти" "Warn" ("" + $uCount + " чакащи")
            } else {
                Write-Log "  Няма чакащи апдейти." "OK"
                Add-Result "Чакащи апдейти" "OK" "няма чакащи"
            }
        } catch {
            Write-Log ("  Търсенето на апдейти се провали: " + $_.Exception.Message) "Warn"
            Add-Result "Чакащи апдейти" "Warn" "проверката не можа да се изпълни"
        }
        Set-Status "Проверка на здравето на системата..."
        Do-Events
        if (Stop-Check) { return }

        # --- Батерия ---
        try {
            $bats = @(Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue)
            foreach ($bt in $bats) {
                $pct = "" + $bt.EstimatedChargeRemaining
                $bst = 0
                try { $bst = [int]$bt.BatteryStatus } catch { }
                $bstTxt = "неизвестен"
                switch ($bst) {
                    1 { $bstTxt = "на батерия" }
                    2 { $bstTxt = "на зарядно (AC)" }
                    3 { $bstTxt = "напълно заредена" }
                    4 { $bstTxt = "ниско ниво" }
                    5 { $bstTxt = "критично ниво" }
                    6 { $bstTxt = "зарежда се" }
                    default { $bstTxt = "статус " + $bst }
                }
                Write-Log ("  Батерия: " + $pct + "% заредена, " + $bstTxt)
                Add-Result "Батерия" "OK" ("" + $pct + "% заряд, " + $bstTxt)
            }
        } catch { }

        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
    }
}

function Show-InstalledPrograms {
    param(
        $Progress, $BtnStart, $BtnLoad, $BtnStop, $BtnQuick, $BtnScan, $BtnMon, $BtnInfo, $BtnDisk, $BtnRam, $BtnSys, $BtnProgs, $BtnHtml
    )
    if ($script:Running) { return }
    $script:StopRequested = $false
    $script:StopLogged = $false
    $script:Running = $true
    [void]$script:Results.Clear()
    try {
        $Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        Set-Status "Събиране на списъка с инсталирани програми..."
        Write-Log "=== ИНСТАЛИРАНИ ПРОГРАМИ ===" "Header"

        $uninstPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $progs = New-Object System.Collections.ArrayList
        foreach ($up in $uninstPaths) {
            if (Stop-Check) { return }
            $subKeys = @()
            try { $subKeys = @(Get-ItemProperty $up -ErrorAction SilentlyContinue) } catch { $subKeys = @() }
            foreach ($sk in $subKeys) {
                $dn = ("" + $sk.DisplayName).Trim()
                if ($dn -eq "") { continue }
                if ($sk.SystemComponent -ne $null -and [int]$sk.SystemComponent -eq 1) { continue }
                if ($sk.ParentKeyName -ne $null -and ("" + $sk.ParentKeyName) -ne "") { continue }
                $instDate = ""
                if ($sk.InstallDate -ne $null) { $instDate = "" + $sk.InstallDate }
                $sizeMb = ""
                if ($sk.EstimatedSize -ne $null) { $sizeMb = "" + [math]::Round([double]$sk.EstimatedSize / 1024, 1) }
                $pr = New-Object PSObject -Property @{
                    Name = $dn
                    Version = ("" + $sk.DisplayVersion).Trim()
                    Publisher = ("" + $sk.Publisher).Trim()
                    InstallDate = $instDate
                    EstimatedSizeMB = $sizeMb
                }
                [void]$progs.Add($pr)
            }
            Do-Events
        }

        $sorted = @($progs | Sort-Object Name)
        Write-Log ("  Открити програми: " + $sorted.Count)
        $shownP = 0
        foreach ($pr in $sorted) {
            if (Stop-Check) { return }
            if ($shownP -ge 120) {
                Write-Log ("  ...още " + ($sorted.Count - 120) + " програми")
                break
            }
            $pLine = "  " + $pr.Name
            if ($pr.Version -ne "") { $pLine = $pLine + "  v" + $pr.Version }
            if ($pr.Publisher -ne "") { $pLine = $pLine + "  [" + $pr.Publisher + "]" }
            Write-Log $pLine
            $shownP++
            Do-Events
        }
        Write-Log ("  Общо: " + $sorted.Count + " програми.")
        Write-Log "  Пълният списък е включен в лога - използвайте 'Запази лога' или файла на Desktop." "OK"
        Add-Result "Инсталирани програми" "OK" ("" + $sorted.Count + " програми")

        Write-Summary

    } catch {
        Write-Log ("Грешка: " + $_.Exception.Message) "Fail"
    } finally {
        Complete-TestRun -Progress $Progress -BtnStart $BtnStart -BtnLoad $BtnLoad -BtnStop $BtnStop `
            -BtnQuick $BtnQuick -BtnScan $BtnScan -BtnMon $BtnMon -BtnInfo $BtnInfo -BtnDisk $BtnDisk -BtnRam $BtnRam `
            -BtnSys $BtnSys -BtnProgs $BtnProgs -BtnHtml $BtnHtml
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
        $form.Size = New-Object System.Drawing.Size(820, 740)
        $form.MinimumSize = New-Object System.Drawing.Size(760, 700)
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

        $btnInfo = New-Object System.Windows.Forms.Button
        $btnInfo.Text = "Машина"
        $btnInfo.Location = New-Object System.Drawing.Point(550, 610)
        $btnInfo.Size = New-Object System.Drawing.Size(110, 28)
        $btnInfo.Anchor = "Bottom, Left"
        $form.Controls.Add($btnInfo)

        $btnDisk = New-Object System.Windows.Forms.Button
        $btnDisk.Text = "Дискове"
        $btnDisk.Location = New-Object System.Drawing.Point(662, 610)
        $btnDisk.Size = New-Object System.Drawing.Size(60, 28)
        $btnDisk.Anchor = "Bottom, Left"
        $form.Controls.Add($btnDisk)

        $btnRam = New-Object System.Windows.Forms.Button
        $btnRam.Text = "RAM"
        $btnRam.Location = New-Object System.Drawing.Point(726, 610)
        $btnRam.Size = New-Object System.Drawing.Size(64, 28)
        $btnRam.Anchor = "Bottom, Left"
        $form.Controls.Add($btnRam)

        # ---------- Bottom buttons row 2 ----------
        $btnSys = New-Object System.Windows.Forms.Button
        $btnSys.Text = "Система"
        $btnSys.Location = New-Object System.Drawing.Point(10, 646)
        $btnSys.Size = New-Object System.Drawing.Size(90, 28)
        $btnSys.Anchor = "Bottom, Left"
        $form.Controls.Add($btnSys)

        $btnProgs = New-Object System.Windows.Forms.Button
        $btnProgs.Text = "Програми"
        $btnProgs.Location = New-Object System.Drawing.Point(110, 646)
        $btnProgs.Size = New-Object System.Drawing.Size(100, 28)
        $btnProgs.Anchor = "Bottom, Left"
        $form.Controls.Add($btnProgs)

        $btnHtml = New-Object System.Windows.Forms.Button
        $btnHtml.Text = "HTML отчет"
        $btnHtml.Location = New-Object System.Drawing.Point(220, 646)
        $btnHtml.Size = New-Object System.Drawing.Size(110, 28)
        $btnHtml.Anchor = "Bottom, Left"
        $form.Controls.Add($btnHtml)

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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Start-AllTests -RouterIp $router -ServerTarget $server -PortsCsv $txtPorts.Text.Trim() `
                -PingCount ([int]$numPing.Value) -StabSec ([int]$numStab.Value) `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Start-LoadTests -ServerTarget $server -PortsCsv $txtPorts.Text.Trim() `
                -Connections ([int]$numLoadConns.Value) -Seconds ([int]$numLoadSec.Value) `
                -LoadFile $txtLoadFile.Text.Trim() `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Start-QuickTest -RouterIp $router -ServerTarget $server `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Start-Monitor -RouterIp $router -ServerTarget $server `
                -IntervalSec ([int]$numMonInt.Value) -Beep $chkBeep.Checked `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Invoke-NetworkScan -ServerTarget $server `
                -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
        })

        $btnInfo.Add_Click({
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Show-SystemInventory -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
        })

        $btnDisk.Add_Click({
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Show-DiskMaintenance -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
        })

        $btnRam.Add_Click({
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Test-Memory -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
        })

        $btnSys.Add_Click({
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Show-SystemHealth -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
        })

        $btnProgs.Add_Click({
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
            $btnInfo.Enabled = $false
            $btnDisk.Enabled = $false
            $btnRam.Enabled = $false
            $btnSys.Enabled = $false
            $btnProgs.Enabled = $false
            $btnHtml.Enabled = $false
            $btnStop.Enabled = $true
            Show-InstalledPrograms -Progress $progress -BtnStart $btnStart -BtnLoad $btnLoad -BtnStop $btnStop `
                -BtnQuick $btnQuick -BtnScan $btnScan -BtnMon $btnMon -BtnInfo $btnInfo -BtnDisk $btnDisk -BtnRam $btnRam `
                -BtnSys $btnSys -BtnProgs $btnProgs -BtnHtml $btnHtml
        })

        $btnHtml.Add_Click({
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = "HTML файлове (*.html)|*.html"
            $stamp = [DateTime]::Now.ToString("yyyy-MM-dd_HH-mm-ss")
            $dlg.FileName = "NetworkTester_" + $stamp + ".html"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                if (Export-HtmlReport $dlg.FileName) {
                    Write-Log ("HTML отчетът е запазен в: " + $dlg.FileName) "OK"
                }
            }
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
            [void]$script:LogEntries.Clear()
        })

        Write-Log "NetworkTester е готов. Попълнете настройките и изберете: 'Старт', 'Бърз тест', 'Старт натоварване', 'Старт мониторинг', 'Сканирай LAN', 'Машина', 'Дискове', 'RAM', 'Система' или 'Програми'. 'HTML отчет' записва лога като уеб страница." "Header"
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
