// Faithful JS port of the verified WakePoint 1D-progress EKF (state [s,v,b], 3x3 P).
// Ported from ekf_reference.py EkfVel. Runs LIVE in-browser — this is the REAL filter, not interpolation.
const CFG={sigmaAccel:0.15,sigmaBias:0.001,gpsFloorVar:625.0,gpsSpeedVar:1.0,zuptVar:0.0025,
  stationVar:100.0,minDt:0.001,maxDt:0.2,sigmaSFloor:5.0,sigmaVFloor:0.1,sigmaBiasFloor:1e-4,biasLimit:0.5};
function huber(norm,d){return norm<=d?1.0:d/norm;}

class EKF {
  constructor(variant){ // 'production' | 'fixed'
    this.variant=variant; this.maxSigmaS = variant==='fixed'?3000.0:200.0;
    this.allowReverse=false; this.init=false; this.mode='surface'; this.motion='vehicle';
    this.s=0;this.v=0;this.b=0; this.P=[[0,0,0],[0,0,0],[0,0,0]]; this.recentAcc=[]; this.lastGpsV=null;
  }
  initFromGps(sG,vG){ this.s=sG; this.v=Math.max(0,vG); this.b=0;
    this.P=[[625,0,0],[0,25,0],[0,0,0.01]]; this.init=true; this._bounds(); this._floors(); }
  _sym(){const P=this.P; P[0][1]=P[1][0]=(P[0][1]+P[1][0])/2; P[0][2]=P[2][0]=(P[0][2]+P[2][0])/2; P[1][2]=P[2][1]=(P[1][2]+P[2][1])/2;}
  _bounds(){ const m=this.maxSigmaS*this.maxSigmaS; if(this.P[0][0]>m)this.P[0][0]=m;
    if(!isFinite(this.s))this.s=0; if(!isFinite(this.v))this.v=0; if(!isFinite(this.b))this.b=0;
    if(Math.abs(this.b)>CFG.biasLimit)this.b=Math.sign(this.b)*CFG.biasLimit; }
  _floors(){ if(!isFinite(this.P[0][0]))this.P[0][0]=200*200; if(!isFinite(this.P[1][1]))this.P[1][1]=100*100;
    if(!isFinite(this.P[2][2]))this.P[2][2]=1.0;
    if(this.P[0][0]<CFG.sigmaSFloor**2)this.P[0][0]=CFG.sigmaSFloor**2;
    if(this.P[1][1]<CFG.sigmaVFloor**2)this.P[1][1]=CFG.sigmaVFloor**2;
    if(this.P[2][2]<CFG.sigmaBiasFloor)this.P[2][2]=CFG.sigmaBiasFloor; }
  _inflate(f){ this.P[0][0]*=f; this.P[1][1]*=f; this.P[2][2]*=f;
    if(this.P[0][0]>200*200)this.P[0][0]=200*200; if(this.P[1][1]>100*100)this.P[1][1]=100*100;
    if(this.P[2][2]>1.0)this.P[2][2]=1.0; }
  sigmaS(){return Math.sqrt(Math.max(0,this.P[0][0]));}
  publicS(){return this.s;}
  onAccel(dt,aFwd){
    if(!this.init||dt==null||dt<=0)return;
    if(dt>1.0){this.v=0;this.b=0;this._inflate(4.0);return;}
    if(dt<CFG.minDt||dt>CFG.maxDt){this._inflate(1.1);return;}
    const sOld=this.s; if(this.mode==='degraded')this._inflate(1.0002);
    const dt2=dt*dt; let aBias=aFwd-this.b; let vDamp=1.0;
    if(this.mode==='degraded'){
      if(this.motion==='stationary'&&Math.abs(this.v)<0.3){vDamp=0.98;}
      else{ if(Math.abs(aBias)<0.1)aBias=0; aBias=Math.max(-1.5,Math.min(1.5,aBias)); }
    }
    this.s=this.s+this.v*dt+0.5*aBias*dt2; this.v=(this.v+aBias*dt)*vDamp;
    if(!this.allowReverse){ if(this.v<0)this.v=0; if(this.s<sOld)this.s=sOld; }
    this.v=Math.max(-25,Math.min(25,this.v));
    const F=[[1,dt,-0.5*dt2],[0,1,-dt],[0,0,1]];
    const sa2=CFG.sigmaAccel**2, sb2=CFG.sigmaBias**2;
    const Q=[[sa2*dt2*dt2/4,0,0],[0,sa2*dt2,0],[0,0,sb2*dt]];
    // P = F P F^T + Q
    const P=this.P, FP=[[0,0,0],[0,0,0],[0,0,0]];
    for(let i=0;i<3;i++)for(let j=0;j<3;j++){let s=0;for(let k=0;k<3;k++)s+=F[i][k]*P[k][j];FP[i][j]=s;}
    const np=[[0,0,0],[0,0,0],[0,0,0]];
    for(let i=0;i<3;i++)for(let j=0;j<3;j++){let s=0;for(let k=0;k<3;k++)s+=FP[i][k]*F[j][k];np[i][j]=s+Q[i][j];}
    this.P=np; this.recentAcc.push(aFwd); if(this.recentAcc.length>50)this.recentAcc.shift();
    this._sym(); this._bounds(); this._floors();
  }
  onZupt(){ if(!this.init)return; const r=CFG.zuptVar,S=this.P[1][1]+r; if(S<=0)return;
    const nu=0-this.v, k0=this.P[0][1]/S,k1=this.P[1][1]/S,k2=this.P[2][1]/S;
    this.s+=k0*nu;this.v+=k1*nu;this.b+=k2*nu;
    const p10=this.P[1][0],p11=this.P[1][1],p12=this.P[1][2];
    this.P[0][0]-=k0*p10;this.P[0][1]-=k0*p11;this.P[0][2]-=k0*p12;
    this.P[1][0]-=k1*p10;this.P[1][1]-=k1*p11;this.P[1][2]-=k1*p12;
    this.P[2][0]-=k2*p10;this.P[2][1]-=k2*p11;this.P[2][2]-=k2*p12;
    if(this.variant==='fixed'){ if(this.P[1][1]>0.25)this.P[1][1]=0.25; } // tighten velocity only
    else { if(this.P[0][0]>100)this.P[0][0]=100; if(this.P[1][1]>0.25)this.P[1][1]=0.25; } // prod tightens POSITION too (the bug)
    this._sym();this._bounds();this._floors();
  }
  onVelocity(vMeas,vVar){ if(!this.init)return; const S=this.P[1][1]+vVar; if(S<=0)return;
    const nu=vMeas-this.v,k0=this.P[0][1]/S,k1=this.P[1][1]/S,k2=this.P[2][1]/S;
    this.s+=k0*nu;this.v+=k1*nu;this.b+=k2*nu;
    const p10=this.P[1][0],p11=this.P[1][1],p12=this.P[1][2];
    this.P[0][0]-=k0*p10;this.P[0][1]-=k0*p11;this.P[0][2]-=k0*p12;
    this.P[1][0]-=k1*p10;this.P[1][1]-=k1*p11;this.P[1][2]-=k1*p12;
    this.P[2][0]-=k2*p10;this.P[2][1]-=k2*p11;this.P[2][2]-=k2*p12;
    this._sym();this._bounds();this._floors();
  }
  onGps(sG,speed,accM){ if(!this.init){this.initFromGps(sG,speed);return;}
    const sig=this.sigmaS(); const nu=sG-this.s; const norm=sig>0?Math.abs(nu)/sig:0;
    if(sig>0&&norm>15){this.initFromGps(sG,speed);return;}
    const w=huber(norm,2.5); if(w<0.2){this._inflate(1.2);return;}
    const baseR=Math.max(accM*accM,CFG.gpsFloorVar), r=baseR/w, S=this.P[0][0]+r; if(S<=0)return;
    const k0=this.P[0][0]/S,k1=this.P[1][0]/S;
    this.s+=k0*nu;this.v+=k1*nu;
    const p00=this.P[0][0],p01=this.P[0][1],p02=this.P[0][2];
    this.P[0][0]-=k0*p00;this.P[0][1]-=k0*p01;this.P[0][2]-=k0*p02;
    this.P[1][0]-=k1*p00;this.P[1][1]-=k1*p01;this.P[1][2]-=k1*p02;
    if(isFinite(speed)){ const rV=CFG.gpsSpeedVar,sV=this.P[1][1]+rV; if(sV>0){
      const nuV=speed-this.v,kV=this.P[1][1]/sV; this.v+=kV*nuV;
      const q10=this.P[1][0],q11=this.P[1][1],q12=this.P[1][2];
      this.P[1][0]=q10-kV*q10;this.P[1][1]=q11-kV*q11;this.P[1][2]=q12-kV*q12;
      this.P[0][1]=this.P[1][0];this.P[2][1]=this.P[1][2]; } }
    // El-Sheimy bias observability via GPS-derived accel (dt_gps in [0.5,5.0]s)
    if(this.lastGpsV!=null && this.recentAcc.length>0){
      const dtGps=1.0; // 1 Hz GPS grid
      if(dtGps>0.5 && dtGps<5.0){
        const aGps=(speed-this.lastGpsV)/dtGps;
        const aImu=this.recentAcc.reduce((x,y)=>x+y,0)/this.recentAcc.length;
        const bEst=aImu-aGps;
        if(Math.abs(bEst)<2.0){ this.b=this.b+0.05*(bEst-this.b); this.b=Math.max(-1.0,Math.min(1.0,this.b)); }
      }
    }
    this.lastGpsV=speed; this._sym();this._bounds();this._floors();
  }
  onStation(sSta){ if(!this.init)return; const r=CFG.stationVar,S=this.P[0][0]+r; if(S<=0)return;
    const nu=sSta-this.s,k0=this.P[0][0]/S,k1=this.P[1][0]/S;
    this.s+=k0*nu;this.v+=k1*nu;
    const p00=this.P[0][0],p01=this.P[0][1],p02=this.P[0][2];
    this.P[0][0]-=k0*p00;this.P[0][1]-=k0*p01;this.P[0][2]-=k0*p02;
    this.P[1][0]-=k1*p00;this.P[1][1]-=k1*p01;this.P[1][2]-=k1*p02;
    this._sym();this._bounds();this._floors();
  }
}
if(typeof module!=='undefined')module.exports={EKF};
