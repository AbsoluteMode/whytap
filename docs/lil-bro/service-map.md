# Whytap service map

Generated from the app's code (`LilBroServiceMap`); do not edit by hand. Each "- <row id>: <title> — <what it does>" line is a row go_kind "row" opens; "*" lines are what a feature needs and its common problems.
Shortcuts are named by what they do; the person can change their keys in Hotkeys or on the feature's screen.

## Drop (Dictation) · feature id `drop`

What it does: Dictation. Use its shortcut in any text field and speak: your words are typed there.
How to use: Always on, nothing to turn on. Shortcuts: Dictate. Settings: its own screen in Features. Its clip shows: A chat field, the shortcut, one sentence: the text is there.
What it needs:
* Speech-to-text model: Turns your voice into text. (row drop.needs.speechModel)
* Keyboard control: To hear your shortcut and type the text where your cursor is. (row drop.needs.keyboard)
* Microphone: To hear you, only while you are recording. (row drop.needs.microphone)
* Your shortcut is heard: macOS delivers Drop's shortcut to Whytap. (row drop.needs.shortcutHeard)
* Speech-to-text model for Smart: Turns your voice into text. Smart keeps its own choice.
* Text model for Smart: Fixes slips and punctuation after you speak.
Settings (row id: title — what it does):
- drop.dictate: Dictate — Drop's shortcut: hold or toggle it and speak, the text is typed where you are
- drop.mode: Mode — Fast types exactly what you said; Smart also fixes slips and punctuation
- drop.language: Language you speak — The language Drop listens for, or detect automatically
- drop.lowerOtherAudio: Lower other audio while speaking — Turns down other sound (music, videos) while you dictate and restores it after; turn it off so audio is not lowered, muted or ducked
- drop.stopAutomatically: Stop Drop automatically — In toggle mode, stops dictation by itself after you stop speaking
- drop.vocab: Vocab — Names and terms Drop should spell right
- drop.filler: Filler — Words Drop cuts from your dictation
- drop.needs.keyboard: Keyboard control — Drop needs keyboard control (Accessibility) to type for you: Allow
- drop.needs.microphone: Microphone — Drop needs the microphone: Allow
- drop.needs.speechModel: Speech-to-text model — The speech model Drop uses: download the free model on this Mac or add a key
- drop.needs.shortcutHeard: Your shortcut is heard — Checks that macOS lets Drop hear its shortcut
Common problems:
* Speech-to-text model is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: drop.needs.speechModel, apiAndModels.dropFast, apiAndModels.apiKeys, apiAndModels.apiHints.
* Keyboard control is not allowed → Allow it on this screen or in Permissions, then come back. Rows: drop.needs.keyboard, permissions.keyboard.
* Microphone is not allowed → Allow it on this screen or in Permissions, then come back. Rows: drop.needs.microphone, permissions.microphone.
* Nothing happens on Drop's shortcut → Check that macOS delivers it: Retry shortcut, or the fix the row shows. Rows: drop.needs.shortcutHeard, permissions.dropShortcut.
* Speech-to-text model for Smart is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: apiAndModels.dropSmart, apiAndModels.apiKeys, apiAndModels.apiHints.
* Text model for Smart is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: apiAndModels.dropSmart, apiAndModels.apiKeys, apiAndModels.apiHints.
* The text does not appear where the cursor is → Whytap pastes into the focused text field; it needs Keyboard control, and the cursor must be in a field that takes text. Rows: permissions.keyboard.
* “Couldn't deliver” after speaking → The provider failed; the recording is kept, so press Retry. A refused or out-of-credit key says so and is fixed in API keys. Rows: apiAndModels.apiKeys.
* Music or videos go quiet while dictating → Turn off Lower other audio while speaking. Rows: drop.lowerOtherAudio.
* Wants cleaner text with punctuation and fixed slips → Switch Drop to Smart (Drop Mode in the island or on Drop's screen); Smart needs a text model too. Rows: toolbox.dropMode.

## Agent (Quick tasks on your Mac) · feature id `agent`

What it does: Ask for a quick task by text or voice: it finds, converts, copies and changes settings. A helper for quick jobs on your Mac. Use its shortcut to type a request, or its voice shortcut to say it. The answer appears in the island; links and files in it can be opened or pasted.
How to use: Turn it on with its switch on its screen. Shortcuts: Type to the Agent, Talk to the Agent, Close the answer. Settings: its own screen in Features. Its clip shows: The shortcut, “Find my last invoice PDF”, then open it or paste its path.
Things to ask: “Find my last invoice PDF in Downloads”; “Convert the PNG on my desktop to JPG”; “What’s on my screen? Sum it up”; “Search the web for today’s euro to dollar rate”; “Add “call the bank” to my To-do”; “Switch Drop to Smart mode”.
What it needs:
* Text model that can use tools: The Agent thinks and answers with it. OpenAI, Anthropic and OpenRouter models can. (row agent.needs.textModel)
* Keyboard control: To hear the shortcut and paste the Agent's results. (row agent.needs.keyboard)
* Speech-to-text model (optional): Only for talking to the Agent. Typing works without it. (row agent.needs.speechModel)
* Microphone (optional): Only for talking to the Agent. (row agent.needs.microphone)
* Screen Recording (optional): Only when you ask the Agent about what is on your screen. (row agent.needs.screenRecording)
Settings (row id: title — what it does):
- agent.switch: Agent — Turns the Agent (Right Command) on or off
- agent.typeShortcut: Type to the Agent — Shortcut that opens the Agent's text input
- agent.talkShortcut: Talk to the Agent — Shortcut to ask the Agent by voice
- agent.closeShortcut: Close the answer — Shortcut that closes the Agent's answer
- agent.allowActions: Allow file edits and commands — Lets the Agent edit files and run commands; off means it only answers
- agent.needs.keyboard: Keyboard control — The Agent needs keyboard control (Accessibility): Allow
- agent.needs.microphone: Microphone — To talk to the Agent it needs the microphone: Allow
- agent.needs.screenRecording: Screen Recording — Lets the Agent see your screen when you ask: Allow
- agent.needs.speechModel: Speech-to-text model — The speech model for talking to the Agent
- agent.needs.textModel: Text model that can use tools — The model the Agent answers with: add a key or pick a model
Common problems:
* Text model that can use tools is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: agent.needs.textModel, apiAndModels.agent, apiAndModels.apiKeys, apiAndModels.apiHints.
* Keyboard control is not allowed → Allow it on this screen or in Permissions, then come back. Rows: agent.needs.keyboard, permissions.keyboard.
* Speech-to-text model is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: agent.needs.speechModel, apiAndModels.agent, apiAndModels.apiKeys, apiAndModels.apiHints.
* Microphone is not allowed → Allow it on this screen or in Permissions, then come back. Rows: agent.needs.microphone, permissions.microphone.
* Screen Recording is not allowed → Allow it on this screen or in Permissions, then come back. Rows: agent.needs.screenRecording, permissions.screenRecording.
* Nothing happens on the Agent's shortcut → Turn the Agent on with its switch. Rows: agent.switch.
* The Agent only answers and does not change files or run commands → Turn on Allow file edits and commands. Rows: agent.allowActions.

## Meeting Notes (Notes from your calls) · feature id `meetings`

What it does: Takes notes on your calls: transcript, summary, tasks and decisions. When a call starts, Whytap offers to take notes. Say yes, or use the shortcut at any time: it transcribes the call and writes a note with a summary, tasks and decisions. The note and the transcript stay on this Mac.
How to use: Turn it on with its switch on its screen. Shortcuts: Start or stop taking notes. Settings: its own screen in Features. Its clip shows: A call starts, Take notes, and the note with its tasks appears.
What it needs:
* Speech-to-text model: Writes down what was said. Speaker names need Soniox, Deepgram or ElevenLabs. (row meetings.needs.speechModel)
* Text model: Reads the transcript and writes the summary, tasks and decisions. (row meetings.needs.textModel)
* Microphone: To hear your side of the call. (row meetings.needs.microphone)
* System audio: To hear the other side of a call. (row meetings.needs.systemAudio)
Settings (row id: title — what it does):
- meetings.switch: Meeting Notes — Turns Meeting Notes on or off: offers to take notes when a call starts
- meetings.recordShortcut: Start or stop taking notes — Shortcut that starts and stops a meeting recording
- meetings.readyNotification: Tell me when a note is ready — A notification when a meeting note is ready
- meetings.yourNotes: Your notes — Opens every meeting note and its transcript
- meetings.needs.microphone: Microphone — Meeting Notes records your side with the microphone: Allow
- meetings.needs.systemAudio: System audio — Records the other side of the call: allow system audio recording
- meetings.needs.speechModel: Speech-to-text model — The model that transcribes meetings
- meetings.needs.textModel: Text model — The model that writes the meeting summary
Common problems:
* Speech-to-text model is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: meetings.needs.speechModel, apiAndModels.meetings, apiAndModels.apiKeys, apiAndModels.apiHints.
* Text model is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: meetings.needs.textModel, apiAndModels.meetings, apiAndModels.apiKeys, apiAndModels.apiHints.
* Microphone is not allowed → Allow it on this screen or in Permissions, then come back. Rows: meetings.needs.microphone, permissions.microphone.
* The other side of a call or the Mac's sound is not heard → macOS asks for System audio recording when the first recording starts and Whytap cannot check it beforehand; allow Whytap in System Settings → Privacy & Security → Screen & System Audio Recording. Rows: meetings.needs.systemAudio.
* No offer to take notes when a call starts → Turn Meeting Notes on; or start notes yourself with its shortcut. Rows: meetings.switch, meetings.recordShortcut.
* No speaker names in the transcript → Speaker names need a Soniox, Deepgram or ElevenLabs speech model. Rows: meetings.needs.speechModel.
* The recording stopped by itself → It ends when the call app stops using the microphone; when the call comes back Whytap offers Reconnect.

## Google search (Search from anywhere) · feature id `googleSearch`

What it does: Type or say a query from anywhere; it opens in Google. A search box one shortcut away, in any app. Type the query, or use the voice shortcut and say it. The results open in Google in your browser.
How to use: Turn it on with its switch on its screen. Shortcuts: Type a search, Say a search. Settings: its own screen in Features. Its clip shows: The voice shortcut, “weather in Lisbon tomorrow”, and Google opens.
What it needs:
* Speech-to-text model (optional): Only for searching by voice. Typing works without it. (row googleSearch.needs.speechModel)
* Microphone (optional): Only for searching by voice. (row googleSearch.needs.microphone)
Settings (row id: title — what it does):
- googleSearch.switch: Google search — Turns Google search from the keyboard on or off
- googleSearch.typeShortcut: Type a search — Shortcut that opens a Google search box
- googleSearch.sayShortcut: Say a search — Shortcut to search Google by voice
- googleSearch.needs.microphone: Microphone — Voice search needs the microphone: Allow
- googleSearch.needs.speechModel: Speech-to-text model — The speech model for voice search
Common problems:
* Speech-to-text model is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: googleSearch.needs.speechModel, apiAndModels.voiceSearch, apiAndModels.apiKeys, apiAndModels.apiHints.
* Microphone is not allowed → Allow it on this screen or in Permissions, then come back. Rows: googleSearch.needs.microphone, permissions.microphone.
* Its shortcut does nothing → Turn Google search on. Rows: googleSearch.switch.

## Translate & Subtitles (Island tools) · feature id `translateSubtitles`

What it does: Translate text in a small window, or show live translated subtitles for a call or video. Two tools in the island. Translate turns text you type or paste into another language with your text model. Subtitles listens to your Mac’s sound and shows a live translation on screen.
How to use: Its tools show in the island when added in Toolbox: Translate, Subtitles. Shortcuts: Open Translate, Start Subtitles. In the island it is the Translate tool. Settings: its own screen in Features. Its clip shows: Type a reply, get the translation, click it to copy.
What it needs:
* Text model for Translate (optional): Translates the text you type or paste. Subtitles work without it. (row translateSubtitles.needs.textModel)
* Soniox or OpenAI key for Subtitles (optional): Live subtitles run on Soniox live translation, or on OpenAI's without a Soniox key. Translate works without it. (row translateSubtitles.needs.subtitlesKey)
* System audio (optional): Subtitles listen to your Mac's sound. (row translateSubtitles.needs.systemAudio)
Settings (row id: title — what it does):
- translateSubtitles.card: Translate & Subtitles — Whether Translate and Subtitles are in the island (Toolbox)
- translateSubtitles.translate: Translate — Try Translate: type or paste text and translate it
- translateSubtitles.subtitles: Subtitles — Try Subtitles: live subtitles for what your Mac plays
- translateSubtitles.openTranslate: Open Translate — Shortcut that opens Translate
- translateSubtitles.startSubtitles: Start Subtitles — Shortcut that starts or stops live subtitles
- translateSubtitles.needs.subtitlesKey: Soniox or OpenAI key for Subtitles — Subtitles need a Soniox or OpenAI key: add a key
- translateSubtitles.needs.systemAudio: System audio — Subtitles listen to what your Mac plays: allow system audio recording
- translateSubtitles.needs.textModel: Text model for Translate — The model Translate uses: add a key or pick a model
Common problems:
* Text model for Translate is not set or its key does not work → Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model. Rows: translateSubtitles.needs.textModel, apiAndModels.translation, apiAndModels.apiKeys, apiAndModels.apiHints.
* Subtitles do not start → Add a Soniox key, or an OpenAI key without one. Rows: translateSubtitles.needs.subtitlesKey, apiAndModels.apiKeys, apiAndModels.apiHints.
* The other side of a call or the Mac's sound is not heard → macOS asks for System audio recording when the first recording starts and Whytap cannot check it beforehand; allow Whytap in System Settings → Privacy & Security → Screen & System Audio Recording. Rows: translateSubtitles.needs.systemAudio.
* Translate or Subtitles is not in the island → Add it to Your hover in Toolbox. Rows: translateSubtitles.card, toolbox.yourHover.

## Screenshots (Island tool Shot) · feature id `screenshots`

What it does: Capture an area, annotate it, blur text and numbers. Pick an area of the screen, draw arrows and text on it, blur anything private, then copy or save it. In the island it is called Shot.
How to use: Its tools show in the island when added in Toolbox: Shot. Shortcuts: Capture an area. In the island it is the Shot tool. Settings: its own screen in Features. Its clip shows: Shot, drag over an area, blur the private details, add an arrow, copy.
What it needs:
* Screen Recording: To capture the area you pick. (row screenshots.needs.screenRecording)
Settings (row id: title — what it does):
- screenshots.card: Screenshots — Whether Shot is in the island (Toolbox)
- screenshots.captureNow: Capture an area now — Takes a screenshot of an area now
- screenshots.shortcut: Capture an area — Shortcut that captures a screenshot of an area
- screenshots.needs.screenRecording: Screen Recording — Shot needs Screen Recording to capture the screen: Allow
Common problems:
* Screen Recording is not allowed → Allow it on this screen or in Permissions, then come back. Rows: screenshots.needs.screenRecording, permissions.screenRecording.
* Shot is not in the island → Add it to Your hover in Toolbox. Rows: screenshots.card, toolbox.yourHover.

## To-do (Island tool) · feature id `todo`

What it does: Quick tasks in the island. The Agent and your coding tools can add to it. A short task list in the island. Type a task and press Return; click one to finish it. The Agent, and coding tools connected to Whytap, can add tasks for you. The list stays on this Mac.
How to use: Its tools show in the island when added in Toolbox: To-do. Shortcuts: Open To-do. In the island it is the To-do tool. Settings: its own screen in Features. Its clip shows: To-do in the island, a task typed in, then ticked off.
Ways to add tasks: “Ask the Agent: “Add ‘renew the passport’ to my To-do””; “Ask Claude Code or Codex: “Turn my last call into tasks””.
What it needs:
* Nothing to allow or pay for: no key, model or permission.
Settings (row id: title — what it does):
- todo.card: To-do — Whether To-do is in the island (Toolbox)
- todo.yourTasks: Your tasks — Opens To-do in the island
- todo.shortcut: Open To-do — Shortcut that opens To-do
Common problems:
* To-do is not in the island → Add it to Your hover in Toolbox. Rows: todo.card, toolbox.yourHover.

## Case (Secrets for coding agents) · feature id `case`

What it does: Keeps API keys on this Mac. Coding agents use them by name and never see the values. A local vault for the API keys your coding agents need. They see key names only; a command started through Case gets the values, and the island can ask you before each one.
How to use: Its tools show in the island when added in Toolbox: Case. Shortcuts: Open Case. In the island it is the Case tool. Settings: its own screen in Features. Its clip shows: A coding agent asks for a key, the island asks you, the command runs.
Things to ask your coding agent: “Ask Claude Code: “Deploy with my API key from Case””; “Ask Codex: “Which keys are in Case for this project?””.
What it needs:
* Nothing to allow or pay for: no key, model or permission.
Settings (row id: title — what it does):
- case.card: Case — Whether Case, the secret keys store, is in the island (Toolbox)
- case.yourKeys: Your keys — Opens Case with your secret keys
- case.shortcut: Open Case — Shortcut that opens Case
Common problems:
* Case is not in the island → Add it to Your hover in Toolbox. Rows: case.card, toolbox.yourHover.
* A coding agent cannot use a key → The agent sees key names only and runs its command through Case, which puts the value in; it needs the Whytap plugin and the tool allowed in Integrations → Coding tools. Rows: case.yourKeys, other.integrations.

## Hover (Island tools) · feature id `hover`

What it does: Small tools that open when you hover the notch. Choose them and put them in order.
How to use: Always on, nothing to turn on. Settings: its own screen in Features. Its clip shows: Move a tool up the list and see it change places in the island.
What it needs:
* Nothing to allow or pay for: no key, model or permission.
Settings (row id: title — what it does):
- hover.dropMode: Drop Mode — Shows or hides Drop Mode in the island (it switches Drop between Fast and Smart); its shortcut and options
- hover.clipboard: History — Shows or hides History in the island (it opens clipboard history); its shortcut and options
- hover.notifs: Notify — Shows or hides Notify in the island (it opens Notify, what arrived from your sources); its shortcut and options
- hover.vocab: Vocab — Shows or hides Vocab in the island (it opens Vocab, words Drop should spell right); its shortcut and options
- hover.caseVault: Case — Shows or hides Case in the island (it opens Case, your secret keys); its shortcut and options
- hover.filler: Filler — Shows or hides Filler in the island (it opens Filler, words Drop cuts); its shortcut and options
- hover.inputLang: Input Lang — Shows or hides Input Lang in the island (it picks the language you speak); its shortcut and options
- hover.outputLang: Output Lang — Shows or hides Output Lang in the island (it picks the language Drop writes in); its shortcut and options
- hover.hotkeys: Hotkeys — Shows or hides Hotkeys in the island (it shows your hotkeys); its shortcut and options
- hover.notes: Notes — Shows or hides Notes in the island (it opens your meeting notes); its shortcut and options
- hover.meetingRecord: Record — Shows or hides Record in the island (it starts and stops a meeting recording); its shortcut and options
- hover.monitor: Monitor — Shows or hides Monitor in the island (it opens Monitor dashboards); its shortcut and options
- hover.brightness: Display — Shows or hides Display in the island (it opens the screen brightness slider); its shortcut and options
- hover.tasks: To-do — Shows or hides To-do in the island (it opens your task list); its shortcut and options
- hover.calendar: Calendar — Shows or hides Calendar in the island (it opens today's calendar); its shortcut and options
- hover.translate: Translate — Shows or hides Translate in the island (it opens Translate); its shortcut and options
- hover.subtitles: Subtitles — Shows or hides Subtitles in the island (it starts live subtitles); its shortcut and options
- hover.screenshot: Shot — Shows or hides Shot in the island (it captures a screenshot of an area); its shortcut and options
- hover.quit: Quit — Shows or hides Quit in the island (it quits Whytap); its shortcut and options
Common problems:
* A tool is missing from the island or in the wrong place → Show it on Hover's screen or in Toolbox → Your hover, and drag to reorder. Rows: toolbox.yourHover.

## Notify (Your own notifications) · feature id `notify`

What it does: Cards beside the island from sources your coding agent connects: builds, messages, checks.
How to use: Its tools show in the island when added in Toolbox: Notify. Shortcuts: Open Notify. In the island it is the Notify tool. Settings: its own screen in Features. Its clip shows: A build finishes and its notification appears beside the island.
What it needs:
* Nothing to allow or pay for: no key, model or permission.
Settings (row id: title — what it does):
- notify.inIsland: Notify in the island — History of what arrived, Clear All and the sources
- notify.shortcut: Open Notify — Shortcut that opens Notify
- notify.meetingNotes: Meeting notes — Notify me when my meeting notes are ready
- notify.addYourOwn: Add your own — A prompt for your coding agent to connect a new notification source: Show prompt, Copy prompt
Common problems:
* No cards arrive → Notify shows sources a coding agent connects: copy the Add your own prompt into your coding agent. Rows: notify.addYourOwn.

## Monitor (Dashboards in the island) · feature id `monitor`

What it does: Numbers from your servers or anything you watch, kept up to date by your coding agent's collector.
How to use: Its tools show in the island when added in Toolbox: Monitor. Shortcuts: Open Monitor. In the island it is the Monitor tool. Settings: its own screen in Features. Its clip shows: Open Monitor in the island and pick a dashboard to see its numbers.
What it needs:
* Nothing to allow or pay for: no key, model or permission.
Settings (row id: title — what it does):
- monitor.inIsland: Monitor in the island — Pick a dashboard to see its numbers in the island
- monitor.shortcut: Open Monitor — Shortcut that opens Monitor
- monitor.buildDashboard: Build a dashboard — A prompt for your coding agent to build a Monitor dashboard: Show prompt, Copy prompt
Common problems:
* No dashboards → A coding agent builds them: copy the Build a dashboard prompt into your coding agent. Rows: monitor.buildDashboard.

## The island

Everything on the island, and what turns each part on, off or changes it. "Not in Settings" or "No setting" means there is no row: say what to do instead, never that it does not exist.

### Island pill
The black pill around the notch (or at the top of a display without one): the orb on the left, hints and status on the right. Hover it to open the drawer. Auto-hide island fades it into the notch after about 20 seconds of no use (hover or any shortcut brings it back); Show island on picks the display; Screenshot protection hides it from screenshots and screen shares. It cannot be removed: quitting Whytap removes it. Rows: other.autoHide, other.showIslandOn, other.screenshotProtection.

### Eye: Hide Hover and Music
While you hover the pill, an eye takes the orb's place on the left. Not in Settings. Click the eye to hide the hover drawer and the music player (it turns into a crossed-out eye); click it again (Show Hover and Music) to bring them back. While they are hidden the brightness keys go back to macOS.

### Music (Now Playing)
While a track plays in any app: a small wing with the track in the pill's right band, and on hover a player card with artwork, play/pause and skip. Always on; there is no music switch in Settings. To hide the player card, hover the pill and click the eye (Hide Hover and Music); the small wing stays while music plays and goes away when it stops.

### Shortcut hints
When nothing else is shown, the pill's right band takes turns showing the main shortcuts (Drop, Agent). Always on; they show the keys set in Hotkeys, so changing a shortcut changes its hint. Rows: hotkeys.dropVoice, hotkeys.agentText, hotkeys.agentVoice.

### Hover drawer and tools
Hover the pill: Search all tools and your tool tiles; Option 1 to Option 5 open the first five. A tool opens its panel in the drawer. Your hover chooses and orders the tiles; All tools lists every tool and opens it. Hide the whole drawer with the eye. Rows: toolbox.yourHover, toolbox.allTools.

### Drop Mode panel and badge
The Drop Mode tool switches Fast and Smart; after a switch the pill shows the new mode for a moment. Drop's Mode row or the Drop Mode tool. Rows: drop.mode, toolbox.dropMode.

### Language panels
Input Lang and Output Lang tools: flags for the language you speak and the language Smart writes in. The Input Lang and Output Lang tools, or Drop's Language you speak. Rows: toolbox.inputLang, toolbox.outputLang, drop.language.

### Vocab and Filler panels
The words dictation spells right (Vocab) and the words it cuts (Filler), editable from the island. The Vocab and Filler tools or Drop's Vocab and Filler rows. Rows: toolbox.vocab, toolbox.filler, drop.vocab, drop.filler.

### Case panel
Case keys and projects in the island: search, add a key, drag a key to another project, delete a project. The Case tool, or Case's Your keys. Rows: toolbox.caseVault, case.yourKeys.

### Notify panel
What arrived from your notification sources, with Clear All. The Notify tool; Add your own connects another source. Rows: toolbox.notifs, notify.inIsland, notify.addYourOwn.

### Brightness strip
The Display tool's brightness slider, with a yellow Extra part above the normal maximum. The Display tool and its Hold brightness, Extra and Brightness keys rows. Rows: toolbox.brightness, toolbox.holdBrightness, toolbox.extraBrightness, toolbox.brightnessKeys.

### Dictation wing
While you dictate, the pill shows your words as you speak; if the text could not be typed, Couldn't deliver with Retry. Drop's rows: its shortcut, Mode, lowering other audio and stopping automatically. Rows: drop.dictate, drop.mode, drop.lowerOtherAudio, drop.stopAutomatically.

### Agent wing and answer
While the Agent works, a wing with what it is doing; then its answer under the island. Agent's switch, Close the answer and Allow file edits and commands. Rows: agent.switch, agent.closeShortcut, agent.allowActions.

### Meeting offer and recording
When a call starts: Take notes / Skip with a countdown; while recording: a timer, a waveform and Stop. Meeting Notes' switch turns the offer off; its shortcut starts or stops a recording. Rows: meetings.switch, meetings.recordShortcut, meetings.readyNotification.

### Notification pill
A short pill when something arrives from a notification source or a meeting note is ready. Notify's sources and its Meeting notes row. Rows: notify.inIsland, notify.meetingNotes.

### Update pill
Update when a new version is out (Download / Skip, then Restart / Later), and Updated for a few seconds after it installs. No setting: nothing downloads until you click Download; Skip hides the pill.

### Case access request
A coding tool asks for Case keys: choose the project and allow or refuse, and see which tools are connected. Case's Your keys and Integrations (Coding tools) change what each tool may use. Rows: case.yourKeys, other.integrations.

### Secure Input badge
A dimmed app logo to the right of the island: that app holds Secure Input (usually a password field), so macOS keeps Whytap's shortcuts from working; it shakes when you press one. No setting: leave the password field or quit that app and the badge goes away.

## Case and coding tools

Case keeps secret keys on this Mac in projects. A coding agent sees key names, never values, and runs a command through Case, which puts the value in and hides it in the output. Coding tools reach Whytap through its plugin after you allow them once (Integrations → Coding tools).

## Keys & models → API keys

Provider keys: click a provider's tile to add, replace or remove its key (OpenAI, Anthropic, Soniox, Deepgram, ElevenLabs, OpenRouter, Tavily, or a custom server). Keys stay in the macOS Keychain. On this Mac downloads a free speech model that needs no key (Apple Silicon).
- apiAndModels.onThisMac: On this Mac — Download or remove the on-device speech model that runs without a key (Apple Silicon)
- apiAndModels.apiKeys: API keys — Add, replace or remove a provider's API key (OpenAI, Anthropic, Soniox, Deepgram, ElevenLabs, OpenRouter, Tavily) or a custom server

## Keys & models → Models

One speech model and one text model serve every feature; Advanced sets a feature's own. A row's status says when a model is not set or its key does not work.
- apiAndModels.speech: Speech — The speech-to-text model every voice feature uses
- apiAndModels.llm: LLM — The language model every text feature uses
- apiAndModels.search: Search — What the Agent searches the web with (built-in or Tavily)
- apiAndModels.subtitles: Subtitles — The model for live subtitles and their translation
- apiAndModels.dropFast: Drop Fast — Drop Fast's own speech model (under Advanced)
- apiAndModels.dropSmart: Drop Smart — Drop Smart's own speech and cleanup models (under Advanced)
- apiAndModels.meetings: Meetings — Meeting transcription and summary models (under Advanced)
- apiAndModels.agent: Agent — The Agent's voice and answer models (under Advanced)
- apiAndModels.voiceSearch: Voice search — Voice search's own speech model (under Advanced)
- apiAndModels.translation: Translation — Translate's own model (under Advanced)

## Keys & models → Costs

What your API keys have cost, by provider, feature and day.
- apiAndModels.costs: Costs — What your API keys have cost, by provider, feature and day

## Keys & models → API hints

Where to get an API key: each provider's free or no-card offer, its sign-up link and which features it covers. The answer to “where do I get a key?”.
- apiAndModels.apiHints: API hints — Where to get an API key: each provider's free or no-card offer and its sign-up link, and which features it covers

## Hotkeys

Every shortcut in one place; click one, press a new combination, Save changes.
- hotkeys.agentText: Agent text — Shortcut that opens the Agent's text input
- hotkeys.agentVoice: Agent voice — Shortcut to ask the Agent by voice
- hotkeys.googleText: Google text — Shortcut that opens Google search by text
- hotkeys.googleVoice: Google voice — Shortcut to search Google by voice
- hotkeys.dropVoice: Drop voice — Dictation shortcut (Drop): hold or toggle to speak
- hotkeys.meetingRecord: Meeting record — Shortcut that starts and stops a meeting recording
- hotkeys.linksInsert: Links insert — Shortcut that inserts a saved link
- hotkeys.linksOpen: Links open — Shortcut that opens a saved link
- hotkeys.linksNext: Links next — Shortcut for the next saved link
- hotkeys.linksPrevious: Links previous — Shortcut for the previous saved link
- hotkeys.agentClose: Agent close — Shortcut that closes the Agent's answer
- hotkeys.toolRecord: Record (additional shortcut) — A second shortcut for the Record tool that starts and stops a meeting recording
- hotkeys.toolSettings: Settings — Shortcut for the Settings hover tool, which opens Whytap Settings
- hotkeys.toolDropMode: Drop Mode — Shortcut for the Drop Mode hover tool, which switches Drop between Fast and Smart
- hotkeys.toolClipboard: History — Shortcut for the History hover tool, which opens clipboard history
- hotkeys.toolNotifs: Notify — Shortcut for the Notify hover tool, which opens Notify, what arrived from your sources
- hotkeys.toolVocab: Vocab — Shortcut for the Vocab hover tool, which opens Vocab, words Drop should spell right
- hotkeys.toolCaseVault: Case — Shortcut for the Case hover tool, which opens Case, your secret keys
- hotkeys.toolFiller: Filler — Shortcut for the Filler hover tool, which opens Filler, words Drop cuts
- hotkeys.toolInputLang: Input Lang — Shortcut for the Input Lang hover tool, which picks the language you speak
- hotkeys.toolOutputLang: Output Lang — Shortcut for the Output Lang hover tool, which picks the language Drop writes in
- hotkeys.toolHotkeys: Hotkeys — Shortcut for the Hotkeys hover tool, which shows your hotkeys
- hotkeys.toolNotes: Notes — Shortcut for the Notes hover tool, which opens your meeting notes
- hotkeys.toolMonitor: Monitor — Shortcut for the Monitor hover tool, which opens Monitor dashboards
- hotkeys.toolBrightness: Display — Shortcut for the Display hover tool, which opens the screen brightness slider
- hotkeys.toolTasks: To-do — Shortcut for the To-do hover tool, which opens your task list
- hotkeys.toolCalendar: Calendar — Shortcut for the Calendar hover tool, which opens today's calendar
- hotkeys.toolTranslate: Translate — Shortcut for the Translate hover tool, which opens Translate
- hotkeys.toolSubtitles: Subtitles — Shortcut for the Subtitles hover tool, which starts live subtitles
- hotkeys.toolScreenshot: Shot — Shortcut for the Shot hover tool, which captures a screenshot of an area
- hotkeys.toolQuit: Quit — Shortcut for the Quit hover tool, which quits Whytap
- hotkeys.save: Save changes — Save, Revert or Reset to defaults for the hotkeys you changed

## Permissions

macOS permissions Whytap uses and whether each is allowed; Refresh after changing them in System Settings.
- permissions.keyboard: Keyboard control — Accessibility and keyboard access Drop and hotkeys need
- permissions.microphone: Microphone — Microphone access for Drop, the Agent and meetings
- permissions.screenRecording: Screen Recording — Screen recording access for screenshots and meeting audio
- permissions.dropShortcut: Drop shortcut — Whether Drop's shortcut works, and Retry shortcut or the fix when it does not
- permissions.refresh: Refresh — Checks permissions again after you changed them in System Settings

## Toolbox

The island's tools: Your hover is what shows on hover, All tools lists every tool, and a tool's pane is that tool itself with its shortcut.
- toolbox.openTodo: Open To-do — Opens your task list inside Hover
- toolbox.openCalendar: Open Calendar — Opens today's calendar inside Hover (coming soon)
- toolbox.holdBrightness: Hold brightness — Keeps the screen brightness you set
- toolbox.extraBrightness: Extra — Extra brightness, brighter than the normal maximum (HDR boost; uses more battery)
- toolbox.brightnessKeys: Brightness keys — Lets the keyboard brightness keys use Whytap's brightness
- toolbox.yourHover: Your hover — The tools shown when you hover over the island: add one, drag to reorder, remove
- toolbox.allTools: All tools — Every tool: click one to use it here, drag it to Your hover
- toolbox.dropMode: Drop Mode — Switch Drop between Fast and Smart
- toolbox.clipboard: History — Your clipboard history: copy or paste an earlier item
- toolbox.notifs: Notify — Recent notifications from your sources
- toolbox.vocab: Vocab — Words dictation should spell right: add or remove one
- toolbox.caseVault: Case — Your Case keys and projects
- toolbox.filler: Filler — Words dictation removes: add or remove one
- toolbox.inputLang: Input Lang — The language you speak for dictation
- toolbox.outputLang: Output Lang — The language Smart writes in
- toolbox.hotkeys: Hotkeys — Opens Hotkeys
- toolbox.notes: Notes — Opens your meeting notes
- toolbox.meetingRecord: Record — Start or stop recording a meeting
- toolbox.monitor: Monitor — Your dashboards
- toolbox.translate: Translate — Translate text from here
- toolbox.subtitles: Subtitles — Start or stop live subtitles
- toolbox.quit: Quit — Quits Whytap
- toolbox.settings: Settings — Opens Keys & models
- toolbox.screenshot: Shot — Take a screenshot of an area
- toolbox.brightness: Display — Screen brightness from the island: the slider, Hold brightness, Extra (above maximum) and Brightness keys
- toolbox.tasks: To-do — Your task list
- toolbox.calendar: Calendar — Today's calendar (coming soon)

## General

The island and the window: auto-hide, which display, screenshot protection, Backup and Integrations.
- other.autoHide: Auto-hide island — Fades the island into the notch after a while of no use
- other.showIslandOn: Show island on — Which display shows the island
- other.screenshotProtection: Screenshot protection — Hides the island from screenshots and screen shares
- other.backup: Backup — Opens Backup: back up and restore Whytap's settings
- other.integrations: Integrations — Opens Integrations: GitHub, calendars and tools that use Whytap

## Integrations

GitHub for Backup, the calendars Whytap reads, and Coding tools: coding agents (Claude Code, Codex and others) that use Whytap through its plugin, each allowed or refused once with a switch per tool. Allowed tools can read meetings, add Vocab and Filler words and change settings; Case keys stay hidden from them.
- integrations.github: GitHub — Connect GitHub (or an access token) for encrypted backups; check or disconnect it
- integrations.calendars: Calendars — Calendars Whytap reads: allow access to calendars, open Internet Accounts to add Google or Outlook

## Backup

Encrypted backups of keys, passwords and settings in your private GitHub repository; keep the recovery code to restore.
- backup.automaticBackup: Automatic backup — Backs up Whytap's settings on its own
- backup.syncSettings: Sync settings between Macs — Keeps settings the same on your Macs
- backup.backUpAndRestore: Back up and restore — Back up now, Restore backup, save or show the recovery code, Connect GitHub
- backup.restoreFromCode: Restore from recovery code — Enter the recovery code and restore a backup on this Mac

