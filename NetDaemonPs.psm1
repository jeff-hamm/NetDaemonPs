#$Env:NdCodegenPath=(Resolve-Path "$PsScriptRoot\..\..\submodules\netdaemon\src\HassModel\NetDaemon.HassModel.CodeGenerator\bin\Debug\net9.0\NetDaemon.HassModel.CodeGenerator.exe")
. NetDaemon.ps1
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


$KnownDaemons=@{}
function Set-NetDaemonEnvRoot($Path) {
    $Env:NdEnvRoot=$Path
}
function Set-NetDaemonCodeGen($Path) {
    $Env:NdCodegenPath=$Path
}
function Reload-NetDaemon($Name) {
    if($Name) {
        $KnownDaemons[$Name]=$Null
        if($global:CurrentNetDaemon.Name -eq $Name) {
            $global:CurrentNetDaemon=$Null
        }
    }
    else {
        $KnownDaemons=@{}
        $global:CurrentNetDaemon=$Null
    }
    Import-Module -Name NetDaemonPs -Force
    Get-NetDaemon($Name)
}

function Get-NetDaemon([string]$Name, $EnvPath, [switch]$Existing, [switch]$Reload) {
    if(!$Name) {
        $Name=(git rev-parse --abbrev-ref HEAD)
    }
    if(!$Reload) {
        if(global:CurrentNetDaemon.Name -eq $Name) {
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
        if($Env:NdEnvRoot){
            $EnvPath=$Env:NdEnvRoot
        }
        else {
            $EnvPath=$PWD
        }
        if($Name) {
            $EnvPath+="\$Name"
        }
        $EnvPath+="\.env"
    }
    if (Test-Path "$EnvPath") {
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
    $KnownDaemons[$Name] = $NetDaemon
    $global:CurrentNetDaemon = $NetDaemon
#    new($Name, $LocalHostName, $RemoteHostName, $Ip, $PreferRemote, $RemotePort, $HaHost, $Port, $IsSsl, $PreferDns)
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
