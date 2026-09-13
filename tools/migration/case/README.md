# case/ (git-ignored)

Put `case.json` here. It holds the search terms, counterparty domains and date window that
`Export-LDCapitalM365Evidence.ps1` and `New-LDCapitalCaseReport.ps1` read. Nothing in this folder except this
README is committed, so names, addresses and domains never enter the repository.

```json
{
  "searchTerms": ["LD Capital", "LDX", "M Helen", "Kiwi's Mulligan", "BitGo", "FalconX"],
  "counterpartyDomains": [],
  "ourDomains": [],
  "since": "2026-01-01",
  "until": null,
  "workstreams": {
    "Custody onboarding": "bitgo|custody|kyc|persona|enterprise id|beneficial owner",
    "Prime broker facility": "falconx|paxg|credit line|ltv",
    "M Helen Hotel SPV": "helen|waterpark|edelweiss|spv|appraisal|proforma",
    "Kiwi's Mulligan": "kiwi|mulligan",
    "LDX platform and brand": "ldx|logo|brand|platform|deck|business plan",
    "Legal and offering": "ppm|reg d|506|subscription|operating agreement|compliance",
    "Software": "rust|crate|cargo|solidity|contract|hook|wasm"
  }
}
```

Add the counterparty's people and addresses to `searchTerms` here, not in the scripts.
