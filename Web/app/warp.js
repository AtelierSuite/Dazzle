/**
 * WordArt warps (`a:prstTxWarp`): where the letters of text laid out flat land
 * on the paths the engine sends (`body.warp`), as the Apple apps place them
 * (TextWarpGeometry in the engine). Each band is either two paths, top and
 * bottom, that its lines are stretched between, or one path its lines run
 * along, their letters upright on it and spread from end to end. Points are
 * in the shape's own space; positions in the text are in its laid-out space,
 * its y axis pointing down, and only differences in them matter.
 */

/** A path as the engine sends it, `[x0, y0, x1, y1, …]`, with how far along it each point is. */
function guide(flat) {
  const points = [];
  for (let index = 0; index + 1 < flat.length; index += 2) points.push({ x: flat[index], y: flat[index + 1] });
  const distances = [];
  let total = 0;
  points.forEach((point, index) => {
    if (index > 0) total += Math.hypot(point.x - points[index - 1].x, point.y - points[index - 1].y);
    distances.push(total);
  });
  return { points, distances, length: total };
}

/** The bands of a warp from the scene, with their paths measured. */
export function warpBands(warp) {
  return warp.map((band) => (band.along
    ? { along: guide(band.along), out: Boolean(band.out) }
    : { top: guide(band.top), bottom: guide(band.bottom) }));
}

/** The point `fraction` of the way along a path, and which way it runs there; past either end, straight on. */
export function position(path, fraction) {
  const { points, distances, length } = path;
  if (points.length < 2 || !(length > 0)) return { x: points[0]?.x ?? 0, y: points[0]?.y ?? 0, tx: 1, ty: 0 };
  const distance = fraction * length;
  let low = 0;
  let high = distances.length - 1;
  while (high - low > 1) {
    const middle = (low + high) >> 1;
    if (distances[middle] <= distance) low = middle;
    else high = middle;
  }
  while (low > 0 && distances[low + 1] - distances[low] <= 0) low -= 1;
  const start = points[low];
  const end = points[low + 1];
  const span = distances[low + 1] - distances[low];
  if (!(span > 0)) return { x: start.x, y: start.y, tx: 1, ty: 0 };
  const tx = (end.x - start.x) / span;
  const ty = (end.y - start.y) / span;
  const along = distance - distances[low];
  return { x: start.x + tx * along, y: start.y + ty * along, tx, ty };
}

/** The band line `index` of `count` is laid in: shared out in turn, the earlier bands taking any left over. */
export function bandForLine(bands, index, count) {
  if (!count || !bands.length) return 0;
  return Math.min(Math.floor((index * bands.length) / count), bands.length - 1);
}

/**
 * Where a band's lines lie: their letters reaching from `top` to `bottom`, the
 * first baseline at `baseline`. Letters that would stand out of the box hang
 * from the path by their tops instead.
 */
export function placement(bands, band, top, bottom, baseline) {
  const found = bands[Math.min(Math.max(band, 0), bands.length - 1)];
  return { band, top, height: Math.max(bottom - top, 0.01), baseline: found.along && found.out ? top : baseline };
}

/** Where the point `x` along a line `lineWidth` long, and `y` down the text, lands. */
export function warpPoint(bands, place, x, lineWidth, y) {
  const fraction = lineWidth > 0 ? x / lineWidth : 0.5;
  const band = bands[Math.min(Math.max(place.band, 0), bands.length - 1)];
  if (band.along) {
    // Below the baseline is to the path's right, which is down a path running left to right.
    const at = position(band.along, fraction);
    const below = y - place.baseline;
    return { x: at.x - at.ty * below, y: at.y + at.tx * below };
  }
  const v = place.height > 0 ? (y - place.top) / place.height : 0;
  const upper = position(band.top, fraction);
  const lower = position(band.bottom, fraction);
  return { x: upper.x + (lower.x - upper.x) * v, y: upper.y + (lower.y - upper.y) * v };
}

/**
 * The transform `[a, b, c, d, e, f]` taking a letter, in its own space (its
 * origin on the baseline where it starts, its y axis pointing up), to where it
 * lands: it runs from `start` to `end` along a line `lineWidth` long whose
 * baseline is at `baseline`.
 */
export function letterTransform(bands, place, start, end, lineWidth, baseline, ascent) {
  const band = bands[Math.min(Math.max(place.band, 0), bands.length - 1)];
  if (band.along) {
    // Upright on the path where its middle falls, as wide as it is, shrunk only to fit the line in.
    const width = end - start;
    const scale = lineWidth > band.along.length && lineWidth > 0 ? band.along.length / lineWidth : 1;
    const at = position(band.along, lineWidth > 0 ? (start + width / 2) / lineWidth : 0.5);
    const foot = warpPoint(bands, place, start + width / 2, lineWidth, baseline);
    return [at.tx * scale, at.ty * scale, at.ty * scale, -at.tx * scale,
      foot.x - (at.tx * scale * width) / 2, foot.y - (at.ty * scale * width) / 2];
  }
  const width = Math.max(end - start, 0.01);
  const rise = Math.max(ascent, 0.01);
  const middle = start + width / 2;
  const origin = warpPoint(bands, place, start, lineWidth, baseline);
  const across = warpPoint(bands, place, start + width, lineWidth, baseline);
  const foot = warpPoint(bands, place, middle, lineWidth, baseline);
  const head = warpPoint(bands, place, middle, lineWidth, baseline - rise);
  return [(across.x - origin.x) / width, (across.y - origin.y) / width,
    (head.x - foot.x) / rise, (head.y - foot.y) / rise, origin.x, origin.y];
}
