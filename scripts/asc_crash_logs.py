"""Download TestFlight crash reports from App Store Connect.

Writes each crash log to out/crashes/<build>-<n>.crash. Tester emails and comments are
not saved (this repo is public). Needs ASC_KEY_ID, ASC_ISSUER_ID and KEY_PATH.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
import jwt

BUNDLE_ID = "com.stocksdetective.app"
API = "https://api.appstoreconnect.apple.com"


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        open(os.environ["KEY_PATH"]).read(), algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


def get(path, params=None):
    url = path if path.startswith("http") else API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} for {path}: {e.read().decode()[:400]}")
        return None


def main():
    os.makedirs("out/crashes", exist_ok=True)
    apps = get("/v1/apps", {"filter[bundleId]": BUNDLE_ID})
    if not apps or not apps["data"]:
        sys.exit(f"App {BUNDLE_ID} not found")
    app_id = apps["data"][0]["id"]

    builds = get("/v1/builds", {"filter[app]": app_id, "sort": "-uploadedDate", "limit": 5,
                                "fields[builds]": "version,processingState,uploadedDate"})
    for b in (builds or {}).get("data", []):
        a = b["attributes"]
        print(f"Build {a['version']}: {a['processingState']} (uploaded {a['uploadedDate']})")

    subs = get(f"/v1/apps/{app_id}/betaFeedbackCrashSubmissions",
               {"limit": 20, "include": "build", "sort": "-createdDate"})
    if subs is None:
        return
    builds_by_id = {i["id"]: i["attributes"].get("version") for i in subs.get("included", []) if i["type"] == "builds"}
    data = subs.get("data", [])
    print(f"\n{len(data)} TestFlight crash report(s) found")
    for n, s in enumerate(data, 1):
        a = s["attributes"]
        build = builds_by_id.get((s.get("relationships", {}).get("build", {}).get("data") or {}).get("id"), "?")
        print(f"- #{n}: build {build}, {a.get('createdDate')}, {a.get('deviceModel')}, iOS {a.get('osVersion')}")
        log = get(f"/v1/betaFeedbackCrashSubmissions/{s['id']}/crashLog")
        text = ((log or {}).get("data") or {}).get("attributes", {}).get("logText")
        if text:
            path = f"out/crashes/build{build}-{n}.crash"
            open(path, "w").write(text)
            print(f"  saved {path} ({len(text)} chars)")
        else:
            print("  no crash log attached")


if __name__ == "__main__":
    main()
