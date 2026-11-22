# Country outlines for the onboarding globe

`countries-110m.json` is `world-atlas@2.0.2/countries-110m.json`
(https://github.com/topojson/world-atlas, fetched from
https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/countries-110m.json on
2026-11-22), a TopoJSON conversion of Natural Earth's 1:110m Admin 0 -
Countries.

- Natural Earth data is in the public domain
  (https://www.naturalearthdata.com/about/terms-of-use/). Made with Natural
  Earth.
- world-atlas is distributed under the ISC License, Copyright 2013-2019
  Michael Bostock.

The file is not shipped in the app: `scripts/onboarding_globe_data.py`
turns it into `Sources/Sidekey/Onboarding/OnboardingGlobeCountries.swift`.
Natural Earth draws de facto borders; the globe only lights a country to
offer its language.
