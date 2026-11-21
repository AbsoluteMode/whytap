from playwright.sync_api import sync_playwright
import pathlib
D = pathlib.Path(__file__).parent
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={'width': 1600, 'height': 1000}, device_scale_factor=2)
    pg.goto((D / 'gate.html').as_uri()); pg.wait_for_timeout(400)
    for id_, name in [('ov', '0-overview'), ('A', '1-variant-A-under-island'), ('B', '2-variant-B-left-like-notify'), ('C', '3-variant-C-wing-drawer')]:
        pg.locator(f'#{id_} .board').screenshot(path=str(D.parent / f'{name}.png'))
    b.close()
print('shot')
