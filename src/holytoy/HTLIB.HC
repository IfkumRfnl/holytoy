//HolyToy shader runtime (HTLIB) -- vector/matrix value classes, scalar GLSL
//builtins, and cross-component helpers called by compiler-generated HolyC.
//
//Conventions:
//  * GLSL float maps to F64, int to I64, uint to I64 masked to 32 bits by
//    the emitter, bool to I64 (0/1).
//  * Composite values (vectors, matrices, structs) are always passed by
//    pointer; every helper writes through its first "out" pointer and never
//    aliases-checks (the emitter only passes distinct temps).
//  * Matrices are column-major F64 arrays: m[col*N+row], matching GLSL
//    constructor/indexing order.
//  * Componentwise operations are emitted inline by HTEMIT; only genuinely
//    cross-component operations live here.
//
//Per-pixel trig uses a 4096-entry F64 sine table with linear interpolation
//(intrinsic error ~3e-7 of full scale, far below 8-bit palette output).
//ACCURACY GATE: HtLibSelfTest reports HT LIB OK/FAIL; the holytoy proof
//checks it. Call HtLibInit once at startup, before any shader runs.

class CHtV2 { F64 x,y; };
class CHtV3 { F64 x,y,z; };
class CHtV4 { F64 x,y,z,w; };
class CHtI2 { I64 x,y; };
class CHtI3 { I64 x,y,z; };
class CHtI4 { I64 x,y,z,w; };
class CHtM2 { F64 m[4]; };
class CHtM3 { F64 m[9]; };
class CHtM4 { F64 m[16]; };

#define HTL_N		4096
#define HTL_MASK	4095
#define HTL_PER_TURN	651.8986469044033		//HTL_N/(2*pi)

F64 htl_sin[HTL_N+1];		//sin(2*pi*i/HTL_N); +1 entry skips a wrap mask

U0 HtLibInit()
{//Build the F64 sine table. Once, at startup; NOT per frame.
  I64 i;
  for (i=0;i<=HTL_N;i++)
    htl_sin[i]=Sin(2*pi*i/HTL_N);
}

F64 HtSinF(F64 a)
{//LUT sine with linear interpolation; any finite angle in radians.
  F64 idx=a*HTL_PER_TURN,fl=Floor(idx),fr=idx-fl;
  I64 i=ToI64(fl)&HTL_MASK;
  return htl_sin[i]+(htl_sin[i+1]-htl_sin[i])*fr;
}

F64 HtCosF(F64 a)
{
  return HtSinF(a+pi*0.5);
}

F64 HtTanF(F64 a)
{
  return HtSinF(a)/HtCosF(a);
}

F64 HtFract(F64 x)
{
  return x-Floor(x);
}

F64 HtModF(F64 x,F64 y)
{//GLSL mod: x-y*floor(x/y); sign follows y.
  return x-y*Floor(x/y);
}

F64 HtClampF(F64 x,F64 lo,F64 hi)
{
  if (x<lo) return lo;
  if (x>hi) return hi;
  return x;
}

I64 HtClampI(I64 x,I64 lo,I64 hi)
{
  if (x<lo) return lo;
  if (x>hi) return hi;
  return x;
}

F64 HtMixF(F64 a,F64 b,F64 t)
{
  return a+(b-a)*t;
}

F64 HtStepF(F64 edge,F64 x)
{
  if (x<edge) return 0.0;
  return 1.0;
}

F64 HtSStepF(F64 e0,F64 e1,F64 x)
{//GLSL smoothstep with the standard clamped Hermite.
  F64 t=HtClampF((x-e0)/(e1-e0),0.0,1.0);
  return t*t*(3.0-2.0*t);
}

F64 HtSignF(F64 x)
{
  if (x>0.0) return 1.0;
  if (x<0.0) return -1.0;
  return 0.0;
}

I64 HtSignI(I64 x)
{
  if (x>0) return 1;
  if (x<0) return -1;
  return 0;
}

F64 HtMinF(F64 a,F64 b)
{
  if (a<b) return a;
  return b;
}

F64 HtMaxF(F64 a,F64 b)
{
  if (a>b) return a;
  return b;
}

F64 HtInvSqrt(F64 x)
{
  return 1.0/Sqrt(x);
}

F64 HtAtanF(F64 y_over_x)
{
  return ATan(y_over_x);
}

F64 HtAtan2F(F64 y,F64 x)
{//GLSL atan(y,x); Arg takes (x,y) and returns the polar angle.
  return Arg(x,y);
}

F64 HtExp2F(F64 x)
{
  return Pow(2.0,x);
}

F64 HtASinF(F64 x)
{//asin via atan; |x|>1 clamps (GLSL result would be undefined).
  if (x>=1.0) return pi*0.5;
  if (x<=-1.0) return -pi*0.5;
  return ATan(x/Sqrt(1.0-x*x));
}

F64 HtACosF(F64 x)
{
  return pi*0.5-HtASinF(x);
}

//--- cross-component vector helpers ---------------------------------------

F64 HtV2Dot(CHtV2 *a,CHtV2 *b)
{
  return a->x*b->x+a->y*b->y;
}

F64 HtV3Dot(CHtV3 *a,CHtV3 *b)
{
  return a->x*b->x+a->y*b->y+a->z*b->z;
}

F64 HtV4Dot(CHtV4 *a,CHtV4 *b)
{
  return a->x*b->x+a->y*b->y+a->z*b->z+a->w*b->w;
}

F64 HtV2Len(CHtV2 *a)
{
  return Sqrt(a->x*a->x+a->y*a->y);
}

F64 HtV3Len(CHtV3 *a)
{
  return Sqrt(a->x*a->x+a->y*a->y+a->z*a->z);
}

F64 HtV4Len(CHtV4 *a)
{
  return Sqrt(a->x*a->x+a->y*a->y+a->z*a->z+a->w*a->w);
}

F64 HtV2Dist(CHtV2 *a,CHtV2 *b)
{
  F64 dx=a->x-b->x,dy=a->y-b->y;
  return Sqrt(dx*dx+dy*dy);
}

