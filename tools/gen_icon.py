import math, os, struct, zlib

INK   = (0x1E, 0x1D, 0x1B)
WHITE = (0xFF, 0xFF, 0xFF)
FOLD  = (0xC6C4BE)  # 折角：纸背面的颜色，比纸暗一档
FOLD  = (0xC6, 0xC4, 0xBE)
BLUE  = (0x0A, 0x6C, 0xFF)
SS = 4

def canvas(n):
    return [[(0.0, 0.0, 0.0, 0.0)] * n for _ in range(n)]

def blend(dst, color, cov):
    if cov <= 0:
        return dst
    sa = cov
    da = dst[3] / 255.0
    oa = sa + da * (1 - sa)
    if oa <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    out = []
    for i in range(3):
        v = (color[i] * sa + dst[i] * da * (1 - sa)) / oa
        out.append(min(255.0, max(0.0, v)))
    return (out[0], out[1], out[2], oa * 255.0)

def resample(cv, f):
    n = len(cv) // f
    out = canvas(n)
    for y in range(n):
        for x in range(n):
            r = g = b = a = 0.0
            for dy in range(f):
                for dx in range(f):
                    pr, pg, pb, pa = cv[y*f+dy][x*f+dx]
                    r += pr*pa; g += pg*pa; b += pb*pa; a += pa
            out[y][x] = (0.0, 0.0, 0.0, 0.0) if a <= 0 else (r/a, g/a, b/a, a/(f*f))
    return out

def write_png(path, cv):
    n = len(cv)
    rows = []
    for row in cv:
        data = bytearray()
        for px in row:
            data += struct.pack('BBBB', int(px[0]+.5), int(px[1]+.5), int(px[2]+.5), int(px[3]+.5))
        rows.append(b'\x00' + bytes(data))
    raw = b''.join(rows)
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag+data) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    open(path, 'wb').write(png)

def clamp01(v):
    return 0.0 if v < 0 else (1.0 if v > 1 else v)

def sd_round_rect(px, py, x0, y0, x1, y1, r):
    cx = (x0+x1)/2.0; cy = (y0+y1)/2.0
    hx = (x1-x0)/2.0 - r; hy = (y1-y0)/2.0 - r
    dx = abs(px-cx) - hx; dy = abs(py-cy) - hy
    return math.hypot(max(dx,0.0), max(dy,0.0)) + min(max(dx,dy), 0.0) - r

def sd_segment(px, py, ax, ay, bx, by):
    vx, vy = bx-ax, by-ay
    wx, wy = px-ax, py-ay
    L = vx*vx + vy*vy
    t = 0.0 if L == 0 else max(0.0, min(1.0, (wx*vx+wy*vy)/L))
    return math.hypot(px-(ax+t*vx), py-(ay+t*vy))

cov_cache = []
def paint(cv, bbox, fn, color):
    n = len(cv)
    x0 = max(0, int(bbox[0])); y0 = max(0, int(bbox[1]))
    x1 = min(n, int(math.ceil(bbox[2])) + 1); y1 = min(n, int(math.ceil(bbox[3])) + 1)
    for y in range(y0, y1):
        row = cv[y]
        py = y + 0.5
        for x in range(x0, x1):
            c = fn(x + 0.5, py)
            if c > 0:
                row[x] = blend(row[x], color, c)

def rect_cov(x0, y0, x1, y1, r):
    return lambda x, y: clamp01(0.5 - sd_round_rect(x, y, x0, y0, x1, y1, r))

def cap_cov(ax, ay, bx, by, r):
    return lambda x, y: clamp01(0.5 - (sd_segment(x, y, ax, ay, bx, by) - r))

def cov_poly(px, py, pts):
    def inside(x, y):
        res = False
        n = len(pts); j = n - 1
        for i in range(n):
            xi, yi = pts[i]; xj, yj = pts[j]
            if ((yi > y) != (yj > y)) and (x < (xj-xi)*(y-yi)/(yj-yi) + xi):
                res = not res
            j = i
        return res
    hits = 0
    for sy in (-0.375, -0.125, 0.125, 0.375):
        for sx in (-0.375, -0.125, 0.125, 0.375):
            if inside(px+sx, py+sy):
                hits += 1
    return hits / 16.0

def poly_cov(pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys)), (lambda x, y: cov_poly(x, y, pts))

def halfplane_cov(nx, ny, c):
    """nx*x + ny*y <= c 的半平面。用于折角斜边。"""
    return lambda x, y: clamp01(0.5 - (nx*x + ny*y - c) / math.hypot(nx, ny))

