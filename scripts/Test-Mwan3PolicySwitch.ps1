#Requires -Version 5.1
<#
.SYNOPSIS
  Switch mwan3 IPv6 policies on openwrt-dev; verify from dev ping + Windows ping (-S, no route changes).

  Dev ping: plain ping6 (no -I) — mwan3 policy selects the tunnel.
  Requires mwan6-npt router-src SNAT rules (oif != wan_prefix -> tunnel address).

  Test hosts:
    HostTracked: 2606:4700:4700::1111  (track_ip, /128 routes via mwan3 sync-track-routes)
    HostPlain:   2001:470:20::2       (HE.net anycast, no host route on Windows)

  HTTP / egress map (-HttpCheck):
    Probes: api6.ipify.org, icanhazip.com, v6.ident.me (plain IPv6 body)
    Maps seen address -> tunnel (iface on router, SNAT target, wan_prefix)
    Compares mapped tunnel with mwan3 policy iface (MwanIface)

  Note: ip route get shows MAIN table (::/1 split-default). mwan3 policy uses fwmark —
  compare MwanIface column, not MainDev. route get uses the same LAN source as Windows ping (-S);
  if empty on the router, falls back to the first global IPv6 on network.lan.device (br-lan).

  DevMatch: egress IP from router (mwan3 policy + mwan6-npt SNAT) vs MwanIface — authoritative.
  WinMatch: Windows curl --interface LAN often shows ULA/LAN, not tunnel SNAT; use -StrictWinHttpMatch to fail on mismatch.

  Windows LAN source: single GUA on -LanInterface (dev host leg); resolved via Get-NetIPAddress.

  Shipped in mwan3 package: /usr/share/doc/mwan3/integration/Test-Mwan3PolicySwitch.ps1
  Lab guide: /usr/share/doc/mwan3/OPENWRT_DEV_INFRASTRUCTURE.en.md (also .ru.md, .de.md)

.EXAMPLE
  .\Test-Mwan3PolicySwitch.ps1
  .\Test-Mwan3PolicySwitch.ai.ps1 -HttpCheck
  .\Test-Mwan3PolicySwitch.ps1 -Policies ipv6_tb62,ipv6_tb66
  .\Test-Mwan3PolicySwitch.ps1 -LanInterface 'vEthernet (OpenWrt-LAN-Host)' -HttpCheck
  .\Test-Mwan3PolicySwitch.ps1 -HttpCheck -HttpViaMwanIface
#>
[CmdletBinding()]
param(
    [string]$DevHost = '192.168.56.1',
    [string]$DevUser = 'root',
    [string]$LanInterface = 'vEthernet (OpenWrt-LAN-Host)',
    [string[]]$Policies = @(
        'ipv6_tb62', 'ipv6_tb63', 'ipv6_tb65', 'ipv6_tb66'
    ),
    [string]$HostTracked = '2606:4700:4700::1111',
    [string]$HostPlain = '2001:470:20::2',
    [string[]]$HttpProbeUrls = @(
        'https://api6.ipify.org',
        'https://icanhazip.com',
        'https://v6.ident.me'
    ),
    [int]$PingCount = 2,
    [int]$WaitAfterSwitchSec = 5,
    [int]$HttpTimeoutSec = 12,
    [switch]$HttpCheck,
    [switch]$HttpViaMwanIface,
    [switch]$StrictWinHttpMatch,
    [switch]$ContinueOnFailure
)

if ($Policies.Count -eq 1 -and $Policies[0] -match ',') {
    $Policies = $Policies[0] -split ',' | ForEach-Object { $_.Trim() }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log([string]$Message) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Get-DevLanSourceV6 {
    if (-not (Get-NetAdapter -Name $LanInterface -ErrorAction SilentlyContinue)) {
        throw "Network adapter '$LanInterface' not found. Run: Get-NetAdapter | Where-Object Status -eq 'Up'"
    }

    $gua = @(Get-NetIPAddress -InterfaceAlias $LanInterface -AddressFamily IPv6 -ErrorAction Stop |
        Where-Object {
            $_.AddressState -eq 'Preferred' -and
            $_.IPAddress -notmatch '^(fe80:|ff|::|fd[0-9a-f]{2}:)'
        })

    if ($gua.Count -eq 1) {
        Write-Log "LAN source $($gua[0].IPAddress)/$($gua[0].PrefixLength) on '$LanInterface'"
        return $gua[0].IPAddress
    }

    $found = (Get-NetIPAddress -InterfaceAlias $LanInterface -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.IPAddress) ($($_.AddressState))" }) -join ', '
    if ($gua.Count -eq 0) {
        throw "No GUA on '$LanInterface' (expected exactly one Preferred global). Found: ${found}. Check RA/PD on openwrt-dev LAN."
    }
    $list = ($gua | ForEach-Object { $_.IPAddress }) -join ', '
    throw "Multiple GUA on '$LanInterface' (expected exactly one): $list. All on adapter: ${found}"
}

function Invoke-DevSshScript([string]$Script) {
    # Avoid "$Script | ssh": PowerShell may inject CRLF into the remote script stream.
    $Script = $Script -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $Script.EndsWith("`n")) {
        $Script += "`n"
    }
    $sshArgs = "-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ${DevUser}@${DevHost} sh -s"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'ssh'
    $psi.Arguments = $sshArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Script)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        $msg = @($stdout, $stderr) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        throw ($msg -join "`n")
    }
    return $stdout.Trim()
}

