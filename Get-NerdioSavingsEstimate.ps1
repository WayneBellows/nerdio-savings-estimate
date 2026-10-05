<#
.SYNOPSIS
  Estimates monthly compute savings from Nerdio Manager (NME) auto-scale, per host pool and in total.

.DESCRIPTION
  The NME REST API does not expose the "Auto-scale savings" figure shown in the console. This
  script rebuilds an estimate from data the customer already has:

    1. Azure Resource Manager   - lists AVD host pools in each subscription.
    2. NME REST API             - auto-scale config per pool (VM size, max hosts, name prefix)
                                  and the current session hosts.
    3. Azure Cost Management    - actual VM compute cost and running hours per VM for the month.

  For each pool and month:
    baseline = max hosts x hours in month x effective hourly rate   (every host on, all month)
    actual   = Cost Management amortized compute cost for the pool's VMs
    savings  = baseline - actual

  The effective hourly rate is actual cost / actual hours, so Azure Hybrid Benefit, reservations
  and negotiated discounts are already in it. A month where a pool's VMs have no cost data at
  all (pool not yet built, or Cost Management has no data) is shown as "no usage data" and is
  NOT counted in the total - claiming 100% savings for it would overstate the figure.

  Deleted hosts (scaled in by auto-scale) are still counted: VMs are matched to a pool by current
  host name OR by the pool's VM name prefix (for example NEDCORP-KW{##}).

  This is an estimate. Nerdio does not publish the console's formula, so the numbers can differ
  from Auto-scale History. Compute only - storage and disk savings are not included.

  Read-only. Nothing is changed in NME or Azure.

.REQUIREMENTS
  - PowerShell 5.1 or 7.
  - Azure CLI (az), signed in with Reader + Cost Management Reader on the subscriptions.
  - An NME REST API app registration (NME > Settings > Integrations > REST API).

.EXAMPLE
  .\Get-NerdioSavingsEstimate.ps1 -CredentialFile .\nme-api.json -SubscriptionId <sub-id>

.EXAMPLE
  # Average the last three full months and save the detail to CSV
  .\Get-NerdioSavingsEstimate.ps1 -CredentialFile .\nme-api.json -SubscriptionId <sub-id> -Months 3 -CsvPath .\savings.csv
#>
[CmdletBinding()]
param(
    # JSON file with tokenUrl, clientId, clientSecret, scope, baseUrl (from NME REST API setup)
    [Parameter(Mandatory)] [string]$CredentialFile,
    [Parameter(Mandatory)] [string[]]$SubscriptionId,
    # Last month to report, yyyy-MM. Default: the last full month.
    [string]$EndMonth,
    # Number of full months to report, ending at EndMonth.
    [ValidateRange(1, 12)] [int]$Months = 1,
    # Also report pools where auto-scale is switched off (their "savings" are not from auto-scale).
    [switch]$IncludeDisabled,
    [string]$CsvPath,
    # Return the per-pool rows as objects as well as printing the summary.
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- helpers

function Invoke-Az {
    param([string]$Method, [string]$Url, $Body)
    $azArgs = @('rest', '--method', $Method, '--url', $Url, '--only-show-errors')
    $tmp = $null
    if ($null -ne $Body) {
        $tmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 10))
        $azArgs += @('--body', "@$tmp", '--headers', 'Content-Type=application/json')
    }
    try {
        $raw = & az @azArgs
        if ($LASTEXITCODE -ne 0) { throw "az rest $Method $Url failed (exit $LASTEXITCODE)" }
        return (($raw -join "`n") | ConvertFrom-Json)
    } finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}

function Get-ArmList {
    param([string]$Url)
    $items = New-Object System.Collections.Generic.List[object]
    while ($Url) {
        $r = Invoke-Az -Method get -Url $Url
        foreach ($v in @($r.value)) { $items.Add($v) }
        $Url = $r.nextLink
    }
    return ,$items
}

function Get-NmeToken {
    param($Creds)
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $Creds.clientId
        client_secret = $Creds.clientSecret
        scope         = $Creds.scope
    }
    return (Invoke-RestMethod -Uri $Creds.tokenUrl -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
}

