#!/usr/bin/env python3
"""Builds Sources/Sidekey/Onboarding/OnboardingGlobeCountries.swift, the
country outlines and languages of the onboarding's language globe.

Input is either
  * world-atlas's TopoJSON (Resources/OnboardingGlobe/countries-110m.json,
    Natural Earth 1:110m admin-0, public domain; ids are ISO 3166-1 numeric),
  * a GeoJSON FeatureCollection of countries (Natural Earth admin-0, public
    domain: properties ISO_A2 / ISO_A2_EH / NAME, Polygon or MultiPolygon
    geometry in [lon, lat]), or
  * the design prototype's country list (a JSON array of objects with code,
    name, center [lat, lon] and rings [[lat, lon], ...]).

The outlines are rounded to 0.1 degree and simplified so that no edge is
shorter than --min-step degrees; tiny islands below --min-area are left out.
The languages of a country come from LANGUAGES below (most spoken first,
ISO 639-1); the app keeps only those its speech route can transcribe.

WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

Usage: scripts/onboarding_globe_data.py <input.json> [--min-step 0.6] [--min-area 0.8]
"""
import argparse
import json
import math
import sys
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent.parent / "Sources/Sidekey/Onboarding/OnboardingGlobeCountries.swift"

# ISO 3166-1 alpha-2 -> spoken languages, most spoken first (ISO 639-1).
LANGUAGES = {
    "AD": "ca", "AE": "ar en", "AF": "fa ps", "AL": "sq", "AM": "hy ru", "AO": "pt", "AR": "es", "AT": "de",
    "AU": "en", "AZ": "az ru", "BA": "bs hr sr", "BD": "bn", "BE": "nl fr de", "BF": "fr", "BG": "bg",
    "BH": "ar", "BI": "fr", "BJ": "fr yo", "BN": "ms", "BO": "es", "BR": "pt", "BS": "en", "BT": "dz en",
    "BW": "en", "BY": "be ru", "BZ": "en es", "CA": "en fr", "CD": "fr ln sw", "CF": "fr", "CG": "fr ln",
    "CH": "de fr it", "CI": "fr", "CL": "es", "CM": "fr en", "CN": "zh yue", "CO": "es", "CR": "es",
    "CU": "es", "CY": "el tr", "CZ": "cs", "DE": "de", "DJ": "fr ar so", "DK": "da", "DO": "es",
    "DZ": "ar fr", "EC": "es", "EE": "et ru", "EG": "ar", "EH": "ar es", "ER": "ti ar", "ES": "es ca gl",
    "ET": "am om", "FI": "fi sv", "FJ": "en", "FK": "en", "FR": "fr", "GA": "fr", "GB": "en cy",
    "GE": "ka ru", "GH": "en", "GL": "kl da", "GM": "en wo", "GN": "fr", "GQ": "es fr", "GR": "el",
    "GT": "es", "GW": "pt", "GY": "en", "HK": "yue zh en", "HN": "es", "HR": "hr", "HT": "fr", "HU": "hu",
    "ID": "id jv", "IE": "en ga", "IL": "he ar", "IN": "hi en bn te mr ta ur gu kn ml pa", "IQ": "ar ku",
    "IR": "fa", "IS": "is", "IT": "it", "JM": "en", "JO": "ar", "JP": "ja", "KE": "sw en", "KG": "ky ru",
    "KH": "km", "KP": "ko", "KR": "ko", "KW": "ar", "KZ": "kk ru", "LA": "lo", "LB": "ar fr", "LK": "si ta",
    "LR": "en", "LS": "st en", "LT": "lt", "LU": "lb fr de", "LV": "lv ru", "LY": "ar", "MA": "ar fr",
    "MD": "ro ru", "ME": "sr", "MG": "mg fr", "MK": "mk sq", "ML": "fr", "MM": "my", "MN": "mn",
    "MR": "ar fr", "MT": "mt en", "MW": "ny en", "MX": "es", "MY": "ms en zh", "MZ": "pt", "NA": "en af",
    "NC": "fr", "NE": "fr ha", "NG": "en ha yo ig", "NI": "es", "NL": "nl", "NO": "no", "NP": "ne",
    "NZ": "en mi", "OM": "ar", "PA": "es", "PE": "es", "PG": "en", "PH": "tl en ceb", "PK": "ur en pa",
    "PL": "pl", "PR": "es en", "PS": "ar", "PT": "pt", "PY": "es", "QA": "ar", "RO": "ro", "RS": "sr",
    "RU": "ru", "RW": "rw fr en", "SA": "ar", "SB": "en", "SD": "ar en", "SE": "sv", "SG": "en zh ms ta",
    "SI": "sl", "SK": "sk", "SL": "en", "SN": "fr wo", "SO": "so ar", "SR": "nl", "SS": "en", "SV": "es",
    "SY": "ar", "SZ": "en", "TD": "fr ar", "TF": "fr", "TG": "fr", "TH": "th", "TJ": "tg ru", "TL": "pt",
    "TM": "tk ru", "TN": "ar fr", "TR": "tr ku", "TT": "en", "TW": "zh", "TZ": "sw en", "UA": "uk ru",
    "UG": "en sw lg", "US": "en es", "UY": "es", "UZ": "uz ru", "VE": "es", "VN": "vi", "VU": "fr en",
    "XK": "sq sr", "YE": "ar", "ZA": "en af zu xh", "ZM": "en", "ZW": "en sn",
}