F64 HtV3Dist(CHtV3 *a,CHtV3 *b)
{
  F64 dx=a->x-b->x,dy=a->y-b->y,dz=a->z-b->z;
  return Sqrt(dx*dx+dy*dy+dz*dz);
}

F64 HtV4Dist(CHtV4 *a,CHtV4 *b)
{
  F64 dx=a->x-b->x,dy=a->y-b->y,dz=a->z-b->z,dw=a->w-b->w;
  return Sqrt(dx*dx+dy*dy+dz*dz+dw*dw);
}

U0 HtV2Norm(CHtV2 *out,CHtV2 *a)
{
  F64 s=1.0/HtV2Len(a);
  out->x=a->x*s;
  out->y=a->y*s;
}

U0 HtV3Norm(CHtV3 *out,CHtV3 *a)
{
  F64 s=1.0/HtV3Len(a);
  out->x=a->x*s;
  out->y=a->y*s;
  out->z=a->z*s;
}

U0 HtV4Norm(CHtV4 *out,CHtV4 *a)
{
  F64 s=1.0/HtV4Len(a);
  out->x=a->x*s;
  out->y=a->y*s;
  out->z=a->z*s;
  out->w=a->w*s;
}

U0 HtV3Cross(CHtV3 *out,CHtV3 *a,CHtV3 *b)
{
  F64 x=a->y*b->z-a->z*b->y,
      y=a->z*b->x-a->x*b->z,
      z=a->x*b->y-a->y*b->x;
  out->x=x;
  out->y=y;
  out->z=z;
}

U0 HtV2Reflect(CHtV2 *out,CHtV2 *i,CHtV2 *n)
{
  F64 d=2.0*HtV2Dot(n,i);
  out->x=i->x-d*n->x;
  out->y=i->y-d*n->y;
}

U0 HtV3Reflect(CHtV3 *out,CHtV3 *i,CHtV3 *n)
{
  F64 d=2.0*HtV3Dot(n,i);
  out->x=i->x-d*n->x;
  out->y=i->y-d*n->y;
  out->z=i->z-d*n->z;
}

U0 HtV3Refract(CHtV3 *out,CHtV3 *i,CHtV3 *n,F64 eta)
{//GLSL refract: zero vector on total internal reflection.
  F64 d=HtV3Dot(n,i),k=1.0-eta*eta*(1.0-d*d),s;
  if (k<0.0) {
    out->x=0.0;
    out->y=0.0;
    out->z=0.0;
  } else {
    s=eta*d+Sqrt(k);
    out->x=eta*i->x-s*n->x;
    out->y=eta*i->y-s*n->y;
    out->z=eta*i->z-s*n->z;
  }
}

U0 HtV2FaceFwd(CHtV2 *out,CHtV2 *n,CHtV2 *i,CHtV2 *nref)
{
  F64 s=1.0;
  if (HtV2Dot(nref,i)>=0.0) s=-1.0;
  out->x=n->x*s;
  out->y=n->y*s;
}

U0 HtV3FaceFwd(CHtV3 *out,CHtV3 *n,CHtV3 *i,CHtV3 *nref)
{
  F64 s=1.0;
  if (HtV3Dot(nref,i)>=0.0) s=-1.0;
  out->x=n->x*s;
  out->y=n->y*s;
  out->z=n->z*s;
}

//--- matrix helpers (column-major: m[col*N+row]) ---------------------------

U0 HtM2MulV(CHtV2 *out,CHtM2 *m,CHtV2 *v)
{
  F64 x=m->m[0]*v->x+m->m[2]*v->y,
      y=m->m[1]*v->x+m->m[3]*v->y;
  out->x=x;
  out->y=y;
}

U0 HtVMulM2(CHtV2 *out,CHtV2 *v,CHtM2 *m)
{//row vector * matrix
  F64 x=m->m[0]*v->x+m->m[1]*v->y,
      y=m->m[2]*v->x+m->m[3]*v->y;
  out->x=x;
  out->y=y;
}

U0 HtM3MulV(CHtV3 *out,CHtM3 *m,CHtV3 *v)
{
  F64 x=m->m[0]*v->x+m->m[3]*v->y+m->m[6]*v->z,
      y=m->m[1]*v->x+m->m[4]*v->y+m->m[7]*v->z,
      z=m->m[2]*v->x+m->m[5]*v->y+m->m[8]*v->z;
  out->x=x;
  out->y=y;
  out->z=z;
}

U0 HtVMulM3(CHtV3 *out,CHtV3 *v,CHtM3 *m)
{
  F64 x=m->m[0]*v->x+m->m[1]*v->y+m->m[2]*v->z,
      y=m->m[3]*v->x+m->m[4]*v->y+m->m[5]*v->z,
      z=m->m[6]*v->x+m->m[7]*v->y+m->m[8]*v->z;
  out->x=x;
  out->y=y;
  out->z=z;
}

U0 HtM4MulV(CHtV4 *out,CHtM4 *m,CHtV4 *v)
{
  F64 x=m->m[0]*v->x+m->m[4]*v->y+m->m[8]*v->z+m->m[12]*v->w,
      y=m->m[1]*v->x+m->m[5]*v->y+m->m[9]*v->z+m->m[13]*v->w,
      z=m->m[2]*v->x+m->m[6]*v->y+m->m[10]*v->z+m->m[14]*v->w,
      w=m->m[3]*v->x+m->m[7]*v->y+m->m[11]*v->z+m->m[15]*v->w;
  out->x=x;
  out->y=y;
  out->z=z;
  out->w=w;
}

U0 HtVMulM4(CHtV4 *out,CHtV4 *v,CHtM4 *m)
{
  F64 x=m->m[0]*v->x+m->m[1]*v->y+m->m[2]*v->z+m->m[3]*v->w,
      y=m->m[4]*v->x+m->m[5]*v->y+m->m[6]*v->z+m->m[7]*v->w,
      z=m->m[8]*v->x+m->m[9]*v->y+m->m[10]*v->z+m->m[11]*v->w,
      w=m->m[12]*v->x+m->m[13]*v->y+m->m[14]*v->z+m->m[15]*v->w;
  out->x=x;
  out->y=y;
  out->z=z;
  out->w=w;
}

