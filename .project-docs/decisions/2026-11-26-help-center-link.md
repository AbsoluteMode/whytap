# Help Center link next to the website link

## Контекст
Owner: keep the whytap.ai link in the app and add a separate Help item that
sends users to the new Help Center (the Ask Q&A page) so they can ask a question.

## Решение
- One constant: `BuildConfig.helpCenterURL` = `https://whytap.ai/help/` (website: `BuildConfig.websiteURL`).
- Settings sidebar footer: `Whytap` (kept) · `Help` (`questionmark.circle`) · `GitHub`.
- Help window: new "Ask a question" button under "Open Learning Center & FAQ".
- Island hover tool `Help` (`questionmark.circle`), found by tool search ("help", "ask question", "помощь"). Not pinned for existing users; not a ring tile in onboarding (the last step already points to Ask).
- `whytap://tool/help` only shows the Toolbox pane; the page opens from its "Open Help Center" button, never from the link.

## Почему
Browser-only link, no Whytap server contact: same class as the existing whytap.ai
Ask link in onboarding and the Calendar privacy page. No status-bar menu exists (invariant 4), so footer + Help window + island search are the conventional places.

## Что протестировали
Unit tests: URL constant, router effect/invoke, tool search, symbol, layout untouched.
At writing time `https://whytap.ai/help/` returned 404 (landing task #55 not deployed): the PR stays draft until it is live.

## Отвергли
- A status-bar/menu item: forbidden by invariant 4.
- Replacing the whytap.ai link: the owner asked to keep it.

2026-11-26 — PR: see feature/help-center-link
