# LDX Capital

Institutional commercial real estate credit across traditional and tokenized capital markets. Six loan programs. Two execution channels. One credit standard.

- **Live site:** https://fthtrading.github.io/ldx-capitol/
- **Custom domain (Cloudflare Pages):** https://ldx.unykorn.ai (to be attached)
- **Firm:** LD Realty Capital, LLC · Dunwoody, GA · [ldrcllc.com](https://ldrcllc.com)
- **Contact:** kevan@ldrcllc.com · (770) 272-2232

## What ships in this repo

| Path | Purpose |
|---|---|
| [`index.html`](./index.html) | Marketing site — programs, dual-rail explainer, tokenization stack, insights, downloads, contact |
| [`app/`](./app/) | Installable PWA — credit-engine deal evaluator, stress suite, pipeline, copilot |
| [`pdfs/`](./pdfs/) | Print-ready client docs (HTML → Print → Save as PDF): program charts, RWA briefing, Centrifuge/BitGo blueprint |
| [`icons/`](./icons/) | LDX brand marks (SVG + PNG) used across the site and PWA |

## The app

The `/app/` PWA is the LDX Capital lending platform. It works offline, installs to the home screen on iPhone and Android, and includes:

- **Deal evaluator** — enter deal inputs, get a verdict across all six programs with LTV / LTC / DSCR analysis and stress suite (income −10%, rate +200 bps, value −15%).
- **Pipeline** — save deals locally on device; nothing leaves the phone until you request a term sheet through the contact form.
- **Copilot** — rules-driven Q&A over the LDX credit box today; API wire-in point ready for a live LLM.
- **Account** — local-only workspace.

Install on iPhone: open `/app/` in Safari → Share → **Add to Home Screen**.
Install on Android: open `/app/` in Chrome → **Install App** prompt.

## Deploy

### GitHub Pages (default)

Push to `main`. Repo → **Settings → Pages → Source: Deploy from a branch → `main` / `/ (root)`**. Live in ~60 seconds at `https://fthtrading.github.io/ldx-capitol/`.

### Cloudflare Pages + `ldx.unykorn.ai`

```powershell
# CLI path
wrangler pages project create ldx-capital --production-branch main
wrangler pages deploy . --project-name ldx-capital
# then Cloudflare dashboard → Pages → ldx-capital → Custom domains → add ldx.unykorn.ai
```

Dashboard path: **Workers & Pages → Create → Pages → Connect to Git → pick `FTHTrading/ldx-capitol` → deploy → Custom domains → add `ldx.unykorn.ai`** (DNS auto-creates since `unykorn.ai` is already on Cloudflare).

## Roadmap

- Wire copilot to a real LLM endpoint (Cloudflare Worker + API key) — hook in place.
- Automated smart contracts hold until Centrifuge onboarding and securities counsel are moving.
- Draw-schedule template and full intake package attached to the contact flow.

## Regulatory

Digital securities described on this site are offered exclusively under Regulation D Rule 506(c) to verified accredited investors. Digital-asset custody by BitGo Bank & Trust, N.A. All loans subject to underwriting, documentation, and credit approval. Terms indicative and subject to change.
