# Generates gate.html: boards of the Harness Gate mockups (Whytap island style).
import pathlib
D = pathlib.Path(__file__).parent

PAGE = '''<div class="menubar"><div class="l"><span>Safari</span><span>File</span><span>Edit</span><span>View</span><span>History</span></div><div class="r">⌁ 87% &nbsp; Вс 22 нояб. 01:24</div></div>
<div class="page"><h2>Swift Concurrency: structured tasks</h2>
<p>Each child task inherits the priority and task-local values of its parent. When the parent is cancelled, every child is cancelled too, and the group waits for all of them before it returns.</p>
<p>Use a task group when the number of children is known only at run time. Results arrive in completion order, not in the order the tasks were added.</p>
<p>Unstructured tasks created with Task {} do not inherit cancellation. Keep a handle if you need to cancel them later.</p></div>'''

CC = '<span class="logo cc"><img src="claude-code.svg"></span>'
CX = '<span class="logo cx"><img src="codex.svg"></span>'

def k(x, off=False): return f'<span class="k{" off" if off else ""}">{x}</span>'

def pill(right='', left=''):
    return f'<div class="pill attached"><div class="wing">{left}</div><div class="wing">{right}</div></div>'

def screen(inner, tall=False, extra='', wide=False):
    return f'<div class="screen{" tall" if tall else ""}{" wide" if wide else ""}">{PAGE}{inner}{extra}</div>'

def frame(sc, tag, cap, w=False):
    return f'<div class="frame{" w" if w else ""}">{sc}<div class="cap"><span class="tag">{tag}</span>{cap}</div></div>'

def hdr(logo, who, where, badge=''):
    b = f'<span class="badge">{badge}</span>' if badge else ''
    return f'<div class="hdr">{logo}<span class="who">{who}</span><span class="where">{where}</span><span class="sp"></span>{b}</div>'

def buttons(armed, always=True, hold=None):
    kk = lambda x: k(x, off=not armed)
    a = f'<div class="b">Always {kk("A")}</div>' if always else '<div class="b dis">Always —</div>'
    if hold is not None:
        y = f'<div class="b pro"><span class="hold" style="width:{hold}%"></span>Hold to run {kk("Y")}</div>'
    else:
        y = f'<div class="b pro">Yes {kk("Y")}</div>'
    return f'<div class="btns"><div class="b">No {kk("N")}</div>{a}{y}</div>'

def foot(on, text):
    return f'<div class="foot{" on" if on else ""}"><span class="kbd"></span>{text}</div>'

def card(body, ring=False):
    return f'<div class="card{" ring" if ring else ""}">{body}</div>'

def island(card_html='', right='', left=''):
    return f'<div class="island">{pill(right, left)}{card_html}</div>'

def cursor(x, y): return f'<svg style="position:absolute;left:{x}px;top:{y}px;z-index:9" width="17" height="24" viewBox="0 0 17 24"><path d="M1 1 L1 19 L5.5 15 L8.5 22 L11.5 20.7 L8.6 14 L14.5 14 Z" fill="#000" stroke="#fff" stroke-width="1.3" stroke-linejoin="round"/></svg>'

HDR_CC = hdr(CC, 'Claude Code', '· whytap · feat/harness-gate', '1/3')
TITLE_TEST = '<div class="title">Run the HarnessGate tests</div>'
CMD_TEST = '<div class="cmd"><span class="cwd">$ </span>swift test --filter HarnessGateTests</div>'

# ---------- Variant A ----------
a1 = island(card(HDR_CC + TITLE_TEST + CMD_TEST + buttons(False) +
                 foot(False, 'Keys wake up when you point here · or ⌃⌥Space')))
a2 = island(card(HDR_CC + TITLE_TEST + CMD_TEST + buttons(True) +
                 foot(True, 'Y · N · A answer · hold Space to reply by voice'), ring=True))
a3 = island(card(hdr(CX, 'Codex', '· whytap-site · main', '2/3') +
                 '<div class="title">Run a command <span class="dim">outside the sandbox</span></div>'
                 '<div class="cmd"><span class="cwd">$ </span>rm -rf ~/Library/Caches/whytap build/</div>'
                 '<div class="risk hi">▲ Deletes files outside the project · not undoable</div>' +
                 buttons(True, always=False, hold=55) +
                 foot(True, 'Always is off for risky commands · hold Y for 0.6 s')))
a4 = island(card(hdr(CC, 'Claude Code', '· whytap · ui-gate', '3/3') +
                 '<div class="title">Where should the card appear?</div>'
                 '<div class="opts">'
                 f'<div class="opt">{k("1")}<div><div class="t">Under the island</div><div class="d">Same place as Case approvals</div></div></div>'
                 f'<div class="opt">{k("2")}<div><div class="t">Left, like Notify</div><div class="d">Stacks with notifications</div></div></div>'
                 f'<div class="opt">{k("3")}<div><div class="t">Only in the drawer</div><div class="d">A count on the island</div></div></div>'
                 '</div>' + foot(True, '1–3 choose · hold Space to answer in your own words')))
