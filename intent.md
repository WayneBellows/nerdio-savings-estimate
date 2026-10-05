# Intent: Nerdio auto-scale savings estimate

## Problem
A customer wants to pull their total Nerdio savings programmatically. The NME REST API has no
savings endpoint or field (checked against the live TAM 1 lab swagger, 5 October 2026). The
figure only exists in the console (Host pool > Auto-scale History > Savings).

## Outcome
A read-only PowerShell script the customer can run that estimates monthly compute savings from
NME auto-scale, per host pool and in total, from data they already have access to:
- NME REST API: host pool auto-scale config (VM size, max capacity, name prefix), current hosts.
- Azure Cost Management API: actual VM compute cost and hours per VM for the month.

Savings = (max hosts x hours in month x effective hourly rate) - actual compute cost.

## Systems affected
None written to. Read-only calls to NME REST API, Azure Resource Manager and Cost Management.

## Constraints
- PowerShell 5.1 and 7 compatible, ASCII only.
- No secrets printed.
- The NME console formula is not documented, so the figure is an estimate and must say so.

## Out of scope
Storage auto-scale, Log Analytics, rightsizing and other savings plays. Personal desktop
power-state savings are reported but not separately modelled.