# ISO 3166-1 numeric -> alpha-2, for world-atlas's ids; unnamed parts by name.
NUMERIC = {
    "004": "AF", "008": "AL", "010": "AQ", "012": "DZ", "024": "AO", "031": "AZ", "032": "AR", "036": "AU",
    "040": "AT", "044": "BS", "050": "BD", "051": "AM", "056": "BE", "064": "BT", "068": "BO", "070": "BA",
    "072": "BW", "076": "BR", "084": "BZ", "090": "SB", "096": "BN", "100": "BG", "104": "MM", "108": "BI",
    "112": "BY", "116": "KH", "120": "CM", "124": "CA", "140": "CF", "144": "LK", "148": "TD", "152": "CL",
    "156": "CN", "158": "TW", "170": "CO", "178": "CG", "180": "CD", "188": "CR", "191": "HR", "192": "CU",
    "196": "CY", "203": "CZ", "204": "BJ", "208": "DK", "214": "DO", "218": "EC", "222": "SV", "226": "GQ",
    "231": "ET", "232": "ER", "233": "EE", "238": "FK", "242": "FJ", "246": "FI", "250": "FR", "260": "TF",
    "262": "DJ", "266": "GA", "268": "GE", "270": "GM", "275": "PS", "276": "DE", "288": "GH", "300": "GR",
    "304": "GL", "320": "GT", "324": "GN", "328": "GY", "332": "HT", "340": "HN", "348": "HU", "352": "IS",
    "356": "IN", "360": "ID", "364": "IR", "368": "IQ", "372": "IE", "376": "IL", "380": "IT", "384": "CI",
    "388": "JM", "392": "JP", "398": "KZ", "400": "JO", "404": "KE", "408": "KP", "410": "KR", "414": "KW",
    "417": "KG", "418": "LA", "422": "LB", "426": "LS", "428": "LV", "430": "LR", "434": "LY", "440": "LT",
    "442": "LU", "450": "MG", "454": "MW", "458": "MY", "466": "ML", "478": "MR", "484": "MX", "496": "MN",
    "498": "MD", "499": "ME", "504": "MA", "508": "MZ", "512": "OM", "516": "NA", "524": "NP", "528": "NL",
    "540": "NC", "548": "VU", "554": "NZ", "558": "NI", "562": "NE", "566": "NG", "578": "NO", "586": "PK",
    "591": "PA", "598": "PG", "600": "PY", "604": "PE", "608": "PH", "616": "PL", "620": "PT", "624": "GW",
    "626": "TL", "630": "PR", "634": "QA", "642": "RO", "643": "RU", "646": "RW", "682": "SA", "686": "SN",
    "688": "RS", "694": "SL", "703": "SK", "704": "VN", "705": "SI", "706": "SO", "710": "ZA", "716": "ZW",
    "724": "ES", "728": "SS", "729": "SD", "732": "EH", "740": "SR", "748": "SZ", "752": "SE", "756": "CH",
    "760": "SY", "762": "TJ", "764": "TH", "768": "TG", "780": "TT", "784": "AE", "788": "TN", "792": "TR",
    "795": "TM", "800": "UG", "804": "UA", "807": "MK", "818": "EG", "826": "GB", "834": "TZ", "840": "US",
    "854": "BF", "858": "UY", "860": "UZ", "862": "VE", "887": "YE", "894": "ZM",
}
UNNAMED = {"N. Cyprus": "CY", "Somaliland": "SO", "Kosovo": "XK"}

# The design prototype joined some neighbours into one region.
PROTOTYPE_REGIONS = {
    "LT_LV_EE": ("Baltic states", "lt lv et ru"),
    "HR_BA": ("Croatia and Bosnia", "hr bs sr"),
    "GE_AZ": ("Georgia and Azerbaijan", "ka az ru"),
    "GT_PA": ("Central America", "es"),
    "IQ_SY": ("Iraq and Syria", "ar"),
    "YE_OM": ("Yemen and Oman", "ar"),
    "TD_NE": ("Chad and Niger", "fr ar"),
    "WA_REGION": ("West Africa", "fr en"),
    "MZ_ZW": ("Mozambique and Zimbabwe", "pt en"),
    "NA_BW": ("Namibia and Botswana", "en af"),
    "CD_AO": ("Congo and Angola", "fr pt"),
}


def ring_area(ring):
    """Rough area in square degrees (shoelace on lat/lon)."""
    total = 0.0
    for (a_lat, a_lon), (b_lat, b_lon) in zip(ring, ring[1:] + ring[:1]):
        total += a_lon * b_lat - b_lon * a_lat
    return abs(total) / 2


