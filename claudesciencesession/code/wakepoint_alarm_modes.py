"""
WakePoint mode-aware alarm evaluator — faithful mirror of:
  lib/services/tracking/alarm_controller.dart  (mode dispatch + eligibility gate)
  lib/services/alarm_evaluator.dart             (estimateEtaSecondsToMeters, stops counting)
Replaces the old fire_lead_m=500 proxy. Four modes: stops / time / distance +
research-derived critical-fractile safety rule (median - k*sigma margin).
"""
import numpy as np

def schedule_eta_ideal(prog_m, target_m, s_true_sched, t_sched):
    """Schedule-anchored ETA: time-to-target minus time-to-progress from the route schedule."""
    if prog_m >= target_m: return 0.0
    t_prog = np.interp(prog_m, s_true_sched, t_sched)
    t_tgt  = np.interp(target_m, s_true_sched, t_sched)
    return max(0.0, t_tgt - t_prog)

def eta_speed(prog_m, target_m, speed_mps):
    """Non-metro fallback ETA = remaining / speed (speed>0.5), mirrors estimateEtaSecondsToMeters."""
    rem = max(0.0, target_m - prog_m)
    if rem <= 0: return 0.0
    return rem/speed_mps if (np.isfinite(speed_mps) and speed_mps > 0.5) else np.inf

def fire_stops(est_s, t, station_arcs, target_idx, N_stops):
    """STOPS mode (metro): fire when remaining stops to target <= N.
       remaining = (intermediate stations ahead) + 1 (the alight station)."""
    for i in range(len(t)):
        passed = sum(1 for k in range(target_idx) if est_s[i] >= station_arcs[k])
        remaining = (target_idx - passed) + 1
        if N_stops > 0 and remaining <= N_stops:
            return t[i]
    return None

def fire_time_schedule(est_s, t, target_m, N_min, s_true_sched, t_sched, eligible_after_s=0.0):
    """TIME mode (metro): fire when schedule-ETA(est_progress -> target) <= N min."""
    thr = N_min*60.0
    for i in range(len(t)):
        if t[i] < eligible_after_s: continue
        eta = schedule_eta_ideal(est_s[i], target_m, s_true_sched, t_sched)
        if 0 < eta <= thr: return t[i]
    return None

def fire_time_speed(est_s, est_v, t, target_m, N_min, eligible_after_s=0.0):
    """TIME mode (non-metro): fire when speed-ETA <= N min. Eligibility-gated by caller."""
    thr = N_min*60.0
    for i in range(len(t)):
        if t[i] < eligible_after_s: continue
        eta = eta_speed(est_s[i], target_m, est_v[i])
        if np.isfinite(eta) and eta <= thr: return t[i]
    return None

def fire_distance(est_s, t, target_m, N_km):
    """DISTANCE mode (non-metro): fire when remaining route distance <= N km."""
    thr = N_km*1000.0
    for i in range(len(t)):
        if (target_m - est_s[i]) <= thr: return t[i]
    return None

def fire_critical_fractile(est_s, sig_s, t, target_m, lead_seconds, s_true_sched, t_sched, k=2.0):
    """SAFETY rule (research: asymmetric conformal / critical fractile).
       Fire when (median ETA - k*sigma_ETA) <= lead. Wider position sigma => bigger ETA spread
       => fires EARLIER, bounding P(wake late). Push position posterior through schedule ETA."""
    rng = np.random.default_rng(0)
    for i in range(0, len(t), 50):
        ps = rng.normal(est_s[i], max(sig_s[i], 1.0), 200)
        etas = np.array([schedule_eta_ideal(p, target_m, s_true_sched, t_sched) for p in ps])
        etas = etas[np.isfinite(etas)]
        if len(etas) < 10: continue
        if np.median(etas) - k*np.std(etas) <= lead_seconds:
            return t[i]
    return None

def true_arrival_time(s_true, t, target_m):
    idx = np.argmax(s_true >= target_m) if (s_true >= target_m).any() else -1
    return t[idx] if idx >= 0 else None

def score_fire(fire_t, true_arr_t, requested_lead_s, accept_window_s=30.0):
    """hit = fire lands within accept_window of ideal (true_arrival - requested_lead).
       lead_err_s > 0 => woke LATE (bad); < 0 => woke early (safe)."""
    if fire_t is None or true_arr_t is None:
        return dict(fired=fire_t is not None, hit=False, lead_err_s=float("nan"))
    lead_err = fire_t - (true_arr_t - requested_lead_s)
    return dict(fired=True, hit=bool(abs(lead_err) <= accept_window_s), lead_err_s=float(lead_err))
