#Requires -Version 5.1
<#
.SYNOPSIS
  Comprehensive mwan3 IPv6 policy switch test: ping, HTTP egress mapping, tcpdump prefix validation.

.DESCRIPTION
  For each policy in -Policies:
  1. Sets mwan3.default_rule_v6.use_policy and restarts mwan3.
  2. Verifies reachability (router ping6, Windows ping -6 -S).
  3. Optionally HTTP egress probes and maps seen address to tunnel (mwan6-npt / wan_prefix).
  4. Runs tcpdump on the policy tunnel interface and checks that captured IPv6 source
     addresses belong to that tunnel's prefix registry (SNAT / wan_prefix / iface address).

  Requires tcpdump on OpenWrt VM (apk add tcpdump).

  Shipped: /usr/share/doc/mwan3/integration/Test-Mwan3ChannelSwitch.ps1
  Lab guide: /usr/share/doc/mwan3/OPENWRT_DEV_INFRASTRUCTURE.en.md (also .ru.md, .de.md)

.EXAMPLE
  .\Test-Mwan3ChannelSwitch.ps1 -DevHost 192.168.56.1 -LanInterface 'vEthernet (OpenWrt-LAN-Host)'

.EXAMPLE
  .\Test-Mwan3ChannelSwitch.ps1 -Policies ipv6_tb62,ipv6_tb63 -CheckLeakOnOtherTunnels
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
    [int]$TcpDumpCount = 10,
    [int]$TcpDumpTimeoutSec = 18,
    [switch]$SkipHttpCheck,
    [switch]$SkipTcpDump,
    [switch]$CheckLeakOnOtherTunnels,
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
        throw "No GUA on '$LanInterface'. Found: ${found}. Check RA/PD on dev LAN."
    }
    $list = ($gua | ForEach-Object { $_.IPAddress }) -join ', '
    throw "Multiple GUA on '$LanInterface': $list"
}

