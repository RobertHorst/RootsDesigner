"""Vectorized Python/NumPy port of RootsProfileApp.m's computational core.

Generates a Roots blower rotor profile and reports the same metrics as the
MATLAB App Designer app's "Results" panel (shaft spacing, lobe geometry,
area efficiency, lambda_r / lambda_w, min/avg mesh gap, max angle deviation
before interference, flow and outlet velocity), then plots the six-angle
rotor mesh figure.

Two profile methods are available:

  'averaged'        The original RootsDesigner construction (paper Eqs 5-6).
                    The generating circle turns at a fixed rate,
                    phi = (2N +/- 1) * theta, and its centre is placed along
                    the radial line at rho3 +/- r_c. This is a fixed-ratio
                    construction: on a noncircular pitch curve the circle
                    slips locally, but the slip averages to zero over each
                    addendum and dedendum. Default; reproduces v0.3 profiles
                    and spline CSVs exactly.

  'noslip'          True rolling without slip. The circle centre is placed
                    along the pitch-curve normal and the circle turns by
                    d(phi) = ds / r_c, where s is arc length along rho3, so
                    r_c = (arc length of rho3) / (4 pi N).

The App Designer UI has no Python equivalent and is not ported here; this
is the math/analysis engine only. See roots_app_qt.py for the GUI.

Usage:
    from roots_profile import roots_profile_script
    r = roots_profile_script()                                   # defaults
    r = roots_profile_script(nodes=4, ex=0.17, offset=1.85)
    r = roots_profile_script(method='noslip', rpm=2000, units='Imperial')
    r = roots_profile_script(ss_or_shelld=130, mode='sd')         # solve ss
    r = roots_profile_script(do_plot=False)                       # numbers only

Or from the command line:
    python3 roots_profile.py
    python3 roots_profile.py --nodes 4 --ex 0.17 --offset 1.85
    python3 roots_profile.py --method noslip --rpm 2000 --units Imperial
    python3 roots_profile.py --mode sd --ss-or-shelld 130
    python3 roots_profile.py --min-gap 2          # solve offset for 2 mm gap
    python3 roots_profile.py --max-angle-dev 3    # solve offset for 3 deg

Geometry inputs and outputs are always in mm. The units setting selects how
flow (CMM for SI, CFM for Imperial) and outlet velocity (m/s for SI, ft/min
for Imperial) are reported.

Copyright 2026, Robert Horst, Horst Tech LLC
"""

import argparse

import numpy as np
from matplotlib.path import Path
from scipy.optimize import brentq, minimize_scalar
from scipy.spatial import cKDTree

CFM_TO_CMM = 0.028316846592          # 1 ft^3/min in m^3/min


class Cancelled(Exception):
    """Raised by solve_offset / design_compute when their cancel() callback
    returns True (used by the GUI to stop a running batch promptly)."""
MPS_TO_FPM = 196.8503937007874       # 1 m/s in ft/min

METHODS = {'averaged': 'Averaged', 'noslip': 'Noslip rolling'}
UNIT_SYSTEMS = ('SI', 'Imperial')


def normalize_method(method):
    """Accept 'averaged' / 'noslip' or their display names."""
    m = str(method).strip().lower().replace('-', '').replace('_', '').replace(' ', '')
    if m.startswith('avg') or m.startswith('averaged'):
        return 'averaged'
    if m.startswith('noslip'):
        return 'noslip'
    raise ValueError(f"Unknown profile method {method!r}; use 'averaged' or 'noslip'.")


def normalize_units(units):
    """Accept 'SI' / 'Imperial' (legacy 'CMM'/'CMH' map to SI, 'CFM' to Imperial)."""
    u = str(units).strip().upper()
    if u in ('SI', 'CMM', 'CMH', 'METRIC'):
        return 'SI'
    if u in ('IMPERIAL', 'CFM', 'US'):
        return 'Imperial'
    raise ValueError(f"Unknown units {units!r}; use 'SI' or 'Imperial'.")


def flow_units(units):
    return 'CMM' if normalize_units(units) == 'SI' else 'CFM'


def velocity_units(units):
    return 'm/s' if normalize_units(units) == 'SI' else 'ft/min'


def flow_from_cmm(q_cmm, units):
    """Convert a flow in m^3/min to the selected unit system (CMM or CFM)."""
    return q_cmm if normalize_units(units) == 'SI' else q_cmm / CFM_TO_CMM


def velocity_from_mps(v_mps, units):
    """Convert a velocity in m/s to the selected unit system (m/s or ft/min)."""
    return v_mps if normalize_units(units) == 'SI' else v_mps * MPS_TO_FPM


def flow_convert(x, units):
    """Legacy helper: convert CFM to 'CMM', 'CMH' or 'CFM'."""
    if units.upper() == 'CMM':
        return x * CFM_TO_CMM
    if units.upper() == 'CMH':
        return x * CFM_TO_CMM * 60
    return x  # already CFM


def pitchcurve(ss, ex, nodes, theta):
    """Noncircular gear pitch curve radius with half-gap correction.

    theta may be a scalar or a NumPy array; the computation is elementwise.
    """
    a = ss / (1 + np.sqrt(1 - ex ** 2))
    cp = a * (1 - ex ** 2)
    rho = cp / (1 - ex * np.cos(nodes * theta))
    other_theta = -theta + np.pi / nodes
    other_rho = cp / (1 - ex * np.cos(nodes * other_theta))
    pitch_gap = ss - rho - other_rho
    rho = rho + pitch_gap / 2
    x = rho * np.cos(theta)
    y = rho * np.sin(theta)
    return x, y, rho


