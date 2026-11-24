#!/usr/bin/env python3
"""Final Lil Bro "Hood" sprite atlas generator (38 frames, 14x16 px, 8 columns).

Faithful to the approved character in reference/hood-pixels-from-mockup.js:
violet hood, blond fringe with highlight, pink cheeks, dark trousers, white sneakers.
Redraws all 38 frames so every animation has distinct, legible pixel art facing RIGHT.

Outputs (into final/ by default):
  - lilbro-hood-light.png
  - lilbro-hood-dark.png (identical layout; only outline 'O' shifts to #9A93BE)
  - lilbro-hood.json     (same schema and frame/animation names as provisional)
  - preview-x8.png       (both atlases scaled 8x nearest-neighbour, labelled)
"""

import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 14, 16
COLS = 8

# Approved palette + 2 extra shades (c = hoodie shadow, L = amber ladder wood)
PAL = {
    "O": "#2B2440",  # outline (light theme)
    "H": "#F2C98A",  # blond hair
    "h": "#FFE7B8",  # hair highlight
    "S": "#FFD9C4",  # skin
    "b": "#FF9FA8",  # blush / pink cheeks
    "E": "#2B2440",  # eyes (stays dark in both themes)
    "W": "#FFFFFF",  # eye shine / sclera
    "m": "#C4576A",  # mouth
    "M": "#7A2E3E",  # open mouth / wow
    "C": "#8C5CFF",  # violet hood & hoodie
    "A": "#F4F2FA",  # white collar / drawstring accent
    "P": "#4A4468",  # dark trousers
    "B": "#F4F2FA",  # white sneakers
    # Extra shades (max 2 allowed):
    "c": "#6D42DC",  # darker violet hoodie shade (arm/torso separation, hood fold)
    "L": "#E8A33A",  # amber wood (2-3 px ladder hint in ladder_pull / ladder_set)
}
DARK_OUTLINE = "#9A93BE"

# ---------------------------------------------------------------------------
# Reusable Heads (9 rows each: rows 0..8)
# ---------------------------------------------------------------------------

# 1) Front-facing approved head top (rows 0..5)
HEAD_F_TOP = [
    "....OOOOOO....",
    "..OOCCCCCCOO..",
    ".OCCCCCCCCCCO.",
    "OCCCHHHHHHCCCO",
    "OCCHHHhHHHHCCO",
    "OCHHSSSHHSSHCO",
]

FACE_F = {
    "normal": [
        "OCSEWSSSSEWSCO",
        "OCSEESSSSEESCO",
        "OCSbSSmmSSbSCO",
    ],
    "blink": [
        "OCSSSSSSSSSSCO",
        "OCSEESSSSEESCO",
        "OCSbSSmmSSbSCO",
    ],
    "up": [
        "OCSEESSSSEESCO",
        "OCSWWSSSSWWSCO",
        "OCSbSSSmSSbSCO",
    ],
    "up_right": [
        "OCSSEESSSSEECO",
        "OCSSWWSSSSWWCO",
        "OCSbSSSmSSbSCO",
    ],
    "wow": [
        "OCSWWSSSSWWSCO",
        "OCSWESSSSWESCO",
        "OCSbSSMMSSbSCO",
    ],
    "happy": [
        "OCSSESSSSESSCO",
        "OCSESESSESESCO",
        "OCSbSSmmSSbSCO",
    ],
    "happy_open": [
        "OCSSESSSSESSCO",
        "OCSESESSESESCO",
        "OCSbSSMMSSbSCO",
    ],
    "sad1": [
        "OCSESSSSSSESCO",
        "OCSSEESSEESSCO",
        "OCSSSSmmSSSSCO",
    ],
    "sad2": [
        "OCSSSSSSSSSSCO",
        "OCSSEESSEESSCO",
        "OCSSSSmmSSSSCO",
    ],
    "land": [
        "OCSEWSSSSEWSCO",
        "OCSEESSSSEESCO",
        "OCSbSSmmSSbSCO",
    ],
}

# 2) 3/4 Right-facing head top (rows 0..5, face shifted 1 px right inside hood)
HEAD_R_TOP = [
    "....OOOOOO....",
    "..OOCCCCCCOO..",
    ".OCCCCCCCCCCO.",
    "OCCCcHHHHHHCCO",
    "OCCcHHHHhHHHCO",
    "OCCcHHSSSHHSCO",
]

