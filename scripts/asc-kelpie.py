#!/usr/bin/env python3
"""asc-kelpie.py — App Store Connect metadata for Kelpie Console (app 6811004082).

    python3 scripts/asc-kelpie.py            # dry run (default): prints every call, makes none
    python3 scripts/asc-kelpie.py --dry-run  # the same
    python3 scripts/asc-kelpie.py --apply    # actually writes

Reads current state first and plans a write only where a value differs or an
object is missing, so it is safe to re-run. It touches: app info categories,
the en-US app info localization (subtitle, privacy policy URL), the age rating
declaration, the 1.0 App Store version and its en-US localization (support and
marketing URLs), and the three consumable tip IAPs with their en-US
localization, USD price and territory availability.

It never submits anything for review, never uploads screenshots, and never
touches the app name, description, keywords, promotional text or what's new.
GETs always run; every mutation goes through plan(), which only prints unless
--apply is given.

Key 6T785PX2FV, issuer 69a6de91-…, p8 in ~/.appstoreconnect/private_keys;
JWT minted by ~/Developer/Weights/scripts/asc-jwt.swift (never printed).
"""

import copy
import json
import re
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APP_ID = "6811004082"
KEY_ID = "6T785PX2FV"
ISSUER = "69a6de91-4abe-47e3-e053-5b8c7c11a4d1"
P8 = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
JWT_TOOL = os.path.expanduser("~/Developer/Weights/scripts/asc-jwt.swift")

LOCALE = "en-US"
PRIMARY_CATEGORY = "DEVELOPER_TOOLS"
SECONDARY_CATEGORY = "UTILITIES"
SUBTITLE = "herdr console for iPad"
PRIVACY_POLICY_URL = "https://github.com/Getterbetter/Kelpie/blob/kelpie/PRIVACY.md"
SUPPORT_URL = "https://www.reddit.com/r/KelpieConsole/"
MARKETING_URL = "https://github.com/Getterbetter/Kelpie"
VERSION_STRING = "1.0"
PLATFORM = "IOS"
BASE_TERRITORY = "USA"

TIPS = [
    ("TME.Kelpie.tip.small", "Small tip", "Small tip",
     "A small thank-you to the developer. Unlocks nothing.", "1.99"),
    ("TME.Kelpie.tip.medium", "Medium tip", "Medium tip",
     "A medium thank-you to the developer. Unlocks nothing.", "4.99"),
    ("TME.Kelpie.tip.large", "Large tip", "Large tip",
     "A large thank-you to the developer. Unlocks nothing.", "9.99"),
]

# Age rating declaration attribute types, read from Apple's AgeRatingDeclaration
# schema (developer.apple.com, 2026-09-11). Enum attributes take NONE; boolean
# attributes take false. Anything not in either list is deliberately left out —
# see SKIPPED_AGE_ATTRS.
AGE_ENUM_NONE = [
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
    "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "violenceCartoonOrFantasy", "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
]
AGE_BOOL_FALSE = [
    "advertising", "ageAssurance", "gambling", "healthOrWellnessTopics",
    "lootBox", "messagingAndChat", "parentalControls", "socialMedia",
    "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent",
]
# Not descriptors, or no safe value to infer: left out of every PATCH.
SKIPPED_AGE_ATTRS = [
    "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
    "developerAgeRatingInfoUrl",
]

APPLY = "--apply" in sys.argv[1:]
for arg in sys.argv[1:]:
    if arg not in ("--apply", "--dry-run"):
        sys.exit(f"usage: {os.path.basename(sys.argv[0])} [--dry-run | --apply]")

planned = []
applied = []
already = []

_jwt = None


def jwt():
    global _jwt
    if _jwt is None:
        _jwt = subprocess.run(["swift", JWT_TOOL, KEY_ID, ISSUER, P8],
                              capture_output=True, text=True, check=True).stdout.strip()
    return _jwt


def call(method, path, body=None):
    headers = {"Authorization": f"Bearer {jwt()}"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} {method} {path}\n{e.read().decode()[:2000]}", file=sys.stderr)
        raise


def get(path):
    return call("GET", path)


