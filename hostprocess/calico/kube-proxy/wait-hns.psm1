# Resolve the network selected by the native CNI configuration. A missing AWS
# configuration preserves the existing Calico default. Resolve on every poll:
# the proxy can start before the CNI initializer writes its configuration.
function Get-HnsProxyNetwork {
    param(
        [object[]]$Networks,
        [string]$NetworkName = 'Calico',
        [string]$NativeCniConfigPath
    )
    $native = $false
    $address = $null
    if ($NativeCniConfigPath -and (Test-Path -LiteralPath $NativeCniConfigPath)) {
        $file = Get-Item -LiteralPath $NativeCniConfigPath -ErrorAction Stop
        if ($file.PSIsContainer -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($file.Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Native CNI configuration must be a regular file in a regular directory'
        }
        $configs = @(Get-ChildItem -LiteralPath $file.DirectoryName -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.conf', '.conflist', '.json') })
        if ($configs.Count -ne 1 -or $configs[0].FullName -ne $file.FullName) {
            throw 'Native CNI selection requires one unambiguous configuration'
        }
        $config = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($config.type -ne 'vpc-bridge' -or
            $config.name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$' -or
            $config.eniMACAddress -notmatch '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' -or
            @($config.eniIPAddresses).Count -ne 1) {
            throw 'Invalid native AWS CNI network identity'
        }
        $parts = ([string]$config.eniIPAddresses[0]).Split('/')
        $ip = $null
        $prefixLength = 0
        if ($parts.Count -ne 2 -or -not [net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
            $ip.AddressFamily -ne [net.sockets.AddressFamily]::InterNetwork -or
            $ip.ToString() -ne $parts[0] -or -not [int]::TryParse($parts[1], [ref]$prefixLength) -or
            $prefixLength -lt 1 -or $prefixLength -gt 32) {
            throw 'Invalid native AWS CNI management address'
        }
        # This is the vpc-bridge provider's deterministic HNS network name.
        $NetworkName = $config.name + 'br' + $config.eniMACAddress.Replace(':', '').ToLowerInvariant()
        $address = $ip.ToString()
        $native = $true
    }
    $selected = @($Networks | Where-Object Name -EQ $NetworkName)
    if ($selected.Count -gt 1) { throw 'Ambiguous HNS network identity' }
    if ($selected.Count -eq 0) { return }
    if ($native -and ($selected[0].Type -ne 'L2Bridge' -or $selected[0].ManagementIP -ne $address)) {
        throw 'HNS network does not match the native CNI configuration'
    }
    return $selected[0]
}

# Wait-HnsNetworkReady: blocks until the named HNS network exists.
#
# The query runs with an injectable scriptblock so tests can mock HNS behavior
# (see hack/appmana/tests/). The default query imports hns.psm1 and calls
# Get-HnsNetwork.
function Wait-HnsNetworkReady {
    param(
        [Parameter(Mandatory)] [string]$NetworkName,
        [scriptblock]$Query,
        [object[]]$QueryArgumentList,
        [string]$HnsModulePath,
        [string]$NativeCniConfigPath,
        [switch]$PassThru,
        [int]$QueryTimeoutSeconds = 15,
        [int]$PollIntervalSeconds = 1
    )
    if (-not $Query) {
        $Query = {
            param($name, $modulePath, $selectorModulePath, $cniConfigPath)
            Import-Module $selectorModulePath -Force
            Import-Module $modulePath -Force -DisableNameChecking
            $network = Get-HnsProxyNetwork -Networks @(Get-HnsNetwork) -NetworkName $name -NativeCniConfigPath $cniConfigPath
            if ($network) { $network.Name }
        }
        $QueryArgumentList = @($NetworkName, $HnsModulePath, $MyInvocation.MyCommand.Module.Path, $NativeCniConfigPath)
    }

    # A separate job bounds HNS RPCs even when the service is restarting.
    # A failed or missing selection never falls back to an unrelated network.
    while ($true) {
        $job = Start-Job -ScriptBlock $Query -ArgumentList $QueryArgumentList
        if (Wait-Job $job -Timeout $QueryTimeoutSeconds) {
            $found = Receive-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force
            if ($found) {
                if ($PassThru) { $found }
                return
            }
        } else {
            Write-Host "HNS query timed out after ${QueryTimeoutSeconds}s (HNS restarting?); retrying with a fresh process."
            Stop-Job $job
            Remove-Job $job -Force
        }
        Start-Sleep $PollIntervalSeconds
    }
}

function Get-HnsProxyDsrEnabled {
    param(
        [object[]]$Networks,
        [string]$NetworkName = 'Calico',
        [string]$NativeCniConfigPath,
        [string]$EnableDSR,
        [string]$DisableDSR
    )
    $network = Get-HnsProxyNetwork -Networks $Networks -NetworkName $NetworkName -NativeCniConfigPath $NativeCniConfigPath
    if (-not $network) { throw 'Cannot select DSR mode before the configured HNS network exists' }

    # Native VPC L2Bridge uses DSR for cross-node Services. Preserve the Calico
    # default and let an explicit disable take precedence over either default.
    $enabled = [bool]($NativeCniConfigPath -and (Test-Path -LiteralPath $NativeCniConfigPath))
    if ($EnableDSR -eq 'true') { $enabled = $true }
    if ($DisableDSR -eq 'true') { $enabled = $false }
    return $enabled
}

Export-ModuleMember -Function Wait-HnsNetworkReady, Get-HnsProxyNetwork, Get-HnsProxyDsrEnabled