function Switch-DevPolicy([string]$Policy, [string]$LanSourceV6) {
    $script = @'
set -eu
POLICY=__POLICY__
HOST_TRACK=__HOST_TRACK__
HOST_PLAIN=__HOST_PLAIN__
WAIT=__WAIT__
PINGC=__PINGC__
LAN_SRC="__LAN_SRC__"
LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo br-lan)
if [ -z "$LAN_SRC" ]; then
	LAN_SRC=$(ip -6 -o addr show dev "$LAN_DEV" scope global 2>/dev/null | awk '{print $4}' | head -1)
	LAN_SRC=${LAN_SRC%%/*}
fi

uci set mwan3.default_rule_v6.use_policy="$POLICY"
uci commit mwan3
/etc/init.d/mwan3 restart
sleep 2
mwan3 flush-conntrack 2>/dev/null || true
mwan3 sync-track-routes 2>/dev/null || true
sleep "$WAIT"
echo POLICY_ACTIVE=$(uci -q get mwan3.default_rule_v6.use_policy)
echo LAN_ROUTE_SRC=${LAN_SRC:-"(none)"}
PRIMARY=""
MEMBERS=0
idx=0
best_metric=9999
best_idx=9999
for m in $(uci -q get "mwan3.${POLICY}.use_member" 2>/dev/null); do
	iface=$(uci -q get "mwan3.${m}.interface")
	metric=$(uci -q get "mwan3.${m}.metric")
	[ -n "$metric" ] || metric=9999
	if [ "$metric" -lt "$best_metric" ] || { [ "$metric" -eq "$best_metric" ] && [ "$idx" -lt "$best_idx" ]; }; then
		best_metric=$metric
		best_idx=$idx
		PRIMARY=$iface
	fi
	MEMBERS=$((MEMBERS + 1))
	idx=$((idx + 1))
done
echo POLICY_MEMBERS=$MEMBERS
echo POLICY_PRIMARY=${PRIMARY:-unknown}
mwan3 status 2>/dev/null | sed -n "/Current ipv6 policies:/,/Directly connected/p"
if [ -n "$LAN_SRC" ]; then
	echo ROUTE_TRACK=$(ip -6 route get "$HOST_TRACK" from "$LAN_SRC" iif "$LAN_DEV" 2>&1 | head -1)
	echo ROUTE_PLAIN=$(ip -6 route get "$HOST_PLAIN" from "$LAN_SRC" iif "$LAN_DEV" 2>&1 | head -1)
else
	echo ROUTE_TRACK=error:no-lan-global-ipv6
	echo ROUTE_PLAIN=error:no-lan-global-ipv6
fi
dev_ping6() {
	_host="$1"
	if [ "$MEMBERS" -ge 2 ] && [ -n "$PRIMARY" ] && [ "$PRIMARY" != unknown ]; then
		mwan3 use "$PRIMARY" ping6 -c "$PINGC" -W 3 "$_host" 2>&1
	else
		ping6 -c "$PINGC" -W 3 "$_host" 2>&1
	fi
}
echo DEV_PING_TRACK=$(dev_ping6 "$HOST_TRACK" | grep -c "bytes from" || true)
echo DEV_PING_PLAIN=$(dev_ping6 "$HOST_PLAIN" | grep -c "bytes from" || true)
'@
    $script = $script.Replace('__POLICY__', $Policy)
    $script = $script.Replace('__HOST_TRACK__', $HostTracked)
    $script = $script.Replace('__HOST_PLAIN__', $HostPlain)
    $script = $script.Replace('__WAIT__', [string]$WaitAfterSwitchSec)
    $script = $script.Replace('__PINGC__', [string]$PingCount)
    $script = $script.Replace('__LAN_SRC__', $LanSourceV6)
    return Invoke-DevSshScript $script
}

function Invoke-DevEgressProbe {
    param(
        [string]$Policy,
        [string]$PrimaryIface = ''
    )

    $primaryToken = if ($PrimaryIface) { $PrimaryIface } else { '' }
    $useBlock = if ($HttpViaMwanIface) {
        if ($PrimaryIface) {
            @'

IFACE="__USE_PRIMARY__"
case "$IFACE" in
tb*|wwan|wan|henet)
	_url=$(echo "$URL0")
	if command -v curl >/dev/null 2>&1; then
		_ip=$(mwan3 use "$IFACE" curl -6 -sS -m "$HTTP_TO" -g "$_url" 2>/dev/null | tr -d "\r\n")
	else
		_ip=$(mwan3 use "$IFACE" wget -q -T "$HTTP_TO" -O- "$_url" 2>/dev/null | tr -d "\r\n")
	fi
	echo "PROBE_USE|${_url}|${_ip}"
	echo "MAP_USE|${_ip}|$(resolve_tunnel "${_ip}")"
	;;
esac
'@
        }
        else {
            @'

IFACE=$(mwan3 status 2>/dev/null | sed -n "s/^ *POLICY_PLACEHOLDER: *//p" | head -1 | tr -d " ")
case "$IFACE" in
tb*|wwan|wan|henet)
	_url=$(echo "$URL0")
	_ip=$(_fetch_http "$_url")
	if command -v curl >/dev/null 2>&1; then
		_ip=$(mwan3 use "$IFACE" curl -6 -sS -m "$HTTP_TO" -g "$_url" 2>/dev/null | tr -d "\r\n")
	else
		_ip=$(mwan3 use "$IFACE" wget -q -T "$HTTP_TO" -O- "$_url" 2>/dev/null | tr -d "\r\n")
	fi
	echo "PROBE_USE|${_url}|${_ip}"
	echo "MAP_USE|${_ip}|$(resolve_tunnel "${_ip}")"
	;;
