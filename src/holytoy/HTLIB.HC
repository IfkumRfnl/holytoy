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

U0 HtLibSelfTest()
{//Accuracy and semantics gate; the holytoy proof greps for HT LIB OK.
  I64 i,ok=TRUE;
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
}