U0 HtMMulM(F64 *out,F64 *a,F64 *b,I64 n)
{//out = a*b for n x n column-major; out must not alias a or b.
  I64 c,r,k;
  F64 s;
  for (c=0;c<n;c++)
    for (r=0;r<n;r++) {
      s=0.0;
      for (k=0;k<n;k++)
        s+=a[k*n+r]*b[c*n+k];
      out[c*n+r]=s;
    }
}

//--- IEEE 754 single-precision bit conversions -----------------------------
//GLSL floatBitsToUint/uintBitsToFloat operate on 32-bit floats; HolyToy
//stores floats as F64, so convert the VALUE to/from F32 bit patterns in
//software (round-to-nearest-even omitted: truncation of the extra 29
//mantissa bits, adequate for hash/bit tricks).

I64 HtF32Bits(F64 x)
{
  F64 f=x;
  I64 raw=*(&f)(I64 *),sign,e,man;
  sign=(raw>>63)&1;
  e=(raw>>52)&0x7FF;
  man=raw&0xFFFFFFFFFFFFF;
  if (e==0x7FF) {			//inf/NaN
    if (man) man=1;
    return (sign<<31)|0x7F800000|(man<<22);
  }
  e=e-1023+127;
  if (e<=0) return sign<<31;		//underflow to signed zero (no denormals)
  if (e>=0xFF) return (sign<<31)|0x7F800000;
  return (sign<<31)|(e<<23)|(man>>29);
}

F64 HtF32FromBits(I64 bits)
{
  I64 b=bits&0xFFFFFFFF,sign=(b>>31)&1,e=(b>>23)&0xFF,man=b&0x7FFFFF,raw;
  F64 res;
  if (e==0xFF) {
    if (man) man=1<<51;
    raw=(sign<<63)|(0x7FF<<52)|man;
  } else if (e==0) {
    if (!man)
      raw=sign<<63;			//signed zero
    else {				//denormal F32: exact as normal F64
      res=man*1.0;
      res=res/8388608.0;		//2^23
      res=res*Pow(2.0,-126.0);
      if (sign) res=-res;
      return res;
    }
  } else
    raw=(sign<<63)|((e-127+1023)<<52)|(man<<29);
  return *(&raw)(F64 *);
}

//--- plan 013: F32 semantics (bit-reproduce llvmpipe) ----------------------
//The visual oracle renders through llvmpipe, which evaluates the shader in
//IEEE-754 single precision. HolyToy stores floats as F64, so to converge the
//fract(sin(x)*C) white-noise hash idiom (~5e4 gain) the generated code must
//reproduce llvmpipe's F32 semantics BIT-FOR-BIT: round every float op/literal
//to F32 (RNE) and replace sin/cos with a replica of gallivm's Cephes-F32
//polynomial. Accuracy is the enemy -- a more accurate sine diverges from
//llvmpipe's deliberately lossy F32 reduction. See plans/013.

//--- plan 014: hardware F32 rounding via x87 precision control --------------
//With CW precision control = 24-bit (CW bits 8-9 = 00) every FADD/FMUL/FDIV/
//FSQRT rounds its result RNE to a 24-bit significand in-register, which the
//PC24 self-test gate proves bit-identical to HtF32 for F32-normal-range
//values. Generated code then runs plain float ops instead of the HtF32 call
//chain (measured 13.3 -> 2.4 ns/op). The CW is task-local (Sched.HC
//FXSAVE/FXRSTORs CTask.fpu_mmx), so shading tasks hold PC24 privately.
//Exponent range stays extended: F32 overflow->inf and subnormal underflow do
//not occur at the F32 boundary (documented deviation, corpus-measured).
//ht_hwf32_mode gates the emitter; the gate clears it if PC24 misbehaves.

Bool ht_hwf32_mode=TRUE;	//plan 014: PC24 hardware F32 (E:/HWF32.TXT=0
				//or a failing HT PC24 gate turns it off)

I64 HtPCSave24()
{//save the x87 control word, set 24-bit precision control, return old CW.
 //noreg pins the scratch to its stack slot: HolyC register-allocates plain
 //locals, and the asm operand &x[RBP] addresses the slot, not the register.
  I64 noreg cw;
  I64 noreg cw2;
  cw=0;
  asm {FSTCW U16 &cw[RBP]}
  cw2=cw&(~0x300);
  asm {FLDCW U16 &cw2[RBP]}
  return cw&0xFFFF;
}

I64 HtPCSave64()
{//save the x87 control word, set 64-bit precision control (TempleOS default),
 //return old CW. Used by helpers whose plan-013 numerics need exact F64
 //intermediates (Cephes fma chains) while callers run at PC24.
  I64 noreg cw;
  I64 noreg cw2;
  cw=0;
  asm {FSTCW U16 &cw[RBP]}
  cw2=cw|0x300;
  asm {FLDCW U16 &cw2[RBP]}
  return cw&0xFFFF;
}

U0 HtPCRestore(I64 old)
{
  I64 noreg cw;
  cw=old&0xFFFF;
  asm {FLDCW U16 &cw[RBP]}
}

//plan 014: shader literal table. The emitter's hw mode replaces runtime
//HtF32(<literal>) calls with ht_glit[k] loads; generated HtShaderInit fills
//the slots once per install (ht_glit[k]=HtF32(<literal>);).
#define HT_GLIT_MAX	3072
F64 ht_glit[HT_GLIT_MAX];