esac
'@
        }
    }
    else {
        ''
    }

    $probeScript = @'
set -eu
HTTP_TO=__HTTP_TO__
URL0="__URL0__"
POLICY_PLACEHOLDER="__POLICY__"
USE_PRIMARY="__USE_PRIMARY__"

_fetch_http() {
	_url="$1"
	if [ -n "$USE_PRIMARY" ]; then
		if command -v curl >/dev/null 2>&1; then
			mwan3 use "$USE_PRIMARY" curl -6 -sS -m "$HTTP_TO" -g "$_url" 2>/dev/null | tr -d "\r\n"
			return
		fi
		if command -v wget >/dev/null 2>&1; then
			mwan3 use "$USE_PRIMARY" wget -q -T "$HTTP_TO" -O- "$_url" 2>/dev/null | tr -d "\r\n"
			return
		fi
		echo ""
		return
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -6 -sS -m "$HTTP_TO" -g "$_url" 2>/dev/null | tr -d "\r\n"
		return
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T "$HTTP_TO" -O- "$_url" 2>/dev/null | tr -d "\r\n"
		return
	fi
	echo ""
}

resolve_tunnel() {
	_e="$1"
	[ -n "$_e" ] || { echo "?"; return; }
	_dev=$(ip -6 -o addr show 2>/dev/null | awk -v e="$_e" "{ split(\$4,a,\"/\"); if (tolower(a[1])==tolower(e)) { print \$2; exit } }")
	case "$_dev" in
	tb*|wwan|wan|henet) echo "$_dev"; return ;;
	esac
	_iface=$(/usr/sbin/mwan6-npt status 2>/dev/null | grep -F "snat ip6 to $_e" | sed -n "s/.*oifname \"\\([^\"]*\\)\".*/\\1/p" | head -1)
	case "$_iface" in
	tb*|wwan|wan|henet) echo "$_iface"; return ;;
	esac
	for _iface in tb6 tb62 tb63 tb64 tb65 tb66 wwan wan henet; do
		_wp=$(uci -q get "mwan6-npt.${_iface}.wan_prefix" 2>/dev/null) || continue
		_pfx=${_wp%/*}
		[ -n "$_pfx" ] || continue
		case "$_e" in
		${_pfx}*|${_pfx}) echo "$_iface"; return ;;
		esac
	done
	_dev=$(ip -6 route get "$_e" 2>/dev/null | sed -n "s/.* dev \\([^ ]*\\).*/\\1/p" | head -1)
	case "$_dev" in
	tb*|wwan|wan|henet) echo "$_dev"; return ;;
	esac
	echo "?"
}