FACE_R = {
    "normal": [
        "OCCSEWSSSEWSCO",
        "OCCSEESSSEESCO",
        "OCCSbSSmmSbSCO",
    ],
    "eager": [
        "OCCSEWSSSEWSCO",
        "OCCSEESSSEESCO",
        "OCCSbSSmMSbSCO",
    ],
    "wow": [
        "OCCSWWSSSWWSCO",
        "OCCSWESSSWESCO",
        "OCCSbSSMMSbSCO",
    ],
    "happy": [
        "OCCSESSSSSESCO",
        "OCCESESSSESECO",
        "OCCSbSSmmSbSCO",
    ],
    "up": [
        "OCCSEESSSEESCO",
        "OCCSWWSSSWWSCO",
        "OCCSbSSSmSbSCO",
    ],
}

# 3) 3/4 Back-Right head for ladder climbing (rows 0..8)
# Violet hood back with seam 'c' on left, blond fringe + side eye looking up + cheek on right
HEAD_CLIMB = [
    "....OOOOOO....",
    "..OOCCCCCCOO..",
    ".OCCCCCCCCCCO.",
    "OCCCCCCcHHHhCO",
    "OCCCCCcCHHHHHO",
    "OCCCCcCCHHSSSO",
    "OCCCCcCCSEESSO",
    "OCCCCcCCSWWSSO",
    ".OCCCcCCSbSSO.",
]


def head_f(face: str) -> list[str]:
    return HEAD_F_TOP + FACE_F[face]


def head_r(face: str) -> list[str]:
    return HEAD_R_TOP + FACE_R[face]


EMPTY = ".............."

# ---------------------------------------------------------------------------
# All 38 frames in exact atlas order from provisional/lilbro-hood.json
# ---------------------------------------------------------------------------

