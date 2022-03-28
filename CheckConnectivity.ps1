[CmdletBinding()]
param (
    [Parameter()]
    [Switch]
    $ShowHistory,
    [String]
    $DaysBack = 30,
    [String[]]
    $EventIDs = '10',
    [Switch]
    $Full
)
$LogSource = "CheckConnectivity.ps1"
$LogName = "CSG - ITM Connectivity"
function Write-AppEventLog {
    Param(
        [Parameter(Mandatory=$true)]
        [String]$Message,
        [String]$eventID = "5",
        [String]$EntryType = "Information"
        )
    Write-EventLog -LogName $LogName -EventID $eventID -EntryType $entryType -Source $LogSource -Message $Message 
    }

If (!([System.Diagnostics.EventLog]::Exists($LogName))) {
    try {
        New-EventLog -LogName $LogName -Source $LogSource -ErrorAction Stop
        Limit-EventLog -LogName $LogName -OverflowAction OverwriteOlder -MaximumSize 2GB
    } catch {
        $EventError = $_
        Write-Error "Failed to create $LogName event log: $_"
        New-EventLog -LogName Application -Source CSG
        Write-EventLog -LogName Application -Source CSG -Message "Failed to create $LogName event log: $EventError" -EventId 6578 -EntryType Error
    }
}
If (!([System.Diagnostics.EventLog]::SourceExists($LogSource))) {
    try {
        New-EventLog -LogName $LogName -Source $LogSource -ErrorAction Stop
    } catch {
        New-EventLog -LogName Application -Source CSG
        Write-EventLog -LogName Application -Source CSG -Message "Failed to create $LogSource log source: $EventError" -EventId 6578 -EntryType Error
    }
}

function Test-ConnectionAverage {
    [CmdletBinding()]
    param (
        [String]
        $Destination
    )
    $FailedCount = 0
    $Pings = Test-Connection $Destination -Count 5 -ErrorAction SilentlyContinue -ErrorVariable FailedCount
    if ($FailedCount.Count -le 4) {
        $Average = (($Pings | % {$_.Responsetime}) | Measure-Object -average).average
        $Average = [Math]::Round($Average,2)
        $ConnStatus = 'Information'
    } else {
        $Average = 'TimedOut'
        $ConnStatus = 'Warning'
    }
    if ($FailedCount.Count -gt 0) {
        $FailedPct = ($FailedCount.Count/5).ToString("P0")
        $FailedPctString = "($FailedPct)"
    }
    return ($Average,$FailedPctString -join ' ').Trim(), $ConnStatus
}

