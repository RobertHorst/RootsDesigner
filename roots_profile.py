"""Vectorized Python/NumPy port of RootsProfileApp.m's computational core.

Generates a Roots blower rotor profile and reports the same metrics as the
MATLAB App Designer app's "Results" panel (shaft spacing, lobe geometry,
area efficiency, lambda, min/avg mesh gap, max angle deviation before
interference, and flow), then plots the six-angle rotor mesh figure.

The App Designer UI has no Python equivalent and is not ported here — this
is the math/analysis engine only (matching RootsDesigner/RootsProfileScript.m,
the Octave script-only port).

Usage:
    from roots_profile import roots_profile_script
    r = roots_profile_script()                                   # defaults
    r = roots_profile_script(nodes=4, ex=0.17, offset=1.85)
    r = roots_profile_script(ss_or_shelld=130, mode='sd')         # solve ss
    r = roots_profile_script(do_plot=False)                       # numbers only

Or from the command line:
    python3 roots_profile.py
    python3 roots_profile.py --nodes 4 --ex 0.17 --offset 1.85
    python3 roots_profile.py --mode sd --ss-or-shelld 130

Copyright 2026, Robert Horst, Horst Tech LLC
"""

import argparse

import numpy as np
from matplotlib.path import Path
from scipy.optimize import brentq, minimize_scalar

CFM_TO_CMM = 0.028316846592


def flow_convert(x, units):
    """Convert CFM to the selected units."""
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


def _rotor_gap_matrix(xyarray, theta1, theta2, ss):
    """Signed pairwise-distance matrix between rotor1 (theta1) and rotor2
    (theta2): negative entries mark rotor2 vertices that fall inside rotor1.
    """
    rotor1 = rotate_shift(xyarray, theta1, [-ss / 2, 0])
    rotor2 = rotate_shift(xyarray, theta2, [ss / 2, 0])

    inside = Path(rotor1).contains_points(rotor2)

    dx = rotor1[:, 0][:, None] - rotor2[:, 0][None, :]
    dy = rotor1[:, 1][:, None] - rotor2[:, 1][None, :]
    dist_matrix = np.sqrt(dx ** 2 + dy ** 2)
    dist_matrix[:, inside] *= -1
    return dist_matrix


def pair_gap(xyarray, theta1, theta2, ss):
    """Clearance (signed: negative = overlap) between rotor1 held at theta1
    and rotor2 held at theta2.
    """
    return _rotor_gap_matrix(xyarray, theta1, theta2, ss).min()


def find_min_gap(xyarray, nodes, ss):
    """Sweep 360 one-degree positions of the synchronized rotor motion,
    returning the minimum/average clearance and the angle of minimum gap.
    """
    starta = 0
    startb = 180 + 180 / nodes

    min_gap = np.inf
    ang_at_min = 0
    gap_accum = 0.0
    gaparray = np.zeros((360, 2))

    for i in range(360):
        ang = i
        current_min = _rotor_gap_matrix(
            xyarray, starta + ang, startb - ang, ss).min()

        if current_min < min_gap:
            min_gap = current_min
            ang_at_min = ang
        gaparray[i] = [i + 1, current_min]
        gap_accum += current_min

    avg_gap = gap_accum / 360
    return min_gap, avg_gap, gaparray, ang_at_min


def crossing_angle(xyarray, theta1, theta2_0, ss, direction, max_search, tol=1e-3, scan_step=1.0):
    """Bisection for the smallest deviation angle (0..max_search) by which
    rotor2 can be turned away from theta2_0, with rotor1 held fixed at
    theta1, before the gap first reaches zero (interference).

    The gap vs. deviation curve is not monotonic in general — it can dip
    negative and recover before reaching max_search — so checking only the
    endpoint would miss interior interference. Scan outward in scan_step
    increments to find the first bracket containing a sign change, then
    bisect within that bracket.
    """
    lo = 0.0
    hi = None
    n_steps = int(np.ceil(max_search / scan_step))
    for i in range(1, n_steps + 1):
        dev = min(i * scan_step, max_search)
        gap = pair_gap(xyarray, theta1, theta2_0 + direction * dev, ss)
        if gap <= 0:
            hi = dev
            break
        lo = dev
        if dev >= max_search:
            break

    if hi is None:
        # No sign change found anywhere in [0, max_search].
        return max_search

    while (hi - lo) > tol:
        mid = (lo + hi) / 2
        if pair_gap(xyarray, theta1, theta2_0 + direction * mid, ss) > 0:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def find_max_angle_deviation(xyarray, nodes, ss, ang):
    """At the given synchronized-sweep rotation angle, hold rotor1 fixed and
    find the smallest single-rotor rotation deviation of rotor2 — in either
    direction — that closes the gap to zero. This is the angular play
    (e.g. timing-gear backlash or torsional deflection) the mechanism can
    tolerate at this position before the rotors interfere.
    """
    starta = 0
    startb = 180 + 180 / nodes
    theta1 = starta + ang
    theta2_0 = startb - ang

    max_search = 180 / nodes  # one half lobe pitch
    dev_pos = crossing_angle(xyarray, theta1, theta2_0, ss, +1, max_search)
    dev_neg = crossing_angle(xyarray, theta1, theta2_0, ss, -1, max_search)
    return min(dev_pos, dev_neg)