FRAME_PIXELS: list[tuple[str, list[str]]] = [
    # ---- Group 1: Idle (4) ----
    (
        "idle_1",
        head_f("normal") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCCO.",
            "OSCCCCCCCCCCSO",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    (
        "idle_2",
        # Breathing beat: chest/collar AA and hands shift 1 px down
        head_f("normal") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCCCCCCCO.",
            ".OcCCCAACCCcO.",
            "OSCCCCCCCCCCSO",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    (
        "idle_blink",
        head_f("blink") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCCO.",
            "OSCCCCCCCCCCSO",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    (
        "idle_look",
        head_f("up") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCCO.",
            "OSCCCCCCCCCCSO",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 2: Run / Walk 6-frame cycle facing RIGHT (6) ----
    # run_1: Contact A — right leg forward-right, left leg back-left; near arm swung back-left, far hand forward-right
    (
        "run_1",
        head_r("normal") + [
            ".OOcSSSSSSCOO.",
            ".OCcCCCAACCCSO",
            "OScCCCCCCCCOO.",
            ".OOCCCCCCCCOO.",
            "..OPPO..OPPO..",
            ".OBBO....OBBO.",
            ".OOOO....OOOO.",
        ],
    ),
    # run_2: Down / Squash A — head drops 1 px (row 1); right foot planted mid, left foot folded behind; near arm passes forward
    (
        "run_2",
        [EMPTY] + head_r("normal") + [
            ".OOcSSSSSSCOO.",
            ".OCCcCCAACCCcO",
            ".OOCcCSCCCCOO.",
            "..OBPO.OPPPO..",
            "..OOO..OBBBO..",
            ".......OOOOO..",
        ],
    ),
    # run_3: Pass / Push-off Up A — head at row 0; right foot pushing off behind, left knee driving forward-up; near arm forward-right
    (
        "run_3",
        head_r("normal") + [
            ".OOCSSSSSSCOO.",
            "OSCCCCAACCCcO.",
            ".OOCCCCcCCCSO.",
            "..OOCCCCCCOO..",
            "..OPPO.OPBBO..",
            ".OBBO..OOOOO..",
            ".OOOO.........",
        ],
    ),
    # run_4: Contact B — left leg forward-right, right leg back-left; near arm sweeping forward-right, far arm back-left
    (
        "run_4",
        head_r("normal") + [
            ".OOCSSSSSSCOO.",
            "OSCCCCAACcCCO.",
            ".OOCCCCCcCCSSO",
            "..OCCCCCCCCOO.",
            "..OPPO..OPBO..",
            ".OBBO...OBBBO.",
            ".OOOO...OOOOO.",
        ],
    ),
    # run_5: Down / Squash B — head drops 1 px (row 1); left foot planted center, right foot folded behind; near arm swings back
    (
        "run_5",
        [EMPTY] + head_r("normal") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACcCCO.",
            ".OOSCcCCCCCOO.",
            ".OBPO.OPPPO...",
            ".OOO..OBBBO...",
            "......OOOOO...",
        ],
    ),
    # run_6: Pass / Push-off Up B — head at row 0; left foot pushing off behind, right knee driving forward-up; near arm back-left
    (
        "run_6",
        head_r("normal") + [
            ".OOcSSSSSSCOO.",
            ".OCcCCCAACCCSO",
            "OScCCCCCCCCOO.",
            "..OOCCCCCCOO..",
            "...OPPOOPBBO..",
            "..OBBO.OOOOO..",
            "..OOOO........",
        ],
    ),

    # ---- Group 3: Jump / Fall / Land (4) ----
    # jump_takeoff: deep crouch (head dropped 2 px to row 2), arms swept back-left, leaning right
    (
        "jump_takeoff",
        [EMPTY, EMPTY] + head_r("eager") + [
            ".OOcSSSSSSCOO.",
            "OScCCCCAACCCO.",
            ".OOcCCCCCCCCO.",
            "..OPBBO.OPBBO.",
            "..OOOO...OOOO.",
        ],
    ),
    # jump_air: airborne leap, happy face, arms raised high, knees tucked (row 15 empty)
    (
        "jump_air",
        head_f("happy") + [
            "OSOCSSSSSSCOSO",
            "OOCCCCAACCCCOO",
            ".OCCCCCCCCCCO.",
            ".OOOPPPPPPOOO.",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
            EMPTY,
        ],
    ),
    # fall: surprised wow face, arms flailing high, legs dangling unevenly (both sneakers 1 px tall)
    (
        "fall",
        head_f("wow") + [
            "OSOCSSSSSSCOSO",
            "OOcCCCAACCCcOO",
            ".OCCCCCCCCCCO.",
            "..OPPPOOPPPO..",
            "..OBBBOOPPPO..",
            "..OOOO.OBBBO..",
            ".......OOOOO..",
        ],
    ),
    # land: impact squash (head dropped 2 px to row 2), wider torso & arms out, wide planted feet
    (
        "land",
        [EMPTY, EMPTY] + head_f("land") + [
            ".OOCSSSSSSCOO.",
            "OCCCCcAAcCCCCO",
            "OSCCCCCCCCCCSO",
            ".OBBPO..OPBBO.",
            ".OOOOO..OOOOO.",
        ],
    ),

    # ---- Group 4: Climb 4-frame cycle seen from side/back-ish (4) ----
    # climb_1: right hand reaching HIGH up-right (row 8), left hand low; left knee hiked high, right leg extended down
    (
        "climb_1",
        HEAD_CLIMB[:8] + [
            ".OCCCcCCSbSOSO",
            ".OOCCcCCCCCCCO",
            ".OCCCcCCCCCCO.",
            "OSCCCcCCCCCOO.",
            ".OOCCcCCCCOO..",
            ".OBBPO.OPPPO..",
            ".OOOO..OBBBO..",
            ".......OOOOO..",
        ],
    ),
    # climb_2: pulling up A — right hand mid-pull (row 10), left hand rising; feet stepping
    (
        "climb_2",
        HEAD_CLIMB + [
            ".OOCcCCCCCCOO.",
            ".OOCcCCCCCCSO.",
            "OSCCcCCCCCCOO.",
            "..OCcCCCCCCO..",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # climb_3: left hand reaching HIGH up-left (row 8), right hand low; right knee hiked high, left leg extended down
    (
        "climb_3",
        HEAD_CLIMB[:8] + [
            "OSOCCcCCSbSSO.",
            "OCCCCcCCCCCCOO",
            ".OCCCcCCCCCCO.",
            ".OOCCcCCCCCSO.",
            "..OCCcCCCCOO..",
            "..OPPPO.OPBBO.",
            "..OBBBO.OOOOO.",
            "..OOOOO.......",
        ],
    ),
    # climb_4: pulling up B — left hand mid-pull (row 10), right hand rising; feet stepping
    (
        "climb_4",
        HEAD_CLIMB + [
            ".OOCcCCCCCCOO.",
            "OSCCcCCCCCCOO.",
            ".OOCcCCCCCCSO.",
            "..OCcCCCCCCO..",
            "..OPPPOOPPPO..",
            "..OBBBO.OBBO..",
            "..OOOOO.OOOO..",
        ],
    ),

    # ---- Group 5: Ladder Prop with 3 px amber wood hint 'L' (2) ----
    # ladder_pull: leaning back slightly, pulling out amber ladder stub (3 px diagonal L)
    (
        "ladder_pull",
        head_r("normal") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCOO.",
            ".OcCCCCCCSLOO.",
            "..OOCCCCCSLLO.",
            "..OPPO..OPPO..",
            ".OBBO....OBBO.",
            ".OOOO....OOOO.",
        ],
    ),
    # ladder_set: leaning forward happily, propping upright amber ladder rail (3 px vertical L)
    (
        "ladder_set",
        head_r("happy") + [
            ".OOCSSSSSSCOLO",
            ".OCCCCAACCCSLO",
            ".OOCCCCCCCSLO.",
            "..OOCCCCCCCOO.",
            "..OPPPO.OPPO..",
            "..OBBBO.OBBO..",
            "..OOOOO.OOOO..",
        ],
    ),

    # ---- Group 6: Punch (3) ----
    # punch_windup: coiled back-left, right fist cocked behind, eyes locked right
    (
        "punch_windup",
        head_r("normal") + [
            ".OOcSSSSSSCOO.",
            ".OCcCCCAACCCO.",
            "OScCCCCCCCCOO.",
            ".OOcCCCCCCCcO.",
            "..OPPO..OPPO..",
            ".OBBO....OBBO.",
            ".OOOO....OOOO.",
        ],
    ),
    # punch_hit: fist extended to right edge (col 13), wow face, lunging right
    (
        "punch_hit",
        head_r("wow") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCOOO",
            ".OCCCCCCCCCCSS",
            "OSCCCCCCCCCOOO",
            "..OPPO..OPPO..",
            ".OBBO....OBBO.",
            ".OOOO....OOOO.",
        ],
    ),
    # punch_recoil: fist rebounding partway back, sturdy upright recovery
    (
        "punch_recoil",
        head_r("eager") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCSO.",
            ".OcCCCCCCCCOO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 7: Caught (2) ----
    # caught_1: surprised little hop (row 15 empty), wow face, arms flung up
    (
        "caught_1",
        head_f("wow") + [
            "OSOCSSSSSSCOSO",
            "OOCCCCAACCCCOO",
            ".OCCCCCCCCCCO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
            EMPTY,
        ],
    ),
    # caught_2: landed & happy, warm open arms
    (
        "caught_2",
        head_f("happy") + [
            ".OOCSSSSSSCOO.",
            "OSCCCCAACCCCSO",
            ".OOCCCCCCCCOO.",
            "..OCCCCCCCCO..",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 8: Think (2) ----
    # think_1: looking up, right hand tucked cleanly to chin with soft c-shade separation
    (
        "think_1",
        head_f("up") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAAcSSCO.",
            "OSCCCCCCcCCOO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # think_2: eyes glance up-right, chin-hand nudges 1 px inward, left hand relaxes down
    (
        "think_2",
        head_f("up_right") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAcSSCCO.",
            ".OCCCCCCcCCOO.",
            "OSCCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 9: Sad (2) ----
    # sad_1: slumped 1 px down, sad face, drooping shoulders & low arms
    (
        "sad_1",
        [EMPTY] + head_f("sad1") + [
            ".OOcSSSSSScOO.",
            ".OcCCCAACCCcO.",
            "OSCCCCCCCCCCSO",
            ".OOPPPOOPPPOO.",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # sad_2: heavy sigh — eyes droop further, chest exhaled 1 px, hands hang limp by knees
    (
        "sad_2",
        [EMPTY] + head_f("sad2") + [
            ".OOcSSSSSScOO.",
            ".OcCCCCCCCCcO.",
            ".OcCCCAACCCcO.",
            "OSOPPPOOPPPOSO",
            ".OOBBBOOBBBOO.",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 10: Ask "Press it?" (2) ----
    # ask_1: standing next to button, 3/4-right attentive face, right hand gesturing toward button
    (
        "ask_1",
        head_r("normal") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCCSO",
            "OSCCCCCCCCCOO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # ask_2: eager smiling follow-up, right hand lifted higher gesturing up-right
    (
        "ask_2",
        head_r("happy") + [
            ".OOCSSSSSSCOSO",
            ".OCCCCAACCCCOO",
            "OSCCCCCCCCCCO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 11: Done (2) ----
    # done_1: grounded happy V-cheer
    (
        "done_1",
        head_f("happy") + [
            "OSOCSSSSSSCOSO",
            "OOCCCCAACCCCOO",
            ".OCCCCCCCCCCO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # done_2: celebratory cheer hop (row 15 empty, open laugh, star legs)
    (
        "done_2",
        head_f("happy_open") + [
            "OSOCSSSSSSCOSO",
            "OOCCCCAACCCCOO",
            ".OCCCCCCCCCCO.",
            "..OPPO..OPPO..",
            ".OBBO....OBBO.",
            ".OOOO....OOOO.",
            EMPTY,
        ],
    ),

    # ---- Group 12: Wave (3) — hover loops wave_1 -> wave_2 -> wave_3 -> wave_2 ----
    # wave_1: right hand raised & tilted inward near cheek (O separates hand cleanly from chin)
    (
        "wave_1",
        head_f("happy") + [
            ".OOCSSSSSSOSCO",
            ".OCCCCAACCcCOO",
            "OSCCCCCCCCCCO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # wave_2: right hand straight up-high (peak of wave, big cheerful laugh)
    (
        "wave_2",
        head_f("happy_open") + [
            ".OOCSSSSSSCOSO",
            ".OCCCCAACCCCOO",
            "OSCCCCCCCCCCO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # wave_3: right hand swung outward-right
    (
        "wave_3",
        head_f("happy") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCSSO",
            "OSCCCCCCCCCOO.",
            ".OOCCCCCCCCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),

    # ---- Group 13: Point (2) ----
    # point_1: 3/4-right attentive face looking right, horizontal arm pointing right at a setting
    (
        "point_1",
        head_r("normal") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCOO.",
            "OSCCCCCCCCCSO.",
            ".OOCCCCCCcCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
    # point_2: subtle emphasis nudge — finger extends 1 px further right, eager focused gaze right
    (
        "point_2",
        head_r("eager") + [
            ".OOCSSSSSSCOO.",
            ".OCCCCAACCCOOO",
            "OSCCCCCCCCCSSO",
            ".OOCCCCCCcCOO.",
            "..OPPPOOPPPO..",
            "..OBBBOOBBBO..",
            "..OOOO..OOOO..",
        ],
    ),
]

# Same animation names & frame names as provisional; tuned ms where helpful
ANIMATIONS = {
    "idle": {
        "frames": [
            "idle_1", "idle_1", "idle_1", "idle_1",
            "idle_2", "idle_2", "idle_2", "idle_2",
            "idle_1", "idle_1", "idle_blink", "idle_1",
            "idle_2", "idle_2", "idle_look", "idle_2",
        ],
        "ms": 260,
        "loop": True,
    },
    "walk": {"frames": ["run_1", "run_2", "run_3", "run_4", "run_5", "run_6"], "ms": 135, "loop": True},
    "run": {"frames": ["run_1", "run_2", "run_3", "run_4", "run_5", "run_6"], "ms": 80, "loop": True},
    "jump": {"frames": ["jump_takeoff", "jump_air"], "ms": 90, "loop": False},
    "fall": {"frames": ["fall"], "ms": 100, "loop": True},
    "land": {"frames": ["land"], "ms": 120, "loop": False},
    "climb": {"frames": ["climb_1", "climb_2", "climb_3", "climb_4"], "ms": 125, "loop": True},
    "prop": {"frames": ["ladder_pull", "ladder_set"], "ms": 150, "loop": False},
    "hit": {"frames": ["punch_windup", "punch_hit", "punch_recoil"], "ms": 75, "loop": True},
    "caught": {"frames": ["caught_1", "caught_2"], "ms": 210, "loop": False},
    "think": {"frames": ["think_1", "think_1", "think_2"], "ms": 420, "loop": True},
    "sad": {"frames": ["sad_1", "sad_1", "sad_2"], "ms": 500, "loop": True},
    "ask": {"frames": ["ask_1", "ask_1", "ask_2", "ask_1"], "ms": 330, "loop": True},
    "done": {"frames": ["done_1", "done_2"], "ms": 200, "loop": True},
    "hover": {"frames": ["wave_1", "wave_2", "wave_3", "wave_2"], "ms": 180, "loop": True},
    "point": {"frames": ["point_1", "point_2"], "ms": 420, "loop": True},
}


def hex_to_rgba(hex_color: str) -> tuple[int, int, int, int]:
    return (
        int(hex_color[1:3], 16),
        int(hex_color[3:5], 16),
        int(hex_color[5:7], 16),
        255,
    )


def validate_frames() -> None:
    assert len(FRAME_PIXELS) == 38, f"Expected 38 frames, got {len(FRAME_PIXELS)}"
    names = [name for name, _ in FRAME_PIXELS]
    assert len(set(names)) == 38, "Duplicate frame names"
    seen_grids: dict[tuple[str, ...], str] = {}
    for name, rows in FRAME_PIXELS:
        assert len(rows) == H, f"{name}: expected {H} rows, got {len(rows)}"
        for y, row in enumerate(rows):
            assert len(row) == W, f"{name} row {y}: expected len {W}, got {len(row)} ({row!r})"
            for x, ch in enumerate(row):
                assert ch == "." or ch in PAL, f"{name} ({x},{y}): unknown char {ch!r}"
        key = tuple(rows)
        assert key not in seen_grids, f"{name} is an exact duplicate of {seen_grids[key]}"
        seen_grids[key] = name


def draw_atlas(dark: bool) -> Image.Image:
    rows_n = (len(FRAME_PIXELS) + COLS - 1) // COLS
    img = Image.new("RGBA", (COLS * W, rows_n * H), (0, 0, 0, 0))
    for i, (_, rows) in enumerate(FRAME_PIXELS):
        ox, oy = (i % COLS) * W, (i // COLS) * H
        for y, row in enumerate(rows):
            for x, ch in enumerate(row):
                if ch == ".":
                    continue
                col = DARK_OUTLINE if (dark and ch == "O") else PAL[ch]
                img.putpixel((ox + x, oy + y), hex_to_rgba(col))
    return img


def make_preview_x8(light_atlas: Image.Image, dark_atlas: Image.Image) -> Image.Image:
    scale = 8
    cell_w, cell_h = W * scale, H * scale  # 112 x 128
    pad_x, pad_y = 14, 10
    label_h = 20
    header_h = 34
    outer_pad = 18
    rows_n = (len(FRAME_PIXELS) + COLS - 1) // COLS

    panel_w = outer_pad * 2 + COLS * cell_w + (COLS - 1) * pad_x
    panel_h = header_h + outer_pad + rows_n * (cell_h + label_h + pad_y) + outer_pad

    canvas = Image.new("RGBA", (panel_w, panel_h * 2), (240, 240, 244, 255))
    draw = ImageDraw.Draw(canvas)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 12)
        title_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
    except OSError:
        font = ImageFont.load_default()
        title_font = font

    panels = [
        ("LIGHT THEME — lilbro-hood-light.png (x8 nearest-neighbour, 14x16 cells)", light_atlas, (245, 245, 248, 255), (232, 232, 238, 255), (43, 36, 64, 255), (210, 210, 220, 255)),
        ("DARK THEME — lilbro-hood-dark.png (x8 nearest-neighbour, O = #9A93BE)", dark_atlas, (30, 30, 34, 255), (42, 42, 48, 255), (232, 230, 240, 255), (64, 64, 74, 255)),
    ]

    for p_idx, (title, atlas, bg, cell_bg, fg, border) in enumerate(panels):
        y0 = p_idx * panel_h
        draw.rectangle([0, y0, panel_w, y0 + panel_h], fill=bg)
        draw.text((outer_pad, y0 + 10), title, fill=fg, font=title_font)

        for i, (name, _) in enumerate(FRAME_PIXELS):
            col, row = i % COLS, i // COLS
            sx, sy = col * W, row * H
            crop = atlas.crop((sx, sy, sx + W, sy + H)).resize((cell_w, cell_h), Image.Resampling.NEAREST)

            cx = outer_pad + col * (cell_w + pad_x)
            cy = y0 + header_h + outer_pad // 2 + row * (cell_h + label_h + pad_y)

            draw.rectangle([cx - 1, cy - 1, cx + cell_w, cy + cell_h], fill=cell_bg, outline=border)
            # Subtle baseline at row 15 bottom
            draw.line([cx, cy + cell_h - 1, cx + cell_w - 1, cy + cell_h - 1], fill=border)
            canvas.alpha_composite(crop, (cx, cy))

            label = f"{i:02d} {name}"
            bbox = draw.textbbox((0, 0), label, font=font)
            tw = bbox[2] - bbox[0]
            draw.text((cx + (cell_w - tw) // 2, cy + cell_h + 3), label, fill=fg, font=font)

    return canvas


def verify_against_provisional(out: Path, prov_json_path: Path) -> None:
    prov = json.loads(prov_json_path.read_text())
    final = json.loads((out / "lilbro-hood.json").read_text())

    assert final["version"] == prov["version"]
    assert final["name"] == prov["name"]
    assert final["cell"] == prov["cell"] == {"width": W, "height": H}
    assert final["columns"] == prov["columns"] == COLS
    assert final["pointsPerPixel"] == prov["pointsPerPixel"]
    assert final["faces"] == prov["faces"] == "right"
    assert final["anchor"] == prov["anchor"] == {"x": 7, "y": 16}
    assert final["frames"] == prov["frames"], "Frame names/order mismatch!"
    assert set(final["animations"].keys()) == set(prov["animations"].keys()), "Animation names mismatch!"
    for anim_name, anim in final["animations"].items():
        assert anim["frames"] == prov["animations"][anim_name]["frames"], f"Anim {anim_name} frame list changed!"
        assert anim["loop"] == prov["animations"][anim_name]["loop"]
        assert all(f in final["frames"] for f in anim["frames"])

    light = Image.open(out / "lilbro-hood-light.png")
    dark = Image.open(out / "lilbro-hood-dark.png")
    expected_size = (COLS * W, ((len(FRAME_PIXELS) + COLS - 1) // COLS) * H)
    assert light.size == expected_size and dark.size == expected_size, (light.size, dark.size, expected_size)
    assert light.mode == "RGBA" and dark.mode == "RGBA"

    allowed_light = {hex_to_rgba(v) for v in PAL.values()} | {(0, 0, 0, 0)}
    allowed_dark = {hex_to_rgba(DARK_OUTLINE if k == "O" else v) for k, v in PAL.items()} | {(0, 0, 0, 0)}
    light_o = hex_to_rgba(PAL["O"])
    dark_o = hex_to_rgba(DARK_OUTLINE)

    for y in range(expected_size[1]):
        for x in range(expected_size[0]):
            pl = light.getpixel((x, y))
            pd = dark.getpixel((x, y))
            assert pl in allowed_light, f"Disallowed light color {pl} at {(x, y)}"
            assert pd in allowed_dark, f"Disallowed dark color {pd} at {(x, y)}"
            assert (pl[3] == 0) == (pd[3] == 0), f"Alpha mismatch at {(x, y)}"
            if pl != pd:
                assert pl == light_o and pd == dark_o, f"Non-outline diff at {(x, y)}: {pl} vs {pd}"


def main(out: Path) -> None:
    validate_frames()
    out.mkdir(parents=True, exist_ok=True)
    light = draw_atlas(False)
    dark = draw_atlas(True)
    light.save(out / "lilbro-hood-light.png")
    dark.save(out / "lilbro-hood-dark.png")

    meta = {
        "version": 1,
        "name": "Hood",
        "cell": {"width": W, "height": H},
        "columns": COLS,
        "pointsPerPixel": 2,
        "faces": "right",
        "anchor": {"x": 7, "y": 16},
        "frames": [name for name, _ in FRAME_PIXELS],
        "animations": ANIMATIONS,
    }
    (out / "lilbro-hood.json").write_text(json.dumps(meta, indent=2) + "\n")

    preview = make_preview_x8(light, dark)
    preview.save(out / "preview-x8.png")

    prov_json = Path(__file__).parent / "provisional" / "lilbro-hood.json"
    if prov_json.exists():
        verify_against_provisional(out, prov_json)

    print(f"OK: {len(FRAME_PIXELS)} unique frames -> {out} ({light.size[0]}x{light.size[1]} px)")


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "final")
