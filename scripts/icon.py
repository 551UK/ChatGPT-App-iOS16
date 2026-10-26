#!/usr/bin/env python3
"""Make the black ChatGPT logo on white iOS app icon (iOS handles corner radius)."""
from pathlib import Path
from io import BytesIO
import urllib.request
import cairosvg
from PIL import Image

# Vector version of the recognizable official knot icon.
# The user requested the standard black symbol on a white background.
LOGO = "https://commons.wikimedia.org/wiki/Special:Redirect/file/ChatGPT_logo.svg"

def main():
    import sys
    app = Path(sys.argv[1])
    req = urllib.request.Request(LOGO, headers={"User-Agent":"ChatGPT-iOS16-build/1.0 (GitHub Actions)"})
    svg = urllib.request.urlopen(req, timeout=45).read()
    rendered = cairosvg.svg2png(bytestring=svg, output_width=800, output_height=800)
    symbol = Image.open(BytesIO(rendered)).convert("RGBA")
    # Normalize logo to black; SVG may include a colored background.
    alpha = symbol.getchannel("A")
    black = Image.new("RGBA", symbol.size, (0, 0, 0, 255))
    black.putalpha(alpha)
    icon = Image.new("RGBA", (1024, 1024), "white")
    icon.alpha_composite(black, (112, 112))
    for size, filename in [
        (120, "AppIcon60x60@2x.png"),
        (180, "AppIcon60x60@3x.png"),
        (152, "AppIcon76x76@2x~ipad.png"),
        (167, "AppIcon83.5x83.5@2x~ipad.png"),
        (1024, "iTunesArtwork@2x.png")
    ]:
        icon.resize((size,size), Image.Resampling.LANCZOS).convert("RGB").save(app / filename)
    print("Created ChatGPT icons")

if __name__ == "__main__":
    main()
