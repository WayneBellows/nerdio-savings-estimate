# Nerdio auto-scale savings estimate

`Get-NerdioSavingsEstimate.ps1` estimates the monthly compute savings that Nerdio Manager (NME)
auto-scale delivers, per host pool and in total.

## Why this exists

The NME REST API has no savings endpoint or field (checked against the live API spec on
5 October 2026). The "Auto-scale savings" figure is only shown in the console:
**Host pool > Auto-scale > History > Savings**. This script rebuilds an estimate from data the
customer can already read.

## How it works

| Data | Source |
|---|---|
| Host pools in the subscription | Azure Resource Manager |
| VM size, max hosts (`hostPoolCapacity`), VM name prefix, current hosts | NME REST API (`/api/v1/arm/hostpool/{sub}/{rg}/{pool}/auto-scale` and `/host`) |
| Actual VM compute cost and running hours per VM, per month | Azure Cost Management Query API (amortized cost) |

For each pool and month:

```
baseline = max hosts x hours in month x effective hourly rate    (every host on, all month)
savings  = baseline - actual compute cost
```

- The effective hourly rate is actual cost / actual hours, so Azure Hybrid Benefit,
  reservations and negotiated discounts are already included.
- Hosts that auto-scale deleted are still counted: VMs are matched to a pool by current host
  name or by the pool's VM name prefix (for example `NEDCORP-KW{##}`).
- If a pool's VMs have no cost data at all in a month (pool not built yet, or no data), the row
  shows "no usage data" and is not counted. Claiming 100% savings for it would overstate the total.
- Personal host pools use the current host count as the baseline.

## Limits

- **Estimate only.** Nerdio does not publish the console's formula, so this figure can differ
  from Auto-scale History. Compare the two for one month before relying on it.
- Compute only. Storage auto-scale, OS disk tier swaps, Log Analytics and rightsizing savings are
  not included.
- Pools with auto-scale switched off are skipped unless `-IncludeDisabled` is used.
- Cost Management throttles per subscription. The script sends one cost query per subscription
  and honours the `retry-after` header. Run it at most once a day - the data only refreshes
  every four hours anyway.
- CSP customers: Cost Management must be enabled for the subscription by the partner.

## Requirements

- PowerShell 5.1 or 7.
- Azure CLI (`az login`) with **Reader** and **Cost Management Reader** on each subscription.
- An NME REST API app registration (NME > Settings > Integrations > REST API). Save the values
  in a JSON file and keep it private:

```json
{
  "tokenUrl": "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token",
  "clientId": "<app-id>",
  "clientSecret": "<secret value>",
  "scope": "<api scope from the NME REST API page>",
  "baseUrl": "https://<your-nme-app>.azurewebsites.net/"
}
```

## Use

```powershell
# Last full month
.\Get-NerdioSavingsEstimate.ps1 -CredentialFile .\nme-api.json -SubscriptionId <sub-id>

# Last three full months, with per-pool detail saved to CSV
.\Get-NerdioSavingsEstimate.ps1 -CredentialFile .\nme-api.json -SubscriptionId <sub-id> -Months 3 -CsvPath .\savings.csv

# Several subscriptions, objects returned for further processing
.\Get-NerdioSavingsEstimate.ps1 -CredentialFile .\nme-api.json -SubscriptionId <sub-1>,<sub-2> -PassThru
```

The script is read-only. It changes nothing in NME or Azure.
