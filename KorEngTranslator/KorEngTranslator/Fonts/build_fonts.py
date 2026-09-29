"""Build the app's Söhne / Pretendard / Favorit font files with layout-preserving line metrics.

Each new font gets the hhea/OS2 vertical metrics (ascent, descent, line gap) of the font it
replaces, so every Text keeps its old line box and nothing around it moves. Only glyphs change.

  TestSohne-*          body, replaces Geist           -> Geist metrics 920/-220/100 (1.24em)
  TestSohneHeading-*   headings, replaces PP Editorial -> 1.28em like PP Editorial (880/-300/100),
                       split 920/-260/100 so Geist fallback glyphs can't grow the line
  PretendardHeading-*  Korean headings, replaces Noto Serif KR -> Noto metrics 1151/-286/0 (1.437em)
  PretendardText-*     Korean body, Pretendard's own metrics

All punctuation (Unicode P* categories) is unmapped from the Söhne and Pretendard files so it
falls back to NeueMontrealPunct-* (English) or FavoritPunct-* (Korean), which map only punctuation
and have metrics smaller than every line box above, so a punctuation run never makes a line taller.

Usage: python3 build_fonts.py [path to the website's public/fonts folder]
Needs fontTools + brotli. Writes the Pretendard variants (OFL) into this Fonts folder, and the
Söhne / Favorit / PP Neue Montreal files into the git-ignored Fonts/Local folder.
"""
import os
import sys
import unicodedata
from fontTools.ttLib import TTFont

WEB = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Projects/portfolio-fresh/public/fonts")
SOHNE = f"{WEB}/GT Söhne"
FONTS = os.path.dirname(os.path.abspath(__file__))
LOCAL = f"{FONTS}/Local"  # git-ignored: these fonts can't be redistributed
FAVORIT_METRICS = (0.80, -0.20, 0.0)


def em(path):
    ref = TTFont(path)
    u = ref["head"].unitsPerEm
    h = ref["hhea"]
    return h.ascent / u, h.descent / u, h.lineGap / u


def set_metrics(font, asc, desc, gap):
    u = font["head"].unitsPerEm
    a, d, g = round(asc * u), round(desc * u), round(gap * u)
    h, o = font["hhea"], font["OS/2"]
    h.ascent, h.descent, h.lineGap = a, d, g
    o.sTypoAscender, o.sTypoDescender, o.sTypoLineGap = a, d, g
    o.usWinAscent, o.usWinDescent = max(o.usWinAscent, a), max(o.usWinDescent, -d)


def rename(font, old, new):
    for rec in font["name"].names:
        s = rec.toUnicode()
        if old in s:
            rec.string = s.replace(old, new)


def is_punct(cp):
    return unicodedata.category(chr(cp)).startswith("P")


def keep_codepoints(font, keep):
    for t in font["cmap"].tables:
        if t.format != 14 and t.isUnicode():
            t.cmap = {cp: g for cp, g in t.cmap.items() if keep(cp)}


def load_woff2(path):
    f = TTFont(path)
    f.flavor = None
    return f


def ext(font):
    return "otf" if "CFF " in font else "ttf"


geist = em(f"{FONTS}/Geist-Medium.ttf")
pp = em(f"{FONTS}/PPEditorialNew-Regular.otf")
noto = em(f"{FONTS}/NotoSerifKR-Variable.ttf")
pp_line = pp[0] - pp[1] + pp[2]
heading = (geist[0], -(pp_line - geist[0] - geist[2]), geist[2])  # same 1.28em box, Geist-sized ascent
no_punct = lambda cp: not is_punct(cp)

for web, cut in [("leicht", "Leicht"), ("buch", "Buch"), ("kraftig", "Kraftig"), ("halbfett", "Halbfett")]:
    f = load_woff2(f"{SOHNE}/GT-soehne-{web}.woff2")
    set_metrics(f, *geist)
    keep_codepoints(f, no_punct)
    f.save(f"{LOCAL}/TestSohne-{cut}.ttf")

for web, cut in [("buch", "Buch"), ("kraftig", "Kraftig")]:
    f = load_woff2(f"{SOHNE}/GT-soehne-{web}.woff2")
    set_metrics(f, *heading)
    keep_codepoints(f, no_punct)
    rename(f, "TestSohne", "TestSohneHeading")
    rename(f, "Test Söhne", "Test Söhne Heading")
    f.save(f"{LOCAL}/TestSohneHeading-{cut}.ttf")

for cut in ["SemiBold", "Medium"]:
    f = TTFont(f"{FONTS}/Pretendard-{cut}.otf")
    set_metrics(f, *noto)
    keep_codepoints(f, no_punct)
    rename(f, "Pretendard", "PretendardHeading")
    f.save(f"{FONTS}/PretendardHeading-{cut}.otf")

for cut in ["Regular", "Medium", "SemiBold"]:
    f = TTFont(f"{FONTS}/Pretendard-{cut}.otf")
    keep_codepoints(f, no_punct)
    rename(f, "Pretendard", "PretendardText")
    f.save(f"{FONTS}/PretendardText-{cut}.otf")

for cut in ["Light", "Regular", "Medium", "Bold"]:
    f = load_woff2(f"{WEB}/ABCFavorit-{cut}-Trial.woff2")
    set_metrics(f, *FAVORIT_METRICS)
    keep_codepoints(f, is_punct)
    rename(f, "ABCFavoritUnlicensedTrial", "FavoritPunct")
    rename(f, "ABC Favorit Unlicensed Trial", "FavoritPunct")
    f.save(f"{LOCAL}/FavoritPunct-{cut}.{ext(f)}")

for cut in ["Light", "Regular", "Medium", "Semibold"]:
    f = load_woff2(f"{WEB}/PPNeueMontreal-{cut}.woff2")
    set_metrics(f, *FAVORIT_METRICS)
    keep_codepoints(f, is_punct)
    rename(f, "PPNeueMontreal", "NeueMontrealPunct")
    rename(f, "PP Neue Montreal", "NeueMontrealPunct")
    f.save(f"{LOCAL}/NeueMontrealPunct-{cut}.{ext(f)}")

for name in ["TestSohne-Buch.ttf", "TestSohneHeading-Kraftig.ttf", "PretendardHeading-SemiBold.otf",
             "PretendardText-Medium.otf", "FavoritPunct-Medium." + ext(TTFont(f"{WEB}/ABCFavorit-Medium-Trial.woff2"))]:
    t = TTFont(f"{FONTS}/{name}" if os.path.exists(f"{FONTS}/{name}") else f"{LOCAL}/{name}")
    u, h = t["head"].unitsPerEm, t["hhea"]
    print(f"{name:32} ps={t['name'].getDebugName(6):28} fam={t['name'].getDebugName(1):28} "
          f"line={(h.ascent - h.descent + h.lineGap) / u:.3f}em mapped={len(t.getBestCmap())}")
