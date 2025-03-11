. "$PsScriptRoot/NetDaemon.ps1"
$HaDefaults = ([ordered]@{
    Host = "homeassistant.local"
    Port = 8123
}).AsReadOnly()

function Merge([hashtable]$H1,[hashtable]$H2) {
    $Dst = $H1.Clone()
    $H2.GetEnumerator() | % { $Dst[$_.Key] = $_.Value }
    return $Dst
}


function EnvsToDict() {
    $d=@{}
    ls Env: | where name -like '*__*' | % { 
        $a = $_.Name -split "__";
        $s=$d
        foreach($v in  $a) {
            if(!$s[$v]) {
                $s[$v] = @{}
            }
            $p=$s
            $s=$s[$v]
        }
        $p[$a[$a.Length-1]]=$_.Value
    }
    return $d;
}
function ConvertTo-ValidVariableName([string]$String) {
    return ($String -replace '^[^a-zA-Z_]|[^a-zA-Z0-9_]', '_')
}
$KnownDaemons=@{}
function Get-NetDaemonConfig() {
    return $global:NdConfig
}
function Set-NetDaemonConfig($AppSrc, $EnvironmentsRoot, $NetDaemonLibSrc,[switch]$CustomCodegen, [switch]$Clean) {
    $Cfg = $global:NdConfig
    if($Clean -or !$Cfg) {
        $Cfg = [pscustomobject]@{
            AppSrc = $AppSrc
            EnvironmentsRoot = $EnvironmentsRoot
            NetDaemonLibSrc = $NetDaemonLibSrc,
            UseCustomCodegen = $CustomCodegen
        }
    }else{
        if($AppSrc) {
            $Cfg.AppSrc = $AppSrc
        }
        if($EnvironmentsRoot) {
            $Cfg.EnvironmentsRoot = $EnvironmentsRoot
        }
        if($NetDaemonLibSrc) {
            $Cfg.NetDaemonLibSrc = $NetDaemonLibSrc
        }
        if($CustomCodegen) {
            $Cfg.UseCustomCodegen = $CustomCodegen
        }
    }
    $global:NdConfig = $Cfg
    return $global:NdConfig
}
function Reload-NetDaemon($Name, [switch]$Clean) {
    if($Clean) {
        Set-NetDaemonConfig -Clean
    }
    if($Name) {
        Set-NetDaemon -Name $Name -NetDaemon $Null -Current
    }
    else {
        $KnownDaemons.Keys | % { Set-NetDaemon -Name $_ -NetDaemon $Null }
        $global:CurrentNetDaemon=$Null
    }
    Import-Module -Name NetDaemonPs -Force
    Get-NetDaemon($Name)
}

function Set-NetDaemon([string]$Name, $NetDaemon, [switch]$Current) {
    $KnownDaemons[$Name] = $NetDaemon
    if($Current) {
        $global:CurrentNetDaemon = $NetDaemon
    }
    $Name=(ConvertTo-ValidVariableName $Name)
    Set-Variable -Name "Nd$Name" -Value $NetDaemon -Scope Global
    if($NetDaemon) {
        Write-Information "Saved as `$global:Nd$Name"
    }
    else {
        Write-Information "Removed `$global:Nd$Name"
    }
}