def rotate_shift(points, angle_degrees, displacement):
    """Rotate an (N,2) point array by a scalar angle (degrees), then translate."""
    a = np.deg2rad(angle_degrees)
    cosA, sinA = np.cos(a), np.sin(a)
    R = np.array([[cosA, -sinA], [sinA, cosA]])
    return points @ R.T + displacement


class _GapContext:
    """Nearest-neighbour search structure for one rotor profile.

    Gaps are evaluated in the frame of rotor1: rotor2's vertices are
    transformed into rotor1's own coordinates, so the KD-tree and the
    point-in-polygon path are built once per profile instead of once per
    rotation angle.
    """

    def __init__(self, xyarray):
        self.xy = np.asarray(xyarray, dtype=float)
        self.tree = cKDTree(self.xy)
        self.path = Path(self.xy)


def _rotor2_in_rotor1_frame(ctx, theta1, theta2, ss):
    rotor2 = rotate_shift(ctx.xy, theta2, [ss / 2, 0])
    return rotate_shift(rotor2 - np.array([-ss / 2, 0]), -theta1, [0, 0])


def pair_gap(xyarray, theta1, theta2, ss, ctx=None):
    """Signed clearance between rotor1 held at theta1 and rotor2 held at
    theta2 (shaft centres at -ss/2 and +ss/2).

    Positive: the smallest vertex-to-vertex distance between the rotors.
    Negative: the rotors overlap; the value is minus the penetration depth
    (the largest distance from a vertex of rotor2 lying inside rotor1 to the
    nearest vertex of rotor1).
    """
    if ctx is None:
        ctx = _GapContext(xyarray)
    p = _rotor2_in_rotor1_frame(ctx, theta1, theta2, ss)
    d, _ = ctx.tree.query(p)
    inside = ctx.path.contains_points(p)
    if inside.any():
        return -d[inside].max()
    return d.min()


def find_min_gap(xyarray, nodes, ss, ctx=None):
    """Sweep 360 one-degree positions of the synchronized rotor motion,
    returning the minimum/average clearance and the angle of minimum gap.
    """
    if ctx is None:
        ctx = _GapContext(xyarray)
    starta = 0
    startb = 180 + 180 / nodes

    gaps = np.array([pair_gap(xyarray, starta + i, startb - i, ss, ctx)
                     for i in range(360)])
    i_min = int(np.argmin(gaps))
    gaparray = np.column_stack([np.arange(1, 361), gaps])
    return gaps[i_min], gaps.mean(), gaparray, i_min


def crossing_angle(xyarray, theta1, theta2_0, ss, direction, max_search,
                   tol=1e-3, ctx=None, step=0.25):
    """Smallest deviation angle (0..max_search) by which rotor2 can be
    turned away from theta2_0, with rotor1 held fixed at theta1, before the
    gap first reaches zero (first contact).

    The deviation is stepped outward from 0 in `step`-degree increments and
    the first step that closes the gap is refined by bisection. (Testing
    only the end of the range is not enough: the rotors can pass through
    each other and be clear again at max_search.)
    """
    if ctx is None:
        ctx = _GapContext(xyarray)

    def gap(dev):
        return pair_gap(xyarray, theta1, theta2_0 + direction * dev, ss, ctx)

    if gap(0.0) <= 0:
        return 0.0
    lo = 0.0
    while lo < max_search:
        hi = min(lo + step, max_search)
        if gap(hi) <= 0:
            while (hi - lo) > tol:
                mid = (lo + hi) / 2
                if gap(mid) > 0:
                    lo = mid
                else:
                    hi = mid
            return (lo + hi) / 2
        lo = hi
    # No contact within a half lobe pitch of deviation.
    return max_search


def find_max_angle_deviation(xyarray, nodes, ss, ang, ctx=None, limit=None):
    """At the given synchronized-sweep rotation angle, hold rotor1 fixed and
    find the smallest single-rotor rotation deviation of rotor2 — in either
    direction — that closes the gap to zero. This is the angular play
    (e.g. timing-gear backlash or torsional deflection) the mechanism can
    tolerate at this position before the rotors interfere.

    limit (deg): stop searching at this deviation (the result is then
    `limit`). Used when only a value below an already-known play matters.
    """
    if ctx is None:
        ctx = _GapContext(xyarray)
    starta = 0
    startb = 180 + 180 / nodes
    theta1 = starta + ang
    theta2_0 = startb - ang

    max_search = 180 / nodes  # one half lobe pitch
    if limit is not None:
        max_search = min(max_search, limit)
    dev_pos = crossing_angle(xyarray, theta1, theta2_0, ss, +1, max_search, ctx=ctx)
    dev_neg = crossing_angle(xyarray, theta1, theta2_0, ss, -1, max_search, ctx=ctx)
    return min(dev_pos, dev_neg)


def refine_min_gap_angle(xyarray, nodes, ss, ang_coarse, ctx=None):
    """Bounded refine of the 1-degree-resolution minimum-gap angle found by
    find_min_gap, searching the synchronized sweep motion (both rotors
    turning together) in a +/-1 degree window.
    """
    if ctx is None:
        ctx = _GapContext(xyarray)
    starta = 0
    startb = 180 + 180 / nodes

    def f(a):
        return pair_gap(xyarray, starta + a, startb - a, ss, ctx)

    res = minimize_scalar(f, bounds=(ang_coarse - 1, ang_coarse + 1),
                           method='bounded')
    return res.x


