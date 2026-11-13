#!/usr/bin/env python3
"""Builds the app's String Catalog and DetectiveKit's .strings files from tools/l10n/*.json.

keys.json   id -> {"src": "app"|"pkg", "en": English source text}
<lang>.json id -> translation (string, or {plural category: string} for plural keys)

Run from the repo root:  python3 tools/l10n/build.py
"""
import json, os, re, sys, glob
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.join(ROOT, "tools", "l10n")
CATALOG = os.path.join(ROOT, "StocksDetective", "Resources", "Localizable.xcstrings")
PKG_RES = os.path.join(ROOT, "Packages", "DetectiveKit", "Sources", "DetectiveKit", "Resources")

LANGS = ["ar", "de", "es", "fr", "he", "hi", "id", "it", "ja", "ko", "nl", "pl",
         "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans"]
# Plural categories each language must provide (CLDR).
PLURALS = {
    "ar": ["zero", "one", "two", "few", "many", "other"],
    "he": ["one", "two", "other"],
    "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"],
    "pl": ["one", "few", "many", "other"],
    "fr": ["one", "many", "other"], "es": ["one", "many", "other"], "it": ["one", "many", "other"],
    "pt-BR": ["one", "many", "other"],
    "de": ["one", "other"], "nl": ["one", "other"], "hi": ["one", "other"], "tr": ["one", "other"],
    "ja": ["other"], "ko": ["other"], "zh-Hans": ["other"], "th": ["other"], "vi": ["other"], "id": ["other"],
}
EN_PLURAL_ONE = {
    "%lld holdings found": "%lld holding found",
    "%lld holdings moved more than usual on their own and are worth a closer look.":
        "%lld holding moved more than usual on its own and is worth a closer look.",
    "%lld unusual moves under investigation": "%lld unusual move under investigation",
}

SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|f|%)")


def specs(s):
    """Format arguments in order of position: e.g. ['@', '@', 'lld']. '%%' is ignored."""
    out, seq = {}, 0
    for m in SPEC.finditer(s):
        pos, kind = m.group(1), m.group(2)
        if kind == "%":
            continue
        seq += 1
        out[int(pos) if pos else seq] = kind
    return [out[k] for k in sorted(out)]


def check(lang, key, en, value, errors):
    if not value or not value.strip():
        errors.append(f"{lang} {key}: empty")
        return
    if specs(en) != specs(value):
        errors.append(f"{lang} {key}: format args {specs(en)} != {specs(value)} in {value!r}")
    if en.count("%%") and "%%" not in value:
        errors.append(f"{lang} {key}: lost a %% in {value!r}")
    # Mixed positional and plain specifiers break String(format:).
    plain = [m for m in SPEC.finditer(value) if m.group(2) != "%" and not m.group(1)]
    posd = [m for m in SPEC.finditer(value) if m.group(1)]
    if plain and posd:
        errors.append(f"{lang} {key}: mixes positional and plain specifiers")


def main():
    keys = json.load(open(os.path.join(HERE, "keys.json")))
    plural_keys = {k for k, v in keys.items() if v["en"] in EN_PLURAL_ONE}
    errors, tr = [], {}
    for lang in LANGS:
        path = os.path.join(HERE, f"{lang}.json")
        if not os.path.exists(path):
            errors.append(f"{lang}: missing file")
            continue
        data = json.load(open(path))
        tr[lang] = data
        for k, meta in keys.items():
            v = data.get(k)
            if v is None:
                errors.append(f"{lang} {k}: missing")
                continue
            if k in plural_keys:
                if not isinstance(v, dict):
                    errors.append(f"{lang} {k}: plural key needs a dict")
                    continue
                for cat in PLURALS[lang]:
                    if cat not in v:
                        errors.append(f"{lang} {k}: missing plural '{cat}'")
                for cat, s in v.items():
                    # Arabic/Hebrew zero/one/two forms may spell the number out.
                    if cat in ("zero", "one", "two") and "%lld" not in s:
                        continue
                    check(lang, f"{k}.{cat}", meta["en"], s, errors)
            else:
                if isinstance(v, dict):
                    errors.append(f"{lang} {k}: unexpected plural dict")
                    continue
                check(lang, k, meta["en"], v, errors)
        extra = set(data) - set(keys)
        if extra:
            errors.append(f"{lang}: unknown keys {sorted(extra)}")
    if errors:
        print("\n".join(errors))
        sys.exit(1)

    # App String Catalog.
    strings = {}
    for k, meta in sorted(keys.items(), key=lambda kv: kv[1]["en"]):
        if meta["src"] != "app":
            continue
        en = meta["en"]
        locs = {}
        if k in plural_keys:
            locs["en"] = {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": EN_PLURAL_ONE[en]}},
                "other": {"stringUnit": {"state": "translated", "value": en}}}}}
        for lang in LANGS:
            v = tr[lang][k]
            if isinstance(v, dict):
                locs[lang] = {"variations": {"plural": {
                    cat: {"stringUnit": {"state": "translated", "value": v[cat]}} for cat in PLURALS[lang]}}}
            else:
                locs[lang] = {"stringUnit": {"state": "translated", "value": v}}
        strings[en] = {"extractionState": "manual", "localizations": locs}
    # Keys that need no translation (symbols, placeholders, brand name).
    for en in ["", " ", "%@ / %@", "%@%@ (%@)", "%lld", "▲", "▼", "i", "@ %@", "Stocks Detective",
               "SYM   QTY   PRICE\nVOO   238   675.99\nNVDA  210   186.64"]:
        strings[en] = {"shouldTranslate": False}
    catalog = {"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"}
    with open(CATALOG, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")

    # DetectiveKit .strings (English is the key; en.lproj makes English a known localization).
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    for lang in ["en"] + LANGS:
        d = os.path.join(PKG_RES, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        lines = []
        for k, meta in keys.items():
            if meta["src"] != "pkg":
                continue
            v = meta["en"] if lang == "en" else tr[lang][k]
            lines.append(f'"{esc(meta["en"])}" = "{esc(v)}";')
        with open(os.path.join(d, "Localizable.strings"), "w") as f:
            f.write("\n".join(lines) + "\n")
    print(f"OK: {len(LANGS)} languages, {sum(1 for m in keys.values() if m['src']=='app')} app + "
          f"{sum(1 for m in keys.values() if m['src']=='pkg')} engine strings")


if __name__ == "__main__":
    main()