def draw_mark(cv, S, fill_ratio):
    """白纸居中 + 三行字线（末行蓝）+ 一支笔压在蓝行尾端。

    构图锚点是纸的中心（用户明确要求纸条居中）：纸是视觉重的实心块，
    笔是细线，笔向右上伸出用轻元素平衡。无折角 —— 元素越少 48dp 越精神。
    """
    px0, py0, px1, py1 = 30.0, 22.0, 78.0, 86.0   # 纸，中心 (54,54)
    bx0, by0, bx1, by1 = 28.0, 20.0, 88.0, 88.0   # 只用于算缩放
    span = max(bx1 - bx0, by1 - by0)
    k = S * fill_ratio / span
    def X(v): return S / 2.0 + (v - 54.0) * k
    def Y(v): return S / 2.0 + (v - 54.0) * k

    # 纸
    paint(cv, (X(px0)-2, Y(py0)-2, X(px1)+2, Y(py1)+2),
          rect_cov(X(px0), Y(py0), X(px1), Y(py1), 6.0*k), WHITE)

    # 写好的两行
    for (xa, xb, yy) in ((38, 62, 36), (38, 53, 48)):
        paint(cv, (X(xa)-6, Y(yy)-6, X(xb)+6, Y(yy)+6),
              cap_cov(X(xa), Y(yy), X(xb), Y(yy), 2.1*k), INK)

    # 正在写的一行：笔尖接在它右端
    paint(cv, (X(38)-6, Y(61)-6, X(52)+6, Y(61)+6),
          cap_cov(X(38), Y(61), X(52), Y(61), 2.1*k), BLUE)

    tail = (85.0, 25.0)
    tip  = (54.0, 61.5)
    r = 3.2 * k
    ax, ay = X(tail[0]), Y(tail[1])
    bx, by = X(tip[0]), Y(tip[1])
    ang = math.atan2(by - ay, bx - ax)
    tx, ty = math.cos(ang), math.sin(ang)
    nx, ny = -ty, tx

    def draw_pen(radius, extend, color):
        """圆笔身 + 尖笔头，缝层与本体层同一函数，永远同心。"""
        apx = (bx + tx*extend, by + ty*extend)
        base = (apx[0] - tx*6.5*k, apx[1] - ty*6.5*k)
        tri = [apx,
               (base[0] + nx*radius, base[1] + ny*radius),
               (base[0] - nx*radius, base[1] - ny*radius)]
        xs = [ax, apx[0], base[0]]
        ys = [ay, apx[1], base[1]]
        box = (min(xs) - radius - 2, min(ys) - radius - 2,
               max(xs) + radius + 2, max(ys) + radius + 2)
        # 笔身只画到三角根部：画到 apex 会用圆头把笔尖裹住
        paint(cv, box, cap_cov(ax, ay, base[0], base[1], radius), color)
        paint(cv, (ax - radius, ay - radius, ax + radius, ay + radius),
              cap_cov(ax, ay, ax, ay, radius), color)
        pb, pf = poly_cov(tri)
        paint(cv, (pb[0] - 2, pb[1] - 2, pb[2] + 2, pb[3] + 2), pf, color)

    # ① 底色缝 ② 本体
    draw_pen(r + 1.2*k, 1.2*k, INK)
    draw_pen(r, 0.0, WHITE)

def legacy(size, path):
    n = size * SS
    cv = canvas(n)
    paint(cv, (0, 0, n, n), rect_cov(0, 0, n, n, n*0.225), INK)
    draw_mark(cv, n, 0.66)
    write_png(path, resample(cv, SS))

def foreground(size, path):
    # 注意：adaptive icon 的 foreground 会被系统 mask 裁掉四周 —— 108 画布上
    # 只有中间 72dp（66.7%）的圆形可见。fill_ratio 要按「mask 后占可见区」
    # 折算：0.40 / 0.667 ≈ 60%，落在国内主流 55-62% 区间。
    # 上一轮按 PNG 本身算 0.52（mask 后 ≈78%），用户看到的图标几乎占满，偏大。
    n = size * SS
    cv = canvas(n)
    draw_mark(cv, n, 0.40)
    write_png(path, resample(cv, SS))

base = 'android/app/src/main/res'
for name, mult in (('mdpi',1.0), ('hdpi',1.5), ('xhdpi',2.0), ('xxhdpi',3.0), ('xxxhdpi',4.0)):
    d = os.path.join(base, 'mipmap-' + name)
    os.makedirs(d, exist_ok=True)
    legacy(int(48*mult), os.path.join(d, 'ic_launcher.png'))
    foreground(int(108*mult), os.path.join(d, 'ic_launcher_foreground.png'))
print('icons written')