def gap_metrics(xyarray, nodes, ss, angle=True):
    """(min_gap, avg_gap, max_angle_dev) for a rotor pair. With
    angle=False the (slower) max angle deviation is skipped and NaN."""
    ctx = _GapContext(xyarray)
    min_gap, avg_gap, gaparray, ang_at_min = find_min_gap(xyarray, nodes, ss, ctx)
    if not angle:
        return min_gap, avg_gap, float('nan')
    # The play is checked at every distinct close approach of the rotors
    # over the rotation, not only at the overall minimum gap: the tightest
    # angular play can be at a different position, and using only the
    # overall minimum makes the value jump when that position moves.
    seg = np.hypot(*np.diff(xyarray, axis=0).T)
    cand = close_approach_angles(gaparray[:, 1], nodes, 0.02 * np.median(seg))
    dev = np.inf
    for i in cand:
        ang_refined = refine_min_gap_angle(xyarray, nodes, ss, i, ctx)
        dev = min(dev, find_max_angle_deviation(xyarray, nodes, ss,
                                                ang_refined, ctx, limit=dev))
    return min_gap, avg_gap, dev


def close_approach_angles(gaps, nodes, tol):
    """Sweep angles (deg) of the distinct close approaches in a 1-degree gap
    sweep (gaps[i] is the gap at sweep angle i), tightest first.

    A close approach is a local minimum of the gap. Two kinds of local
    minima are dropped, because checking them repeats work without
    changing the result:

      * ripples: minima that rise less than `tol` before the gap falls
        lower again. These come from the polygon discretization; on a
        near-uniform gap (e.g. ex = 0) there are dozens of them.
      * symmetric repeats: the mesh repeats every 360/N degrees of sweep
        (one lobe pitch), and mirroring it about the line of centres maps
        sweep angle a to -a, so a minimum at a has twins at +/-a + k*360/N
        with the same gap and the same play. Only one of each set is
        checked. (The half-pitch repeat, a + 180/N, swaps the roles of the
        two rotors, which changes the play, so it is not folded.)

    The overall minimum is always kept.
    """
    gaps = np.asarray(gaps, dtype=float)
    n = gaps.size
    i_min = int(np.argmin(gaps))
    is_min = (gaps <= np.roll(gaps, 1)) & (gaps <= np.roll(gaps, -1))

    def rise(i, step):
        # Largest rise above gaps[i] before the gap falls below gaps[i].
        top = gaps[i]
        for k in range(1, n):
            g = gaps[(i + step * k) % n]
            if g < gaps[i]:
                return top - gaps[i]
            top = max(top, g)
        return np.inf

    cand = [i for i in np.flatnonzero(is_min)
            if i == i_min or min(rise(i, -1), rise(i, +1)) > tol]
    cand.sort(key=lambda i: gaps[i])

    period = 360.0 / nodes
    kept, folded = [], []
    for i in cand:
        a = i % period
        a = min(a, period - a)
        if all(abs(a - b) > 1.0 for b in folded):
            kept.append(int(i))
            folded.append(a)
    return kept


def _rolling_radius_averaged(nodes, ex, ss):
    """Rolling-circle radius used by the 'averaged' method (unchanged from v0.3).

    r_c = L / (4 pi N), where L is the arc length of the conjugate curve
    ss - rho(theta + pi/N) of the uncorrected base gear (paper Eq 2 applied
    to the Eq 1 gear). Kept as-is so that existing profiles reproduce exactly.
    Also returns that curve's max/min radius for the legacy gear lambda.
    """
    a = ss / (1 + np.sqrt(1 - ex ** 2))
    num_pts = 10000
    theta = np.linspace(0, 2 * np.pi, num_pts)
    cp = a * (1 - ex ** 2)
    rho = cp / (1 - ex * np.cos(nodes * theta))
    other_theta = -theta + np.pi / nodes
    other_rho = cp / (1 - ex * np.cos(nodes * other_theta))
    rho = ss - other_rho  # full correction
    x = rho * np.cos(theta)
    y = rho * np.sin(theta)
    circumference = np.sum(np.hypot(np.diff(x), np.diff(y)))
    return circumference / (4 * nodes * np.pi), rho.max(), rho.min()


def _raw_profile_averaged(nodes, ex, ss, points):
    """Paper Eqs 5-6: fixed-ratio construction, centre on the radial line."""
    r, _, _ = _rolling_radius_averaged(nodes, ex, ss)
    p = np.arange(1, points + 1)
    th = (p - 1) * (2 * np.pi / points)
    _, _, rhoP = pitchcurve(ss, ex, nodes, th)

    span = (points + 1) / (nodes * 2)
    halfspan = (points + 1) / (nodes * 4)
    dedend = np.floor((p + halfspan) / span).astype(int) % 2

    # Addendum (dedend == 0): circle outside the pitch curve
    phi_add = th * (2 * nodes + 1)
    Mx_add = (rhoP + r) * np.cos(th) + r * np.cos(phi_add)
    My_add = (rhoP + r) * np.sin(th) + r * np.sin(phi_add)

    # Dedendum (dedend == 1): circle inside the pitch curve
    phi_ded = -th * (2 * nodes - 1)
    Mx_ded = (rhoP - r) * np.cos(th) - r * np.cos(phi_ded)
    My_ded = (rhoP - r) * np.sin(th) - r * np.sin(phi_ded)

    is_add = dedend == 0
    xy = np.column_stack([np.where(is_add, Mx_add, Mx_ded),
                          np.where(is_add, My_add, My_ded)])
    return xy, r