if ($ShowHistory.IsPresent) {
    $ErrorActionPreference = 'Stop'
    $DaysBack = (Get-Date).AddDays(-$DaysBack)
    try {
        Get-EventLog -LogName $LogName -InstanceId $EventIDs -After $DaysBack | ForEach-Object {
            Write-Host "<$($_.TimeWritten)> ($($_.EntryType))  $($_.Message)"
        }
    }
    catch {
        "Error while trying to retrieve ping/traceroute history:
        
        $($_.Exception.Message)"
    }
} else {
    # Determine secondary host to ping. If Google is unavailable due to no DNS, use the K-server.
    $Lookup = try {
        [System.Net.Dns]::GetHostAddresses("google.com")
        }
        catch {
            $_.Exception.Message
        }


    if ($Lookup -like "*No such host is known*") {
        $Secondary = '68.168.253.23'
        $SecondaryName = 'Kaseya'
    }
    else {
        $Secondary = $Lookup | % {$_.IPAddressToString} | Select-Object -First 1
        $SecondaryName = 'Google'
    }

    # Determine ITM Server Name to ping

    If (Test-Path "${env:ProgramFiles(x86)}\uGenius\LaunchAIT.bat") {
        $bat = Get-Content "${env:ProgramFiles(x86)}\uGenius\LaunchAIT.bat"
    } ElseIf (Test-Path "${env:ProgramFiles}\uGenius\LaunchAIT.bat") {
        $bat = Get-Content "${env:ProgramFiles}\uGenius\LaunchAIT.bat"
    }
    if ($bat) {
        $PTMFolder = $bat[0].Trim('cd "')
        $ConFile = $PTMFolder + '\Configuration\Configuration.xml'
        [xml]$ITMConfig = Get-Content $ConFile        
        $ItmServer = $ITMConfig.uGeniusConfiguration.ServerHost
        if ($Full.IsPresent) {
            $TcpipPath = $PTMFolder + '\Config\TCPIPCommunicationsServiceConfig.XML'
            [xml]$TcpipConfig = Get-Content $TCPIPPath
            $SPFiles = Get-ChildItem ($PTMFolder + '\Customer\SharedProperties*.accfg')
            foreach ($SPFile in $SPFiles) {
                [xml]$xml = Get-Content $SPFile.Fullname
                if ($xml.SelectNodes("//SharedProperty[@Name=`'STARTOFDAY_ATMTCPIPROLE`']").Value) {
                    $TcpipRole = $xml.SelectNodes("//SharedProperty[@Name=`'STARTOFDAY_ATMTCPIPROLE`']").Value
                }
            }
            if ($TcpipRole) {
                $Netstat = netstat -a
                if ($TcpipRole -like 'Client') {
                    $HostIP = $TcpipConfig.CommunicationsConfig.TCPIPCommunicationsLink.RemoteHost | Select-Object -First 1
                    $HostConnectionString = $Netstat | Select-String $HostIP | Out-String
                }
                elseif ($TcpipRole -like 'Server') {
                    $HostIP = $TcpipConfig.CommunicationsConfig.TCPIPCommunicationsLinkListener.RemoteHostIP.RemoteHost | Select-Object -First 1
                    $LocalPort = $TcpipConfig.CommunicationsConfig.TCPIPCommunicationsLinkListener.LocalPort | Select-Object -First 1
                    $HostConnectionString = $Netstat | Select-String $LocalPort | Out-String
                }
                $AtmHostPing = (Ping $HostIP) | % {"        $_`n"}
                $AtmHostTracert = (tracert -w 1000 -h 30 $HostIP) | % {"        $_`n"}
            }
            else {
                $HostConnectionString = $AtmHostPing = $AtmHostTracert = "        No ATM host has been configured"
            }
            Write-AppEventLog -eventID 40 -EntryType 'Information' -Message "ATM Host ping results:`r`n$AtmHostPing"
            Write-AppEventLog -eventID 43 -EntryType 'Information' -Message "ATM Host netstat info:`r`n$HostConnectionString"
            Write-AppEventLog -eventID 46 -EntryType 'Information' -Message "ATM Host traceroute:`r`n$AtmHostTracert"
        }
    }
    if ($ItmServer -eq 'localhost' -or $null -eq $ItmServer) {
        $ItmServer = 'ITMServer'
        $ServerResult = 'Unused'
        $ServerStatus = 'Information'
    }
    else {
        $ServerResult,$ServerStatus = Test-ConnectionAverage $ItmServer
        if (!(Get-EventLog -LogName $LogName -after (Get-Date).AddHours(-1) -InstanceId 20 -ErrorAction SilentlyContinue)) {
            $traceroutePrimary = (tracert -w 1000 -h 30 $ItmServer) | % {"        $_`n"}
            Write-AppEventLog -Message "$traceroutePrimary" -eventID '20'
        }
    }
    $SecondaryResult,$SecondaryStatus = Test-ConnectionAverage $Secondary
    if ($SecondaryName -eq 'Google' -and $SecondaryStatus -like 'Warning') {
        # Google resolves but cannot be pinged.  Repeat with Kaseya instead and log the results.
        $Secondary = '68.168.253.23'
        $SecondaryName = 'Kaseya'
        $SecondaryResult,$SecondaryStatus = Test-ConnectionAverage $Secondary
    }
    $Results = "$ItmServer`: $ServerResult - $SecondaryName`: $SecondaryResult"
    Write-Host $Results
    Write-AppEventLog $Results -eventID 10 -EntryType $ServerStatus

    if ($Full.IsPresent) {
        # Determine whether VPN/VPNless, then test connectivity to Vidyo appliances
        if ($ServerResult -ne 'Unused' -and $null -ne $ServerResult) {
            $ServerLookup = [System.Net.Dns]::GetHostAddresses($ItmServer)
            $ServerIp = $ServerLookup | Select-Object -ExpandProperty IPAddressToString
            $LocalIpRanges = @(
                '10.*'
                '172.16*'
                '172.18*'
                '192.168*'
            )

            if ($null -ne ($LocalIpRanges | Where-Object {$ServerIp -like $_})`
                -and $ItmServer -notlike 'rogue-itm01') {
                # ITM Server resolves to a local IP, must be over VPN
                # Rogue CU is a unique case using an internal IP to hit Alpha envt.
                $VidyoAppliances = @(
                    "vpt01.itm.cooksecuritygroup.com:17992"
                    "vrp01.itm.cooksecuritygroup.com:443"
                    "vrt01.itm.cooksecuritygroup.com:17990"
                    "vrt02.itm.cooksecuritygroup.com:17990"
                    "vrt03.itm.cooksecuritygroup.com:17990"
                )
            }
            else {
                # ITM Server will be a public IP, must be VPNless
                $VidyoAppliances = @(
                    "portala.itm.cooksecuritygroup.com:17992"                
                    "replaya.itm.cooksecuritygroup.com:443"
                    "routera1.itm.cooksecuritygroup.com:17990"
                    "routera2.itm.cooksecuritygroup.com:17990"
                )
            }

            # Test connectivity to each Vidyo appliance over required port, then log as event 15

            ForEach ($Appl in $VidyoAppliances) {
                $Hostname, $Port = $Appl.split(':')
                try {
                    $Attempt = New-Object System.Net.Sockets.TcpClient($Hostname,$Port)
                    if ($Attempt.Connected) {
                        Write-AppEventLog -eventID 30 -EntryType 'Information' -Message "Successfully connected to $Hostname over port $Port"
                    } else {
                        Write-AppEventLog -eventID 32 -EntryType 'Warning' -Message  "Failed to connect to $Hostname over port $Port"
                    }
                }
                catch {
                    Write-AppEventLog -eventID 32 -EntryType 'Error' -Message  "Failed to connect to $Hostname over port $Port with error: `n$($_.Exception.Message)"
                }
            
                # Tracert to each Vidyo appliance hourly
                if (!(Get-EventLog -LogName $LogName -InstanceId '35' -after (Get-Date).AddHours(-1) -ErrorAction SilentlyContinue | Where-Object {$_.Message -like "*Tracing route to $Hostname*"})) {
                    $tracerouteVidyo = (tracert -w 1000 -h 30 $Hostname) | % {"        $_`n"}
                    Write-AppEventLog -Message "$tracerouteVidyo" -eventID '35'
                }
            }
        }
    }
}

<# 

Event IDs:
5  - Default - Not intended for use
10 - ITM Server & Secondary - Pings - Information
11 - ITM Server & Secondary - Pings - Failed
20 - ITM Server - Traceroute
30 - Vidyo Envt. - TCP Test - Information
32 - Vidyo Envt. - TCP Test - Failed
35 - Vidyo Envt. - Traceroute
40 - ATM Host - Ping
43 - ATM Host - Connectivity Status
46 - ATM Host - Traceroute

#>