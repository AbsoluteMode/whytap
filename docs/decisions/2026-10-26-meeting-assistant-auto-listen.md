# Meeting Assistant listens automatically after model setup

Superseded later on 2026-10-26 by [Beta and explicit per-meeting enable](2026-10-26-meeting-assistant-beta-opt-in.md). The earlier requirement is retained as history.

On 2026-10-26 the user rejected the separate «Слушать встречу» action and
clarified: «Настроил модели — слушает каждую встречу». This supersedes the
manual-start and no-auto-join policy in the
[pilot](2026-10-23-meeting-assistant-pilot.md) and
[session switch](2026-10-24-meeting-assistant-session-switch.md) decisions.

Both Meeting Assistant routes and a ready selected Space enable listening on
each recognized meeting. There is no additional saved enable switch or required
hotkey. A metadata-only MeetingContextActiveProbe watches successive contexts;
system audio goes to the configured speech route only during a meeting. Notes
recording and microphone capture are independent and are not started by this.

The answers window opens on request. Closing it hides answers and cancels an
unfinished answer/screenshot request, while listening and question extraction
continue. Its former Listen/Stop button becomes a noninteractive connection
status; the idle hint only offers asking a question. The existing hover wand
can stop or resume Assistant for the current meeting, including without Notes.
An explicit off stays off across catalog refreshes and brief reconnects. After
the context has ended for 15 seconds, the next meeting enables listening again.

Audio/provider failures pause that meeting instead of repeatedly retrying model
requests. The wand permits an explicit retry; the next recognized meeting can
try automatically. Unsetting a required model stops audio and context monitoring.
Sleep and quit stop all audio and monitoring; wake rechecks configuration and
current meeting context. Startup and newly created Spaces are handled without
opening a window. Opening a tool link still has no capture action of its own;
automatic listening follows the configured meeting observer independently.

The probe remains a mic-activity heuristic, not a calendar or unique call ID.
A long mute can look like meeting end, a seamless call switch can lack a boundary,
and calls outside the recognized app/browser set can be missed. This change
does not claim universal meeting detection. Audio, transcripts, screenshots and
conversations remain bounded in memory and are not persisted by the assistant.

Validation uses isolated catalogs, defaults, metadata probes and fake speech/
answer providers. Offscreen native fixtures verify the reduced module in both
themes. Real-call detection, provider/audio permissions and physical hover remain
acceptance checks in the one installed Whytap; feature workers launch no app.