def refine_min_gap_angle(xyarray, nodes, ss, ang_coarse):
    """Bounded refine of the 1-degree-resolution minimum-gap angle found by
    find_min_gap, searching the synchronized sweep motion (both rotors
    turning together) in a +/-1 degree window.
    """
    starta = 0
    startb = 180 + 180 / nodes

    def f(a):
        return pair_gap(xyarray, starta + a, startb - a, ss)

    res = minimize_scalar(f, bounds=(ang_coarse - 1, ang_coarse + 1),
                           method='bounded')
    return res.x


def _generate_profile(nodes, ex, offset, ss, points):
    """Vectorized generation of the rolling-circle rotor profile and the
    supporting pitch-curve geometry. Returns (xy, gear_xy, max_rho, min_rho,
    lamb, r).
    """
    a = ss / (1 + np.sqrt(1 - ex ** 2))

    # --- Circumference & rolling-circle radius (full gap correction) ---
    num_pts = 10000
    theta = np.linspace(0, 2 * np.pi, num_pts)
    cp = a * (1 - ex ** 2)
    rho = cp / (1 - ex * np.cos(nodes * theta))
    other_theta = -theta + np.pi / nodes
    other_rho = cp / (1 - ex * np.cos(nodes * other_theta))
    pitch_gap = ss - rho - other_rho
    rho = rho + pitch_gap  # full correction

    x = rho * np.cos(theta)
    y = rho * np.sin(theta)
    circumference = np.sum(np.hypot(np.diff(x), np.diff(y)))

    max_rho = rho.max()
    min_rho = rho.min()
    lamb = min_rho / max_rho
    r = circumference / (4 * nodes * np.pi)  # rolling circle radius

    # --- Generate profile points (vectorized over p = 1..points) -------
    p = np.arange(1, points + 1)
    th = (p - 1) * (2 * np.pi / points)

    _, _, rhoP = pitchcurve(ss, ex, nodes, th)
    gear_xy = np.column_stack(pitchcurve(ss, ex, nodes, th)[:2])

    span = (points + 1) / (nodes * 2)
    halfspan = (points + 1) / (nodes * 4)
    dedend = np.floor((p + halfspan) / span).astype(int) % 2

    # Addendum (dedend == 0)
    phi_add = th * (2 * nodes + 1)
    Sx_add = (rhoP + r) * np.cos(th)
    Sy_add = (rhoP + r) * np.sin(th)
    Mx_add = Sx_add + r * np.cos(phi_add)
    My_add = Sy_add + r * np.sin(phi_add)

    # Dedendum (dedend == 1)
    phi_ded = -th * (2 * nodes - 1)
    Sx_ded = (rhoP - r) * np.cos(th)
    Sy_ded = (rhoP - r) * np.sin(th)
    Mx_ded = Sx_ded - r * np.cos(phi_ded)
    My_ded = Sy_ded - r * np.sin(phi_ded)

    is_add = dedend == 0
    Mx = np.where(is_add, Mx_add, Mx_ded)
    My = np.where(is_add, My_add, My_ded)

    xyarray0gap = np.zeros((points + 1, 2))
    xyarray0gap[:points, 0] = Mx
    xyarray0gap[:points, 1] = My
    xyarray0gap[points] = xyarray0gap[0]

    gear_xy_full = np.zeros((points + 1, 2))
    gear_xy_full[:points] = gear_xy
    gear_xy_full[points] = gear_xy_full[0]

    # --- Offset shrink (vectorized neighbor-tangent normal) -------------
    idx = np.arange(points)
    prev = (idx - 1) % points
    nxt = (idx + 1) % points
    ddx = xyarray0gap[nxt, 0] - xyarray0gap[prev, 0]
    ddy = xyarray0gap[nxt, 1] - xyarray0gap[prev, 1]
    thtan = np.arctan2(ddy, ddx)
    xi = np.pi / 2 + thtan

    xyarray = np.zeros((points + 1, 2))
    xyarray[:points, 0] = xyarray0gap[:points, 0] + offset * np.cos(xi)
    xyarray[:points, 1] = xyarray0gap[:points, 1] + offset * np.sin(xi)
    xyarray[points] = xyarray[0]

    return xyarray, gear_xy_full, max_rho, min_rho, lamb, r


