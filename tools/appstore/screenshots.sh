#!/bin/bash
# Captures 6.9" App Store screenshots in every language using the demo portfolio.
# Usage: tools/appstore/screenshots.sh <simulator-udid> [path/to/StocksDetective.app]
set -euo pipefail
D="$1"; APP="${2:-build/sim/Build/Products/Debug-iphonesimulator/StocksDetective.app}"
BID=com.stocksdetective.app
OUT=fastlane/screenshots
xcrun simctl install "$D" "$APP"
xcrun simctl status_bar "$D" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
# app language : App Store locale folder(s)
PAIRS="en:en-US de:de-DE fr:fr-FR es:es-ES it:it pt-BR:pt-BR nl:nl-NL ru:ru uk:uk pl:pl tr:tr id:id vi:vi ja:ja ko:ko zh-Hans:zh-Hans th:th ar:ar-SA he:he hi:hi"
shot() { # lang locale name extra-args...
  local lang=$1 loc=$2 name=$3; shift 3
  xcrun simctl terminate "$D" $BID >/dev/null 2>&1 || true
  xcrun simctl launch "$D" $BID -AppleLanguages "($lang)" -AppleLocale "${lang/-/_}" \
    -seedDemoPortfolio YES -inMemoryStore YES "$@" >/dev/null
  sleep "${WAIT:-7}"
  mkdir -p "$OUT/$loc"
  xcrun simctl io "$D" screenshot --type=png "$OUT/$loc/$name.png" >/dev/null 2>&1
}
for p in $PAIRS; do
  lang=${p%%:*}; loc=${p##*:}
  shot "$lang" "$loc" "1_portfolio"
  WAIT=16 shot "$lang" "$loc" "2_case" -openCase NVDA
  shot "$lang" "$loc" "3_briefing" -openTab briefing
  echo "done $loc"
done
# Same images for the extra storefront locales.
for pair in es-MX:es-ES fr-CA:fr-FR en-GB:en-US en-AU:en-US en-CA:en-US; do
  rm -rf "$OUT/${pair%%:*}"; cp -R "$OUT/${pair##*:}" "$OUT/${pair%%:*}"
done
xcrun simctl status_bar "$D" clear