def _raw_profile_noslip(nodes, ex, ss, points, dense=200000):
    """True rolling without slip of a circle on the rho3 pitch curve.

    The circle centre lies on the pitch-curve normal at the contact point and
    the circle turns by d(phi) = ds / r_c (outside, addendum) or -ds / r_c
    (inside, dedendum) relative to the local normal. Closure with 2N arcs of
    one full turn each forces r_c = L / (4 pi N), L = arc length of rho3.
    Output points are uniformly spaced in pitch-curve arc length, starting
    on the +x axis (lobe tip) and running counter-clockwise.
    """
    th = np.linspace(0, 2 * np.pi, dense + 1)
    _, _, rho = pitchcurve(ss, ex, nodes, th)
    C = rho * np.exp(1j * th)
    s = np.concatenate([[0.0], np.cumsum(np.abs(np.diff(C)))])
    L = s[-1]
    r = L / (4 * np.pi * nodes)

    dC = np.gradient(C, th)
    nu = np.unwrap(np.angle(dC)) - np.pi / 2       # outward normal angle

    su = np.arange(points) * L / points
    Cs = np.interp(su, s, C.real) + 1j * np.interp(su, s, C.imag)
    nus = np.interp(su, s, nu)
    n_hat = np.exp(1j * nus)

    seg = L / (2 * nodes)                          # one addendum or dedendum arc = 2 pi r
    k = np.floor((su + seg / 2) / seg).astype(int)
    sc = k * seg                                   # arc-length centre of the segment
    is_add = (k % 2) == 0
    psi = np.where(is_add, nus + (su - sc) / r, nus + np.pi - (su - sc) / r)
    P = np.where(is_add, Cs + r * n_hat, Cs - r * n_hat) + r * np.exp(1j * psi)
    return np.column_stack([P.real, P.imag]), r


def _offset_pointwise(xy0, offset):
    """Shift each point by `offset` along the inward normal estimated from its
    neighbours (unchanged from v0.3)."""
    n = xy0.shape[0]
    idx = np.arange(n)
    prev = (idx - 1) % n
    nxt = (idx + 1) % n
    ddx = xy0[nxt, 0] - xy0[prev, 0]
    ddy = xy0[nxt, 1] - xy0[prev, 1]
    xi = np.pi / 2 + np.arctan2(ddy, ddx)
    return np.column_stack([xy0[:, 0] + offset * np.cos(xi),
                            xy0[:, 1] + offset * np.sin(xi)])


def _segment_crossings(xy, k):
    """For an open list of closed-polygon vertices, test every segment i
    against segment i+k (mod n). Returns (i, t, u) for proper crossings."""
    n = xy.shape[0]
    P = xy
    Q = np.roll(xy, -1, axis=0)
    i = np.arange(n)
    j = (i + k) % n
    d1 = Q[i] - P[i]
    d2 = Q[j] - P[j]
    w = P[j] - P[i]
    den = d1[:, 0] * d2[:, 1] - d1[:, 1] * d2[:, 0]
    with np.errstate(divide='ignore', invalid='ignore'):
        t = (w[:, 0] * d2[:, 1] - w[:, 1] * d2[:, 0]) / den
        u = (w[:, 0] * d1[:, 1] - w[:, 1] * d1[:, 0]) / den
    hit = (den != 0) & (t > 0) & (t < 1) & (u > 0) & (u < 1)
    return i[hit], t[hit]


