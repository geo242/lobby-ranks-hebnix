"""Render listing/banner.png (1600x900) for the Hebnix plugin portal.

    python -m pip install pillow
    python tools/make_banner.py

Uses Segoe UI from C:/Windows/Fonts, the same face the in-game table uses.
Colors match the plugin defaults in lobby_ranks/main.lua.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "listing" / "banner.png"
FONTS = Path("C:/Windows/Fonts")

W, H = 1600, 900
BG = (17, 24, 39)
ACCENT = (32, 116, 255)       # team blue
ORANGE = (255, 156, 12)       # team orange
WHITE = (243, 244, 246)
MUTED = (156, 163, 175)

RANK = {
    "B": (255, 153, 0), "S": (255, 255, 255), "G": (255, 217, 0), "P": (57, 248, 255),
    "D": (67, 164, 255), "C": (202, 137, 255), "GC": (255, 93, 93), "SSL": (255, 111, 219),
}


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / name), size)


def rank_color(text: str):
    if text.startswith("SSL"):
        return RANK["SSL"]
    if text.startswith("GC"):
        return RANK["GC"]
    return RANK.get(text[0], WHITE)


def text_w(draw: ImageDraw.ImageDraw, text: str, f) -> float:
    return draw.textlength(text, font=f)


def main() -> None:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img, "RGBA")

    # left: title + tagline
    title = font("segoeuib.ttf", 112)
    x, y = 100, 300
    d.text((x, y), "Lobby", font=title, fill=WHITE)
    d.text((x + text_w(d, "Lobby ", title), y), "Ranks", font=title, fill=ACCENT)
    tag = font("segoeui.ttf", 34)
    d.text((x + 4, y + 160), "Everyone's rank, MMR and games played,", font=tag, fill=MUTED)
    d.text((x + 4, y + 206), "right on your scoreboard.", font=tag, fill=MUTED)
    d.text((x + 4, 250), "ROCKET LEAGUE  \u2022  HEBNIX PLUGIN", font=font("segoeuib.ttf", 24), fill=(107, 114, 128))

    # right: miniature of the in-game table
    head = font("segoeuib.ttf", 26)
    cell_b = font("segoeuib.ttf", 26)
    cell = font("segoeui.ttf", 22)
    cols = ["Name", "1v1", "2v2", "3v3"]
    widths = [190, 110, 110, 110]
    rows = [
        ("Mike", 0, [("D3 D2", "1088"), ("C2 D1", "1301"), ("C1 D4", "1244")]),
        ("Oscar", 0, [("GC2 D1", "1528"), ("GC3 D2", "1652"), ("GC1 D3", "1470")]),
        ("Foxtrot", 1, [("S3 D4", "455"), ("G2 D1", "699"), ("G1 D2", "640")]),
        ("Juliet", 1, [("P2 D3", "805"), ("D1 D2", "935"), ("P3 D1", "866")]),
    ]
    tw = sum(widths)
    header_h, block_h = 52, 84
    tx = W - 110 - tw
    ty = (H - header_h - block_h * len(rows)) // 2

    # soft shadow + panel
    d.rounded_rectangle((tx - 14, ty - 14, tx + tw + 14, ty + header_h + block_h * len(rows) + 14),
                        radius=18, fill=(0, 0, 0, 90))
    d.rectangle((tx, ty, tx + tw, ty + header_h), fill=(26, 26, 26, 235))
    cx = tx
    for name, w in zip(cols, widths):
        if name == "Name":
            d.text((cx + 16, ty + 10), name, font=head, fill=WHITE)
        else:
            d.text((cx + (w - text_w(d, name, head)) / 2, ty + 10), name, font=head, fill=WHITE)
        cx += w

    by = ty + header_h
    for i, (name, team, ranks) in enumerate(rows):
        d.rectangle((tx, by, tx + tw, by + block_h), fill=(42, 42, 42, 235) if i % 2 == 0 else (31, 31, 31, 235))
        d.rectangle((tx, by, tx + 5, by + block_h), fill=ACCENT if team == 0 else ORANGE)
        d.text((tx + 16, by + (block_h - 34) / 2), name, font=cell_b, fill=ACCENT if team == 0 else ORANGE)
        cx = tx + widths[0]
        for (rank, mmr), w in zip(ranks, widths[1:]):
            color = rank_color(rank)
            d.text((cx + (w - text_w(d, rank, cell_b)) / 2, by + 8), rank, font=cell_b, fill=color)
            d.text((cx + (w - text_w(d, mmr, cell)) / 2, by + 46), mmr, font=cell, fill=color)
            cx += w
        by += block_h

    cx = tx
    for w in widths[:-1]:
        cx += w
        d.line((cx, ty, cx, by), fill=(255, 255, 255, 25), width=1)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
