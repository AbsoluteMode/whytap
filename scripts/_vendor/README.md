# DMG layout dependencies

Unmodified Python modules from the MIT-licensed
[ds_store](https://github.com/dmgbuild/ds_store) and
[mac_alias](https://github.com/dmgbuild/mac_alias) projects. Their LICENSE files
are included in the corresponding directories. They support Apple's Python 3.9
and let the release build write Finder metadata without Finder, pip or network
access. Update deliberately; do not edit vendored modules.

The source wheels were downloaded from PyPI and SHA-256 verified before extraction:

| Package | Version | Wheel SHA-256 |
| --- | --- | --- |
| ds_store | 1.3.1 | `fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5` |
| mac_alias | 2.2.2 | `504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd` |

Only package `.py` files and licenses are copied; wheel metadata and tests are
omitted. The layout uses the same `bwsp`, `icvp`, `icvl`, `Iloc` records and
on-volume background alias as [dmgbuild](https://github.com/dmgbuild/dmgbuild).