function Invoke-DevSshScript([string]$Script) {
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

function Get-TunnelRegistryFromDev {
    $script = @'
echo TUNNEL_REG_BEGIN
ip -6 -o addr show 2>/dev/null | awk "/inet6/ && \$2 ~ /^tb|^wwan|^wan|^henet/ { split(\$4,a,\"/\"); print \"REG_ADDR|\" \$2 \"|\" a[1] }"
/usr/sbin/mwan6-npt status 2>/dev/null | grep "snat ip6 to " | while read -r line; do
  iface=$(printf "%s\n" "$line" | sed -n "s/.*oifname \"\\([^\"]*\\)\".*/\\1/p")
  addr=$(printf "%s\n" "$line" | sed -n "s/.*snat ip6 to \\([^;]*\\).*/\\1/p")
  printf "REG_SNAT|%s|%s\n" "$iface" "$addr"
done
for iface in tb6 tb62 tb63 tb64 tb65 tb66 tb67 wwan wan henet; do
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

function Test-SourceMatchesTunnel([string]$SrcIp, [string]$ExpectedIface, $Registry) {
    $mapped = Resolve-TunnelForIp $SrcIp $Registry
    if ($ExpectedIface -eq '?' -or -not $SrcIp) {
        return [pscustomobject]@{ Ok = $false; Detail = "src=$SrcIp map=$mapped" }
    }
    if ($mapped -eq $ExpectedIface) {
        return [pscustomobject]@{ Ok = $true; Detail = "OK $SrcIp -> $ExpectedIface" }
    }
    return [pscustomobject]@{ Ok = $false; Detail = "MISMATCH src=$SrcIp map=$mapped want=$ExpectedIface" }
}

function Invoke-TcpDumpTrafficCapture {
    param(
        [string]$ExpectedIface,
        [string]$LanSourceV6,
        [string[]]$LeakIfaces,
        [string]$UsePrimary = ''
    )

    $leakList = ($LeakIfaces | Where-Object { $_ -and $_ -ne $ExpectedIface }) -join ','
    $usePrimary = if ($UsePrimary) { $UsePrimary } else { 'none' }
    $script = @'
set -eu
IFACE="__IFACE__"
USE_PRIMARY="__USE_PRIMARY__"
LAN_SRC="__LAN_SRC__"
HOST_TRACK="__HOST_TRACK__"
HOST_PLAIN="__HOST_PLAIN__"
COUNT=__COUNT__
TIMEOUT=__TIMEOUT__
LEAK_IFACES="__LEAK__"
LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo br-lan)
PCAP_FILTER="ip6"
_wpp=$(uci -q get "mwan6-npt.${IFACE}.wan_prefix" 2>/dev/null || true)
if [ -n "$_wpp" ]; then
	PCAP_FILTER="ip6 and src net ${_wpp}"
fi

strip_ip() {
	printf "%s" "$1" | sed 's/\.[0-9]*$//'
}

if ! command -v tcpdump >/dev/null 2>&1; then
	echo "PCAP_ERR|tcpdump-not-installed"
	exit 0
fi

gen_traffic() {
	if [ -n "$USE_PRIMARY" ] && [ "$USE_PRIMARY" != none ]; then
		mwan3 use "$USE_PRIMARY" ping6 -c 2 -W 2 "$HOST_TRACK" >/dev/null 2>&1 || true
		mwan3 use "$USE_PRIMARY" ping6 -c 2 -W 2 "$HOST_PLAIN" >/dev/null 2>&1 || true
		if command -v curl >/dev/null 2>&1; then
			mwan3 use "$USE_PRIMARY" curl -6 -sS -m 8 -g "https://api6.ipify.org" >/dev/null 2>&1 || true
		fi
	else
		ping6 -c 2 -W 2 "$HOST_TRACK" >/dev/null 2>&1 || true
		ping6 -c 2 -W 2 "$HOST_PLAIN" >/dev/null 2>&1 || true
		if command -v curl >/dev/null 2>&1; then
			curl -6 -sS -m 8 -g "https://api6.ipify.org" >/dev/null 2>&1 || true
		fi
	fi
	if [ -n "$LAN_SRC" ]; then
		ping6 -c 2 -W 2 -S "$LAN_SRC" "$HOST_TRACK" >/dev/null 2>&1 || true
	fi
}

parse_pcap() {
	_if="$1"
	_file="$2"
	_cnt=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		case "$line" in
		*"IP6 "*" > "*)
			src=$(strip_ip "$(printf "%s\n" "$line" | sed -n "s/.*IP6 \\([^ ]*\\) >.*/\\1/p")")
			dst=$(strip_ip "$(printf "%s\n" "$line" | sed -n "s/.*IP6 [^ ]* > \\([^,: ]*\\).*/\\1/p")")
			[ -n "$src" ] || continue
			echo "PCAP_SRC|${_if}|${src}|${dst}"
			_cnt=$((_cnt + 1))
			;;
		esac
	done <"$_file"
	echo "PCAP_STAT|${_if}|count=${_cnt}"
}

run_capture() {
	_if="$1"
	_out=$(mktemp)
	tcpdump -i "$_if" -n -l -c "$COUNT" $PCAP_FILTER 2>/dev/null >"$_out" &
	_tp=$!
	sleep 1
	gen_traffic
	_wait=0
	while kill -0 "$_tp" 2>/dev/null && [ "$_wait" -lt "$TIMEOUT" ]; do
		sleep 1
		_wait=$((_wait + 1))
	done
	kill "$_tp" 2>/dev/null || true
	wait "$_tp" 2>/dev/null || true
	parse_pcap "$_if" "$_out"
	rm -f "$_out"
}

run_capture "$IFACE"

if [ -n "$LEAK_IFACES" ]; then
	OLDIFS=$IFS
	IFS=','
	for leak_if in $LEAK_IFACES; do
		[ -n "$leak_if" ] || continue
		[ "$leak_if" = "$IFACE" ] && continue
		ip link show "$leak_if" >/dev/null 2>&1 || continue
		_out=$(mktemp)
		_lfilter="$PCAP_FILTER"
		tcpdump -i "$leak_if" -n -l -c 3 $_lfilter 2>/dev/null >"$_out" &
		_lp=$!
		sleep 1
		gen_traffic
		_lwait=0
		while kill -0 "$_lp" 2>/dev/null && [ "$_lwait" -lt 6 ]; do
			sleep 1
			_lwait=$((_lwait + 1))
		done
		kill "$_lp" 2>/dev/null || true
		wait "$_lp" 2>/dev/null || true
		while IFS= read -r line; do
			case "$line" in
			*"IP6 "*" > "*)
				src=$(strip_ip "$(printf "%s\n" "$line" | sed -n "s/.*IP6 \\([^ ]*\\) >.*/\\1/p")")
				[ -n "$src" ] || continue
				echo "PCAP_LEAK|${leak_if}|${src}"
				;;
			esac
		done <"$_out"
		rm -f "$_out"
	done
	IFS=$OLDIFS
