#!/usr/bin/env python3
"""
Generate SuenMusic Android app icons across all mipmap densities:
- ic_launcher.png (squircle with brand orange background + white soundwave)
- ic_launcher_round.png (circle with brand orange background + white soundwave)
- ic_launcher_foreground.png (transparent 108dp canvas with white soundwave)
"""

import math
import os
from PIL import Image, ImageDraw

BRAND_ORANGE = (224, 120, 60, 255) # #E0783C
WHITE = (255, 255, 255, 255)

DENSITIES = {
    'mdpi': (48, 108),
    'hdpi': (72, 162),
    'xhdpi': (96, 216),
    'xxhdpi': (144, 324),
    'xxxhdpi': (192, 432),
}

def cubic_bezier(p0, p1, p2, p3, t):
    mt = 1.0 - t
    x = mt*mt*mt*p0[0] + 3*mt*mt*t*p1[0] + 3*mt*t*t*p2[0] + t*t*t*p3[0]
    y = mt*mt*mt*p0[1] + 3*mt*mt*t*p1[1] + 3*mt*t*t*p2[1] + t*t*t*p3[1]
    return (x, y)

def draw_wave(draw, width, height, stroke_width, scale_factor=0.625, center_y_ratio=0.5):
    """
    Draws the SuenMusic signature wave centered at (width/2, height*center_y_ratio).
    Normalized points in 64x64:
      p0 = (12, 32)
      p1 = (18.67, 41.33)
      p2 = (25.33, 41.33)
      p3 = (32, 32)
      p4 = (38.67, 22.67)
      p5 = (45.33, 22.67)
      p6 = (52, 32)
    """
    cx = width / 2.0
    cy = height * center_y_ratio
    
    # In 64x64, total width of wave is 52 - 12 = 40.
    # We scale it so total width = width * scale_factor.
    wave_width = width * scale_factor
    s = wave_width / 40.0
    
    # Points relative to (32, 32):
    # p0 = (-20, 0)
    # p1 = (-13.33, +9.33)
    # p2 = (-6.67, +9.33)
    # p3 = (0, 0)
    # p4 = (+6.67, -9.33)
    # p5 = (+13.33, -9.33)
    # p6 = (+20, 0)
    
    p0 = (cx - 20.0 * s, cy)
    p1 = (cx - 13.3333 * s, cy + 9.3333 * s)
    p2 = (cx - 6.6667 * s, cy + 9.3333 * s)
    p3 = (cx, cy)
    p4 = (cx + 6.6667 * s, cy - 9.3333 * s)
    p5 = (cx + 13.3333 * s, cy - 9.3333 * s)
    p6 = (cx + 20.0 * s, cy)
    
    # Sample points along the two cubic Bezier curves
    points = []
    steps = 100
    for i in range(steps):
        t = i / float(steps)
        points.append(cubic_bezier(p0, p1, p2, p3, t))
    for i in range(steps + 1):
        t = i / float(steps)
        points.append(cubic_bezier(p3, p4, p5, p6, t))
        
    # Draw segments with round caps by drawing circles at endpoints and along the line
    r = stroke_width / 2.0
    for i in range(len(points) - 1):
        pt1 = points[i]
        pt2 = points[i+1]
        draw.line([pt1, pt2], fill=WHITE, width=int(round(stroke_width)))
        draw.ellipse([pt1[0]-r, pt1[1]-r, pt1[0]+r, pt1[1]+r], fill=WHITE)
    draw.ellipse([points[-1][0]-r, points[-1][1]-r, points[-1][0]+r, points[-1][1]+r], fill=WHITE)

def render_icon(size, kind='squircle'):
    # Super-sample 4x for smooth anti-aliasing
    scale = 4
    canvas_size = size * scale
    im = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    
    if kind == 'foreground':
        # Pure transparent background
        # In Android Adaptive Icon (108dp canvas), the visible viewport is the center 72dp.
        # To maintain exact brand proportions (wave width = 62.5% of visible icon):
        # wave width = 72 * 0.625 = 45dp (on 108dp canvas, ratio = 45 / 108 = 5/12)
        # stroke = 72 * (6.2 / 64) = 6.975dp (on 108dp canvas)
        stroke = (6.975 / 108.0) * canvas_size
        draw_wave(draw, canvas_size, canvas_size, stroke, scale_factor=(45.0 / 108.0))
    elif kind == 'round':
        # Circular background
        draw.ellipse([0, 0, canvas_size, canvas_size], fill=BRAND_ORANGE)
        # Wave centered, wave width approx 62.5% of diameter
        stroke = (6.2 / 64.0) * canvas_size
        draw_wave(draw, canvas_size, canvas_size, stroke, scale_factor=0.625)
    else: # squircle / standard
        # Rounded rectangle, radius rx = 19/64 of width
        rx = int(round(canvas_size * (19.0 / 64.0)))
        draw.rounded_rectangle([0, 0, canvas_size, canvas_size], radius=rx, fill=BRAND_ORANGE)
        stroke = (6.2 / 64.0) * canvas_size
        draw_wave(draw, canvas_size, canvas_size, stroke, scale_factor=0.625)
        
    # Resize down with Lanczos filter
    final_im = im.resize((size, size), Image.Resampling.LANCZOS)
    return final_im

def main():
    base_dir = 'android/app/src/main/res'
    for density, (icon_size, fg_size) in DENSITIES.items():
        density_dir = os.path.join(base_dir, f'mipmap-{density}')
        os.makedirs(density_dir, exist_ok=True)
        
        # 1. ic_launcher.png
        launcher = render_icon(icon_size, 'squircle')
        launcher_path = os.path.join(density_dir, 'ic_launcher.png')
        launcher.save(launcher_path, 'PNG')
        
        # 2. ic_launcher_round.png
        launcher_round = render_icon(icon_size, 'round')
        round_path = os.path.join(density_dir, 'ic_launcher_round.png')
        launcher_round.save(round_path, 'PNG')
        
        # 3. ic_launcher_foreground.png
        launcher_fg = render_icon(fg_size, 'foreground')
        fg_path = os.path.join(density_dir, 'ic_launcher_foreground.png')
        launcher_fg.save(fg_path, 'PNG')
        
        print(f"Generated {density}: launcher={icon_size}x{icon_size}, round={icon_size}x{icon_size}, fg={fg_size}x{fg_size}")

if __name__ == '__main__':
    main()
