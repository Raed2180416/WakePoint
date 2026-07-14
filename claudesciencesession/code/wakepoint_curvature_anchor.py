# WakePoint curvature anchor (tilt-compensated yaw + desync detection + combined trigger)
# Extraction: yaw-rate = gyro . gHat_unit (gravity axis). Bandpass 0.01-0.3Hz removes bias.
# Use as: (1) desync detector r=0.98, (2) combined OR-trigger -> 0/6 underground late.

def true_yaw_rate(imu, i, tf):
    """Yaw-rate about the VERTICAL (gravity) axis = gyro . gHat_unit. tf.gHat updated by forward_accel."""
    g=tf.gHat
    if g is None: return 0.0
    gnorm=np.linalg.norm(g)
    if gnorm<1e-6: return 0.0
    ghat=g/gnorm
    gyro=np.array([imu["gx"][i],imu["gy"][i],imu["gz"][i]])
    return float(gyro@ghat)  # component of angular velocity about vertical = yaw-rate

def route_heading_signature(line):
    """Cumulative signed heading change vs arc-length from the route polyline's own headings."""
    arc=np.asarray(line["arc_m"])
    if "heading_rad" in line and len(line["heading_rad"])>1:
        hd=np.asarray(line["heading_rad"])
    else:
        # derive heading from curvature: heading(s) = integral kappa ds (signed)
        kap=np.asarray(line["curvature_invm"])
        n=min(len(arc),len(kap)); arc=arc[:n]; kap=kap[:n]
        hd=np.concatenate([[0.0],np.cumsum(kap[:-1]*np.diff(arc))])
    n=min(len(arc),len(hd)); return arc[:n], np.unwrap(hd[:n])

def curvature_pf(rd, blk, fs=100.0, n_particles=500, seed=0):
    imu=rd["imu"]; t=rd["t"]; s_true=rd["s_true"]; line=rd["line"]; kin=rd["kin"]; arcs=rd["arcs"]
    arc_line=np.asarray(line["arc_m"]); kap_line=np.asarray(line["curvature_invm"])
    n=min(len(arc_line),len(kap_line)); arc_line=arc_line[:n]; kap_line=kap_line[:n]
    tf=H.TiltFilterApp(); yaw=np.empty(len(t))
    for i in range(len(t)):
        tf.forward_accel(imu["ax"][i],imu["ay"][i],imu["az"][i],imu["grx"][i],imu["gry"][i],imu["grz"][i])
        yaw[i]=true_yaw_rate(imu,i,tf)
    # BANDPASS 0.01-0.3 Hz: removes DC bias (drift) but keeps route-curve turns (10-100s timescale)
    b,a=spsig.butter(2,[0.01/50.0,0.3/50.0],btype='band'); yaw_bp=spsig.filtfilt(b,a,yaw)
    vl=learned_velocity_series(imu,velreg,fs)
    rng=np.random.default_rng(seed)
    bs=np.searchsorted(t,blk[0]); be=np.searchsorted(t,blk[1])
    # init particles around true start-of-blackout position with spread
    s0=s_true[bs]; particles=rng.normal(s0, 200, n_particles); weights=np.ones(n_particles)/n_particles
    est_traj=[]
    step=50  # update every 0.5s
    for i in range(bs, be, step):
        v=max(vl[i],0.5)
        particles=particles + v*(step/fs)  # propagate by velocity
        particles+=rng.normal(0,5,n_particles)  # process noise
        # expected turn-rate at each particle = v * kappa(particle_pos)
        exp_turn=v*np.interp(particles, arc_line, kap_line)
        obs=yaw_bp[i]
        # weight by match (gaussian on turn-rate residual)
        weights*=np.exp(-0.5*((exp_turn-obs)/0.02)**2)+1e-12
        weights/=weights.sum()
        # resample if degenerate
        neff=1/np.sum(weights**2)
        if neff<n_particles/2:
            idx=rng.choice(n_particles,n_particles,p=weights); particles=particles[idx]; weights=np.ones(n_particles)/n_particles
        est_traj.append((t[i], np.average(particles,weights=weights), s_true[i]))
    return np.array(est_traj)

def curvature_desync_check(rd, blk, fs=100.0, seed=0):
    imu=rd["imu"]; t=rd["t"]; s_true=rd["s_true"]; line=rd["line"]; arcs=rd["arcs"]
    arc_line=np.asarray(line["arc_m"]); kap_line=np.asarray(line["curvature_invm"])
    n=min(len(arc_line),len(kap_line)); arc_line=arc_line[:n]; kap_line=kap_line[:n]
    tf=H.TiltFilterApp(); yaw=np.empty(len(t))
    for i in range(len(t)):
        tf.forward_accel(imu["ax"][i],imu["ay"][i],imu["az"][i],imu["grx"][i],imu["gry"][i],imu["grz"][i])
        yaw[i]=true_yaw_rate(imu,i,tf)
    b,a=spsig.butter(2,[0.01/50.0,0.3/50.0],btype='band'); yaw_bp=spsig.filtfilt(b,a,yaw)
    def seg_turn(a0,a1):
        m=(arc_line>=a0)&(arc_line<=a1)
        if m.sum()<2: return 0.0
        return float(_trap(np.abs(kap_line[m]), arc_line[m]))
    checks=[]
    for k in range(1,len(arcs)):
        ta=AM.true_arrival_time(s_true,t,arcs[k-1]); tb=AM.true_arrival_time(s_true,t,arcs[k])
        if ta is None or tb is None: continue
        ia,ib=np.searchsorted(t,ta),np.searchsorted(t,tb)
        obs=float(np.sum(np.abs(yaw_bp[ia:ib]))/fs); exp=seg_turn(arcs[k-1],arcs[k])
        checks.append((k, obs, exp))
    return checks