I64 HtF32BitsRNE(F64 x)
{//IEEE-754 round-to-nearest-even of x into a 32-bit float bit pattern.
 //Correct on normals, subnormals, overflow, inf and NaN (self-test gated).
  F64 f=x;
  I64 raw=*(&f)(I64 *),sign,e,man,e32,kept,rbits,half,inc,sig,shift,mask;
  sign=(raw>>63)&1;
  e=(raw>>52)&0x7FF;
  man=raw&0xFFFFFFFFFFFFF;
  if (e==0x7FF) {			//inf / NaN
    if (man) return (sign<<31)|0x7FC00000;
    return (sign<<31)|0x7F800000;
  }
  if (!e) return sign<<31;		//F64 subnormal/zero -> underflows F32
  e32=e-1023+127;
  if (e32>=0xFF) return (sign<<31)|0x7F800000;	//overflow -> inf
  if (e32>=1) {				//normal F32: keep top 23 mantissa bits
    kept=man>>29;
    rbits=man&0x1FFFFFFF;		//low 29 bits
    half=0x10000000;			//bit 28
    inc=0;
    if (rbits>half) inc=1;
    else if (rbits==half) inc=kept&1;	//tie to even
    kept+=inc;
    if (kept==0x800000) {		//mantissa carry into exponent
      kept=0;
      e32++;
      if (e32>=0xFF) return (sign<<31)|0x7F800000;
    }
    return (sign<<31)|(e32<<23)|kept;
  }
  //e32<=0: F32 subnormal or underflow to zero. Round the full 53-bit
  //significand to a multiple of 2^-149 (=F32 subnormal step).
  sig=(1<<52)|man;
  shift=926-e;				//>=30 here (e<=896)
  if (shift>=64) return sign<<31;
  kept=sig>>shift;
  mask=(1<<shift)-1;
  rbits=sig&mask;
  half=1<<(shift-1);
  inc=0;
  if (rbits>half) inc=1;
  else if (rbits==half) inc=kept&1;
  kept+=inc;
  if (!kept) return sign<<31;
  return (sign<<31)|kept;		//kept 0x800000 => smallest normal, exact
}

F64 HtF32(F64 x)
{//round-to-nearest-even to F32, returned as F64 (an exact F32 value).
  return HtF32FromBits(HtF32BitsRNE(x));
}

F64 HtFmaF32(F64 a,F64 b,F64 c)
{//fused multiply-add reproduced: a*b+c is exact in F64 for F32 operands in
 //the sine's controlled domain, so one round to F32 == a hardware FMA.
  return HtF32(a*b+c);
}

F64 HtFractF32(F64 x)
{
  return HtF32(x-Floor(x));
}

F64 HtModF32(F64 x,F64 y)
{//GLSL mod bit-reproduced: x - y*floor(x/y), each sub-op rounded to F32.
  return HtF32(x-HtF32(y*Floor(HtF32(x/y))));
}

F64 HtSqrtF32(F64 x)
{
  return HtF32(Sqrt(x));
}

F64 HtInvSqrtF32(F64 x)
{//gallivm inversesqrt = rcp(sqrt(x)); rcp = exact 1.0/x fdiv (two roundings).
  return HtF32(1.0/HtF32(Sqrt(x)));
}

//gallivm Cephes-F32 sin/cos constants, folded to their F32 value once.
F64 htf_fopi,htf_dp1,htf_dp2,htf_dp3;
F64 htf_sin0,htf_sin1,htf_sin2;
F64 htf_cos0,htf_cos1,htf_cos2;
F64 htf_half,htf_one;

U0 HtF32Init()
{//fold the Cephes constants to F32; call once at startup after HtLibInit.
 //NOTE: TempleOS's float lexer corrupts literals with ~20 significant
 //digits (verified: 2.4187564849853515625e-4 parses to 5.74e-5). Each
 //constant below is a 9-significant-digit decimal, which numpy confirms
 //rounds to the SAME F32 bit pattern as the exact gallivm constant.
  htf_fopi=HtF32(1.273239545);			//4/pi
  htf_dp1=HtF32(-0.78515625);
  htf_dp2=HtF32(-2.418756485e-4);
  htf_dp3=HtF32(-3.774894977e-8);
  htf_sin0=HtF32(-1.951529589e-4);
  htf_sin1=HtF32(8.332160874e-3);
  htf_sin2=HtF32(-1.666665461e-1);
  htf_cos0=HtF32(2.443315712e-5);
  htf_cos1=HtF32(-1.388731625e-3);
  htf_cos2=HtF32(4.166664568e-2);
  htf_half=HtF32(0.5);
  htf_one=HtF32(1.0);
}

F64 HtSinCosF32(F64 x,I64 want_sin)
{//Replica of gallivm lp_build_sin_or_cos (Cephes single-precision). Every
 //arithmetic step is done in F64 and rounded to F32; each fma is HtFmaF32.
 //cos is NOT sin(x+pi/2): its quadrant/sign logic differs (validated vs
 //tools/glsl_ref.py). See plans/013 open question 5.
 //plan 014: forces PC64 internally -- the fma reproduction needs exact F64
 //products, and hw-mode callers run at PC24.
  F64 xa,prod,y,xr,z,ys,yc,w,a,b,c,d,r;
  I64 emm2_i,emm2_add,emm2_and,emm2c,sgn,poly_sin,htpc;
  htpc=HtPCSave64;
  xa=HtF32(Abs(x));
  prod=HtF32(xa*htf_fopi);
  emm2_i=ToI64(prod);			//FPToSI: truncate toward zero (xa>=0)
  emm2_add=emm2_i+1;
  emm2_and=emm2_add&(~1);
  y=HtF32(emm2_and);
  xr=HtFmaF32(y,htf_dp1,xa);		//extended-precision argument reduction
  xr=HtFmaF32(y,htf_dp2,xr);
  xr=HtFmaF32(y,htf_dp3,xr);
  z=HtF32(xr*xr);
  //cos polynomial: ((yc*z)*z) - 0.5*z + 1.0
  yc=htf_cos0;
  yc=HtFmaF32(yc,z,htf_cos1);
  yc=HtFmaF32(yc,z,htf_cos2);
  a=HtF32(yc*z);
  b=HtF32(a*z);
  c=HtF32(htf_half*z);
  d=HtF32(b-c);
  yc=HtF32(d+htf_one);
  //sin polynomial: fma(ys*z, xr, xr)
  ys=htf_sin0;
  ys=HtFmaF32(ys,z,htf_sin1);
  ys=HtFmaF32(ys,z,htf_sin2);
  w=HtF32(ys*z);
  ys=HtFmaF32(w,xr,xr);
  if (want_sin) {
    poly_sin=!(emm2_and&2);
    sgn=x<0.0;
    if (emm2_add&4) sgn=!sgn;
  } else {
    emm2c=emm2_and-2;
    poly_sin=!(emm2c&2);
    sgn=!(emm2c&4);
  }
  if (poly_sin) r=ys;
  else r=yc;
  if (sgn) r=-r;
  HtPCRestore(htpc);
  return r;
}