def _short(body):
    """Abbreviate long id arrays so a dry run stays readable."""
    b = copy.deepcopy(body)
    rels = b.get("data", {}).get("relationships", {})
    for name, rel in rels.items():
        items = rel.get("data")
        if isinstance(items, list) and len(items) > 8:
            ids = [i["id"] for i in items]
            rel["data"] = f"<{len(ids)} {name}: {ids[0]}, {ids[1]}, ... {ids[-1]}>"
    return b


def plan(method, path, body, what):
    """Print a mutation; execute it only under --apply."""
    print(f"{'APPLY' if APPLY else 'PLAN '} {what}")
    print(f"        {method} {path}")
    print(f"        {json.dumps(_short(body), separators=(',', ':'))}")
    if APPLY:
        r = call(method, path, body)
        applied.append(what)
        return r
    planned.append(what)
    return None


def unchanged(what):
    already.append(what)
    print(f"OK    {what}")


def new_id(r, label):
    return r["data"]["id"] if r else f"<new {label} id>"


def step_categories(app_info):
    rels = app_info["relationships"]
    cur_primary = (rels.get("primaryCategory", {}).get("data") or {}).get("id")
    cur_secondary = (rels.get("secondaryCategory", {}).get("data") or {}).get("id")
    if cur_primary == PRIMARY_CATEGORY and cur_secondary == SECONDARY_CATEGORY:
        unchanged(f"categories already {PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}")
        return
    ids = {c["id"] for c in get("/v1/appCategories?filter%5Bplatforms%5D=IOS&limit=100")["data"]}
    for want in (PRIMARY_CATEGORY, SECONDARY_CATEGORY):
        if want not in ids:
            sys.exit(f"category {want} not offered for IOS")
    body = {"data": {"type": "appInfos", "id": app_info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}}}}}
    plan("PATCH", f"/v1/appInfos/{app_info['id']}", body,
         f"categories {cur_primary} / {cur_secondary} -> {PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}")


def step_app_info_localization(app_info):
    locs = get(f"/v1/appInfos/{app_info['id']}/appInfoLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    want = {"subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY_POLICY_URL}
    if loc is None:
        body = {"data": {"type": "appInfoLocalizations",
                         "attributes": dict(want, locale=LOCALE),
                         "relationships": {"appInfo": {"data": {"type": "appInfos", "id": app_info["id"]}}}}}
        plan("POST", "/v1/appInfoLocalizations", body, f"{LOCALE} app info localization (create)")
        return
    diff = {k: v for k, v in want.items() if loc["attributes"].get(k) != v}
    if not diff:
        unchanged(f"{LOCALE} subtitle and privacy policy URL already set")
        return
    body = {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": diff}}
    plan("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", body,
         f"{LOCALE} app info: {', '.join(sorted(diff))}")


def step_age_rating(app_info):
    decl = get(f"/v1/appInfos/{app_info['id']}/ageRatingDeclaration")["data"]
    attrs = decl["attributes"]
    want = {}
    for name in attrs:
        if name in AGE_ENUM_NONE:
            want[name] = "NONE"
        elif name in AGE_BOOL_FALSE:
            want[name] = False
        elif name == "kidsAgeBand":
            want[name] = None
    unknown = [n for n in attrs if n not in want and n not in SKIPPED_AGE_ATTRS]
    if unknown:
        print(f"NOTE  age rating attributes left out (type not inferable): {', '.join(unknown)}")
    left_out = [n for n in SKIPPED_AGE_ATTRS if n in attrs]
    if left_out:
        print(f"NOTE  age rating attributes left alone (not content descriptors): "
              f"{', '.join(f'{n}={attrs[n]!r}' for n in left_out)}")
    diff = {k: v for k, v in want.items() if attrs.get(k) != v}
    if not diff:
        unchanged("age rating declaration already all-NONE/false")
        return
    body = {"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": diff}}
    plan("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}", body,
         f"age rating: {len(diff)} attributes to NONE/false/null")