__PROBE_LOOP__
__USE_BLOCK__
'@

    $loop = ($HttpProbeUrls | ForEach-Object {
        $u = $_
        '_ip=$(_fetch_http "' + $u + '")' + "`n" +
        'echo "PROBE_DEV|' + $u + '|$_ip"' + "`n" +
        'echo "MAP_DEV|$_ip|$(resolve_tunnel "$_ip")"'
    }) -join "`n"

    $probeScript = $probeScript.Replace('__HTTP_TO__', [string]$HttpTimeoutSec)
    $probeScript = $probeScript.Replace('__URL0__', $HttpProbeUrls[0])
    $probeScript = $probeScript.Replace('__POLICY__', $Policy)
    $probeScript = $probeScript.Replace('__USE_PRIMARY__', $primaryToken)
    $probeScript = $probeScript.Replace('__PROBE_LOOP__', $loop)
    $useBlockText = $useBlock.Replace('POLICY_PLACEHOLDER', $Policy).Replace('__USE_PRIMARY__', $primaryToken)
    $probeScript = $probeScript.Replace('__USE_BLOCK__', $useBlockText)
    if ($env:MWAN_DEBUG_PROBE -eq '1') {
        [System.IO.File]::WriteAllText("$env:TEMP\mwan-probe.sh", $probeScript.Replace("`r`n", "`n"))
        Write-Log "DEBUG: wrote $env:TEMP\mwan-probe.sh"
    }
    return Invoke-DevSshScript $probeScript
}

function Get-CurlBindAddress([string]$SourceV6) {
    # Windows curl: --interface must be an IP address (not adapter friendly name or ifIndex).
    return $SourceV6
}

function Test-WinHttp {
    param(
        [string]$InterfaceAlias,
        [string]$SourceV6,
        [string]$Url
    )

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Ok     = $false
            Body   = ''
            Detail = 'curl.exe not found (Windows 10+ ships it)'
        }
    }

    $bindAddr = Get-CurlBindAddress -SourceV6 $SourceV6
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $curlArgs = @(
            '-6', '-sS',
            '--max-time', [string]$HttpTimeoutSec,
            '--interface', $bindAddr,
            '-w', "`nCURL_META:http_code=%{http_code}|time_total=%{time_total}",
            '-o', $tmp,
            $Url
        )
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $lines = & curl.exe @curlArgs 2>&1
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
        $exit = $LASTEXITCODE
        $meta = ($lines | Where-Object { $_ -match '^CURL_META:' } | Select-Object -Last 1) -replace '^CURL_META:', ''
        $code = if ($meta -match 'http_code=(\d+)') { $Matches[1] } else { '0' }
        $body = ''
        if (Test-Path $tmp) {
            $rawBody = Get-Content -LiteralPath $tmp -Raw -ErrorAction SilentlyContinue
            if ($null -ne $rawBody) {
                $body = $rawBody.Trim()
            }
        }
        $ok = ($exit -eq 0) -and ($code -match '^2') -and ($body.Length -gt 0)
        $detail = if ($meta) { $meta } else { "exit=$exit" }
        if ($body) { $detail = "$detail body=$body" }
        return [pscustomobject]@{ Ok = $ok; Body = $body; Detail = $detail }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Test-WinPing([string]$SourceV6, [string]$Target) {
    Start-Sleep -Seconds 1
    $pingLines = & ping.exe -6 -S $SourceV6 -n $PingCount -w 4000 $Target 2>&1
    $ping = ($pingLines | Out-String)
    $targetPattern = [regex]::Escape($Target)
    $replyLines = @($pingLines | Where-Object {
            $_ -match $targetPattern -and $_ -match '=\d+'
        })
    $ok = ($replyLines.Count -gt 0)
    if (-not $ok -and $ping -match '0%') {
        $ok = ($ping -notmatch '100%')
    }
    $avg = $null
    if ($ping -match 'Average\s*=\s*(\d+)\s*ms') {
        $avg = [int]$Matches[1]
    }
    elseif ($ping -match '(\d+)\s*ms') {
        $nums = [regex]::Matches($ping, '(\d+)\s*ms') | ForEach-Object { [int]$_.Groups[1].Value }
        if ($nums.Count -gt 0) {
            $avg = [int](($nums | Measure-Object -Average).Average)
        }
    }
    return [pscustomobject]@{ Ok = $ok; AvgMs = $avg; Raw = ($pingLines | Select-Object -Last 4) -join "`n" }
}

function Get-MwanIface([string]$DevOut, [string]$PolicyName) {
    $escaped = [regex]::Escape($PolicyName)
    if ($DevOut -match "(?ms)${escaped}:\s*\r?\n\s*(tb\w+|wwan|henet|unreachable)") {
        return $Matches[1]
    }
    return '?'
}

