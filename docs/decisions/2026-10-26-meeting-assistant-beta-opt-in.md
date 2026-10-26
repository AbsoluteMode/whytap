# Meeting Assistant Beta starts off on every meeting

On 2026-10-26 the user reported unexpected Assistant calls while believing it
was off and requested that it start disabled and be marked Beta. This supersedes
[automatic listening](2026-10-26-meeting-assistant-auto-listen.md), including the
rule that a later recognized meeting clears a previous wand-off choice.

Configuring routes and a ready Space only exposes the existing wand. A click
explicitly starts system audio and question extraction for the current meeting.
No persistent enabled flag is introduced. Successive meetings, wake, metadata
refresh and errors cannot grant consent or restart capture. Existing stop,
cleanup and late-result cancellation paths remain shared by the wand and model.
An explicitly started session keeps listening when answers are hidden; ending
the meeting, sleep, quit or a changed/removed Space stops it.

The native module shows Beta beside its Space picker, API & Models labels the
group Beta, and tool/help text identifies the same state. The existing controls,
layout and interaction feedback are retained. Manual text questions still work
while listening is off.

Fake meeting probes, upstream audio and HTTP transports verify no audio/model
requests before explicit enable, off across later meetings and after failures,
pending-start cancellation, cleanup and explicit restart. Native offscreen
fixtures verify the small presentation change without launching another app.