fi
'@
    $script = $script.Replace('__IFACE__', $ExpectedIface)
    $script = $script.Replace('__USE_PRIMARY__', $usePrimary)
    $script = $script.Replace('__LAN_SRC__', $LanSourceV6)
    $script = $script.Replace('__HOST_TRACK__', $HostTracked)
    $script = $script.Replace('__HOST_PLAIN__', $HostPlain)
    $script = $script.Replace('__COUNT__', [string]$TcpDumpCount)
    $script = $script.Replace('__TIMEOUT__', [string]$TcpDumpTimeoutSec)
    $script = $script.Replace('__LEAK__', $leakList)
    return Invoke-DevSshScript $script
}

function Parse-PcapLines([string]$DevOut) {
    $srcRows = [System.Collections.Generic.List[object]]::new()
    $leaks = [System.Collections.Generic.List[string]]::new()
    $statCount = 0
    $err = ''

    foreach ($line in ($DevOut -split "`n")) {
        if ($line -match '^PCAP_SRC\|([^|]+)\|([^|]+)\|(.*)$') {
            $srcRows.Add([pscustomobject]@{
                    Iface = $Matches[1]
                    Src   = $Matches[2].Trim()
                    Dst   = $Matches[3].Trim()
                })
        }
        elseif ($line -match '^PCAP_LEAK\|([^|]+)\|(.+)$') {
            $leaks.Add("$($Matches[1]):$($Matches[2].Trim())")
        }
        elseif ($line -match '^PCAP_STAT\|[^|]+\|count=(\d+)$') {
            $statCount = [int]$Matches[1]
        }
        elseif ($line -match '^PCAP_ERR\|(.+)$') {
            $err = $Matches[1]
        }
    }

    return [pscustomobject]@{
        Sources   = $srcRows.ToArray()
        Leaks     = $leaks.ToArray()
        Count     = $statCount
        Error     = $err
    }
}