function Get-PolicyMetaFromDevOut([string]$DevOut) {
    $members = 1
    $primary = ''
    if ($DevOut -match '(?m)^POLICY_MEMBERS=(\d+)') {
        $members = [int]$Matches[1]
    }
    if ($DevOut -match '(?m)^POLICY_PRIMARY=(\S+)') {
        $primary = $Matches[1]
    }
    if ($primary -eq 'unknown') {
        $primary = ''
    }
    return [pscustomobject]@{
        Members = $members
        Primary = $primary
        IsDual  = ($members -ge 2 -and [bool]$primary)
    }
}

function Resolve-ExpectedTestIface([string]$DevOut, [string]$PolicyName) {
    $meta = Get-PolicyMetaFromDevOut $DevOut
    if ($meta.IsDual) {
        return $meta.Primary
    }
    return Get-MwanIface $DevOut $PolicyName
}

function Get-MainDev([string]$RouteLine) {
    if ($RouteLine -match '\bdev (tb\w+|br-lan|eth\d+)\b') {
        return $Matches[1]
    }
    return '?'
}

function Get-DevHttpField([string]$DevOut, [string]$Key) {
    $escaped = [regex]::Escape($Key)
    if ($DevOut -match "(?m)^${escaped}=(.*)$") {
        return $Matches[1].Trim()
    }
    return ''
}

function Format-HttpCell([string]$Body) {
    if (-not $Body) { return 'FAIL' }
    if ($Body.Length -gt 40) { return "OK $($Body.Substring(0, 37))..." }
    return "OK $Body"
}

function Get-TunnelRegistryFromDev {
    $script = @'
echo TUNNEL_REG_BEGIN
ip -6 -o addr show 2>/dev/null | awk "/inet6/ && \$2 ~ /^tb|^wwan|^wan|^henet/ { split(\$4,a,\"/\"); print \"REG_ADDR|\" \$2 \"|\" a[1] }"
/usr/sbin/mwan6-npt status 2>/dev/null | grep "snat ip6 to " | while read -r line; do
  iface=$(printf "%s\n" "$line" | sed -n "s/.*oifname \"\\([^\"]*\\)\".*/\\1/p")
  addr=$(printf "%s\n" "$line" | sed -n "s/.*snat ip6 to \\([^;]*\\).*/\\1/p")
  printf "REG_SNAT|%s|%s\n" "$iface" "$addr"
done
for iface in tb6 tb62 tb63 tb64 tb65 tb66 wwan wan henet; do
  wp=$(uci -q get "mwan6-npt.${iface}.wan_prefix" 2>/dev/null) || continue
  printf "REG_PREFIX|%s|%s\n" "$iface" "$wp"
done
echo TUNNEL_REG_END
'@
    $out = Invoke-DevSshScript $script
    $addrs = @{}
    $snat = @{}
    $prefixes = @()
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^REG_ADDR\|([^|]+)\|(.+)$') {
            $addrs[$Matches[2].Trim().ToLower()] = $Matches[1]
        }
        elseif ($line -match '^REG_SNAT\|([^|]+)\|(.+)$') {
            $snat[$Matches[2].Trim().ToLower()] = $Matches[1]
        }
        elseif ($line -match '^REG_PREFIX\|([^|]+)\|(.+)$') {
            $rawBase = ($Matches[2] -replace '/.*$', '').ToLower().TrimEnd(':')
            $prefixes += [pscustomobject]@{
                Iface  = $Matches[1]
                Prefix = $Matches[2]
                Base   = $rawBase
            }
        }
    }
    return [pscustomobject]@{ Addrs = $addrs; Snat = $snat; Prefixes = $prefixes }
}

function Resolve-TunnelForIp([string]$Ip, $Registry) {
    $key = $Ip.Trim().ToLower()
    if (-not $key) { return '?' }
    if ($Registry.Addrs.ContainsKey($key)) { return $Registry.Addrs[$key] }
    if ($Registry.Snat.ContainsKey($key)) { return $Registry.Snat[$key] }
    $best = $null
    $bestLen = -1
    foreach ($p in $Registry.Prefixes) {
        $pfx = $p.Base.TrimEnd(':')
        if (-not $pfx) { continue }
        $inPrefix = ($key -eq $pfx) -or $key.StartsWith("${pfx}:")
        if (-not $inPrefix) { continue }
        $plen = if ($p.Prefix -match '/(\d+)$') { [int]$Matches[1] } else { 0 }
        if ($plen -gt $bestLen) { $best = $p.Iface; $bestLen = $plen }
    }
    if ($best) { return $best }
    return '?'
}

function Invoke-WinHttpProbes([string]$SourceV6, [string[]]$Urls) {
    $probes = [System.Collections.Generic.List[object]]::new()
    foreach ($url in $Urls) {
        $r = Test-WinHttp -InterfaceAlias $LanInterface -SourceV6 $SourceV6 -Url $url
        $probes.Add([pscustomobject]@{
                Url    = $url
                Ip     = if ($r.Ok) { $r.Body.Trim() } else { '' }
                Ok     = $r.Ok
                Detail = $r.Detail
            })
        Start-Sleep -Milliseconds 300
    }
    return $probes.ToArray()
}