def _min_lobe_width(xyarray, points):
    """Port of the App's scan-based minimum lobe width (walks the y-column
    looking for the first local max followed by a local min).
    """
    y = xyarray[:, 1]
    lobe_w = 0.0
    p = 1  # 0-indexed equivalent of MATLAB's p = 2
    while p < points and y[p] >= y[p - 1]:
        p += 1
    if p < points:
        lobe_w = y[p]
        p += 1
    while p < points and y[p] <= lobe_w:
        lobe_w = y[p]
        p += 1
    return lobe_w * 2


def roots_compute(nodes, ex, offset, rotor_H, shellgap, ss, points):
    """Core Roots profile computation (no plotting). Returns geometry,
    efficiency, flow and profile arrays.
    """
    xyarray, gear_xy, max_rho, min_rho, lamb, r = _generate_profile(
        nodes, ex, offset, ss, points)

    lobe_w = _min_lobe_width(xyarray, points)

    lobe_rmax = max_rho + 2 * r - offset
    lobe_rmin = min_rho - 2 * r - offset

    # --- Area efficiency --------------------------------------------------
    shell_area = np.pi * lobe_rmax ** 2
    rotor_area = 0.5 * np.abs(np.dot(xyarray[:-1, 0], xyarray[1:, 1]) -
                               np.dot(xyarray[1:, 0], xyarray[:-1, 1]))
    air_area = shell_area - rotor_area
    area_eff = air_area / shell_area
    shell_d = 2 * (lobe_rmax + shellgap)

    # --- Volume & flow at 1000 RPM (CFM) ----------------------------------
    vol_mm3 = air_area * rotor_H
    vol_in3 = vol_mm3 / (25.4 ** 3)
    vol_cuft = 2 * vol_in3 / (12 ** 3)  # 2x for both rotors

    min_gap, avg_gap, _, ang_at_min = find_min_gap(xyarray, nodes, ss)

    # --- Max angle deviation before interference at the tightest gap -----
    ang_refined = refine_min_gap_angle(xyarray, nodes, ss, ang_at_min)
    max_angle_dev = find_max_angle_deviation(xyarray, nodes, ss, ang_refined)

    gap_area = avg_gap * 2 * np.pi * ((lobe_rmax + lobe_rmin) / 2)
    vol_loss_mm3 = gap_area * rotor_H
    vol_loss_in3 = vol_loss_mm3 / (25.4 ** 3)
    vol_loss_cuft = vol_loss_in3 / (12 ** 3)

    CFM_max = vol_cuft * 1000
    CFM_loss = vol_loss_cuft * 1000
    CFM_net = CFM_max - CFM_loss

    return {
        'lobe_rmax': lobe_rmax, 'lobe_rmin': lobe_rmin, 'lobe_w': lobe_w,
        'shell_d': shell_d, 'area_eff': area_eff, 'CFM_loss': CFM_loss,
        'CFM_net': CFM_net, 'min_gap': min_gap, 'avg_gap': avg_gap,
        'lamb': lamb, 'max_angle_dev': max_angle_dev, 'xy': xyarray,
        'gear_xy': gear_xy,
    }


def lobe_rmax_from_ss(nodes, ex, offset, ss, points):
    """Lightweight computation of lobe_rmax for a given ss.
    Used by the fzero-equivalent solver in roots_profile_script (no gap analysis).
    """
    a = ss / (1 + np.sqrt(1 - ex ** 2))

    num_pts = 10000
    theta = np.linspace(0, 2 * np.pi, num_pts)
    cp = a * (1 - ex ** 2)
    rho = cp / (1 - ex * np.cos(nodes * theta))
    other_theta = -theta + np.pi / nodes
    other_rho = cp / (1 - ex * np.cos(nodes * other_theta))
    pitch_gap = ss - rho - other_rho
    rho = rho + pitch_gap  # full correction

    x = rho * np.cos(theta)
    y = rho * np.sin(theta)
    circumference = np.sum(np.hypot(np.diff(x), np.diff(y)))

    max_rho = rho.max()
    r = circumference / (4 * nodes * np.pi)
    return max_rho + 2 * r - offset


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