function Invoke-DevEgressProbe {
    param(
        [string]$PrimaryIface = ''
    )

    $primaryToken = if ($PrimaryIface) { $PrimaryIface } else { '' }
    $loop = ($HttpProbeUrls | ForEach-Object {
        $u = $_
        '_ip=$(_fetch_http "' + $u + '")' + "`n" +
        'echo "PROBE_DEV|' + $u + '|$_ip"' + "`n" +
        'echo "MAP_DEV|$_ip|$(resolve_tunnel "$_ip")"'
    }) -join "`n"

    $probeScript = @'
set -eu
HTTP_TO=__HTTP_TO__
USE_PRIMARY="__USE_PRIMARY__"

_fetch_http() {
	_url="$1"
	if [ -n "$USE_PRIMARY" ]; then
		if command -v curl >/dev/null 2>&1; then
			mwan3 use "$USE_PRIMARY" curl -6 -sS -m "$HTTP_TO" -g "$_url" 2>/dev/null | tr -d "\r\n"
			return
		fi
		mwan3 use "$USE_PRIMARY" wget -q -T "$HTTP_TO" -O- "$_url" 2>/dev/null | tr -d "\r\n"
		return
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -6 -sS -m "$HTTP_TO" -g "$_url" 2>/dev/null | tr -d "\r\n"
		return
	fi
	wget -q -T "$HTTP_TO" -O- "$_url" 2>/dev/null | tr -d "\r\n"
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
	for _iface in tb6 tb62 tb63 tb64 tb65 tb66 tb67 wwan wan henet; do
		_wp=$(uci -q get "mwan6-npt.${_iface}.wan_prefix" 2>/dev/null) || continue
		_pfx=${_wp%/*}
		[ -n "$_pfx" ] || continue
		case "$_e" in
		${_pfx}*|${_pfx}) echo "$_iface"; return ;;
		esac
	done
	echo "?"
}

__PROBE_LOOP__
'@
    $probeScript = $probeScript.Replace('__HTTP_TO__', [string]$HttpTimeoutSec)
    $probeScript = $probeScript.Replace('__USE_PRIMARY__', $primaryToken)
    $probeScript = $probeScript.Replace('__PROBE_LOOP__', $loop)
    return Invoke-DevSshScript $probeScript
}

function Get-ProbeConsensus([array]$Probes) {
    $okProbes = @($Probes | Where-Object { $_.Ok -and $_.Ip })
    if ($okProbes.Count -eq 0) {
        return [pscustomobject]@{ Ip = ''; Agree = $false; Detail = 'all probes failed' }
    }
    $groups = $okProbes | Group-Object { $_.Ip.Trim().ToLower() }
    $best = $groups | Sort-Object Count -Descending | Select-Object -First 1
    $detail = ($okProbes | ForEach-Object {
            $h = ([uri]$_.Url).Host
            if (-not $h) { $h = $_.Url }
            "${h}=$($_.Ip)"
        }) -join '; '
    return [pscustomobject]@{ Ip = $best.Name; Agree = ($groups.Count -eq 1); Detail = $detail }
}

function Parse-DevProbeLines([string]$DevOut) {
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($DevOut -split "`n")) {
        if ($line -match '^PROBE_DEV\|(.+)\|(.*)$') {
            $ip = $Matches[2].Trim()
            $list.Add([pscustomobject]@{ Url = $Matches[1]; Ip = $ip; Ok = [bool]$ip })
        }
    }
    return $list.ToArray()
}

function Parse-DevMapLines([string]$DevOut) {
    $maps = @{}
    foreach ($line in ($DevOut -split "`n")) {
        if ($line -match '^MAP_DEV\|([^|]+)\|(.+)$') {
            $maps[$Matches[1].Trim().ToLower()] = $Matches[2].Trim()
        }
    }
    return $maps
}

function Test-WinPing([string]$SourceV6, [string]$Target) {
    Start-Sleep -Seconds 1
    $pingLines = & ping.exe -6 -S $SourceV6 -n $PingCount -w 4000 $Target 2>&1
    $ping = ($pingLines | Out-String)
    $targetPattern = [regex]::Escape($Target)
    $replyLines = @($pingLines | Where-Object { $_ -match $targetPattern -and $_ -match '=\d+' })
    $ok = ($replyLines.Count -gt 0)
    if (-not $ok -and $ping -match '0%') {
        $ok = ($ping -notmatch '100%')
    }
    return [pscustomobject]@{ Ok = $ok }
}

function Assert-Check {
    param(
        [string]$Policy,
        [string]$CheckName,
        [bool]$Ok,
        [string]$Detail = ''
    )

    if ($Ok) { return }
    Write-Log "FAIL policy=$Policy check=$CheckName $Detail"
    if (-not $ContinueOnFailure) {
        throw "Failed: policy=$Policy check=$CheckName"
    }
}

$src = Get-DevLanSourceV6
Write-Log "Comprehensive channel switch test: ${DevUser}@${DevHost}"
Write-Log "LAN source: $src | Tracked: $HostTracked | Plain: $HostPlain"

$tunnelRegistry = Get-TunnelRegistryFromDev
Write-Log ("Tunnel registry: {0} addrs, {1} SNAT, {2} prefixes" -f `
        $tunnelRegistry.Addrs.Count, $tunnelRegistry.Snat.Count, $tunnelRegistry.Prefixes.Count)

$allTunnelIfaces = @($tunnelRegistry.Prefixes | ForEach-Object { $_.Iface } | Sort-Object -Unique)
if ($CheckLeakOnOtherTunnels -and $allTunnelIfaces.Count -eq 0) {
    $allTunnelIfaces = @('tb62', 'tb63', 'tb65', 'tb66')
}

$results = @()

foreach ($policy in $Policies) {
    Write-Log "=== $policy ==="
    $devOut = Switch-DevPolicy $policy $src
    $active = if ($devOut -match 'POLICY_ACTIVE=(\S+)') { $Matches[1] } else { $policy }
    $policyMeta = Get-PolicyMetaFromDevOut $devOut
    $expectedIface = Resolve-ExpectedTestIface $devOut $active
    if ($policyMeta.IsDual) {
        Write-Log "Dual policy: testing primary channel only ($($policyMeta.Primary))"
    }
    $devPingTrack = if ($devOut -match 'DEV_PING_TRACK=(\d+)') { [int]$Matches[1] } else { 0 }
    $devPingPlain = if ($devOut -match 'DEV_PING_PLAIN=(\d+)') { [int]$Matches[1] } else { 0 }

    $winTrack = Test-WinPing -SourceV6 $src -Target $HostTracked
    Start-Sleep -Seconds 1
    $winPlain = Test-WinPing -SourceV6 $src -Target $HostPlain

    $pcapMatch = 'SKIP'
    $pcapCount = 0
    $pcapDetail = ''
    $leakDetail = 'none'

    if (-not $SkipTcpDump) {
        if ($expectedIface -eq '?' -or $expectedIface -eq 'unreachable') {
            $pcapMatch = 'SKIP no-iface'
        }
        else {
            $leakIfaces = @()
            if ($CheckLeakOnOtherTunnels) { $leakIfaces = $allTunnelIfaces }
            $pcapOut = Invoke-TcpDumpTrafficCapture -ExpectedIface $expectedIface -LanSourceV6 $src -LeakIfaces $leakIfaces -UsePrimary $(if ($policyMeta.IsDual) { $policyMeta.Primary } else { '' })
            $parsed = Parse-PcapLines $pcapOut
            if ($parsed.Error) {
                $pcapMatch = "ERR $($parsed.Error)"
            }
            else {
                $pcapCount = $parsed.Count
                $mismatch = @()
                foreach ($row in $parsed.Sources) {
                    $m = Test-SourceMatchesTunnel $row.Src $expectedIface $tunnelRegistry
                    if (-not $m.Ok) { $mismatch += $m.Detail }
                }
                if ($pcapCount -eq 0) {
                    $pcapMatch = 'FAIL no-packets'
                }
                elseif ($mismatch.Count -gt 0) {
                    $pcapMatch = 'FAIL ' + ($mismatch -join '; ')
                }
                else {
                    $uniq = ($parsed.Sources | ForEach-Object { $_.Src } | Sort-Object -Unique) -join ', '
                    $pcapMatch = "OK n=$pcapCount src=[$uniq]"
                }
                if ($parsed.Leaks.Count -gt 0) {
                    $leakDetail = $parsed.Leaks -join '; '
                    $pcapMatch = "$pcapMatch LEAK=$leakDetail"
                }
            }
            $pcapDetail = $pcapOut
        }
    }

    $devMatch = 'SKIP'
    $devSeen = ''
    if (-not $SkipHttpCheck) {
        $probeOut = Invoke-DevEgressProbe -PrimaryIface $(if ($policyMeta.IsDual) { $policyMeta.Primary } else { '' })
        $devProbes = Parse-DevProbeLines $probeOut
        $devMaps = Parse-DevMapLines $probeOut
        $consensus = Get-ProbeConsensus $devProbes
        $devSeen = $consensus.Ip
        $mapped = if ($consensus.Ip) { $devMaps[$consensus.Ip.ToLower()] } else { '?' }
        if (-not $mapped -and $consensus.Ip) {
            $mapped = Resolve-TunnelForIp $consensus.Ip $tunnelRegistry
        }
        if (-not $consensus.Ip) {
            $devMatch = 'FAIL no-egress-ip'
        }
        elseif ($mapped -eq $expectedIface) {
            $devMatch = "OK $devSeen -> $expectedIface"
        }
        else {
            $devMatch = "MISMATCH ip=$devSeen map=$mapped want=$expectedIface"
        }
    }

    $row = [pscustomobject]@{
        Policy     = $active
        MwanIface  = $expectedIface
        DevPing    = if ($devPingTrack -gt 0 -and $devPingPlain -gt 0) { 'OK' } else { 'FAIL' }
        WinPing    = if ($winTrack.Ok -and $winPlain.Ok) { 'OK' } else { 'FAIL' }
        HttpMatch  = $devMatch
        TcpDump    = $pcapMatch
        Leak       = $leakDetail
    }
    $results += $row
    Write-Host ($row | Format-List | Out-String)

    Assert-Check -Policy $active -CheckName 'DevPing' -Ok ($devPingTrack -gt 0 -and $devPingPlain -gt 0)
    Assert-Check -Policy $active -CheckName 'WinPing' -Ok ($winTrack.Ok -and $winPlain.Ok)
    if (-not $SkipHttpCheck) {
        Assert-Check -Policy $active -CheckName 'HttpMatch' -Ok ($devMatch -like 'OK *') -Detail $devMatch
    }
    if (-not $SkipTcpDump -and $pcapMatch -notlike 'SKIP*') {
        $pcapOk = ($pcapMatch -like 'OK *') -and ($leakDetail -eq 'none')
        Assert-Check -Policy $active -CheckName 'TcpDumpPrefix' -Ok $pcapOk -Detail $pcapMatch
        if (-not $pcapOk -and $pcapDetail) {
            Write-Host ($pcapDetail -split "`n" | Select-Object -Last 20 | Out-String)
        }
    }
}

Write-Log '=== Summary ==='
$results | Format-Table -AutoSize Policy, MwanIface, DevPing, WinPing, HttpMatch, TcpDump

Write-Log 'Restore ipv6_primary'
Invoke-DevSshScript @'
uci set mwan3.default_rule_v6.use_policy=ipv6_primary
uci commit mwan3
/etc/init.d/mwan3 restart
'@ | Out-Null
Write-Log 'Done.'
