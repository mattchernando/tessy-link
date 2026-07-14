#!/usr/bin/env python3
"""Generates icon_1024.png for Tessy Link. Requires Pillow (pip install pillow)."""
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
margin, radius = 60, 235
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0)); bgd = ImageDraw.Draw(bg)
top, bot = (46, 51, 60), (17, 19, 23)
for y in range(S):
    t = y / (S - 1); c = tuple(int(top[i]*(1-t)+bot[i]*t) for i in range(3))
    bgd.line([(0, y), (S, y)], fill=c + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([margin, margin, S-margin, S-margin], radius=radius, fill=255)
img.paste(bg, (0, 0), mask)
d = ImageDraw.Draw(img)
d.rounded_rectangle([margin, margin, S-margin, S-margin], radius=radius, outline=(255, 255, 255, 30), width=3)
mx0, my0, mx1, my1 = 300, 392, 724, 664
d.rounded_rectangle([mx0-16, my0-16, mx1+16, my1+16], radius=44, fill=(8, 9, 11, 255))
d.rounded_rectangle([mx0, my0, mx1, my1], radius=26, fill=(244, 246, 249, 255))
cx = 512
d.polygon([(cx-42, my1+16), (cx+42, my1+16), (cx+74, my1+104), (cx-74, my1+104)], fill=(8, 9, 11, 255))
d.rounded_rectangle([cx-128, my1+100, cx+128, my1+130], radius=15, fill=(8, 9, 11, 255))
d.rounded_rectangle([mx0+24, my0+24, mx1-24, my0+70], radius=12, fill=(232, 33, 39, 255))
for xx in (mx0+50, mx0+84, mx0+118):
    d.ellipse([xx-7, my0+40, xx+7, my0+54], fill=(255, 255, 255, 240))
for k, yy in enumerate(range(my0+100, my1-28, 40)):
    w = (mx1-52)-(mx0+24)
    d.rounded_rectangle([mx0+24, yy, mx0+24+int(w*(0.92-0.14*(k % 3))), yy+16], radius=8, fill=(206, 213, 221, 255))
ox, oy = cx, my0-30
for i, r in enumerate([58, 108, 158]):
    a = 255 - i*52
    d.arc([ox-r, oy-r, ox+r, oy+r], start=214, end=326, fill=(232, 33, 39, a), width=20)
d.ellipse([ox-15, oy-15, ox+15, oy+15], fill=(232, 33, 39, 255))
img.save("icon_1024.png")
print("icon saved")