F64 HtSinF32(F64 x)
{
  return HtSinCosF32(x,1);
}

F64 HtCosF32(F64 x)
{
  return HtSinCosF32(x,0);
}

//--- plan 013: F32 cross-component helpers ---------------------------------
//llvmpipe does NOT fuse ordinary a*b+c (probe: user a*b+c is muladd, not
//FMA), so these reproduce it with PER-OP F32 rounding: each product and each
//accumulate is rounded to F32 (left-associative), matching the scalar path
//the emitter already emits. Used when a builtin result feeds an amplified
//hash argument (Reinder fbm raymarchers route mat*vec/dot into sin).

//dot reduces RIGHT-associatively in llvmpipe (probe: perR matches 100%),
//i.e. x*x + (y*y + (z*z + w*w)); each product and add rounded to F32.
F64 HtV2DotF32(CHtV2 *a,CHtV2 *b)
{
  return HtF32(HtF32(a->x*b->x)+HtF32(a->y*b->y));
}

F64 HtV3DotF32(CHtV3 *a,CHtV3 *b)
{
  F64 s=HtF32(HtF32(a->y*b->y)+HtF32(a->z*b->z));
  return HtF32(HtF32(a->x*b->x)+s);
}

F64 HtV4DotF32(CHtV4 *a,CHtV4 *b)
{
  F64 s=HtF32(HtF32(a->z*b->z)+HtF32(a->w*b->w));
  s=HtF32(HtF32(a->y*b->y)+s);
  return HtF32(HtF32(a->x*b->x)+s);
}

F64 HtV2LenF32(CHtV2 *a)
{
  return HtSqrtF32(HtV2DotF32(a,a));
}

F64 HtV3LenF32(CHtV3 *a)
{
  return HtSqrtF32(HtV3DotF32(a,a));
}

F64 HtV4LenF32(CHtV4 *a)
{
  return HtSqrtF32(HtV4DotF32(a,a));
}

F64 HtV2DistF32(CHtV2 *a,CHtV2 *b)
{
  CHtV2 d;
  d.x=HtF32(a->x-b->x);
  d.y=HtF32(a->y-b->y);
  return HtV2LenF32(&d);
}

F64 HtV3DistF32(CHtV3 *a,CHtV3 *b)
{
  CHtV3 d;
  d.x=HtF32(a->x-b->x);
  d.y=HtF32(a->y-b->y);
  d.z=HtF32(a->z-b->z);
  return HtV3LenF32(&d);
}

F64 HtV4DistF32(CHtV4 *a,CHtV4 *b)
{
  CHtV4 d;
  d.x=HtF32(a->x-b->x);
  d.y=HtF32(a->y-b->y);
  d.z=HtF32(a->z-b->z);
  d.w=HtF32(a->w-b->w);
  return HtV4LenF32(&d);
}

U0 HtV2NormF32(CHtV2 *out,CHtV2 *a)
{//GLSL normalize = v * inversesqrt(dot(v,v))
  F64 s=HtInvSqrtF32(HtV2DotF32(a,a));
  out->x=HtF32(a->x*s);
  out->y=HtF32(a->y*s);
}

U0 HtV3NormF32(CHtV3 *out,CHtV3 *a)
{
  F64 s=HtInvSqrtF32(HtV3DotF32(a,a));
  out->x=HtF32(a->x*s);
  out->y=HtF32(a->y*s);
  out->z=HtF32(a->z*s);
}

U0 HtV4NormF32(CHtV4 *out,CHtV4 *a)
{
  F64 s=HtInvSqrtF32(HtV4DotF32(a,a));
  out->x=HtF32(a->x*s);
  out->y=HtF32(a->y*s);
  out->z=HtF32(a->z*s);
  out->w=HtF32(a->w*s);
}

U0 HtV3CrossF32(CHtV3 *out,CHtV3 *a,CHtV3 *b)
{
  F64 x=HtF32(HtF32(a->y*b->z)-HtF32(a->z*b->y)),
      y=HtF32(HtF32(a->z*b->x)-HtF32(a->x*b->z)),
      z=HtF32(HtF32(a->x*b->y)-HtF32(a->y*b->x));
  out->x=x;
  out->y=y;
  out->z=z;
}

U0 HtV2ReflectF32(CHtV2 *out,CHtV2 *i,CHtV2 *n)
{//i - 2*dot(n,i)*n
  F64 d=HtF32(HtF32(2.0*HtV2DotF32(n,i)));
  out->x=HtF32(i->x-HtF32(d*n->x));
  out->y=HtF32(i->y-HtF32(d*n->y));
}

U0 HtV3ReflectF32(CHtV3 *out,CHtV3 *i,CHtV3 *n)
{
  F64 d=HtF32(2.0*HtV3DotF32(n,i));
  out->x=HtF32(i->x-HtF32(d*n->x));
  out->y=HtF32(i->y-HtF32(d*n->y));
  out->z=HtF32(i->z-HtF32(d*n->z));
}

U0 HtM2MulVF32(CHtV2 *out,CHtM2 *m,CHtV2 *v)
{
  F64 x=HtF32(m->m[0]*v->x),y=HtF32(m->m[1]*v->x);
  x=HtF32(x+HtF32(m->m[2]*v->y));
  y=HtF32(y+HtF32(m->m[3]*v->y));
  out->x=x;
  out->y=y;
}

U0 HtVMulM2F32(CHtV2 *out,CHtV2 *v,CHtM2 *m)
{
  F64 x=HtF32(m->m[0]*v->x),y=HtF32(m->m[2]*v->x);
  x=HtF32(x+HtF32(m->m[1]*v->y));
  y=HtF32(y+HtF32(m->m[3]*v->y));
  out->x=x;
  out->y=y;
}

