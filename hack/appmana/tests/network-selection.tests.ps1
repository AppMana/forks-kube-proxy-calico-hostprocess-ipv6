$ErrorActionPreference = 'Stop'
$modulePath = (Resolve-Path (Join-Path $PSScriptRoot '../../../hostprocess/calico/kube-proxy/wait-hns.psm1')).Path
Import-Module $modulePath -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('proxy-selection-' + [guid]::NewGuid())
New-Item -ItemType Directory $root | Out-Null
$configPath = Join-Path $root 'vpc-bridge.conf'
$config = @{ type='vpc-bridge'; name='vpc'; eniMACAddress='02:ff:cf:ad:b3:43'; eniIPAddresses=@('172.29.0.14/25') }
$native = [pscustomobject]@{ Name='vpcbr02ffcfadb343'; Type='L2Bridge'; ManagementIP='172.29.0.14' }
$calico = [pscustomobject]@{ Name='Calico'; Type='L2Bridge'; ManagementIP='10.0.0.2' }
$passed = 0
function Assert-Selection($Name, $Networks, $Expected) {
    $actual = Get-HnsProxyNetwork -Networks $Networks -NativeCniConfigPath $configPath
    if ($actual.Name -ne $Expected) { throw "$Name selected an unexpected network" }
    $script:passed++; Write-Host "PASS $Name"
}
function Assert-Rejected($Name, [scriptblock]$Action) {
    $rejected=$false
    try { & $Action | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw "$Name was accepted" }
    $script:passed++; Write-Host "PASS $Name"
}
try {
    Assert-Selection 'Calico default' @($calico,$native) 'Calico'
    foreach ($nativeMode in @($false,$true)) {
        if ($nativeMode) { $config | ConvertTo-Json | Set-Content $configPath }
        foreach ($enable in @('', 'true')) {
            foreach ($disable in @('', 'true')) {
                $expected = ($nativeMode -or $enable -eq 'true') -and $disable -ne 'true'
                $actual = Get-HnsProxyDsrEnabled -Networks @($calico,$native) -NativeCniConfigPath $configPath -EnableDSR $enable -DisableDSR $disable
                if ($actual -ne $expected) { throw "Incorrect DSR mode: native=$nativeMode enable=$enable disable=$disable" }
                $passed++; Write-Host "PASS DSR mode native=$nativeMode enable=$enable disable=$disable"
            }
        }
    }
    Assert-Rejected 'DSR requires configured network' { Get-HnsProxyDsrEnabled -Networks @($calico) -NativeCniConfigPath $configPath }
    Assert-Rejected 'DSR override cannot bypass native identity validation' { Get-HnsProxyDsrEnabled -Networks @($calico) -NativeCniConfigPath $configPath -EnableDSR true }
    Remove-Item $configPath
    if (Get-HnsProxyNetwork -Networks @($native) -NativeCniConfigPath $configPath) { throw 'Selected an unrelated network before CNI configuration' }
    $passed++; Write-Host 'PASS wait before CNI configuration'
    $config | ConvertTo-Json | Set-Content $configPath
    Assert-Selection 'native CNI overrides Calico fallback' @($calico,$native) $native.Name
    if (Get-HnsProxyNetwork -Networks @($calico) -NativeCniConfigPath $configPath) { throw 'Fell back to Calico while native network missing' }
    $passed++; Write-Host 'PASS no fallback while native network missing'
    Assert-Rejected 'duplicate HNS identity' { Get-HnsProxyNetwork -Networks @($native,$native) -NativeCniConfigPath $configPath }
    Assert-Rejected 'wrong management IP' { Get-HnsProxyNetwork -Networks @([pscustomobject]@{Name=$native.Name;Type='L2Bridge';ManagementIP='172.29.0.15'}) -NativeCniConfigPath $configPath }
    Assert-Rejected 'wrong HNS type' { Get-HnsProxyNetwork -Networks @([pscustomobject]@{Name=$native.Name;Type='Overlay';ManagementIP='172.29.0.14'}) -NativeCniConfigPath $configPath }
    foreach ($change in @(@{type='bridge'},@{name='vpc.*'},@{eniMACAddress='invalid'},@{eniIPAddresses=@('172.29.0.14/25','172.29.0.15/25')},@{eniIPAddresses=@('::1/128')},@{eniIPAddresses=@('172.29.0.14/0')})) {
        $bad=$config.Clone(); foreach($key in $change.Keys){$bad[$key]=$change[$key]}
        $bad | ConvertTo-Json | Set-Content $configPath
        Assert-Rejected ('invalid config '+($change.Keys -join ',')) { Get-HnsProxyNetwork -Networks @($native,$calico) -NativeCniConfigPath $configPath }
    }
    '{invalid' | Set-Content $configPath
    Assert-Rejected 'malformed JSON' { Get-HnsProxyNetwork -Networks @($native) -NativeCniConfigPath $configPath }
    $config | ConvertTo-Json | Set-Content $configPath
    '{}' | Set-Content (Join-Path $root 'other.conflist')
    Assert-Rejected 'competing CNI configuration' { Get-HnsProxyNetwork -Networks @($native) -NativeCniConfigPath $configPath }
    Remove-Item (Join-Path $root 'other.conflist')

    # Exercise the default bounded query, including late CNI initialization.
    $stub = Join-Path $root 'mock-hns.psm1'
    "function Get-HnsNetwork { [pscustomobject]@{Name='vpcbr02ffcfadb343';Type='L2Bridge';ManagementIP='172.29.0.14'} }; Export-ModuleMember Get-HnsNetwork" | Set-Content $stub
    Remove-Item $configPath
    $writer=Start-Job -ScriptBlock { param($path,$json); Start-Sleep 3; [IO.File]::WriteAllText($path,$json) } -ArgumentList $configPath,($config | ConvertTo-Json)
    $probe=Start-Job -ScriptBlock {
        param($module,$stub,$path)
        Import-Module $module -Force
        Wait-HnsNetworkReady -NetworkName Calico -HnsModulePath $stub -NativeCniConfigPath $path -QueryTimeoutSeconds 5 -PollIntervalSeconds 1 -PassThru
    } -ArgumentList $modulePath,$stub,$configPath
    try {
        if (-not (Wait-Job $probe -Timeout 30)) { throw 'Late configuration was not discovered' }
        $result=Receive-Job $probe -ErrorAction Stop
        if ($result -ne $native.Name) { throw 'Bounded query selected the wrong network' }
        $passed++; Write-Host 'PASS late native configuration in bounded query'
    } finally { $writer,$probe | Stop-Job; $writer,$probe | Remove-Job -Force }
    Write-Host "$passed network-selection checks passed"
} finally { Remove-Item -Recurse -Force $root }