function Get-ProbeConsensus([array]$Probes) {
    $okProbes = @($Probes | Where-Object { $_.Ok -and $_.Ip })
    if ($okProbes.Count -eq 0) {
        return [pscustomobject]@{
            Ip     = ''
            Agree  = $false
            Detail = 'all probes failed'
        }
    }
    $groups = $okProbes | Group-Object { $_.Ip.Trim().ToLower() }
    $best = $groups | Sort-Object Count -Descending | Select-Object -First 1
    $detail = ($okProbes | ForEach-Object {
            $probeHost = ([uri]$_.Url).Host
            if (-not $probeHost) { $probeHost = $_.Url }
            "${probeHost}=$($_.Ip)"
        }) -join '; '
    [pscustomobject]@{
        Ip     = $best.Name
        Agree  = ($groups.Count -eq 1) -or ($best.Count -ge 2)
        Detail = $detail
    }
}

function Parse-DevProbeLines([string]$DevOut, [string]$LinePrefix) {
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($DevOut -split "`n")) {
        if ($line -match "^${LinePrefix}\|(.+)\|(.*)$") {
            $ip = $Matches[2].Trim()
            $list.Add([pscustomobject]@{
                    Url = $Matches[1]
                    Ip  = $ip
                    Ok  = [bool]$ip
                })
        }
    }
    return $list.ToArray()
}

function Parse-DevMapLines([string]$DevOut, [string]$LinePrefix) {
    $maps = @{}
    foreach ($line in ($DevOut -split "`n")) {
        if ($line -match "^${LinePrefix}\|([^|]+)\|(.+)$") {
            $maps[$Matches[1].Trim().ToLower()] = $Matches[2].Trim()
        }
    }
    return $maps
}

function Format-PolicyTunnelMatch([string]$ExpectedIface, [string]$MappedTunnel, [string]$SeenIp) {
    if (-not $SeenIp) { return 'FAIL no-egress-ip' }
    if (-not $ExpectedIface -or $ExpectedIface -eq '?') { return "ip=$SeenIp tunnel=$MappedTunnel" }
    if ($MappedTunnel -eq '?') { return "ip=$SeenIp tunnel=?" }
    if ($ExpectedIface -eq $MappedTunnel) { return "OK $SeenIp -> $MappedTunnel" }
    return "MISMATCH ip=$SeenIp map=$MappedTunnel want=$ExpectedIface"
}