function Invoke-Nme {
    param([string]$Path)
    try { return Invoke-RestMethod -Uri ($script:NmeBase + $Path) -Headers $script:NmeHeaders -UseBasicParsing }
    catch { return $null }
}

function ConvertTo-PrefixRegex {
    # NEDCORP-KW{##} -> ^nedcorp-kw\d+$ ; returns $null when there is no usable prefix
    param([string]$Prefix)
    if (-not $Prefix) { return $null }
    $parts = [regex]::Split($Prefix.ToLower(), '\{#+\}')
    if ($parts.Count -lt 2) { return '^' + [regex]::Escape($Prefix.ToLower()) + '\d*$' }
    return '^' + (($parts | ForEach-Object { [regex]::Escape($_) }) -join '\d+') + '$'
}

function Invoke-CostQuery {
    # Cost Management throttles per tenant (429). Honour its retry-after header, at most 2 retries.
    param([string]$Url, $Body)
    $token = & az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    Write-Verbose "Cost query: $Url $json"
    for ($attempt = 0; $attempt -le 2; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Method Post -Uri $Url -Body $json -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing
            return ($resp.Content | ConvertFrom-Json)
        } catch {
            $res = $_.Exception.Response
            if ($null -eq $res -or [int]$res.StatusCode -ne 429 -or $attempt -eq 2) { throw }
            $wait = 60
            foreach ($hn in @('x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after',
                              'x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after',
                              'x-ms-ratelimit-microsoft.costmanagement-entity-retry-after',
                              'x-ms-ratelimit-microsoft.costmanagement-tenant-retry-after', 'Retry-After')) {
                $v = $null
                try { $v = @($res.Headers.GetValues($hn))[0] } catch { try { $v = $res.Headers[$hn] } catch { } }
                if ($v -and [int]$v -gt 0) { $wait = [Math]::Min([int]$v + 2, 300); break }
            }
            Write-Warning "Cost Management is busy (429). Waiting $wait seconds, retry $($attempt + 1) of 2."
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-VmCost {
    # Amortized compute cost and hours per VM per month, for one subscription, in ONE query.
    # Cost Management throttles hard (429), so never query month by month.
    param([string]$Sub, [datetime]$From, [datetime]$To)
    $body = @{
        type       = 'AmortizedCost'
        timeframe  = 'Custom'
        timePeriod = @{ from = $From.ToString('yyyy-MM-ddT00:00:00Z'); to = $To.ToString('yyyy-MM-ddT23:59:59Z') }
        dataset    = @{
            granularity = 'Monthly'
            aggregation = @{
                totalCost = @{ name = 'Cost'; function = 'Sum' }
                totalQty  = @{ name = 'UsageQuantity'; function = 'Sum' }
            }
            grouping    = @(
                @{ type = 'Dimension'; name = 'ResourceId' },
                @{ type = 'Dimension'; name = 'UnitOfMeasure' }
            )
            filter      = @{ dimensions = @{ name = 'MeterCategory'; operator = 'In'; values = @('Virtual Machines') } }
        }
    }
    $url = "https://management.azure.com/subscriptions/$Sub/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $byKey = @{}   # "yyyy-MM|vmname" -> object
    $currency = $null
    while ($url) {
        $r = Invoke-CostQuery -Url $url -Body $body
        $cols = @($r.properties.columns | ForEach-Object { $_.name })
        $iCost = [array]::IndexOf($cols, 'Cost'); $iQty = [array]::IndexOf($cols, 'UsageQuantity')
        $iRes = [array]::IndexOf($cols, 'ResourceId'); $iUnit = [array]::IndexOf($cols, 'UnitOfMeasure')
        $iCur = [array]::IndexOf($cols, 'Currency')
        $iDate = -1
        for ($c = 0; $c -lt $cols.Count; $c++) { if ($cols[$c] -match '^(BillingMonth|UsageDate)$') { $iDate = $c } }
        foreach ($row in @($r.properties.rows)) {
            $rid = "$($row[$iRes])".ToLower()
            if ($rid -notmatch '/providers/microsoft.compute/virtualmachines/([^/]+)$') { continue }
            $name = $Matches[1]
            # PS 7 ConvertFrom-Json turns ISO dates into [datetime]; PS 5.1 leaves a string
            # (2026-09-01T00:00:00) and some API versions send a number (20260901).
            $d = $row[$iDate]
            if ($d -is [datetime]) { $month = $d.ToString('yyyy-MM') }
            else { $d = ("$d" -replace '-', ''); $month = $d.Substring(0, 4) + '-' + $d.Substring(4, 2) }
            $key = "$month|$name"
            if (-not $byKey.ContainsKey($key)) { $byKey[$key] = [pscustomobject]@{ month = $month; name = $name; id = $rid; cost = 0.0; hours = 0.0 } }
            $byKey[$key].cost += [double]$row[$iCost]
            if ("$($row[$iUnit])" -match 'hour') { $byKey[$key].hours += [double]$row[$iQty] }
            if ($iCur -ge 0) { $currency = $row[$iCur] }
        }
        $url = $r.properties.nextLink
    }
    return @{ rows = @($byKey.Values); currency = $currency }
}

# ---------------------------------------------------------------- months

if ($EndMonth) { $end = [datetime]::ParseExact($EndMonth, 'yyyy-MM', $null) }
else { $now = Get-Date; $end = (New-Object datetime $now.Year, $now.Month, 1).AddMonths(-1) }
$monthStarts = @()
for ($i = $Months - 1; $i -ge 0; $i--) { $monthStarts += $end.AddMonths(-$i) }

# ---------------------------------------------------------------- sign in

$null = & az account show --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run: az login' }

$creds = Get-Content -LiteralPath $CredentialFile -Raw | ConvertFrom-Json
$script:NmeBase = "$($creds.baseUrl)".TrimEnd('/')
$script:NmeHeaders = @{ Authorization = "Bearer $(Get-NmeToken $creds)" }
Write-Host "NME: signed in to $script:NmeBase"

# ---------------------------------------------------------------- collect

$results = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$currencySeen = $null

foreach ($sub in $SubscriptionId) {
    $pools = Get-ArmList "https://management.azure.com/subscriptions/$sub/providers/Microsoft.DesktopVirtualization/hostPools?api-version=2024-04-03"
    Write-Host "Subscription ${sub}: $($pools.Count) host pool(s)"

    # Pool config from NME, once per pool
    $poolInfo = @()
    foreach ($p in $pools) {
        $rg = ($p.id -split '/')[4]; $name = $p.name
        $as = Invoke-Nme "/api/v1/arm/hostpool/$sub/$rg/$name/auto-scale"
        if ($null -eq $as) { $skipped.Add("$name (not managed by NME or no auto-scale config)"); continue }
        if (-not $as.isEnabled -and -not $IncludeDisabled) { $skipped.Add("$name (auto-scale off)"); continue }
        [array]$hosts = Invoke-Nme "/api/v1/arm/hostpool/$sub/$rg/$name/host"
        if ($null -eq $hosts) { $hosts = @() }
        $hostNames = @($hosts | ForEach-Object { ("$($_.vmId)" -split '/')[-1].ToLower() } | Where-Object { $_ })
        $poolInfo += [pscustomobject]@{
            name = $name; rg = $rg; location = $p.location
            type = "$($p.properties.hostPoolType)"
            autoScale = [bool]$as.isEnabled
            size = "$($as.vmTemplate.size)"
            capacity = [int]$as.hostPoolCapacity
            regex = ConvertTo-PrefixRegex "$($as.vmTemplate.prefix)"
            hostNames = $hostNames
        }
    }
    if (-not $poolInfo.Count) { continue }

    $cost = Get-VmCost -Sub $sub -From $monthStarts[0] -To $end.AddMonths(1).AddDays(-1)
    if ($cost.currency) { $currencySeen = $cost.currency }

    foreach ($m in $monthStarts) {
        $hoursInMonth = [double]([DateTime]::DaysInMonth($m.Year, $m.Month) * 24)
        $monthKey = $m.ToString('yyyy-MM')
        $monthVms = @($cost.rows | Where-Object { $_.month -eq $monthKey })

        # Assign each VM to one pool: current host name first, then name prefix
        $assigned = @{}
        foreach ($vm in $monthVms) {
            $hit = @($poolInfo | Where-Object { $_.hostNames -contains $vm.name })
            if (-not $hit.Count) { $hit = @($poolInfo | Where-Object { $_.regex -and $vm.name -match $_.regex }) }
            if ($hit.Count -gt 1) { Write-Warning "$($vm.name) matches more than one pool; counted in $($hit[0].name)" }
            if ($hit.Count) { $assigned[$vm.name] = $hit[0].name }
        }

        foreach ($pi in $poolInfo) {
            $vms = @($monthVms | Where-Object { $assigned[$_.name] -eq $pi.name })
            $actual = [double](($vms | Measure-Object cost -Sum).Sum)
            $hours = [double](($vms | Measure-Object hours -Sum).Sum)

            # Baseline host count: max capacity for pooled, host count for personal
            $maxHosts = $pi.capacity
            if ($pi.type -eq 'Personal' -or $maxHosts -le 0) { $maxHosts = [Math]::Max($pi.hostNames.Count, $pi.capacity) }

            $rate = $null; $note = ''
            if ($hours -gt 0) { $rate = $actual / $hours } else { $note = 'no usage data - not counted' }
            $baseline = $null; $savings = $null; $pct = $null
            if ($null -ne $rate -and $maxHosts -gt 0) {
                $baseline = $maxHosts * $hoursInMonth * $rate
                $savings = $baseline - $actual
                if ($baseline -gt 0) { $pct = [Math]::Round(100 * $savings / $baseline, 1) }
            }
            $results.Add([pscustomobject]@{
                Month        = $m.ToString('yyyy-MM')
                Subscription = $sub
                HostPool     = $pi.name
                Type         = $pi.type
                AutoScale    = $(if ($pi.autoScale) { 'On' } else { 'Off' })
                MaxHosts     = $maxHosts
                VMsMatched   = $vms.Count
                HostHours    = [Math]::Round($hours, 1)
                RatePerHour  = $(if ($null -ne $rate) { [Math]::Round($rate, 4) } else { $null })
                Note         = $note
                BaselineCost = $(if ($null -ne $baseline) { [Math]::Round($baseline, 2) } else { $null })
                ActualCost   = [Math]::Round($actual, 2)
                Savings      = $(if ($null -ne $savings) { [Math]::Round($savings, 2) } else { $null })
                SavingsPct   = $pct
            })
        }
    }
}

# ---------------------------------------------------------------- report

if ($skipped.Count) { Write-Host "`nSkipped: $($skipped -join '; ')" }
if (-not $results.Count) { Write-Host "`nNo host pools to report."; return }

$results | Format-Table Month, HostPool, AutoScale, MaxHosts, VMsMatched, HostHours, RatePerHour, BaselineCost, ActualCost, Savings, SavingsPct, Note -AutoSize | Out-String | Write-Host

$valid = @($results | Where-Object { $null -ne $_.Savings })
$tBase = [double](($valid | Measure-Object BaselineCost -Sum).Sum)
$tAct = [double](($valid | Measure-Object ActualCost -Sum).Sum)
$tSav = $tBase - $tAct
$cur = $(if ($currencySeen) { $currencySeen } else { '' })
$pctTotal = $(if ($tBase -gt 0) { [Math]::Round(100 * $tSav / $tBase, 1) } else { 0 })

Write-Host ("Total ({0} month(s), {1} to {2}):" -f $Months, $monthStarts[0].ToString('yyyy-MM'), $end.ToString('yyyy-MM'))
Write-Host ("  Cost if every host ran all month : {0:N2} {1}" -f $tBase, $cur)
Write-Host ("  Actual compute cost              : {0:N2} {1}" -f $tAct, $cur)
Write-Host ("  Estimated auto-scale savings     : {0:N2} {1} ({2}%)" -f $tSav, $cur, $pctTotal)
$monthsCounted = @($valid | Select-Object -ExpandProperty Month -Unique).Count
if ($monthsCounted -gt 1) { Write-Host ("  Average per month ({0} counted)    : {1:N2} {2}" -f $monthsCounted, ($tSav / $monthsCounted), $cur) }
if (@($results | Where-Object { $null -eq $_.Savings }).Count) {
    Write-Host '  Note: rows with no usage data are not counted in the total.'
}
Write-Host '  Estimate only - compute cost, amortized. The NME console figure can differ.'

if ($CsvPath) {
    $results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation
    Write-Host "Detail saved to $CsvPath"
}
if ($PassThru) { $results }