def curvature_combined(rd, target_idx, fs=100.0, seed=0, floor_rate=0.6, k_fire=2.0, max_interstop_s=780.0):
    imu=rd["imu"]; t=rd["t"]; s_true=rd["s_true"]; arcs=rd["arcs"]; line=rd["line"]
    arc_line=np.asarray(line["arc_m"]); kap_line=np.asarray(line["curvature_invm"])
    nn=min(len(arc_line),len(kap_line)); arc_line=arc_line[:nn]; kap_line=kap_line[:nn]
    # route cumulative |turning| profile vs arc
    cum_route=np.concatenate([[0.0],np.cumsum(np.abs(kap_line[:-1])*np.diff(arc_line))])
    vl=learned_velocity_series(imu,velreg,fs); isv=precompute_vehicle_fast(imu,fs)
    tf=H.TiltFilterApp(); yaw=np.empty(len(t))
    for i in range(len(t)):
        tf.forward_accel(imu["ax"][i],imu["ay"][i],imu["az"][i],imu["grx"][i],imu["gry"][i],imu["grz"][i])
        yaw[i]=true_yaw_rate(imu,i,tf)
    b,a=spsig.butter(2,[0.01/50.0,0.3/50.0],btype='band'); yaw_bp=spsig.filtfilt(b,a,yaw)
    cum_obs=np.cumsum(np.abs(yaw_bp))/fs  # cumulative observed |turning|
    F,cen=imu_features2(imu["ax"],imu["ay"],imu["az"],imu["gx"],imu["gy"],imu["gz"],fs=fs)
    md_series=np.array([ood_maha(x) if not np.any(np.isnan(x)) else md_p95 for x in F]); cen_t=cen/fs
    def md_at(tt):
        j=np.searchsorted(cen_t,tt); return md_series[min(j,len(md_series)-1)] if len(md_series) else md_p95
    ti=target_idx
    ek=EkfVel(allow_reverse=False); dd=DwellDetector(fs=fs); dca=DwellCountAssociator(arcs)
    ek.s=0.0; ek.v=0.0; ek.b=0.0; ek.P=np.diag([((arcs[1]-arcs[0])/2)**2,25.0,0.01]).astype(float)
    ek.mode="degraded"; dca.k=0; dca.in_blackout=True
    fire_t=None; fire_src=None; pt=None; t_last_adv=t[0]
    gap=arcs[ti]-arcs[ti-1]; fa=arcs[ti]-gap
    for i in range(len(t)):
        dt=None if pt is None else t[i]-pt; pt=t[i]
        aF=tf.forward_accel(imu["ax"][i],imu["ay"][i],imu["az"][i],imu["grx"][i],imu["gry"][i],imu["grz"][i])
        a_lin=np.linalg.norm(np.array([imu["ax"][i],imu["ay"][i],imu["az"][i]])-tf.gHat*9.807)
        gm=np.sqrt(imu["gx"][i]**2+imu["gy"][i]**2+imu["gz"][i]**2); ek.on_forward_accel(dt,aF)
        if i%50==0: ek.on_velocity(float(vl[i]),safe_vel_var(md_at(t[i])))
        if dd.update(a_lin,gm,isv[i]):
            ek.on_zupt(); rr=dca.confirm_dwell(t[i])
            if rr is not None:
                ek.on_station(rr[1]); t_last_adv=t[i]
                if fire_t is None and dca.k>=ti-1: fire_t=t[i]; fire_src="count"
        if (t[i]-t_last_adv)>=max_interstop_s and dca.k+1<len(arcs):
            dca.k+=1; ek.on_station(float(arcs[dca.k])); t_last_adv=t[i]
            if fire_t is None and dca.k>=ti-1: fire_t=t[i]; fire_src="watchdog"
        # CURVATURE POSITION trigger: invert cumulative turning -> arc position
        if i%50==0 and fire_t is None:
            s_curv=np.interp(cum_obs[i], cum_route, arc_line)
            if s_curv>=fa: fire_t=t[i]; fire_src="curvature"
        floor=floor_rate*(t[i]-t[0]); s_cur=ek.public_s(); sig_cur=max(ek.sigmaS(),floor)
        if fire_t is None and (s_cur+k_fire*sig_cur)>=fa: fire_t=t[i]; fire_src="critfrac"
    ii=np.argmax(s_true>=fa) if (s_true>=fa).any() else -1
    return ((fire_t-t[ii]) if (fire_t is not None and ii>=0) else None), fire_src