a5 = island(card(HDR_CC + '<div class="title">Reply to Claude Code <span class="dim">· No, with a note</span></div>'
                 '<div class="live"><span class="rec"></span><span class="txt">Сначала прогони только тесты гейта, <i>потом весь</i></span></div>' +
                 foot(True, 'Release Space to send · Esc cancels')))
a6 = island('', right=f'<span class="stackl">{CC}{CX}</span><span class="cnt">3</span>')
a6_note = ('<div style="position:absolute;top:46px;left:50%;transform:translateX(-50%);width:312px;background:#000;color:#fff;border-radius:12px;padding:8px 11px;font-size:11px;line-height:1.45;opacity:1;box-shadow:0 6px 18px rgba(0,0,0,.25)">'
           '<b>3 waiting</b> · oldest 1 min<br><span style="color:rgba(255,255,255,.6)">Point at the island to answer. After 60 s each request also returns to its terminal.</span></div>')

boardA = f'''<div class="board"><h1>Вариант A — карточка под островом (семья Case)</h1>
<div class="lead">Запрос выезжает под островом шириной острова, как Case-апрув. Клавиши Y / N / A <b>не перехватываются</b>, пока человек не навёл курсор на карточку (или не нажал ⌃⌥Space): так набор текста в другом окне никогда не ответит агенту. Клик по кнопкам работает всегда. Опасная команда — без «Always» и с удержанием Y. Голос — тот же Drop: зажал Space над карточкой.</div>
<div class="row">{frame(screen(a1), 'A1', '<b>Пришёл запрос.</b> Клавиши-подсказки полые: Y / N / A пока ничего не перехватывают. Заголовок — из <code>description</code> команды, ниже сама команда и репо/ветка. «1/3» — очередь.')}
{frame(screen(a2 + cursor(300, 150)), 'A2', '<b>Курсор над карточкой → клавиши живые</b> (синяя подсказка, тонкая рамка). Дальше 300 мс тишины клавиатуры, как у Case, и Y / N / A отвечают. Увёл курсор — клавиши снова свободны. У Codex кнопки «Always» нет: его хуки не умеют «на всю сессию».')}
{frame(screen(a3), 'A3', '<b>Опасная команда.</b> Локальный разбор: rm -rf, push --force, reset --hard, sudo, curl | sh, запись вне репо. Красная строка риска, «Always» нет, «Yes» — удержание 0,6 с. Это эвристика, не гарантия.')}</div>
<div class="row" style="margin-top:26px">{frame(screen(a4, tall=True), 'A4', '<b>Вопрос агента</b> (AskUserQuestion). Варианты на 1–3; свой ответ — голосом. Ответ уходит через PreToolUse + <code>updatedInput.answers</code>.')}
{frame(screen(a5 + cursor(300, 120)), 'A5', '<b>Голосовой ответ.</b> Зажал Space над карточкой — идёт обычный Drop-тейк в этот запрос. Для разрешения это «No + записка»: агент получает текст в <code>message</code> и меняет план.')}
{frame(screen(a6 + a6_note), 'A6', '<b>Не ответил.</b> Через 20 с карточка уезжает в крыло острова: логотипы харнессов и янтарный счётчик. Через 60 с хук отпускает запрос — в терминале появляется обычный диалог, ответить можно и там.')}</div></div>'''

# ---------- Variant B ----------
def nc(logo_src, title, body, age, risky=False):
    return (f'<div class="nc{" risky" if risky else ""}"><span class="ic"><img src="{logo_src}" style="{"filter:invert(1)" if "codex" in logo_src else "filter:invert(55%) sepia(40%) saturate(900%) hue-rotate(335deg) brightness(95%)"}"></span>'
            f'<div style="min-width:0;flex:1"><div class="tt">{title}</div><div class="bd">{body}</div></div><span class="age">{age}</span></div>')
stack3 = ('<div class="leftstack">' +
          nc('claude-code.svg', 'Claude Code · whytap — run tests', 'swift test --filter HarnessGateTests', '12s') +
          nc('codex.svg', 'Codex · whytap-site — run command', 'rm -rf ~/Library/Caches/whytap build/', '40s', risky=True) +
          nc('claude-code.svg', 'Claude Code · whytap — question', 'Where should the card appear?', '1m') + '</div>')
b1 = island('', right='') + stack3
big = ('<div class="leftstack"><div class="nc big ring" style="width:300px">' +
       hdr(CC, 'Claude Code', '· whytap · feat/harness-gate', '1/3') + TITLE_TEST + CMD_TEST + buttons(True) + '</div>' +
       nc('codex.svg', 'Codex · whytap-site — run command', 'rm -rf ~/Library/Caches/whytap build/', '40s', risky=True) + '</div>')
