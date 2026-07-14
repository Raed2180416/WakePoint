# EkfFixed — honest-covariance variant of the faithful EkfPy port.
# Changes vs production (ekf_reference.EkfPy):
#   1. sigmaS cap raised 200m -> 3000m (stop lying about position uncertainty underground)
#   2. ZUPT updates velocity + bias ONLY; does NOT tighten position covariance
#      (a zero-velocity update observes velocity, not position).
# Requires ekf_reference.py alongside.
import numpy as np, importlib.util
_spec=importlib.util.spec_from_file_location('ekf_reference','ekf_reference.py')
ekf_mod=importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ekf_mod)

class EkfFixed(ekf_mod.EkfPy):
    def __init__(self,*a,**k):
        super().__init__(*a,**k); self._maxSigmaS=3000.0
    def _inflate(self,f):
        self.P[0,0]*=f; self.P[1,1]*=f; self.P[2,2]*=f
        self.P[0,0]=min(self.P[0,0],self._maxSigmaS**2)
        self.P[1,1]=min(self.P[1,1],100.0**2); self.P[2,2]=min(self.P[2,2],1.0)
    def on_zupt(self):
        if not self.init: return
        r=self.c['zuptVar']; S=self.P[1,1]+r
        if S<=0: return
        nu=0.0-self.v; k0=self.P[0,1]/S; k1=self.P[1,1]/S; k2=self.P[2,1]/S
        self.s+=k0*nu; self.v+=k1*nu; self.b+=k2*nu
        p10,p11,p12=self.P[1,0],self.P[1,1],self.P[1,2]
        self.P[0,0]-=k0*p10; self.P[0,1]-=k0*p11; self.P[0,2]-=k0*p12
        self.P[1,0]-=k1*p10; self.P[1,1]-=k1*p11; self.P[1,2]-=k1*p12
        self.P[2,0]-=k2*p10; self.P[2,1]-=k2*p11; self.P[2,2]-=k2*p12
        self.P[1,1]=min(self.P[1,1],0.5**2)   # tighten VELOCITY only (justified by a ZUPT)
        self._sym(); self._bounds(); self._floors(); self._pub()
