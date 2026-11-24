# Lil Bro ("Hood") — Final Sprite Atlas Notes

## Contract & Files
- `lilbro-hood-light.png` & `lilbro-hood-dark.png`: 112 × 80 px RGBA, transparent background, 8 columns × 5 rows, 38 unique 14 × 16 px frames (nearest-neighbour, zero anti-aliasing). Dark atlas has identical pixel layout with only outline `O` (`#2B2440`) remapped to `#9A93BE` (eyes `E` remain `#2B2440`).
- `lilbro-hood.json`: exact same schema, frame names/order, animation names, and anchor (`x: 7, y: 16`, `faces: "right"`) as `provisional/lilbro-hood.json`, with minor `ms` timing polish (`walk` 135 ms, `climb` 125 ms, `prop` 150 ms, `hit` 75 ms, `hover` 180 ms, `point` 420 ms).
- `preview-x8.png`: both light and dark atlases scaled ×8 (nearest-neighbour) with frame index + name labels.
- Generated reproducibly by `../make_final_atlas.py`.

## Extra Colours Added (2 of max 2)
1. `#6D42DC` (`c` — darker violet hoodie shade): separates overlapping arms/sleeves from the torso in `run`, `punch`, `think`, `sad`, and `land`, and adds the hood back seam in `climb_1..4`.
2. `#E8A33A` (`L` — amber ladder wood): 3-pixel ladder rail hint held in hands in `ladder_pull` and `ladder_set`.

All other pixels strictly use the approved palette from `reference/hood-pixels-from-mockup.js`.

## Frame-by-Frame Summary (38 unique frames, all facing RIGHT)
| # | Frame | Description |
|---|-------|-------------|
| 00 | `idle_1` | Approved base standing pose (front-facing, violet hood, blond fringe, white collar accent, dark trousers, white sneakers). |
| 01 | `idle_2` | Breathing beat: collar accent and hands/shoulders shift 1 px down while head and feet stay grounded. |
| 02 | `idle_blink` | Eyes closed blink on `idle_1` body. |
| 03 | `idle_look` | Curious upward glance on `idle_1` body. |
| 04 | `run_1` | 6-frame run cycle (3/4-right head): Contact A — right leg forward, left leg back, near arm swung back-left, far hand forward-right. |
| 05 | `run_2` | Down / squash A — head drops 1 px to row 1, right foot planted mid-cell on row 15, left foot folded behind, near arm passing forward. |
| 06 | `run_3` | Push-off / up A — head back at row 0, right foot pushing off behind (row 15), left knee tucked forward-up (row 14), near arm forward-right. |
| 07 | `run_4` | Contact B — left leg forward, right leg back, near arm sweeping forward-right, far arm back-left. |
| 08 | `run_5` | Down / squash B — head drops 1 px to row 1, left foot planted center on row 15, right foot folded behind, near arm swinging back. |
| 09 | `run_6` | Push-off / up B — head at row 0, left foot pushing off behind (row 15), right knee driving forward-up (row 14), near arm back-left. |
| 10 | `jump_takeoff` | Deep anticipation crouch (head dropped 2 px to row 2), eager 3/4-right face, arms swept back-left, crouched feet on row 15. |
| 11 | `jump_air` | Joyful airborne leap — happy `^ ^` face, arms raised high, knees tucked (row 15 empty). |
| 12 | `fall` | Surprised `"wow"` face, arms flailing high, legs dangling unevenly (left tucked 1 px higher, right dangling to row 15). |
| 13 | `land` | Impact squash — head dropped 2 px to row 2, 14 px wide squashed hoodie with arms out for balance, wide planted stance on row 15. |
| 14 | `climb_1` | 3/4 side-back view (violet hood back + seam, blond fringe & side eye looking up): right hand high (row 8), left hand low, left knee hiked up. |
| 15 | `climb_2` | Mid-pull A — right hand pulling at chest height, left hand rising, feet stepping cleanly. |
| 16 | `climb_3` | Opposite reach — left hand high (row 8), right hand low, right knee hiked up, left foot extended down. |
| 17 | `climb_4` | Mid-pull B — left hand pulling at chest height, right hand rising, feet transitioning back to `climb_1`. |
| 18 | `ladder_pull` | Braced stance leaning slightly back-left, holding a tilted 3-px amber ladder hint (`#E8A33A`) in hands. |
| 19 | `ladder_set` | Happy 3/4-right stance stepping forward, propping the 3-px upright amber ladder hint in front-right hands. |
| 20 | `punch_windup` | Coiled back-left on wide braced stance, right fist cocked behind, focused 3/4-right gaze. |
| 21 | `punch_hit` | Lunging right with `"wow"` 3/4-right face, right arm and fist extended to the right edge (col 13). |
| 22 | `punch_recoil` | Fist rebounding partway back, eager expression, feet recovering to sturdy stance. |
| 23 | `caught_1` | Startled click reaction — `"wow"` face, arms flung up, popped 1 px airborne (row 15 empty). |
| 24 | `caught_2` | Landed & delighted — happy `^ ^` face, warm open arms, grounded on row 15. |
| 25 | `think_1` | Looking up, right hand resting thoughtfully under chin (separated cleanly with `c` hoodie shade). |
| 26 | `think_2` | Eyes glancing up-right, chin hand nudges 1 px inward, left hand relaxes 1 px down. |
| 27 | `sad_1` | Offline / can't reach — slumped 1 px down, sad downturned face (no blush), drooping shoulders and low arms. |
| 28 | `sad_2` | Heavy sigh — eyes droop further, chest exhaled 1 px down, hands hang limply beside knees. |
| 29 | `ask_1` | Standing next to button, 3/4-right attentive face, right hand gesturing right at shoulder height. |
| 30 | `ask_2` | Eager `"Press it?"` follow-up — happy 3/4-right face with right hand raised higher up-right. |
| 31 | `done_1` | Grounded happy V-cheer (`^ ^` eyes, both arms up). |
| 32 | `done_2` | Celebratory cheer hop — open happy laugh, arms high, wide kicked legs 1 px airborne (row 15 empty). |
| 33 | `wave_1` | Hover wave inner beat — happy face, right hand raised and tilted inward near cheek. |
| 34 | `wave_2` | Hover wave center peak — beaming open laugh, right hand raised straight up. |
| 35 | `wave_3` | Hover wave outer beat — happy face, right hand tilted outward-right (loops `1-2-3-2`). |
| 36 | `point_1` | 3/4-right attentive stance pointing horizontally right at a setting. |
| 37 | `point_2` | Subtle emphasis nudge — pointing finger extends 1 px further right with eager focused gaze. |

## Tradeoffs / Limitations
- At 14 × 16 px, fingers on `point_1/2` and `think_1/2` are necessarily 1–2 px skin clusters framed with violet shadow (`#6D42DC`) rather than individual digits; both were checked at actual 2× macOS size (28 × 32 pt) for clean readability on light and dark backgrounds.
- Every frame fits strictly inside its 14 × 16 cell; grounded frames rest on row 15, while midair frames (`jump_air`, `caught_1`, `done_2`) leave row 15 transparent so the hop reads without requiring CSS/offset hacks.
