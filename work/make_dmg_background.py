from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 760, 460
img = Image.new("RGBA", (W, H), (10, 12, 16, 255))
px = img.load()

# A subtle graphite/blue gradient keeps the installer calm while matching the app.
for y in range(H):
    for x in range(W):
        glow = max(0.0, 1.0 - (((x - 380) / 470) ** 2 + ((y - 155) / 320) ** 2))
        px[x, y] = (
            int(10 + 13 * glow),
            int(12 + 17 * glow),
            int(16 + 30 * glow),
            255,
        )

draw = ImageDraw.Draw(img)
font_path = "/System/Library/Fonts/SFNS.ttf"
font_bold_path = "/System/Library/Fonts/SFNS.ttf"
try:
    title = ImageFont.truetype(font_bold_path, 32)
    subtitle = ImageFont.truetype(font_path, 18)
    hint = ImageFont.truetype(font_path, 20)
except OSError:
    title = ImageFont.load_default()
    subtitle = ImageFont.load_default()
    hint = ImageFont.load_default()

def centered(text, y, font, fill):
    box = draw.textbbox((0, 0), text, font=font)
    draw.text(((W - (box[2] - box[0])) / 2, y), text, font=font, fill=fill)

centered("Install NotchDock", 48, title, (244, 247, 255, 255))
centered("Drag NotchDock to Applications to get started", 92, subtitle, (170, 181, 198, 255))

# Soft divider and a clean horizontal hand-off arrow between the two icons.
draw.rounded_rectangle((126, 154, 634, 318), radius=28, outline=(75, 91, 116, 110), width=2)
draw.line((255, 236, 500, 236), fill=(120, 176, 255, 230), width=5)
draw.polygon([(500, 236), (475, 219), (475, 253)], fill=(120, 176, 255, 230))

centered("Just drag, then launch from Applications", 354, hint, (205, 214, 228, 255))
centered("Your Mac may ask you to confirm the first launch.", 389, subtitle, (130, 141, 160, 255))

img = img.filter(ImageFilter.GaussianBlur(radius=0.15))
img.save("Assets/NotchDock-dmg-background.png")