def roots_profile_script(nodes=3, ex=0.245, offset=2.72, rotor_H=100,
                          shellgap=2, ss_or_shelld=80.4, points=1001,
                          units='CMM', mode='ss', do_plot=True):
    """Compute a Roots blower rotor profile and report the same metrics as
    the App Designer "Results" panel, then optionally plot the six-angle
    rotor mesh figure.

    mode: 'ss' (default) — ss_or_shelld is the shaft spacing (mm).
          'sd' — ss_or_shelld is the target shell diameter (mm); shaft
                 spacing is solved for via brentq, as in the app's
                 "Set Shell Diameter" mode.
    """
    if mode.lower() == 'sd':
        shell_d_target = ss_or_shelld
        target_rmax = shell_d_target / 2 - shellgap
        if target_rmax <= 0:
            raise ValueError('Shell diameter too small for shell gap.')

        def f(ss_val):
            return lobe_rmax_from_ss(nodes, ex, offset, ss_val, points) - target_rmax

        ss_lo = max(2 * offset + 1, 5)
        ss_hi = shell_d_target * 2
        ss = brentq(f, ss_lo, ss_hi)
    else:
        ss = ss_or_shelld

    r = roots_compute(nodes, ex, offset, rotor_H, shellgap, ss, points)

    fl = flow_convert(r['CFM_loss'], units)
    fn = flow_convert(r['CFM_net'], units)

    print(f"{'Shaft Spacing':<16} {ss:10.2f} mm")
    print(f"{'Lobe Rmax':<16} {r['lobe_rmax']:10.1f} mm")
    print(f"{'Lobe Rmin':<16} {r['lobe_rmin']:10.1f} mm")
    print(f"{'Lobe Width':<16} {r['lobe_w']:10.1f} mm")
    print(f"{'Shell Diameter':<16} {r['shell_d']:10.1f} mm")
    print(f"{'Area Efficiency':<16} {r['area_eff']:10.3f}")
    print(f"{'Lambda':<16} {r['lamb']:10.3f}")
    print(f"{'Min Gap':<16} {r['min_gap']:10.2f} mm")
    print(f"{'Avg Gap':<16} {r['avg_gap']:10.2f} mm")
    print(f"{'Max Angle Dev':<16} {r['max_angle_dev']:10.3f} deg")
    print(f"{'Flow Loss':<16} {fl:10.2f} {units}")
    print(f"{'Flow Net':<16} {fn:10.2f} {units}")

    fig = plot_profiles(r['xy'], nodes, ss) if do_plot else None

    results = {
        'nodes': nodes, 'ex': ex, 'offset': offset, 'rotor_H': rotor_H,
        'shellgap': shellgap, 'points': points, 'units': units,
        'mode': mode, 'ss': ss, 'lobe_rmax': r['lobe_rmax'],
        'lobe_rmin': r['lobe_rmin'], 'lobe_w': r['lobe_w'],
        'shell_d': r['shell_d'], 'area_eff': r['area_eff'],
        'lambda': r['lamb'], 'min_gap': r['min_gap'],
        'avg_gap': r['avg_gap'], 'max_angle_dev_deg': r['max_angle_dev'],
        'flow_loss': fl, 'flow_net': fn, 'xy': r['xy'], 'fig': fig,
    }
    return results


def _build_arg_parser():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--nodes', type=int, default=3)
    p.add_argument('--ex', type=float, default=0.245)
    p.add_argument('--offset', type=float, default=2.72)
    p.add_argument('--rotor-h', type=float, default=100, dest='rotor_H')
    p.add_argument('--shellgap', type=float, default=2)
    p.add_argument('--ss-or-shelld', type=float, default=80.4)
    p.add_argument('--points', type=int, default=1001)
    p.add_argument('--units', choices=['CMM', 'CMH', 'CFM'], default='CMM')
    p.add_argument('--mode', choices=['ss', 'sd'], default='ss')
    p.add_argument('--no-plot', action='store_true')
    return p


if __name__ == '__main__':
    args = _build_arg_parser().parse_args()
    result = roots_profile_script(
        nodes=args.nodes, ex=args.ex, offset=args.offset,
        rotor_H=args.rotor_H, shellgap=args.shellgap,
        ss_or_shelld=args.ss_or_shelld, points=args.points,
        units=args.units, mode=args.mode, do_plot=not args.no_plot)
    if result['fig'] is not None:
        import matplotlib.pyplot as plt
        plt.show()