//matrix multiplies reduce right-associatively too (each output is a dot).
F64 HtMixF32(F64 a,F64 b,F64 t)
{//GLSL mix = a + (b-a)*t, per-op F32 (probe: matches llvmpipe 100%).
  return HtF32(a+HtF32(HtF32(b-a)*t));
}

U0 HtM3MulVF32(CHtV3 *out,CHtM3 *m,CHtV3 *v)
{
  out->x=HtF32(HtF32(m->m[0]*v->x)+HtF32(HtF32(m->m[3]*v->y)+HtF32(m->m[6]*v->z)));
  out->y=HtF32(HtF32(m->m[1]*v->x)+HtF32(HtF32(m->m[4]*v->y)+HtF32(m->m[7]*v->z)));
  out->z=HtF32(HtF32(m->m[2]*v->x)+HtF32(HtF32(m->m[5]*v->y)+HtF32(m->m[8]*v->z)));
}

U0 HtVMulM3F32(CHtV3 *out,CHtV3 *v,CHtM3 *m)
{
  out->x=HtF32(HtF32(m->m[0]*v->x)+HtF32(HtF32(m->m[1]*v->y)+HtF32(m->m[2]*v->z)));
  out->y=HtF32(HtF32(m->m[3]*v->x)+HtF32(HtF32(m->m[4]*v->y)+HtF32(m->m[5]*v->z)));
  out->z=HtF32(HtF32(m->m[6]*v->x)+HtF32(HtF32(m->m[7]*v->y)+HtF32(m->m[8]*v->z)));
}

U0 HtM4MulVF32(CHtV4 *out,CHtM4 *m,CHtV4 *v)
{
  F64 sx,sy,sz,sw;
  sx=HtF32(HtF32(m->m[8]*v->z)+HtF32(m->m[12]*v->w));
  sx=HtF32(HtF32(m->m[4]*v->y)+sx);
  out->x=HtF32(HtF32(m->m[0]*v->x)+sx);
  sy=HtF32(HtF32(m->m[9]*v->z)+HtF32(m->m[13]*v->w));
  sy=HtF32(HtF32(m->m[5]*v->y)+sy);
  out->y=HtF32(HtF32(m->m[1]*v->x)+sy);
  sz=HtF32(HtF32(m->m[10]*v->z)+HtF32(m->m[14]*v->w));
  sz=HtF32(HtF32(m->m[6]*v->y)+sz);
  out->z=HtF32(HtF32(m->m[2]*v->x)+sz);
  sw=HtF32(HtF32(m->m[11]*v->z)+HtF32(m->m[15]*v->w));
  sw=HtF32(HtF32(m->m[7]*v->y)+sw);
  out->w=HtF32(HtF32(m->m[3]*v->x)+sw);
}

U0 HtVMulM4F32(CHtV4 *out,CHtV4 *v,CHtM4 *m)
{
  F64 sx,sy,sz,sw;
  sx=HtF32(HtF32(m->m[2]*v->z)+HtF32(m->m[3]*v->w));
  sx=HtF32(HtF32(m->m[1]*v->y)+sx);
  out->x=HtF32(HtF32(m->m[0]*v->x)+sx);
  sy=HtF32(HtF32(m->m[6]*v->z)+HtF32(m->m[7]*v->w));
  sy=HtF32(HtF32(m->m[5]*v->y)+sy);
  out->y=HtF32(HtF32(m->m[4]*v->x)+sy);
  sz=HtF32(HtF32(m->m[10]*v->z)+HtF32(m->m[11]*v->w));
  sz=HtF32(HtF32(m->m[9]*v->y)+sz);
  out->z=HtF32(HtF32(m->m[8]*v->x)+sz);
  sw=HtF32(HtF32(m->m[14]*v->z)+HtF32(m->m[15]*v->w));
  sw=HtF32(HtF32(m->m[13]*v->y)+sw);
  out->w=HtF32(HtF32(m->m[12]*v->x)+sw);
}

U0 HtMMulMF32(F64 *out,F64 *a,F64 *b,I64 n)
{//out = a*b, n x n column-major, per-op right-assoc F32; out must not alias.
  I64 c,r,k;
  F64 s;
  for (c=0;c<n;c++)
    for (r=0;r<n;r++) {
      s=HtF32(a[(n-1)*n+r]*b[c*n+(n-1)]);
      for (k=n-2;k>=0;k--)
        s=HtF32(HtF32(a[k*n+r]*b[c*n+k])+s);
      out[c*n+r]=s;
    }
}

//--- plan 014: Hf helper twins (PC24 callers, no software rounding) ---------
//Same formulas and associativity as the F32 family above; every arithmetic
//op is rounded by the caller's PC24 control word instead of HtF32 calls.
//Division/sqrt become single-rounded (exactly llvmpipe's fdiv/sqrtss; the
//F32 family double-rounds those through F64 -- a documented ~1/2^29 1-ULP
//artifact this path removes).

F64 HtFractHf(F64 x)
{
  return x-Floor(x);
}

F64 HtModHf(F64 x,F64 y)
{//x - y*floor(x/y); PC24 rounds each op.
  return x-y*Floor(x/y);
}

F64 HtInvSqrtHf(F64 x)
{//gallivm inversesqrt = rcp(sqrt(x)); both ops PC24-rounded.
  return 1.0/Sqrt(x);
}

F64 HtMixHf(F64 a,F64 b,F64 t)
{//GLSL mix = a + (b-a)*t, per-op.
  return a+(b-a)*t;
}

F64 HtV2DotHf(CHtV2 *a,CHtV2 *b)
{
  return a->x*b->x+a->y*b->y;
}

F64 HtV3DotHf(CHtV3 *a,CHtV3 *b)
{//right-associative like the F32 family (llvmpipe-verified order)
  F64 s=a->y*b->y+a->z*b->z;
  return a->x*b->x+s;
}

F64 HtV4DotHf(CHtV4 *a,CHtV4 *b)
{
  F64 s=a->z*b->z+a->w*b->w;
  s=a->y*b->y+s;
  return a->x*b->x+s;
}