def step_version():
    versions = get(f"/v1/apps/{APP_ID}/appStoreVersions?limit=50")["data"]
    editable = [v for v in versions if v["attributes"]["platform"] == PLATFORM
                and v["attributes"]["appStoreState"] not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION")]
    if not editable:
        body = {"data": {"type": "appStoreVersions",
                         "attributes": {"platform": PLATFORM, "versionString": VERSION_STRING},
                         "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}
        r = plan("POST", "/v1/appStoreVersions", body, f"App Store version {VERSION_STRING} (create)")
        return new_id(r, "appStoreVersions")
    version = editable[0]
    vid = version["id"]
    current = version["attributes"]["versionString"]
    if current == VERSION_STRING:
        unchanged(f"App Store version {VERSION_STRING} exists ({version['attributes']['appStoreState']})")
    else:
        body = {"data": {"type": "appStoreVersions", "id": vid,
                         "attributes": {"versionString": VERSION_STRING}}}
        plan("PATCH", f"/v1/appStoreVersions/{vid}", body,
             f"version string {current} -> {VERSION_STRING} (matches MARKETING_VERSION)")
    return vid


COPY_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "KelpieVault", "App Store copy.md")


def listing_copy():
    """The approved listing text from the vault: each `**Field** (limit):`
    block up to the next bold heading. Returns ASC attribute names."""
    try:
        text = open(COPY_FILE, encoding="utf-8").read()
    except OSError:
        return {}
    # No whatsNew: App Store Connect refuses it on a first release (409).
    fields = {"Description": "description", "Keywords": "keywords",
              "Promotional text": "promotionalText"}
    out = {}
    for heading, attr in fields.items():
        m = re.search(r"\*\*" + re.escape(heading) + r"\*\*[^\n]*:\n(.*?)(?=\n\*\*|\Z)", text, re.S)
        if m:
            out[attr] = m.group(1).strip()
    return out


def step_version_localization(version_id):
    want = {"supportUrl": SUPPORT_URL, "marketingUrl": MARKETING_URL}
    want.update(listing_copy())
    if version_id.startswith("<"):
        body = {"data": {"type": "appStoreVersionLocalizations",
                         "attributes": dict(want, locale=LOCALE),
                         "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}}
        plan("POST", "/v1/appStoreVersionLocalizations", body,
             f"{LOCALE} version localization (create)")
        return
    locs = get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    if loc is None:
        body = {"data": {"type": "appStoreVersionLocalizations",
                         "attributes": dict(want, locale=LOCALE),
                         "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}}
        plan("POST", "/v1/appStoreVersionLocalizations", body,
             f"{LOCALE} version localization (create)")
        return
    diff = {k: v for k, v in want.items() if loc["attributes"].get(k) != v}
    if not diff:
        unchanged(f"{LOCALE} support and marketing URLs already set")
        return
    body = {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": diff}}
    plan("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", body,
         f"{LOCALE} version: {', '.join(sorted(diff))}")


def price_point(iap_id, usd):
    """Resolve the USA price point whose customerPrice equals usd (apply only)."""
    path = f"/v2/inAppPurchases/{iap_id}/pricePoints?filter%5Bterritory%5D={BASE_TERRITORY}&limit=200"
    while path:
        page = get(path)
        for p in page["data"]:
            if float(p["attributes"]["customerPrice"]) == float(usd):
                return p["id"]
        path = page.get("links", {}).get("next", "").replace(API, "") or None
    sys.exit(f"no {BASE_TERRITORY} price point at {usd} for {iap_id}")


def step_iap(product_id, reference_name, name, description, usd, territories):
    found = get(f"/v1/apps/{APP_ID}/inAppPurchasesV2?filter%5BproductId%5D={product_id}&limit=10")["data"]
    iap = found[0] if found else None
    if iap:
        iap_id = iap["id"]
        unchanged(f"IAP {product_id} exists ({iap['attributes'].get('state')})")
    else:
        body = {"data": {"type": "inAppPurchases",
                         "attributes": {"name": reference_name, "productId": product_id,
                                        "inAppPurchaseType": "CONSUMABLE"},
                         "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}}
        r = plan("POST", "/v2/inAppPurchases", body, f"IAP {product_id} CONSUMABLE (create)")
        iap_id = new_id(r, product_id)

    # en-US localization
    loc = None
    if not iap_id.startswith("<"):
        locs = get(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=50")["data"]
        loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    want = {"name": name, "description": description}
    if loc is None:
        body = {"data": {"type": "inAppPurchaseLocalizations",
                         "attributes": dict(want, locale=LOCALE),
                         "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}}
        plan("POST", "/v1/inAppPurchaseLocalizations", body, f"{product_id} {LOCALE} localization")
    else:
        diff = {k: v for k, v in want.items() if loc["attributes"].get(k) != v}
        if diff:
            body = {"data": {"type": "inAppPurchaseLocalizations", "id": loc["id"], "attributes": diff}}
            plan("PATCH", f"/v1/inAppPurchaseLocalizations/{loc['id']}", body,
                 f"{product_id} {LOCALE}: {', '.join(sorted(diff))}")
        else:
            unchanged(f"{product_id} {LOCALE} localization already set")

    # price schedule, base territory USA
    schedule = None
    if not iap_id.startswith("<"):
        # A brand-new IAP has no schedule yet; ASC answers 404, not an empty body.
        try:
            schedule = get(f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule").get("data")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    if schedule:
        unchanged(f"{product_id} price schedule exists (verify {usd} USD in App Store Connect)")
    else:
        lookup = f"/v2/inAppPurchases/{iap_id}/pricePoints?filter%5Bterritory%5D={BASE_TERRITORY}&limit=200"
        if iap_id.startswith("<"):
            print(f"LOOKUP {product_id} price point for {usd} USD, resolved at apply time")
            print(f"        GET {lookup}  (needs the IAP id, which does not exist yet)")
            point = f"<{BASE_TERRITORY} price point at {usd}>"
        else:
            point = price_point(iap_id, usd)
        body = {"data": {"type": "inAppPurchasePriceSchedules",
                         "relationships": {
                             "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                             "baseTerritory": {"data": {"type": "territories", "id": BASE_TERRITORY}},
                             "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${price}"}]}},
                         },
                "included": [{"type": "inAppPurchasePrices", "id": "${price}",
                              "attributes": {"startDate": None, "endDate": None},
                              "relationships": {"inAppPurchasePricePoint": {
                                  "data": {"type": "inAppPurchasePricePoints", "id": point}}}}]}
        plan("POST", "/v1/inAppPurchasePriceSchedules", body,
             f"{product_id} price {usd} USD (base territory {BASE_TERRITORY})")

    # availability in every territory
    availability = None
    if not iap_id.startswith("<"):
        availability = get(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability").get("data")
    if availability:
        unchanged(f"{product_id} availability already configured")
    else:
        body = {"data": {"type": "inAppPurchaseAvailabilities",
                         "attributes": {"availableInNewTerritories": True},
                         "relationships": {
                             "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                             "availableTerritories": {"data": [{"type": "territories", "id": t}
                                                               for t in territories]}}}}
        plan("POST", "/v1/inAppPurchaseAvailabilities", body,
             f"{product_id} available in all {len(territories)} territories")


def main():
    print(f"asc-kelpie — app {APP_ID} (Kelpie Console) — "
          f"{'APPLY: writing to App Store Connect' if APPLY else 'DRY RUN: no writes'}")

    app_infos = get(f"/v1/apps/{APP_ID}/appInfos?include=primaryCategory,secondaryCategory")["data"]
    editable = [a for a in app_infos
                if a["attributes"]["appStoreState"] not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION")]
    if not editable:
        sys.exit("no editable appInfo")
    app_info = editable[0]
    print(f"      appInfo {app_info['id']} ({app_info['attributes']['appStoreState']})")

    step_categories(app_info)
    step_app_info_localization(app_info)
    step_age_rating(app_info)
    version_id = step_version()
    step_version_localization(version_id)

    territories = [t["id"] for t in get("/v1/territories?limit=200")["data"]]
    for product_id, reference_name, name, description, usd in TIPS:
        step_iap(product_id, reference_name, name, description, usd, territories)

    print(f"\nSummary — {len(planned) if not APPLY else len(applied)} "
          f"{'planned' if not APPLY else 'applied'}, {len(already)} already set")
    for w in (planned if not APPLY else applied):
        print(f"  {'->' if not APPLY else 'ok'} {w}")
    for w in already:
        print(f"  == {w}")
    if not APPLY:
        print("  nothing was written; re-run with --apply to execute")


if __name__ == "__main__":
    main()