def _remove_offset_loops(xy, max_span):
    """Trim the small swallow-tail loops that an inward offset creates where the
    profile's radius of curvature is smaller than the offset (e.g. at the
    cusps of an epicycloid/hypocycloid profile). A loop is a pair of
    segments i, i+k (2 <= k <= max_span) that cross; the points between them
    are replaced by the crossing point. Profiles without loops are returned
    unchanged."""
    xy = xy.copy()
    for _ in range(10000):
        n = xy.shape[0]
        best = None
        for k in range(min(max_span, n // 2), 1, -1):
            ii, tt = _segment_crossings(xy, k)
            if ii.size:
                best = (int(ii[0]), k, float(tt[0]))
                break
        if best is None:
            return xy
        i, k, t = best
        X = xy[i] + t * (xy[(i + 1) % n] - xy[i])
        keep = np.ones(n, dtype=bool)
        keep[(i + 1 + np.arange(k)) % n] = False
        # insert the crossing point where the loop was
        pos = int(np.count_nonzero(keep[:(i + 1) % n])) if (i + 1) % n else 0
        xy = np.insert(xy[keep], pos, X, axis=0)
    return xy


def _profile_is_simple(xy):
    """True when the closed profile has no remaining self-intersections."""
    n = xy.shape[0]
    for k in range(2, n - 1):
        ii, _ = _segment_crossings(xy, k)
        if ii.size:
            return False
    return True


def _start_at_tip(xy):
    """Rotate the point list so it starts at the lobe tip on the +x axis."""
    ang = np.abs(np.arctan2(xy[:, 1], xy[:, 0]))
    r = np.hypot(xy[:, 0], xy[:, 1])
    score = ang + (r < 0.5 * r.max()) * 10.0
    return np.roll(xy, -int(np.argmin(score)), axis=0)


def _generate_profile(nodes, ex, offset, ss, points, method='averaged'):
    """Generate the offset rotor profile. Returns (xy, gear_xy, r_c), with xy and
    gear_xy closed (first point repeated at the end)."""
    method = normalize_method(method)
    if method == 'noslip':
        xy0, r = _raw_profile_noslip(nodes, ex, ss, points)
    else:
        xy0, r = _raw_profile_averaged(nodes, ex, ss, points)

    xy = _offset_pointwise(xy0, offset)
    xy = _remove_offset_loops(xy, max_span=max(4, points // (4 * nodes)))
    xy = _start_at_tip(xy)
    xy = np.vstack([xy, xy[:1]])

    th = np.arange(points) * (2 * np.pi / points)
    gx, gy, _ = pitchcurve(ss, ex, nodes, th)
    gear_xy = np.vstack([np.column_stack([gx, gy]), [[gx[0], gy[0]]]])
    return xy, gear_xy, r


def _min_lobe_width(xyarray, points=None):
    """Port of the App's scan-based minimum lobe width (walks the y-column
    from the lobe tip looking for the first local max followed by a local
    min).
    """
    y = xyarray[:, 1]
    n = len(y) - 1
    lobe_w = 0.0
    p = 1  # 0-indexed equivalent of MATLAB's p = 2
    while p < n and y[p] >= y[p - 1]:
        p += 1
    if p < n:
        lobe_w = y[p]
        p += 1
    while p < n and y[p] <= lobe_w:
        lobe_w = y[p]
        p += 1
    return lobe_w * 2


def roots_compute(nodes, ex, offset, rotor_H, shellgap, ss, points,
                  method='averaged', rpm=1000.0, outlet_d=51.0):
    """Core Roots profile computation (no plotting).

    All lengths in mm. Flows are returned in m^3/min (CMM) for the given RPM,
    plus CFM keys for backward compatibility. outlet_d is the diameter (mm) of
    the discharge opening used to convert net flow to a mean outlet velocity
    (m/s); pass 0 or None to skip it.
    """
    method = normalize_method(method)
    xyarray, gear_xy, r = _generate_profile(nodes, ex, offset, ss, points, method)

    lobe_w = _min_lobe_width(xyarray)
    radii = np.hypot(xyarray[:, 0], xyarray[:, 1])
    lobe_rmax = radii.max()            # measured from the profile
    lobe_rmin = radii.min()
    lambda_r = lobe_rmin / lobe_rmax
    lambda_w = lobe_w / lobe_rmax

    # --- Area efficiency --------------------------------------------------
    shell_area = np.pi * lobe_rmax ** 2
    rotor_area = 0.5 * np.abs(np.dot(xyarray[:-1, 0], xyarray[1:, 1]) -
                               np.dot(xyarray[1:, 0], xyarray[:-1, 1]))
    air_area = shell_area - rotor_area
    area_eff = air_area / shell_area
    shell_d = 2 * (lobe_rmax + shellgap)

    # --- Gaps ---------------------------------------------------------------
    min_gap, avg_gap, max_angle_dev = gap_metrics(xyarray, nodes, ss)
    valid = _profile_is_simple(xyarray[:-1])
    # Interference: the lobes overlap somewhere in the rotation, or the
    # offset profile crosses itself. Gap, angle and flow values are then
    # meaningless and are reported as 0 (raw values kept under *_raw).
    interfere = bool(min_gap <= 0 or not valid)

    # --- Flow at the given RPM (m^3/min) -------------------------------------
    vol_mm3 = 2 * air_area * rotor_H                                   # both rotors, per rev
    gap_area = avg_gap * 2 * np.pi * ((lobe_rmax + lobe_rmin) / 2)      # avg gap x circumference
    vol_loss_mm3 = gap_area * rotor_H
    CMM_max = vol_mm3 * 1e-9 * rpm
    CMM_loss = vol_loss_mm3 * 1e-9 * rpm
    CMM_net = CMM_max - CMM_loss

    if outlet_d:
        outlet_area_m2 = np.pi * (outlet_d * 1e-3) ** 2 / 4
        velocity_mps = (CMM_net / 60.0) / outlet_area_m2
    else:
        velocity_mps = float('nan')

    raw = {'min_gap_raw': min_gap, 'avg_gap_raw': avg_gap,
           'max_angle_dev_raw': max_angle_dev}
    if interfere:
        min_gap = avg_gap = max_angle_dev = 0.0
        CMM_max = CMM_loss = CMM_net = velocity_mps = 0.0

    return {
        'offset': offset, 'ss': ss, 'interfere': interfere, **raw,
        'method': method, 'r_c': r, 'rpm': rpm, 'outlet_d': outlet_d,
        'lobe_rmax': lobe_rmax, 'lobe_rmin': lobe_rmin, 'lobe_w': lobe_w,
        'lambda_r': lambda_r, 'lambda_w': lambda_w,
        'shell_d': shell_d, 'area_eff': area_eff,
        'CMM_max': CMM_max, 'CMM_loss': CMM_loss, 'CMM_net': CMM_net,
        'CFM_loss': CMM_loss / CFM_TO_CMM, 'CFM_net': CMM_net / CFM_TO_CMM,
        'velocity_mps': velocity_mps,
        'min_gap': min_gap, 'avg_gap': avg_gap,
        'max_angle_dev': max_angle_dev,
        'valid': valid,
        'xy': xyarray, 'gear_xy': gear_xy,
    }


def lobe_rmax_from_ss(nodes, ex, offset, ss, points, method='averaged'):
    """Profile-measured lobe_rmax for a given ss (no gap analysis).
    Used by the shell-diameter solver in roots_profile_script and the GUI.
    """
    xy, _, _ = _generate_profile(nodes, ex, offset, ss, points, method)
    return np.hypot(xy[:, 0], xy[:, 1]).max()


def solve_ss_for_shell_d(nodes, ex, offset, shellgap, shell_d_target, points,
                         method='averaged'):
    """Shaft spacing that gives the target shell (housing) diameter."""
    target_rmax = shell_d_target / 2 - shellgap
    if target_rmax <= 0:
        raise ValueError('Shell diameter too small for shell gap.')

    def f(ss_val):
        return lobe_rmax_from_ss(nodes, ex, offset, ss_val, points, method) - target_rmax

    ss_lo = max(2 * offset + 1, 5)
    ss_hi = shell_d_target * 2
    return brentq(f, ss_lo, ss_hi, xtol=1e-6)


# ---------------------------------------------------------------------------
#  Design input: Offset, Min Gap or Max Angle Dev
# ---------------------------------------------------------------------------
INPUT_KINDS = {
    'offset': ('Offset', 'mm'),
    'min_gap': ('Min Gap', 'mm'),
    'max_angle_dev': ('Max Angle Dev', 'deg'),
}
INPUT_DEFAULTS = {'offset': 2.72, 'min_gap': 2.0, 'max_angle_dev': 3.0}


def normalize_input_kind(kind):
    k = str(kind).strip().lower().replace(' ', '_')
    aliases = {'gap': 'min_gap', 'mingap': 'min_gap', 'angle': 'max_angle_dev',
               'max_angle': 'max_angle_dev', 'maxangledev': 'max_angle_dev'}
    k = aliases.get(k, k)
    if k not in INPUT_KINDS:
        raise ValueError(f"input must be one of {list(INPUT_KINDS)}, got {kind!r}")
    return k


def _ss_for(nodes, ex, offset, shellgap, mode, ss_or_shelld, points, method):
    if mode == 'sd':
        return solve_ss_for_shell_d(nodes, ex, offset, shellgap, ss_or_shelld,
                                    points, method)
    return ss_or_shelld


def solve_offset(nodes, ex, input_kind, target, shellgap, mode, ss_or_shelld,
                 points, method='averaged', xtol=1e-3, cancel=None):
    """Offset (and shaft spacing) that gives the target Min Gap (mm) or
    Max Angle Dev (deg).

    The smallest offset that reaches the target is found: the bracket is
    grown from a first guess, then refined by bisection. In Set Shell
    Diameter mode the shaft spacing is re-solved for every trial offset.
    Returns (offset, ss, note); note is None, or explains why the achieved
    value is above the target (the value jumps past it).
    cancel: optional callable; when it returns True, Cancelled is raised
    before the next trial offset is evaluated.
    """
    kind = normalize_input_kind(input_kind)
    mode = 'sd' if str(mode).lower() == 'sd' else 'ss'
    if kind == 'offset':
        return target, _ss_for(nodes, ex, target, shellgap, mode,
                               ss_or_shelld, points, method), None
    if target <= 0:
        raise ValueError(f"{INPUT_KINDS[kind][0]} must be greater than 0.")
    if kind == 'max_angle_dev' and target >= 180 / nodes:
        raise ValueError(f"Max Angle Dev must be less than half a lobe pitch "
                         f"({180 / nodes:g} deg for {nodes} lobes).")

    label, unit = INPUT_KINDS[kind]
    cache = {}
    best = {'val': -np.inf, 'off': None}

    def f(off):
        """Achieved value minus target (negative: not reached). A profile
        that crosses itself, or fails to generate, counts as not reached
        and is marked so the bracket search can look below it."""
        if off not in cache:
            if cancel is not None and cancel():
                raise Cancelled()
            try:
                ss = _ss_for(nodes, ex, off, shellgap, mode, ss_or_shelld,
                             points, method)
                xy, _, _ = _generate_profile(nodes, ex, off, ss, points, method)
            except Exception:       # noqa: BLE001 — treated as unusable offset
                cache[off] = (-target, None, 'error')
                return cache[off][0]
            if not _profile_is_simple(xy[:-1]):
                cache[off] = (-target, ss, 'crossed')
                return cache[off][0]
            g, _, ang = gap_metrics(xy, nodes, ss, angle=(kind != 'min_gap'))
            achieved = max(g, 0.0) if kind == 'min_gap' else (ang if g > 0 else 0.0)
            cache[off] = (achieved - target, ss, 'ok')
            if achieved > best['val']:
                best.update(val=achieved, off=off)
        return cache[off][0]

    def usable(off):
        return cache[off][2] == 'ok'

    def unreachable():
        msg = f"{label} of {target:g} {unit} cannot be reached"
        if best['off'] is not None and best['val'] > 0:
            msg += (f"; the largest found is {best['val']:.3g} {unit} "
                    f"(offset {best['off']:.3g} mm)")
        return ValueError(msg + ".")

    size = ss_or_shelld if mode == 'ss' else ss_or_shelld / 2
    off_max = 0.45 * size
    a = target / 2 if kind == 'min_gap' else 1.0
    a = min(max(a, 0.01), off_max)
    fa = f(a)
    if fa < 0:
        b = a
        while True:
            b_next = min(b * 1.5, off_max)
            fb = f(b_next)
            if fb >= 0:
                b = b_next
                break
            if not usable(b_next) and usable(b):
                # The profile breaks down somewhere between b and b_next:
                # the target may still be reached just below that point.
                found = False
                for c in np.linspace(b, b_next, 9)[1:-1]:
                    fc = f(c)
                    if fc >= 0:
                        found = True
                        break
                    if usable(c):
                        a, fa = c, fc
                if found:
                    b, fb = c, fc
                    break
                raise unreachable()
            if b_next >= off_max:
                raise unreachable()
            a, fa = b_next, fb
            b = b_next
    else:
        b, fb = a, fa
        while True:
            a = a / 1.5
            fa = f(a)
            if fa < 0:
                break
            if a < 1e-3:
                return a, cache[a][1], None
            b, fb = a, fa

    # Bisection keeps f(a) < 0 <= f(b), so the result always reaches the
    # target, even where the value jumps (e.g. Max Angle Dev, which is
    # measured at the minimum-gap position and can jump when that moves).
    while b - a > xtol:
        c = 0.5 * (a + b)
        if f(c) < 0:
            a = c
        else:
            b = c
    note = None
    achieved = cache[b][0] + target
    if achieved - target > max(0.02 * target, 0.01):
        below = cache[a][0] + target
        note = (f"{label} jumps from {below:.3g} to {achieved:.3g} {unit} near "
                f"offset {b:.3f} mm, so exactly {target:g} {unit} cannot be "
                f"reached; the next larger value is used.")
    return b, cache[b][1], note


def design_compute(nodes, ex, input_kind, input_value, rotor_H, shellgap,
                   mode, ss_or_shelld, points, method='averaged', rpm=1000.0,
                   outlet_d=51.0, cancel=None):
    """Solve the offset and shaft spacing for the chosen inputs, then run
    roots_compute. mode 'ss': ss_or_shelld is the shaft spacing; 'sd': it is
    the shell diameter. input_kind: 'offset', 'min_gap' or 'max_angle_dev'.
    """
    kind = normalize_input_kind(input_kind)
    offset, ss, note = solve_offset(nodes, ex, kind, input_value, shellgap,
                                    mode, ss_or_shelld, points, method,
                                    cancel=cancel)
    if cancel is not None and cancel():
        raise Cancelled()
    r = roots_compute(nodes, ex, offset, rotor_H, shellgap, ss, points,
                      method=method, rpm=rpm, outlet_d=outlet_d)
    r.update({'nodes': nodes, 'ex': ex, 'input_kind': kind,
              'input_value': input_value, 'mode': mode, 'solve_note': note})
    return r


def plot_profiles(xy, nodes, ss):
    """Six-panel rotor mesh figure, matching the app's plotProfiles method."""
    import matplotlib.pyplot as plt

    starta = 0
    startb = 180 + 180 / nodes
    ang_delta = (180 / nodes) / 5

    fig, axes = plt.subplots(2, 3, figsize=(11, 7))
    fig.canvas.manager.set_window_title('Roots Profile — Rotor Mesh at 6 Angles')
    maxR = np.max(np.abs(xy)) + ss / 2 + 10

    for idx, ax in enumerate(axes.flat):
        ang = idx * ang_delta
        r1 = rotate_shift(xy, starta + ang, [-ss / 2, 0])
        r2 = rotate_shift(xy, startb - ang, [ss / 2, 0])

        ax.plot(r1[:, 0], r1[:, 1], '-', color=(0.15, 0.35, 0.70), linewidth=1.2)
        ax.plot(r2[:, 0], r2[:, 1], '-', color=(0.75, 0.22, 0.17), linewidth=1.2)

        ax.set_aspect('equal')
        ax.set_xlim(-maxR, maxR)
        ax.set_ylim(-maxR * 0.70, maxR * 0.70)
        ax.set_title(f'{ang:.1f} deg')
        ax.grid(True, alpha=0.3)

    fig.tight_layout()
    return fig


def format_results(r, ss, units='SI', input_kind='offset', mode='ss'):
    """Rows for the Results panel / console report, grouped in three
    sections. Each row is (name, value, style); style is 'header' (section
    title, value ''), 'normal', 'solved' (an output the program solved for
    from the chosen inputs), or 'bad' (interfering lobes: value shown as 0).
    Net flow is the last row.
    """
    units = normalize_units(units)
    kind = normalize_input_kind(input_kind)
    fu, vu = flow_units(units), velocity_units(units)
    fl = flow_from_cmm(r['CMM_loss'], units)
    fn = flow_from_cmm(r['CMM_net'], units)
    v = velocity_from_mps(r['velocity_mps'], units)
    vfmt = f"{v:.2f} {vu}" if units == 'SI' else f"{v:.0f} {vu}"
    bad = 'bad' if r.get('interfere') else 'normal'
    off_style = 'solved' if kind != 'offset' else 'normal'
    ss_style = 'solved' if str(mode).lower() == 'sd' else 'normal'
    rows = [
        ('Gaps and Angles', '', 'header'),
        ('Offset', f"{r['offset']:.3f} mm", off_style),
        ('Min Gap', f"{r['min_gap']:.2f} mm", bad),
        ('Avg Gap', f"{r['avg_gap']:.2f} mm", bad),
        ('Max Angle Dev', f"{r['max_angle_dev']:.3f} deg", bad),
        ('Lobe and Shell Geometry', '', 'header'),
        ('Shaft Spacing', f"{ss:.2f} mm", ss_style),
        ('Shell Diameter', f"{r['shell_d']:.1f} mm", 'normal'),
        ('Lobe Rmax', f"{r['lobe_rmax']:.1f} mm", 'normal'),
        ('Lobe Rmin', f"{r['lobe_rmin']:.1f} mm", 'normal'),
        ('Lobe Width', f"{r['lobe_w']:.1f} mm", 'normal'),
        ('Lambda r / w', f"{r['lambda_r']:.3f} / {r['lambda_w']:.3f}", 'normal'),
        ('Area Efficiency', f"{r['area_eff']:.3f}", 'normal'),
        (f"Airflow @ {r['rpm']:g} RPM", '', 'header'),
        ('Outlet Velocity', vfmt, bad),
        ('Flow Loss', f"{fl:.3f} {fu}", bad),
        ('Flow Net', f"{fn:.3f} {fu}", bad),
    ]
    if r.get('solve_note'):
        # The solved-for value missed its target (it jumps past it): red.
        k = {'min_gap': 2, 'max_angle_dev': 4}[kind]
        rows[k] = rows[k][:2] + ('bad',)
    return rows


def roots_profile_script(nodes=3, ex=0.245, offset=2.72, rotor_H=100,
                          shellgap=2, ss_or_shelld=80.4, points=1001,
                          units='SI', mode='ss', do_plot=True,
                          method='averaged', rpm=1000.0, outlet_d=51.0,
                          input_kind='offset', input_value=None):
    """Compute a Roots blower rotor profile and report the same metrics as
    the App "Results" panel, then optionally plot the six-angle rotor mesh
    figure.

    mode:   'ss' (default) — ss_or_shelld is the shaft spacing (mm).
            'sd' — ss_or_shelld is the target shell diameter (mm); shaft
                   spacing is solved for, as in the app's
                   "Set Shell Diameter" mode.
    input_kind: 'offset' (default; uses offset), 'min_gap' (mm) or
            'max_angle_dev' (deg); for the last two the offset is solved
            for to give input_value.
    method: 'averaged' (default, paper Eqs 5-6) or 'noslip' (true rolling).
    units:  'SI' (flow in CMM, velocity in m/s) or 'Imperial' (CFM, ft/min).
    rpm:    rotor speed used for flow and velocity.
    outlet_d: discharge opening diameter (mm) for the outlet velocity.
    """
    method = normalize_method(method)
    units = normalize_units(units)
    kind = normalize_input_kind(input_kind)
    mode = 'sd' if mode.lower() == 'sd' else 'ss'
    if kind == 'offset' or input_value is None:
        value = offset if kind == 'offset' else INPUT_DEFAULTS[kind]
    else:
        value = input_value

    r = design_compute(nodes, ex, kind, value, rotor_H, shellgap, mode,
                       ss_or_shelld, points, method=method, rpm=rpm,
                       outlet_d=outlet_d)
    ss = r['ss']

    for name, val, style in format_results(r, ss, units, kind, mode):
        if style == 'header':
            print(f"-- {name} --")
        else:
            flag = '   (lobes interfere)' if style == 'bad' else ''
            print(f"  {name:<20} {val}{flag}")

    fig = plot_profiles(r['xy'], nodes, ss) if do_plot else None

    results = dict(r)
    results.update({
        'rotor_H': rotor_H, 'shellgap': shellgap, 'points': points,
        'units': units, 'max_angle_dev_deg': r['max_angle_dev'],
        'flow_loss': flow_from_cmm(r['CMM_loss'], units),
        'flow_net': flow_from_cmm(r['CMM_net'], units),
        'velocity': velocity_from_mps(r['velocity_mps'], units),
        'fig': fig,
    })
    return results


def _build_arg_parser():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--nodes', type=int, default=3)
    p.add_argument('--ex', type=float, default=0.245)
    p.add_argument('--offset', type=float, default=2.72)
    p.add_argument('--min-gap', type=float, default=None, dest='min_gap',
                   help='solve the offset for this minimum gap (mm)')
    p.add_argument('--max-angle-dev', type=float, default=None,
                   dest='max_angle_dev',
                   help='solve the offset for this max angle deviation (deg)')
    p.add_argument('--rotor-h', type=float, default=100, dest='rotor_H')
    p.add_argument('--shellgap', type=float, default=2)
    p.add_argument('--ss-or-shelld', type=float, default=80.4)
    p.add_argument('--points', type=int, default=1001)
    p.add_argument('--method', choices=['averaged', 'noslip'], default='averaged')
    p.add_argument('--rpm', type=float, default=1000)
    p.add_argument('--outlet-d', type=float, default=51.0, dest='outlet_d',
                   help='discharge opening diameter in mm (for outlet velocity)')
    p.add_argument('--units', choices=['SI', 'Imperial'], default='SI')
    p.add_argument('--mode', choices=['ss', 'sd'], default='ss')
    p.add_argument('--no-plot', action='store_true')
    return p


if __name__ == '__main__':
    args = _build_arg_parser().parse_args()
    if args.min_gap is not None:
        kind, value = 'min_gap', args.min_gap
    elif args.max_angle_dev is not None:
        kind, value = 'max_angle_dev', args.max_angle_dev
    else:
        kind, value = 'offset', args.offset
    result = roots_profile_script(
        input_kind=kind, input_value=value,
        nodes=args.nodes, ex=args.ex, offset=args.offset,
        rotor_H=args.rotor_H, shellgap=args.shellgap,
        ss_or_shelld=args.ss_or_shelld, points=args.points,
        units=args.units, mode=args.mode, do_plot=not args.no_plot,
        method=args.method, rpm=args.rpm, outlet_d=args.outlet_d)
    if result['fig'] is not None:
        import matplotlib.pyplot as plt
        plt.show()