F64 HtV2LenHf(CHtV2 *a)
{
  return Sqrt(HtV2DotHf(a,a));
}

F64 HtV3LenHf(CHtV3 *a)
{
  return Sqrt(HtV3DotHf(a,a));
}

F64 HtV4LenHf(CHtV4 *a)
{
  return Sqrt(HtV4DotHf(a,a));
}

F64 HtV2DistHf(CHtV2 *a,CHtV2 *b)
{
  CHtV2 d;
  d.x=a->x-b->x;
  d.y=a->y-b->y;
  return HtV2LenHf(&d);
}

F64 HtV3DistHf(CHtV3 *a,CHtV3 *b)
{
  CHtV3 d;
  d.x=a->x-b->x;
  d.y=a->y-b->y;
  d.z=a->z-b->z;
  return HtV3LenHf(&d);
}

F64 HtV4DistHf(CHtV4 *a,CHtV4 *b)
{
  CHtV4 d;
  d.x=a->x-b->x;
  d.y=a->y-b->y;
  d.z=a->z-b->z;
  d.w=a->w-b->w;
  return HtV4LenHf(&d);
}

U0 HtV2NormHf(CHtV2 *out,CHtV2 *a)
{//GLSL normalize = v * inversesqrt(dot(v,v))
  F64 s=HtInvSqrtHf(HtV2DotHf(a,a));
  out->x=a->x*s;
  out->y=a->y*s;
}

U0 HtV3NormHf(CHtV3 *out,CHtV3 *a)
{
  F64 s=HtInvSqrtHf(HtV3DotHf(a,a));
  out->x=a->x*s;
  out->y=a->y*s;
  out->z=a->z*s;
}

U0 HtV4NormHf(CHtV4 *out,CHtV4 *a)
{
  F64 s=HtInvSqrtHf(HtV4DotHf(a,a));
  out->x=a->x*s;
  out->y=a->y*s;
  out->z=a->z*s;
  out->w=a->w*s;
}

U0 HtV3CrossHf(CHtV3 *out,CHtV3 *a,CHtV3 *b)
{
  F64 x=a->y*b->z-a->z*b->y,
      y=a->z*b->x-a->x*b->z,
      z=a->x*b->y-a->y*b->x;
  out->x=x;
  out->y=y;
  out->z=z;
}

U0 HtV2ReflectHf(CHtV2 *out,CHtV2 *i,CHtV2 *n)
{//i - 2*dot(n,i)*n
  F64 d=2.0*HtV2DotHf(n,i);
  out->x=i->x-d*n->x;
  out->y=i->y-d*n->y;
}

U0 HtV3ReflectHf(CHtV3 *out,CHtV3 *i,CHtV3 *n)
{
  F64 d=2.0*HtV3DotHf(n,i);
  out->x=i->x-d*n->x;
  out->y=i->y-d*n->y;
  out->z=i->z-d*n->z;
}

U0 HtM2MulVHf(CHtV2 *out,CHtM2 *m,CHtV2 *v)
{
  F64 x=m->m[0]*v->x,y=m->m[1]*v->x;
  x=x+m->m[2]*v->y;
  y=y+m->m[3]*v->y;
  out->x=x;
  out->y=y;
}

U0 HtVMulM2Hf(CHtV2 *out,CHtV2 *v,CHtM2 *m)
{
  F64 x=m->m[0]*v->x,y=m->m[2]*v->x;
  x=x+m->m[1]*v->y;
  y=y+m->m[3]*v->y;
  out->x=x;
  out->y=y;
}

U0 HtM3MulVHf(CHtV3 *out,CHtM3 *m,CHtV3 *v)
{
  F64 sx,sy,sz;
  sx=m->m[3]*v->y+m->m[6]*v->z;
  out->x=m->m[0]*v->x+sx;
  sy=m->m[4]*v->y+m->m[7]*v->z;
  out->y=m->m[1]*v->x+sy;
  sz=m->m[5]*v->y+m->m[8]*v->z;
  out->z=m->m[2]*v->x+sz;
}

U0 HtVMulM3Hf(CHtV3 *out,CHtV3 *v,CHtM3 *m)
{
  F64 sx,sy,sz;
  sx=m->m[1]*v->y+m->m[2]*v->z;
  out->x=m->m[0]*v->x+sx;
  sy=m->m[4]*v->y+m->m[5]*v->z;
  out->y=m->m[3]*v->x+sy;
  sz=m->m[7]*v->y+m->m[8]*v->z;
  out->z=m->m[6]*v->x+sz;
}

U0 HtM4MulVHf(CHtV4 *out,CHtM4 *m,CHtV4 *v)
{
  F64 sx,sy,sz,sw;
  sx=m->m[8]*v->z+m->m[12]*v->w;
  sx=m->m[4]*v->y+sx;
  out->x=m->m[0]*v->x+sx;
  sy=m->m[9]*v->z+m->m[13]*v->w;
  sy=m->m[5]*v->y+sy;
  out->y=m->m[1]*v->x+sy;
  sz=m->m[10]*v->z+m->m[14]*v->w;
  sz=m->m[6]*v->y+sz;
  out->z=m->m[2]*v->x+sz;
  sw=m->m[11]*v->z+m->m[15]*v->w;
  sw=m->m[7]*v->y+sw;
  out->w=m->m[3]*v->x+sw;
}

U0 HtVMulM4Hf(CHtV4 *out,CHtV4 *v,CHtM4 *m)
{
  F64 sx,sy,sz,sw;
  sx=m->m[2]*v->z+m->m[3]*v->w;
  sx=m->m[1]*v->y+sx;
  out->x=m->m[0]*v->x+sx;
  sy=m->m[6]*v->z+m->m[7]*v->w;
  sy=m->m[5]*v->y+sy;
  out->y=m->m[4]*v->x+sy;
  sz=m->m[10]*v->z+m->m[11]*v->w;
  sz=m->m[9]*v->y+sz;
  out->z=m->m[8]*v->x+sz;
  sw=m->m[14]*v->z+m->m[15]*v->w;
  sw=m->m[13]*v->y+sw;
  out->w=m->m[12]*v->x+sw;
}

