# Stocks Detective

**An AI-powered portfolio analyst for iPhone, built on Apple Intelligence.**

Most apps tell you *"AAPL is down 3%."* Stocks Detective tells you **why**:

1. **What happened** – the move in plain English, with the numbers that matter.
2. **Which news caused it** – the headlines that best explain the move, with sources.
3. **Is it justified?** – a verdict: *Justified*, *Overreaction*, *Underreaction*, *Unexplained* or *Just noise*.
4. **What to watch next** – specific, checkable things for the coming days.

Think of it as a personal financial analyst that keeps investigating your portfolio, even when the app is closed.

## How the detective works

Every holding becomes a **case file**:

| Step | What it does | Where |
|---|---|---|
| Gather evidence | 6 months of daily prices, the stock's sector ETF, the S&P 500, company and market headlines | `CaseBuilder`, `YahooMarketData` |
| Separate market from company | Beta vs the sector ETF → expected move → stock-specific "excess" move | `MovementAnalyzer` |
| Measure surprise | Move size vs the stock's normal day (z-score) and volume vs its 20-day average | `MovementAnalyzer` |
| Triage the news | Rank headlines by relevance, sentiment and catalyst type (earnings, guidance, analyst, legal, macro…) | `NewsScorer` |
| Write the report | Apple's on-device **Foundation Models** fill a typed `@Generable` report, grounded only in the evidence | `DetectiveAI` |
| Fallback | A rule-based analyst writes the report when Apple Intelligence isn't available | `RuleBasedDetective` |
| Follow-ups | "Interrogate the detective": a chat where the model can call tools to fetch prices and headlines for other tickers | `Interrogation` |
| Keep watching | Background refresh + notifications only for unusual, *stock-specific* moves | `BackgroundInvestigator` |

All AI runs **on-device**: your portfolio never leaves your iPhone.

## Screens

- **Portfolio** – total value and today's P&L; each holding shows the *reason* for its move and a verdict, sorted by how surprising the move is.
- **Case file** – verdict with confidence, what happened, "Market or company?" breakdown, suspects (causes), what to watch next, and the evidence locker (headlines).
- **Daily Briefing** – one story for the whole portfolio and who moved it.
- **Import** – paste a holdings table from your broker, a spreadsheet or notes (`+` › Import from paste); tickers and share counts are read automatically.
- **Settings** – Apple Intelligence status, background alerts and sensitivity, demo data.

## Requirements

- iOS 26+, iPhone. AI investigations need an Apple Intelligence–capable iPhone (iPhone 15 Pro or newer) with Apple Intelligence turned on. Other devices get the rule-based analyst.
- Xcode 26 to build.

## Build

### On GitHub (no Mac needed)

Every push runs [`.github/workflows/ios.yml`](.github/workflows/ios.yml):

- **DetectiveKit tests** on Linux.
- **iOS build** on a `macos-26` runner with Xcode 26: Simulator build and an unsigned device build.

Download the **StocksDetective** artifact from the workflow run:
- `StocksDetective-simulator.zip` – drag the `.app` onto a running Simulator.
- `StocksDetective-unsigned.ipa` – sign it with your own certificate (e.g. Sideloadly, AltStore, or `codesign`) to install on a device.

### TestFlight

[`.github/workflows/testflight.yml`](.github/workflows/testflight.yml) archives, signs and uploads to TestFlight. Run it from **Actions › TestFlight › Run workflow**, or push a tag like `v1.0.0`. The build number is the workflow run number.

One-time setup:

1. In [App Store Connect](https://appstoreconnect.apple.com) create the app with bundle ID `com.stocksdetective.app` (or change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).
2. **Users and Access › Integrations › App Store Connect API**: create a Team key with the **Admin** role (needed for automatic signing). Download the `.p8`.
3. In this repo, **Settings › Secrets and variables › Actions**, add:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | 10-character Team ID (developer.apple.com › Membership) |
| `ASC_KEY_ID` | The API key's Key ID |
| `ASC_ISSUER_ID` | Issuer ID shown above the keys list |
| `ASC_KEY_P8` | Full contents of the `.p8` file (or its base64) |

Signing certificates and provisioning profiles are created automatically by Xcode using the API key.

### Locally

```sh
brew install xcodegen
xcodegen generate
open StocksDetective.xcodeproj
```

Pick your team under *Signing & Capabilities* and run on your iPhone.

Core logic tests (work on macOS or Linux):

```sh
cd Packages/DetectiveKit && swift test
```

## Project layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated)
StocksDetective/
  App/                          App entry, SwiftData model, app state
  AI/                           Apple Intelligence: report generation, interrogation + tools
  Views/                        SwiftUI screens
  Background/                   Background refresh + notifications
Packages/DetectiveKit/          Platform-independent engine (data, statistics, news triage, fallback analyst)
```

## Data sources

Live data uses free, keyless endpoints (Yahoo Finance chart API, Yahoo Finance and Google News RSS). They are unofficial and may be delayed or change; `MarketDataProvider` makes it easy to plug in a paid provider. Turn on **Demo data** in Settings to try the app offline.

## Disclaimer

Stocks Detective explains market moves for educational purposes. It is not investment advice.