function Get-NetDaemon([string]$Name, $EnvPath, [switch]$Existing, [switch]$Reload) {
    if(!$Name) {
        if($global:CurrentNetDaemon.Name) {
            $Name=$global:CurrentNetDaemon.Name
        }
        else {
            $Name=(git rev-parse --abbrev-ref HEAD)
        }
    }
    if(!$Reload) {
        if($global:CurrentNetDaemon.Name -eq $Name) {
            return $global:CurrentNetDaemon
        }
        if($KnownDaemons[$Name]) {
            return $KnownDaemons[$Name]
        }
        if($Existing) {
            return throw "Daemon $Name not loaded"
        }   
    }
    return New-NetDaemon -Name $Name -EnvPath $EnvPath
}
function New-NetDaemon(
        [string]$Name,
        [string]$EnvPath,
        [string]$LocalHostName, [string]$RemoteHostName, [string]$Ip, [bool]$PreferRemote, [int]$RemotePort, [string]$Hostname, [int]$Port, [bool]$IsSsl, [bool]$PreferDns
    ) {
    if(!$EnvPath) {
        if($NdConfig?.EnvironmentsRoot){
            $EnvPath=$NdConfig.EnvironmentsRoot
        }
        else {
            $EnvPath=$PWD
        }
        if($Name -and (Test-Path "$EnvPath\$Name\.env" -PathType Leaf)) {
            $EnvPath+="\$Name"
        }
        $EnvPath+="\.env"
    }
    if (Test-Path "$EnvPath" -PathType Leaf) {
        Write-Information "Loading $EnvPath"
        dotenv "$EnvPath" -AllowClobber
    }
    $Values = EnvsToDict
    $HaDict = Merge -H1 ([hashtable]::new($HaDefaults)) -H2 ($Values["HomeAssistant"])
    if($HaHost) {
        $HaDict["Host"] = $HaHost
    }
    $FnArgs=$Args
    0..($FnArgs.Length - 1) | ? { $_ % 2 -eq 0 } | % { 
        if($FnArgs.Length -ge $_ + 1) {
            $Arg = $FnArgs[$_].TrimStart("-")
            Write-Debug "Command Line: $Arg to $($FnArgs[$($_ + 1)])"
            $HaDict[$Arg] = $FnArgs[$_ + 1] }
        }
    $MyInvocation.BoundParameters.GetEnumerator() | % { 
        $HaDict[$_.Key] = $_.Value
    }
    # $MyInvocation.MyCommand.Parameters.GetEnumerator() | % { 
    #     $Value=$((Get-Variable $_.Key).Value)
    #     if((!$Value) -and $HaDict[$_.Key]) {
    #         Write-Debug "Setting $($_.Key) to $DVal"
    #         Set-Variable $_.Key $HaDict[$_.Key]
    #     }
    # };
    $NetDaemon = New-NetDaemonFromHashtable -Name $Name -HaDict $HaDict
    Set-NetDaemon -Name $Name -NetDaemon $NetDaemon
   return $NetDaemon
}

function New-NetDaemonFromHashtable($Name,[hashtable]$HaDict) {
        $HaDict.GetEnumerator() | % { 
            Write-Debug "Setting $($_.Key) to $($_.Value)"
            if($_.Key -ne "Host") {
                Set-Variable $($_.Key) $($_.Value)
            }
        }
        $HaHost=$HaDict["Host"]
        if ($HaHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
            if(!$Ip) {
                $Ip = $HaHost
            } elseif ($Ip -ne $HaHost) {
                Write-Warning "IP mismatch: $Ip != $HaHost"
            }
        } elseif ($HaHost -match '\.local$|\.lan$') {
            if(!$LocalHostName) {
                $LocalHostName = $HaHost
            } elseif ($LocalHostName -ne $HaHost) {
                Write-Warning "Local hostname mismatch: $LocalHostName != $HaHost"
            }
            if(!$Name) {
                $Name = $HaHost -replace '\.(local|lan)$', ''
            } elseif ($Name -ne ($HaHost -replace '\.(local|lan)$', '')) {
                Write-Warning "Name mismatch: $Name != $($HaHost -replace '\.(local|lan)$', '')"
            }
            # if(!$LocalDnsSuffix) {
            #     $LocalDnsSuffix = $matches[0]
            # } elseif ($LocalDnsSuffix -ne $matches[0]) {
            #     Write-Warning "Local DNS suffix mismatch: $LocalDnsSuffix != $($matches[0])"
            # }
        } else {
            if(!$RemoteHostName) {
                $RemoteHostName=$HaHost
            } elseif ($RemoteHostName -ne $HaHost) {
                Write-Warning "Remote hostname mismatch: $RemoteHostName != $HaHost"
            }
            $parts = $HaHost -split '\.', 2
            if(!$Name) {
                $Name = $parts[0]
            }elseif($Name -ne $parts[0]) {
                Write-Warning "Name mismatch: $Name != $($parts[0])"
            }
        }
        if(!$Port) {
            $Port = $HaDict["Port"] ? $HaDict["Port"] : 8123
        }
        if(!$Token) {
            $Token = $HaDict["Token"] ? $HaDict["Token"] : (Get-SecretString -Name "Ha${Name}Token" -AsPlainText)
        }
        $IsSsl = $IsSsl || ($HaDict["Ssl"] -eq "true")
        return [NetDaemon]::new($Name, $LocalHostName, $RemoteHostName, $Ip, $PreferRemote, $RemotePort, $HaHost, $Port, $IsSsl, $PreferDns)
}

echo "NetDaemonPs loaded"