U0 HtMMulMHf(F64 *out,F64 *a,F64 *b,I64 n)
{//out = a*b, n x n column-major, right-assoc; out must not alias.
  I64 c,r,k;
  F64 s;
  for (c=0;c<n;c++)
    for (r=0;r<n;r++) {
      s=a[(n-1)*n+r]*b[c*n+(n-1)];
      for (k=n-2;k>=0;k--)
        s=a[k*n+r]*b[c*n+k]+s;
      out[c*n+r]=s;
    }
}

//plan 014: non-replicated transcendentals must keep their plan-013 numerics
//(computed at TempleOS's default 64-bit precision, no result rounding), so
//under PC24 callers they force PC64 internally.

F64 HtExpHf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=Exp(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtLnHf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=Ln(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtLog2Hf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=Log2(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtExp2Hf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtExp2F(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtPowHf(F64 x,F64 y)
{
  I64 htpc=HtPCSave64;
  F64 r=Pow(x,y);
  HtPCRestore(htpc);
  return r;
}

F64 HtTanHf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtTanF(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtASinHf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtASinF(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtACosHf(F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtACosF(x);
  HtPCRestore(htpc);
  return r;
}

F64 HtAtanHf(F64 y_over_x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtAtanF(y_over_x);
  HtPCRestore(htpc);
  return r;
}

F64 HtAtan2Hf(F64 y,F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtAtan2F(y,x);
  HtPCRestore(htpc);
  return r;
}

F64 HtSStepHf(F64 e0,F64 e1,F64 x)
{
  I64 htpc=HtPCSave64;
  F64 r=HtSStepF(e0,e1,x);
  HtPCRestore(htpc);
  return r;
}

U0 HtLibSelfTest()
{//Accuracy and semantics gate; the holytoy proof greps for HT LIB OK.
  I64 i,ok=TRUE,ok2=TRUE;
  F64 a,err,maxerr=0.0;
  for (i=0;i<10000;i++) {
    a=(i-5000)*0.01;
    err=Abs(HtSinF(a)-Sin(a));
    if (err>maxerr) maxerr=err;
  }
  if (maxerr>0.0002) ok=FALSE;
  if (Abs(HtModF(-1.5,2.0)-0.5)>1e-12) ok=FALSE;
  if (Abs(HtAtan2F(1.0,0.0)-pi*0.5)>1e-9) ok=FALSE;
  if (HtF32Bits(1.0)!=0x3F800000) ok=FALSE;
  if (HtF32Bits(-2.0)!=0xC0000000) ok=FALSE;
  if (Abs(HtF32FromBits(0x3F800000)-1.0)>1e-12) ok=FALSE;
  if (ok)
    "HT LIB OK\n";
  else
    "HT LIB FAIL maxerr=%g\n",maxerr;
  //plan 013: F32 RNE rounding gate. Host-verified bit patterns (normals,
  //fixed-subnormal denormal branch, overflow) plus HtF32 idempotence.
  HtF32Init;
  if (HtF32BitsRNE(0.1)!=0x3DCCCCCD) ok2=FALSE;
  if (HtF32BitsRNE(1.0/3.0)!=0x3EAAAAAB) ok2=FALSE;
  if (HtF32BitsRNE(43758.5453)!=0x472AEE8C) ok2=FALSE;
  if (HtF32BitsRNE(12.9898)!=0x414FD639) ok2=FALSE;
  if (HtF32BitsRNE(78.233)!=0x429C774C) ok2=FALSE;
  if (HtF32BitsRNE(-2.5)!=0xC0200000) ok2=FALSE;
  if (HtF32BitsRNE(1.0)!=0x3F800000) ok2=FALSE;
  if (HtF32BitsRNE(-2.0)!=0xC0000000) ok2=FALSE;
  if (HtF32BitsRNE(1e39)!=0x7F800000) ok2=FALSE;
  if (HtF32BitsRNE(1e-40)!=0x000116C2) ok2=FALSE;
  if (HtF32BitsRNE(1.4e-45)!=0x00000001) ok2=FALSE;
  if (HtF32(HtF32(0.1))!=HtF32(0.1)) ok2=FALSE;
  if (ok2)
    "HT F32 OK\n";
  else
    "HT F32 FAIL\n";
  //plan 014: PC24 hardware-rounding gate. Native mul/add/div under 24-bit
  //precision control must bit-match HtF32 (RNE incl. ties), and 80-bit
  //intermediates must be gone. On failure fall back to the plan-013
  //software rounding path BEFORE any shader is compiled.
  {
    I64 htpc,k,seed,raw,ok3=TRUE;
    F64 x,r,one,zero,tiny;
    one=1.0;
    zero=0.0;
    raw=(1023-60)<<52;			//2^-60
    tiny=*(&raw)(F64 *);
    seed=88172645463325252;
    htpc=HtPCSave24;
    if ((one+tiny)-one!=zero) ok3=FALSE;	//PC24 must round 1+2^-60 to 1
    for (k=0;k<4096;k++) {
      seed=seed*6364136223846793005+1442695040888963407;
      if (k%3==0)			//exact RNE tie patterns
        raw=((seed>>1&0x7FFF)%240-120+1023)<<52|
            ((seed>>13)&0xFFFFFF)<<29|0x10000000;
      else				//F32 normal range
        raw=((seed>>1&0x7FFF)%252-125+1023)<<52|(seed>>5)&0xFFFFFFFFFFFFF;
      if (seed&1) raw=raw|0x8000000000000000;
      x=*(&raw)(F64 *);
      r=HtF32(x);			//integer path, PC-independent
      if (x*one!=r) ok3=FALSE;
      if (x+zero!=r) ok3=FALSE;
      if (x/one!=r) ok3=FALSE;
    }
    HtPCRestore(htpc);
    if (ok3)
      "HT PC24 OK\n";
    else {
      ht_hwf32_mode=FALSE;
      "HT PC24 SWFALLBACK\n";
    }
  }
}