function Invoke-FailureDiagnostics {
    param(
        [string]$Policy,
        [string]$DevOut,
        [string]$FailedCheck,
        [string]$WinSource
    )

    Write-Host ''
    Write-Log "FAIL on policy=$Policy check=$FailedCheck - collecting diagnostics"
    Write-Host $DevOut
    Write-Host ''

    $diag = @'
LAN_SRC="__LAN_SRC__"
LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo br-lan)
if [ -z "$LAN_SRC" ]; then
	LAN_SRC=$(ip -6 -o addr show dev "$LAN_DEV" scope global 2>/dev/null | awk '{print $4}' | head -1)
	LAN_SRC=${LAN_SRC%%/*}
fi
echo "=== uci default_rule_v6 ==="
uci show mwan3.default_rule_v6
echo "=== LAN route-get source: ${LAN_SRC:-(none)} dev=$LAN_DEV ==="
echo "=== track /128 routes (sample tables 2,3,4) ==="
for t in 2 3 4 5 6 7; do
  ip -6 route show table "$t" 2>/dev/null | grep -E "/128|default" || true
done
if [ -n "$LAN_SRC" ]; then
	echo "=== route get tracked ==="
	ip -6 route get __HOST_TRACK__ from "$LAN_SRC" iif "$LAN_DEV" 2>&1 || true
	echo "=== route get plain ==="
	ip -6 route get __HOST_PLAIN__ from "$LAN_SRC" iif "$LAN_DEV" 2>&1 || true
else
	echo "=== route get skipped: no LAN global IPv6 on $LAN_DEV ==="
fi
echo "=== ping6 tracked (router default) ==="
ping6 -c 3 -W 3 __HOST_TRACK__ 2>&1 || true
echo "=== ping6 plain (router default) ==="
ping6 -c 3 -W 3 __HOST_PLAIN__ 2>&1 || true
echo "=== mwan6-npt status ==="
/etc/init.d/mwan6-npt status 2>&1 || true
'@
    $diag = $diag.Replace('__HOST_TRACK__', $HostTracked).Replace('__HOST_PLAIN__', $HostPlain)
    $diag = $diag.Replace('__LAN_SRC__', $WinSource)
    try {
        Invoke-DevSshScript $diag | Write-Host
    }
    catch {
        Write-Log "Diagnostic SSH failed: $_"
    }

    Write-Log "Windows ping from $WinSource (no route changes):"
    & ping.exe -6 -S $WinSource -n 3 -w 4000 $HostTracked 2>&1 | Write-Host
    & ping.exe -6 -S $WinSource -n 3 -w 4000 $HostPlain 2>&1 | Write-Host
}

function Assert-PingOk {
    param(
        [string]$Policy,
        [string]$DevOut,
        [string]$CheckName,
        [bool]$Ok,
        [string]$WinSource
    )

    if ($Ok) { return }
    Invoke-FailureDiagnostics -Policy $Policy -DevOut $DevOut -FailedCheck $CheckName -WinSource $WinSource
    if (-not $ContinueOnFailure) {
        throw "Ping failed: policy=$Policy check=$CheckName"
    }
}

$src = Get-DevLanSourceV6
Write-Log "Windows ping -S $src via '$LanInterface' (host routes NOT changed)"
$tunnelRegistry = $null
if ($HttpCheck) {
    Write-Log "HTTP egress probes: $($HttpProbeUrls -join ', ')"
    Write-Log "Windows: curl -6 --interface $src | Router: curl (active mwan3 policy)"
    if ($HttpViaMwanIface) {
        Write-Log 'Also: mwan3 use <policy iface> on first probe URL'
    }
    Write-Log 'Loading tunnel registry from dev (addrs, SNAT, wan_prefix)...'
    $tunnelRegistry = Get-TunnelRegistryFromDev
    Write-Log ("Registry: {0} addrs, {1} SNAT, {2} prefixes" -f $tunnelRegistry.Addrs.Count, $tunnelRegistry.Snat.Count, $tunnelRegistry.Prefixes.Count)
}
Write-Log "Dev: ${DevUser}@${DevHost} | LAN route-get source: $src | Tracked(/128): $HostTracked | Plain: $HostPlain"
Write-Host ''

$results = @()

foreach ($policy in $Policies) {
    Write-Log "=== $policy ==="
    try {
        $devOut = Switch-DevPolicy $policy $src
        $policyMeta = Get-PolicyMetaFromDevOut $devOut
        if ($HttpCheck) {
            $probePrimary = if ($policyMeta.IsDual) { $policyMeta.Primary } else { '' }
            $devOut = "$devOut`n$(Invoke-DevEgressProbe -Policy $policy -PrimaryIface $probePrimary)"
        }
    }
    catch {
        Write-Log "ERROR switching policy: $_"
        throw
    }

    $active = if ($devOut -match 'POLICY_ACTIVE=(\S+)') { $Matches[1] } else { $policy }
    $routeTrack = if ($devOut -match '(?m)^ROUTE_TRACK=(.*)$') { $Matches[1].Trim() } else { '' }
    $devPingTrack = if ($devOut -match 'DEV_PING_TRACK=(\d+)') { [int]$Matches[1] } else { 0 }
    $devPingPlain = if ($devOut -match 'DEV_PING_PLAIN=(\d+)') { [int]$Matches[1] } else { 0 }
    if ($policyMeta.IsDual) {
        Write-Log "Dual policy: testing primary channel only ($($policyMeta.Primary))"
    }

    $winTrack = Test-WinPing -SourceV6 $src -Target $HostTracked
    Start-Sleep -Seconds 1
    $winPlain = Test-WinPing -SourceV6 $src -Target $HostPlain

    $expectedIface = Resolve-ExpectedTestIface $devOut $active
    $devConsensus = $null
    $winConsensus = $null
    $devMatch = ''
    $winMatch = ''
    $devUseMatch = ''
    if ($HttpCheck) {
        $devProbes = Parse-DevProbeLines $devOut 'PROBE_DEV'
        $devMaps = Parse-DevMapLines $devOut 'MAP_DEV'
        $devConsensus = Get-ProbeConsensus $devProbes
        $devMapped = if ($devConsensus.Ip) {
            $devMaps[$devConsensus.Ip.ToLower()]
        } else { '?' }
        if (-not $devMapped -and $devConsensus.Ip) {
            $devMapped = Resolve-TunnelForIp $devConsensus.Ip $tunnelRegistry
        }
        $devMatch = Format-PolicyTunnelMatch $expectedIface $devMapped $devConsensus.Ip

        $winProbes = Invoke-WinHttpProbes -SourceV6 $src -Urls $HttpProbeUrls
        $winConsensus = Get-ProbeConsensus $winProbes
        $winMapped = Resolve-TunnelForIp $winConsensus.Ip $tunnelRegistry
        $winMatch = Format-PolicyTunnelMatch $expectedIface $winMapped $winConsensus.Ip

        if ($HttpViaMwanIface) {
            $useProbes = Parse-DevProbeLines $devOut 'PROBE_USE'
            $useMaps = Parse-DevMapLines $devOut 'MAP_USE'
            $useConsensus = Get-ProbeConsensus $useProbes
            $useMapped = if ($useConsensus.Ip) { $useMaps[$useConsensus.Ip.ToLower()] } else { '?' }
            if (-not $useMapped -and $useConsensus.Ip) {
                $useMapped = Resolve-TunnelForIp $useConsensus.Ip $tunnelRegistry
            }
            $devUseMatch = Format-PolicyTunnelMatch $expectedIface $useMapped $useConsensus.Ip
        }

        Write-Host "  Dev egress:  $($devConsensus.Detail)"
        Write-Host "  Dev map:     $devMatch"
        Write-Host "  Win egress:  $($winConsensus.Detail)"
        Write-Host "  Win map:     $winMatch"
        if ($devUseMatch) { Write-Host "  mwan3 use:   $devUseMatch" }
    }

    $row = [pscustomobject]@{
        Policy      = $active
        MwanIface   = $expectedIface
        MainDev     = Get-MainDev $routeTrack
        DevTracked  = if ($devPingTrack -gt 0) { "OK x$devPingTrack" } else { 'FAIL' }
        DevPlain    = if ($devPingPlain -gt 0) { "OK x$devPingPlain" } else { 'FAIL' }
        WinTracked  = if ($winTrack.Ok) { if ($null -ne $winTrack.AvgMs) { "OK $($winTrack.AvgMs)ms" } else { 'OK' } } else { 'FAIL' }
        WinPlain    = if ($winPlain.Ok) { if ($null -ne $winPlain.AvgMs) { "OK $($winPlain.AvgMs)ms" } else { 'OK' } } else { 'FAIL' }
    }
    if ($HttpCheck) {
        $row | Add-Member -NotePropertyName DevSeen -NotePropertyValue $(if ($devConsensus.Ip) { $devConsensus.Ip } else { 'FAIL' })
        $row | Add-Member -NotePropertyName DevMatch -NotePropertyValue $devMatch
        $row | Add-Member -NotePropertyName WinSeen -NotePropertyValue $(if ($winConsensus.Ip) { $winConsensus.Ip } else { 'FAIL' })
        $row | Add-Member -NotePropertyName WinMatch -NotePropertyValue $winMatch
        if ($HttpViaMwanIface) {
            $row | Add-Member -NotePropertyName UseMatch -NotePropertyValue $devUseMatch
        }
    }
    $results += $row
    Write-Host ($row | Format-List | Out-String)

    Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'DevTracked' -Ok ($devPingTrack -gt 0) -WinSource $src
    Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'DevPlain' -Ok ($devPingPlain -gt 0) -WinSource $src
    Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'WinTracked' -Ok $winTrack.Ok -WinSource $src
    Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'WinPlain' -Ok $winPlain.Ok -WinSource $src
    if ($HttpCheck) {
        Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'DevEgress' -Ok ([bool]$devConsensus.Ip) -WinSource $src
        Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'DevMatch' -Ok ($devMatch -like 'OK *') -WinSource $src
        if ($StrictWinHttpMatch) {
            Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'WinEgress' -Ok ([bool]$winConsensus.Ip) -WinSource $src
            Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'WinMatch' -Ok ($winMatch -like 'OK *') -WinSource $src
        }
        if ($HttpViaMwanIface) {
            Assert-PingOk -Policy $active -DevOut $devOut -CheckName 'UseMatch' -Ok ($devUseMatch -like 'OK *') -WinSource $src
        }
    }
}

Write-Log '=== Summary ==='
if ($HttpCheck -and $HttpViaMwanIface) {
    $results | Format-Table -AutoSize Policy, MwanIface, DevSeen, DevMatch, WinSeen, WinMatch, UseMatch, DevTracked, WinTracked
}
elseif ($HttpCheck) {
    $results | Format-Table -AutoSize Policy, MwanIface, DevSeen, DevMatch, WinSeen, WinMatch, DevTracked, WinTracked
}
else {
    $results | Format-Table -AutoSize Policy, MwanIface, MainDev, DevTracked, DevPlain, WinTracked, WinPlain
}

Write-Log 'Restore ipv6_primary'
Invoke-DevSshScript @'
uci set mwan3.default_rule_v6.use_policy=ipv6_primary
uci commit mwan3
/etc/init.d/mwan3 restart
'@ | Out-Null
Write-Log 'Done.'
