class NetDaemon {
    [string]$Name
    [string]$LocalHostName
    [string]$RemoteHostName
    [string]$Ip
    [bool]$PreferRemote
    [int]$RemotePort
    [string]$Hostname
    [int]$Port
    [string]$Scheme
    [string]$Url
    [bool]$IsSsl
    [bool]$PreferDns
    [string]$NetDaemonVersion = "5"
    [string]$ConfigDirectory = "\config"
    [string]$NetDaemonDirectory = "\netdaemon5"
    [bool]$PersistDrive = $true
    [string]$NdSlug = "c6a2317c_netdaemon5"
    [string]$NdJson = '{"addon": "c6a2317c_netdaemon5"}'
    [string]$SrcPath
    [string]$DriveUsername = "homeassistant"
    [string]$DriveRoot,
    $HaDrive

    NetDaemon([string]$Name, [string]$LocalHostName, [string]$RemoteHostName, [string]$Ip, [bool]$PreferRemote, [int]$RemotePort, [string]$Hostname, [int]$Port, [bool]$IsSsl, [bool]$PreferDns) {
        $this.Name = $Name
        $this.LocalHostName = $LocalHostName
        $this.RemoteHostName = $RemoteHostName
        $this.Ip = $Ip
        $this.PreferRemote = $PreferRemote
        $this.RemotePort = $RemotePort
        $this.Hostname = $Hostname
        $this.Port = $Port
        $this.IsSsl = $IsSsl
        $this.PreferDns = $PreferDns
        $this.UpdateHostName()
    }
    [void]UpdateHostName() {
        $this.PreferRemote = $this.PreferRemote -or ($this.Ip -and !$this.LocalHostName -and $this.RemoteHostName) ? $true : $false
        $this.Scheme = $this.IsSsl ? "http" : "https"
        if ($this.PreferRemote) {
            $this.PreferDns = $true
            $this.Hostname = $this.RemoteHostName
            if (-not $this.RemotePort) {
                $this.RemotePort = $this.Port
            }
            $this.SetDriveRoot("")
        } elseif ($this.Ip) {
            $this.Hostname = $this.Ip
            $this.SetDriveRoot("\\$($this.Hostname)\$($this.ConfigDirectory)")
        } else {
            $this.Hostname = $this.LocalHostName
            $this.SetDriveRoot("\\$($this.Hostname)\$($this.ConfigDirectory)")
        }
        $this.Url = "$($this.Scheme)://"
        $this.Url += $this.Hostname + ":"
        $this.Url += $this.PreferRemote ? $this.RemotePort : $this.Port
    }

    [string]TryResolveIp() {
        if ($this.Ip) {
            return $this.Ip
        }
        if ($this.Hostname) {
            $ResolvedIp = (Resolve-DNSName $this.Hostname | where Ip4Address -ne $null | select -ExpandProperty IP4Address)
            if ($ResolvedIp) {
                $this.Ip = $ResolvedIp
                $this.UpdateHostName()
                return $this.Ip
            }
        }
        return $null
    }

    [string]GetDriveRoot() {
        if (-not $this.DriveRoot) {
            $this.TryResolveIp()
        }
        return $this.DriveRoot
    }

    [void]SetDriveRoot([string]$DriveRoot) {
        $this.DriveRoot = $DriveRoot
        # TODO: Remap drive
    }

    [bool]IsConnected() {
        return $global:ha_api_configured
    }

    [void]MapDrive() {
        $Root = $this.DriveRoot
        if (-not $this.HaDrive) {
            $Credential = (Get-SecretCredential -Name $this.DriveRoot -UserName "$this.DriveUsername" -Message "Enter the password for the Home Assistant user for $Root")
            Get-DriveOrCreate -RootPath $Root -Credential $Credential -Persist
            $this.HaDrive = $Env:HaDrive = $global:HaDrive = $global:CurrentPSDrive
        }
    }

    [void]Connect() {
        if (-not $this.IsConnected()) {
            Import-Module Home-Assistant
            $Token = Get-SecretString -Name "Ha$($this.Name)Token" -AsPlainText
            $HaHost = $this.PreferDns ? $this.Hostname : $this.Ip
            echo "Connecting to $HaHost"
            if (-not $HaHost) {
                $this.TryResolveIp()
                $HaHost = $this.Ip
            }
            echo "Connecting to $($this.Scheme)`://$HaHost`:$($this.Port)"
            New-HomeAssistantSession -ip $HaHost -port $this.Port -token $Token -scheme $this.Scheme
            $global:ha_api_configured = $true
        }
    }

    [void]Disconnect() {
        if ($this.IsConnected()) {
            $global:ha_api_configured = $false
        }
    }

    [void]InvokeService([string]$service, [string]$json) {
        $this.Connect()
        try {
            Write-Information "Invoking $service"
            Invoke-HomeAssistantService -service $service -json $json
        } catch {
            $this.Disconnect()
            throw
        }
    }

    [void]UpdateTool() {
        dotnet tool update -g NetDaemon.HassModel.CodeGen
    }

    [void]UpdateEntities() {
        $GenArgs = "-fpe"
        $token = (Get-SecretString -Name "Ha$($this.Name)Token" -AsPlainText)
        if ($this.IsSsl) {
            $GenArgs += " -ssl true"
        }
        $HaHost = $this.Ip
        if (-not $HaHost) {
            $HaHost = $this.Hostname
        }
        $Cfg = Get-NetDaemonConfig
        if($Cfg.UseCustomCodegen -and $Cfg.NetDaemonLibSrc) {
            pushd "$($Cfg.NetDaemonLibSrc)\src\HassModel\NetDaemon.HassModel.CodeGenerator"
            try {
                $Tool=$Env:NdCodegenPath
            }
            finally {
                popd
            }
        }
        else {
            $Tool = "nd-codegen"
        }
        Write-Debug "$Tool $GenArgs -host $($HaHost) -port $($This.Port) -token ***"
        Invoke-Expression "$Tool $GenArgs -host $($HaHost) -port $($This.Port) -token $token 2>&1 | Write-Information" -Verbose
    }

    [void]RestartService() {
        $this.InvokeService("HASSIO.ADDON_STOP", $this.NdJson)
        $this.InvokeService("HASSIO.ADDON_START", $this.NdJson)
    }

    [void]Deploy() {
        $BuildRoot=$this.SrcPath
        if(!$BuildRoot) {
            $BuildRoot = $Env:NdAppRoot
        }
        if(!$BuildRoot) { 
            throw "No source path specified"
        }
        Log-Debug "Deploying from $BuildRoot"
        pushd $BuildRoot
        try {
            Write-Information "dotnet build -c Release ""Hammassistant.csproj"" -v n"
            dotnet build -c Release "Hammassistant.csproj" -v n 2>&1 | Write-Information
            if (-not $?) {
                throw "Failed to publish"
            }
            $this.GetDriveRoot()
            $OutputPath = $this.DriveRoot + $this.NetDaemonDirectory
            if (!$OutputPath) {
                throw "No output path"
            }
            $this.InvokeService("HASSIO.ADDON_STOP", $this.NdJson)
            ls -File $OutputPath | ForEach-Object {
                rm $_ -Force -Recurse -Verbose
            }
            Write-Information "dotnet publish -c Release ""Hammassistant.csproj""--no-build -o ""$OutputPath"" -v n"
            dotnet publish -c Release "Hammassistant.csproj" --no-build -o "$OutputPath"  -v n 2>&1 | Write-Information
            $this.InvokeService("HASSIO.ADDON_START", $this.NdJson)
        } finally {
            popd
        }
    }
}