b2 = island('') + big
boardB = f'''<div class="board"><h1>Вариант B — слева от острова, как Notify</h1>
<div class="lead">Запросы — карточки в левом слоте Notify, стопкой до трёх, без таймера-заливки (висят, пока не ответил). Наведение раскрывает верхнюю карточку до полной формы с кнопками; клавиши живут только под курсором. Центр экрана не закрыт, но язык «уведомления» читается как «можно игнорировать».</div>
<div class="row">{frame(screen(b1, tall=True, wide=True), 'B1', '<b>Три запроса стопкой.</b> Опасный помечен янтарной кромкой. Видно сразу все сессии и возраст запросов.', w=True)}
{frame(screen(b2 + cursor(330, 175), tall=True, wide=True), 'B2', '<b>Наведение раскрывает карточку</b> в полную форму A. Остальные сдвигаются вниз — цель под курсором не уезжает, потому что растёт вниз от верхнего края.', w=True)}</div><div class="row" style="margin-top:26px">
{frame(screen(island('') + '<div class="leftstack">' + nc('claude-code.svg', 'Notify · Build finished', 'whytap 2.3.4 build 1502 is ready', 'now') + nc('claude-code.svg', 'Claude Code · whytap — run tests', 'swift test --filter HarnessGateTests', '12s') + '</div>', tall=True, wide=True), 'B3', '<b>Минус:</b> запрос стоит в одном ряду с обычными уведомлениями — «билд готов» и «агент ждёт тебя» выглядят одинаково, и слот на 33 события делят оба потока.', w=True)}</div></div>'''

# ---------- Variant C ----------
wing = f'<span class="stackl">{CC}{CX}</span><span class="cnt">3</span>'
drawer = ('<div class="drawer"><div class="dh"><span>Waiting for you</span><span>↑↓ · Y N A</span></div>'
          f'<div class="dr sel">{CC}<div class="m"><div class="a">whytap · Run the HarnessGate tests</div><div class="c">swift test --filter HarnessGateTests</div></div><span class="age">12s</span></div>'
          '<div style="padding:0 6px 4px">' + buttons(True) + '</div>'
          f'<div class="dr">{CX}<div class="m"><div class="a" style="color:var(--danger)">whytap-site · rm outside the project</div><div class="c">rm -rf ~/Library/Caches/whytap build/</div></div><span class="age">40s</span></div>'
          f'<div class="dr">{CC}<div class="m"><div class="a">whytap · Question: where should the card…</div><div class="c">3 options</div></div><span class="age">1m</span></div></div>')
c1 = island('', right=wing)
c2 = f'<div class="island">{pill(wing)}{drawer}</div>'
boardC = f'''<div class="board"><h1>Вариант C — счётчик в крыле, очередь в дровере</h1>
<div class="lead">Ничего не выезжает само: в правом крыле острова появляются логотипы харнессов и счётчик. Наведение открывает дровер шириной острова (как History) со списком запросов; выбранный раскрыт с кнопками, ↑↓ переключают. Ноль прерываний, но и ноль заметности — легко пропустить, и путь до ответа длиннее.</div>
<div class="row">{frame(screen(c1), 'C1', '<b>Только сигнал.</b> Один мягкий «вдох» острова при новом запросе (без анимации при Reduce Motion). Больше ничего на экране.')}
{frame(screen(c2 + cursor(395, 250), tall=True), 'C2', '<b>Наведение → дровер.</b> Список всех сессий, старые внизу, опасные красным. Клавиши работают, пока курсор в дровере.')}
{frame(screen(island(card(hdr(CC, 'Claude Code', '· whytap · ui-gate', '') + '<div class="title">Where should the card appear?</div><div class="opts">' + f'<div class="opt">{k("1")}<div><div class="t">Under the island</div></div></div><div class="opt">{k("2")}<div><div class="t">Left, like Notify</div></div></div><div class="opt">{k("3")}<div><div class="t">Only in the drawer</div></div></div></div>' + foot(True, '← back to the list · hold Space to answer')), right=wing), tall=True), 'C3', '<b>Вопрос открывается</b> внутри дровера той же формой, что в A4.')}</div></div>'''

# ---------- Overview ----------
ov = f'''<div class="board"><h1>Harness Gate — три места для запроса агента</h1>
<div class="lead">Один и тот же запрос Claude Code в трёх вариантах. Рекомендация: <b>A + сворачивание в счётчик C</b> (кадр A6). Клавиши живые только под курсором или после ⌃⌥Space — в отличие от Case, запрос приходит сам, пока человек печатает в другом окне.</div>
<div class="row">{frame(screen(a1), 'A', '<b>Под островом.</b> + заметно, знакомо по Case, вся информация сразу. − закрывает верх страницы, пока не ответил (сворачивается через 20 с).')}
{frame(screen(b1, tall=False, wide=True), 'B', '<b>Слева, как Notify.</b> + видно всю очередь, центр свободен. − выглядит как обычное уведомление, делит слот с Notify, далеко от взгляда.', w=True)}
{frame(screen(c1), 'C', '<b>Счётчик в крыле.</b> + ноль прерываний, масштабируется на 10 сессий. − легко пропустить; ответ = наведение + чтение + клавиша.')}</div></div>'''

html = f'''<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="gate.css"></head><body>
<div id="ov">{ov}</div><div style="height:28px"></div><div id="A">{boardA}</div><div style="height:28px"></div>
<div id="B">{boardB}</div><div style="height:28px"></div><div id="C">{boardC}</div></body></html>'''
(D / 'gate.html').write_text(html)
print('ok')