def simplify(ring, min_step):
    out = []
    for lat, lon in ring:
        point = (round(lat, 1), round(lon, 1))
        if out and math.hypot(point[0] - out[-1][0], (point[1] - out[-1][1]) * math.cos(math.radians(lat))) < min_step:
            continue
        out.append(point)
    if len(out) > 2 and out[0] == out[-1]:
        out.pop()
    return out


def from_geojson(data):
    countries = []
    for feature in data["features"]:
        props = feature["properties"]
        code = props.get("ISO_A2_EH") or props.get("ISO_A2") or props.get("iso_a2")
        if not code or code == "-99" or code == "AQ":
            continue
        name = props.get("NAME") or props.get("name") or code
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        rings = [[(lat, lon) for lon, lat in polygon[0]] for polygon in polygons]
        lat = props.get("LABEL_Y")
        lon = props.get("LABEL_X")
        countries.append({"code": code, "name": name, "rings": rings,
                          "center": (lat, lon) if lat is not None else None})
    return countries


def from_topojson(data):
    """Decodes quantized, delta-encoded arcs; parts with one alpha-2 code
    (Cyprus and Northern Cyprus, Somalia and Somaliland) become one country."""
    scale = data["transform"]["scale"]
    translate = data["transform"]["translate"]
    arcs = []
    for arc in data["arcs"]:
        x = y = 0
        points = []
        for dx, dy in arc:
            x += dx
            y += dy
            points.append((y * scale[1] + translate[1], x * scale[0] + translate[0]))
        arcs.append(points)

    def ring(indices):
        out = []
        for index in indices:
            points = arcs[index] if index >= 0 else list(reversed(arcs[~index]))
            out.extend(points if not out else points[1:])
        return out

    merged = {}
    for geometry in data["objects"]["countries"]["geometries"]:
        name = geometry["properties"]["name"]
        code = NUMERIC.get(geometry.get("id") or "") or UNNAMED.get(name)
        if not code or code == "AQ":
            continue
        polygons = geometry["arcs"] if geometry["type"] == "MultiPolygon" else [geometry["arcs"]]
        rings = [ring(polygon[0]) for polygon in polygons]
        entry = merged.setdefault(code, {"code": code, "name": name, "rings": [], "center": None})
        if geometry.get("id"):
            entry["name"] = name
        entry["rings"] += rings
    return list(merged.values())


def from_prototype(data):
    return [{"code": c["code"], "name": PROTOTYPE_REGIONS.get(c["code"], (c["name"],))[0],
             "rings": [[tuple(p) for p in ring] for ring in c["rings"]], "center": tuple(c["center"])}
            for c in data]


def centroid(rings):
    """The mean direction of the biggest ring's corners (safe across 180°)."""
    biggest = max(rings, key=ring_area)
    x = y = z = 0.0
    for lat, lon in biggest:
        la, lo = math.radians(lat), math.radians(lon)
        x += math.cos(la) * math.cos(lo)
        y += math.cos(la) * math.sin(lo)
        z += math.sin(la)
    return math.degrees(math.atan2(z, math.hypot(x, y))), math.degrees(math.atan2(y, x))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--min-step", type=float, default=0.6)
    parser.add_argument("--min-area", type=float, default=0.8)
    args = parser.parse_args()
    data = json.loads(Path(args.input).read_text())
    if isinstance(data, list):
        countries = from_prototype(data)
    elif data.get("type") == "Topology":
        countries = from_topojson(data)
    else:
        countries = from_geojson(data)
    lines = []
    for country in sorted(countries, key=lambda c: c["code"]):
        rings = [simplify(r, args.min_step) for r in country["rings"]]
        rings = [r for r in rings if len(r) >= 3 and ring_area(r) >= args.min_area] or \
            [max((simplify(r, args.min_step) for r in country["rings"]), key=len)]
        rings = [r for r in rings if len(r) >= 3]
        if not rings:
            continue
        languages = LANGUAGES.get(country["code"]) or PROTOTYPE_REGIONS.get(country["code"], ("", ""))[1]
        if not languages:
            print(f"no languages for {country['code']} {country['name']}", file=sys.stderr)
        lat, lon = country["center"] or centroid(rings)
        encoded = ";".join(" ".join(f"{p[0]:g},{p[1]:g}" for p in r) for r in rings)
        name = country["name"].replace("|", " ")
        lines.append(f"{country['code']}|{name}|{languages}|{lat:.1f},{lon:.1f}|{encoded}")
    points = sum(line.count(",") for line in lines)
    body = "\n".join(lines)
    OUTPUT.write_text(f"""// Generated by scripts/onboarding_globe_data.py from {Path(args.input).name}; do not edit.
// {len(lines)} countries, about {points} points. One line per country:
// code|English name|languages (ISO 639-1, most spoken first)|label lat,lon|rings (lat,lon pairs; rings by ";")
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

enum OnboardingGlobeCountries {{
    static let encoded = #\"\"\"
{body}
\"\"\"#
}}
""")
    print(f"wrote {OUTPUT.relative_to(Path.cwd()) if OUTPUT.is_relative_to(Path.cwd()) else OUTPUT}: {len(lines)} countries, {points} points")


if __name__ == "__main__":
    main()
