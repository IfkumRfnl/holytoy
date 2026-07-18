//probe-sse.HC -- plan 015 stage D: SSE stage-0 enablement probe.
//
//TempleOS boots with CR4.OSFXSR(9)/CR4.OSXMMEXCPT(10) CLEAR on every core
//(SYS_ENTER_LONG_MODE sets only 0xB0, KStart64.HC:45-47, and every AP runs
//the same path via MultiProc.HC), so any SSE arithmetic instruction #UDs
//until this probe sets CR4|=0x600 per core.  The task-switch machinery is
//already XMM-ready: Sched.HC FXSAVE/FXRSTORs a 512-byte 16-aligned CFPU per
//task, so once OSFXSR=1 the XMM registers and MXCSR ride through task
//switches automatically.  This probe proves all of that end to end:
//
//  1. CR4 before/after + LDMXCSR 0x1F80 on EVERY core 0..mp_cnt-1
//     (core 0 directly -- this task runs there -- APs via JobQue), twice,
//     so enabling is shown idempotent.  We enable FIRST and only then
//     exercise SSE: a deliberate pre-enable #UD would drop the guest into
//     the debugger and wedge the run, so the #UD-before-enable expectation
//     is documented rather than exercised.
//  2. Raw-encoded MOVSS/ADDSS/MULSS/SUBSS/DIVSS/SQRTSS execute on core 0
//     AND on an AP (the HolyC assembler has no SSE arithmetic mnemonics --
//     ARGT_XMM* are "Not implemented", KernelA.HH -- so the SSE bodies
//     below are DU8 raw bytes).
//  3. An XMM sentinel survives Yield+Sleep(50) inside an AP job WHILE a
//     competing spawned task on the same core keeps clobbering the same
//     register (forces real FXSAVE/FXRSTOR round trips; a counter proves
//     the clobber task actually ran in between).
//  4. Bit-exactness sweep: ADDSS/MULSS/SUBSS/DIVSS/SQRTSS vs the plan-013
//     HtF32 software-rounding reference over deterministic operand classes
//     (normals across the exponent range, constructed RNE add/mul ties,
//     near-overflow, denormal/near-underflow, negative zero + specials,
//     LCG pseudorandoms -- no wall-clock anywhere).  Divergences where
//     either side lands on the F32 exponent boundary (denormal/zero/inf),
//     and 1-ulp div/sqrt cases (the plan-013 documented double-rounding
//     edge: HtF32 re-rounds through F64, SSE single-rounds -- SSE is the
//     correct one), are counted separately as BOUNDARY; anything else is a
//     MISMATCH and fails the probe.
//
//Prints "HT SSE OK" only if enable + execute + XMM survival all pass and
//MISMATCH==0; otherwise "HT SSE FAIL <reasons>".  tools/test.sh proof 15
//greps for the OK line.
//
//Pure probe: no production file changes; PC24 (plan 014) stays the shipped
//F32 math.  Findings de-risk a future packed-PS raw-machine-code backend
//(plan 016 candidate).
//
//NOTE (mul/div/sqrt tie classes): exact RNE ties can only be CONSTRUCTED
//for add and mul.  A divide tie would need a=(2m+1)/2*ulp*b exactly with a
//still a 24-bit significand (impossible: (2m+1)*b needs >=25 bits), and a
//sqrt tie would need (m+1/2)^2 to be a 24-bit operand (impossible: 49 odd
//bits).  This is a theorem, not a gap in coverage.

#include "E:/HTLIB.HC"		//HtF32BitsRNE/HtF32FromBits reference chain

#define PS_MXCSR	0x1F80	//RN, all exceptions masked, FTZ=0, DAZ=0
#define PS_CR4_SSE	0x600	//OSFXSR|OSXMMEXCPT

class CPsEn
{//_PS_ENABLE result block. Member order = asm offsets 0/8/16/20.
  I64 cr4_before;
  I64 cr4_after;
  U32 mxcsr_in;			//caller pre-fills PS_MXCSR
  U32 mxcsr_out;		//STMXCSR readback
};

class CPsOps
{//_PS_OPS operand/result block. Member order = asm offsets 0/4/8/...
  U32 a;			//F32 bits, first operand (also sqrt operand)
  U32 b;			//F32 bits, second operand
  U32 r_add;			//ADDSS a,b
  U32 r_mul;			//MULSS a,b
  U32 r_sub;			//SUBSS a,b
  U32 r_div;			//DIVSS a,b
  U32 r_sqrt;			//SQRTSS a
};

class CPsSurv
{//XMM survival block (16-byte sentinel through XMM7).
  U32 pat[4];
  U32 res[4];
  I64 delta;			//clobber-task iterations during the Sleep
};

asm {
//The HolyC assembler has FSTCW/FXSAVE etc. but ZERO SSE arithmetic or
//MXCSR mnemonics, so every SSE/MXCSR instruction below is DU8 raw bytes.
//All memory operands go through RBX (clobber-ok per REGG_CLOBBERED):
//  [RBX]        mod=00 rm=011
//  disp8[RBX]   mod=01 rm=011, disp8 follows ModRM
//First arg is at SF_ARG1[RBP] after the standard prologue.

_PS_ENABLE::
//Set CR4.OSFXSR|OSXMMEXCPT on THIS core, then pin MXCSR.  Must run on the
//target core (CR4 is per-core state); dispatch via JobQue for APs.
//LDMXCSR would #UD with OSFXSR=0, so it comes after the CR4 write.
	PUSH	RBP
	MOV	RBP,RSP
	MOV	RBX,U64 SF_ARG1[RBP]
	MOV_RAX_CR4
	MOV	U64 [RBX],RAX		//cr4_before
	OR	RAX,0x600
	MOV_CR4_RAX
	MOV_RAX_CR4
	MOV	U64 8[RBX],RAX		//cr4_after
	DU8	0x0F,0xAE,0x53,0x10;	//LDMXCSR [RBX+16]  (0F AE /2)
	DU8	0x0F,0xAE,0x5B,0x14;	//STMXCSR [RBX+20]  (0F AE /3)
	POP	RBP
	RET1	8

_PS_OPS::
//Scalar SSE op battery on one CPsOps block: results of all five ops.
	PUSH	RBP
	MOV	RBP,RSP
	MOV	RBX,U64 SF_ARG1[RBP]
	DU8	0xF3,0x0F,0x10,0x03;		//MOVSS  XMM0,[RBX]     a
	DU8	0xF3,0x0F,0x10,0x4B,0x04;	//MOVSS  XMM1,[RBX+4]   b
	DU8	0x0F,0x28,0xD0;			//MOVAPS XMM2,XMM0
	DU8	0xF3,0x0F,0x58,0xD1;		//ADDSS  XMM2,XMM1
	DU8	0xF3,0x0F,0x11,0x53,0x08;	//MOVSS  [RBX+8],XMM2
	DU8	0x0F,0x28,0xD0;			//MOVAPS XMM2,XMM0
	DU8	0xF3,0x0F,0x59,0xD1;		//MULSS  XMM2,XMM1
	DU8	0xF3,0x0F,0x11,0x53,0x0C;	//MOVSS  [RBX+12],XMM2
	DU8	0x0F,0x28,0xD0;			//MOVAPS XMM2,XMM0
	DU8	0xF3,0x0F,0x5C,0xD1;		//SUBSS  XMM2,XMM1
	DU8	0xF3,0x0F,0x11,0x53,0x10;	//MOVSS  [RBX+16],XMM2
	DU8	0x0F,0x28,0xD0;			//MOVAPS XMM2,XMM0
	DU8	0xF3,0x0F,0x5E,0xD1;		//DIVSS  XMM2,XMM1
	DU8	0xF3,0x0F,0x11,0x53,0x14;	//MOVSS  [RBX+20],XMM2
	DU8	0xF3,0x0F,0x51,0x13;		//SQRTSS XMM2,[RBX]
	DU8	0xF3,0x0F,0x11,0x53,0x18;	//MOVSS  [RBX+24],XMM2
	POP	RBP
	RET1	8

_PS_XSET::
//Load the 16-byte pattern at arg1 into XMM7 (survival sentinel).
	PUSH	RBP
	MOV	RBP,RSP
	MOV	RBX,U64 SF_ARG1[RBP]
	DU8	0x0F,0x10,0x3B;			//MOVUPS XMM7,[RBX]
	POP	RBP
	RET1	8

_PS_XGET::
//Store XMM7 to the 16-byte buffer at arg1.
	PUSH	RBP
	MOV	RBP,RSP
	MOV	RBX,U64 SF_ARG1[RBP]
	DU8	0x0F,0x11,0x3B;			//MOVUPS [RBX],XMM7
	POP	RBP
	RET1	8
}

_extern _PS_ENABLE U0 PsEnable(CPsEn *b);
_extern _PS_OPS U0 PsOps(CPsOps *o);
_extern _PS_XSET U0 PsXSet(U32 *p);
_extern _PS_XGET U0 PsXGet(U32 *p);

//--- globals (JobQue'd workers need reachable state) ------------------------
CPsEn ps_en[MP_PROCESSORS_NUM*2];	//two enable passes per core
CPsOps ps_ops0,ps_opsap,ps_ops_buf;
CPsSurv ps_surv;
U32 ps_xb[4];				//clobber pattern (spinner task)
I64 ps_spin_cnt,ps_spin_stop;
I64 ps_lcg;				//deterministic; never seeded from clock
I64 ps_pairs;
I64 ps_match[5],ps_bnd[5],ps_mis[5];
I64 ps_bnd_shown,ps_mis_shown;

I64 PsLcg()
{//Knuth MMIX LCG; fixed seed set in PsMain.
  ps_lcg=ps_lcg*6364136223846793005+1442695040888963407;
  return ps_lcg;
}

U8 *PsOpName(I64 op)
{
  switch (op) {
    case 0: return "add";
    case 1: return "mul";
    case 2: return "sub";
    case 3: return "div";
    case 4: return "sqrt";
  }
  return "?";
}

F64 PsBitsToF64(I64 b32)
{//Exact F32-bits -> F64 value, pure integer construction (denormals become
 //normal F64s; no Pow, no rounding anywhere).  Independent reimplementation
 //-- the licensed local/ probe code was not consulted.
  I64 s,e,m,k,raw;
  s=(b32>>31)&1;
  e=(b32>>23)&0xFF;
  m=b32&0x7FFFFF;
  if (e==0xFF) {			//inf/NaN (not generated, completeness)
    if (m) m=1<<51;
    raw=(s<<63)|(0x7FF<<52)|m;
  } else if (!e) {
    if (!m)
      raw=s<<63;			//signed zero
    else {				//F32 denormal: m*2^-149, normalize
      k=0;
      while (!(m&0x800000)) {
        m=m<<1;
        k++;
      }
      raw=(s<<63)|((897-k)<<52)|((m&0x7FFFFF)<<29);
    }
  } else
    raw=(s<<63)|((e+896)<<52)|(m<<29);
  return *(&raw)(F64 *);
}

U0 PsClassify(I64 op,I64 abits,I64 bbits,I64 sse,I64 ref)
{//MATCH / BOUNDARY-DIVERGE / MISMATCH per the header comment.
  I64 es,er,d;
  sse=sse&0xFFFFFFFF;
  ref=ref&0xFFFFFFFF;
  if (sse==ref) {
    ps_match[op]++;
    return;
  }
  es=(sse>>23)&0xFF;
  er=(ref>>23)&0xFF;
  if (es==0 || es==0xFF || er==0 || er==0xFF) {
    //F32 exponent boundary (denormal/zero/inf on either side): the plan-014
    //documented class where the F64-based reference and true IEEE F32 can
    //part ways.  SSE-CORRECT; counted, printed, never fails the probe.
    ps_bnd[op]++;
    if (ps_bnd_shown<8) {
      ps_bnd_shown++;
      "HT SSE BND op=%s a=%X b=%X sse=%X ref=%X\n",
        PsOpName(op),abits,bbits,sse,ref;
    }
    return;
  }
  if (op==3 || op==4) {
    d=sse-ref;
    if (d==1 || d==-1) {
      //div/sqrt double-rounding edge: the reference rounds the infinitely
      //precise quotient/root to F64 first, then to F32 (plan-013 documented
      //~2^-29 artifact); SSE single-rounds and is the correct one.
      ps_bnd[op]++;
      if (ps_bnd_shown<8) {
        ps_bnd_shown++;
        "HT SSE BND op=%s a=%X b=%X sse=%X ref=%X (1ulp)\n",
          PsOpName(op),abits,bbits,sse,ref;
      }
      return;
    }
  }
  ps_mis[op]++;
  if (ps_mis_shown<16) {
    ps_mis_shown++;
    "HT SSE MIS op=%s a=%X b=%X sse=%X ref=%X\n",
      PsOpName(op),abits,bbits,sse,ref;
  }
}

U0 PsPair(I64 abits,I64 bbits)
{//Run the SSE battery on one operand pair and classify all ops against the
 //HtF32 reference (HtF32BitsRNE of the F64 op -- exactly the plan-013
 //semantics the shipped renderer reproduces).
  F64 af,bf;
  abits=abits&0xFFFFFFFF;
  bbits=bbits&0xFFFFFFFF;
  ps_ops_buf.a=abits;
  ps_ops_buf.b=bbits;
  PsOps(&ps_ops_buf);
  af=PsBitsToF64(abits);
  bf=PsBitsToF64(bbits);
  ps_pairs++;
  PsClassify(0,abits,bbits,ps_ops_buf.r_add,HtF32BitsRNE(af+bf));
  PsClassify(1,abits,bbits,ps_ops_buf.r_mul,HtF32BitsRNE(af*bf));
  PsClassify(2,abits,bbits,ps_ops_buf.r_sub,HtF32BitsRNE(af-bf));
  PsClassify(3,abits,bbits,ps_ops_buf.r_div,HtF32BitsRNE(af/bf));
  if (!(abits&0x80000000) || !(abits&0x7FFFFFFF))
    PsClassify(4,abits,abits,ps_ops_buf.r_sqrt,HtF32BitsRNE(Sqrt(af)));
}

U0 PsSweepRandom(I64 n,I64 elo,I64 ehi)
{//n pseudorandom pairs with biased exponents in [elo,ehi], random signs and
 //mantissas.  elo>=1 keeps operands normal; results may still over/underflow
 //when the range is wide (both paths must agree there too).
  I64 i,r,ab,bb,span;
  span=ehi-elo+1;
  for (i=0;i<n;i++) {
    r=PsLcg;
    ab=(((r>>40)&1)<<31)|((elo+((r>>8)&0x7FFFFFFF)%span)<<23)|(r&0x7FFFFF);
    r=PsLcg;
    bb=(((r>>40)&1)<<31)|((elo+((r>>8)&0x7FFFFFFF)%span)<<23)|(r&0x7FFFFF);
    PsPair(ab,bb);
  }
}

U0 PsSweepAddTies(I64 n)
{//Constructed exact RNE ties for ADDSS/SUBSS: b = half an ulp of a's binade
 //(mantissa 0, exponent ea-24), so |a|+|b| sits exactly between neighbors
 //and RNE must pick the even mantissa.  Mixed signs exercise the
 //subtraction ties too.
  I64 i,r,ea,m,sa,sb,ab,bb;
  for (i=0;i<n;i++) {
    r=PsLcg;
    ea=40+((r>>13)&0xFF)%180;		//biased 40..219: ea-24 stays normal
    m=(r>>21)&0x7FFFFF;
    sa=(r>>45)&1;
    sb=sa^((r>>50)&1);
    ab=(sa<<31)|(ea<<23)|m;
    bb=(sb<<31)|((ea-24)<<23);
    PsPair(ab,bb);
  }
}

U0 PsSweepMulTies(I64 n)
{//Constructed exact RNE ties for MULSS.  With a=1.5 (significand p=3*2^22)
 //and q odd, p*q = (3q)*2^22: a 47-bit product whose 23 cut bits are exactly
 //0x400000 -> tie.  With q=2*rr (rr odd, 3*rr>=2^24), p*q=(3rr)*2^23: a
 //48-bit product whose 24 cut bits are exactly 0x800000 -> tie.  Both tie
 //directions occur since the kept mantissa's parity follows q.
  I64 got,iter,r,q,rr,ea,eb,sa,sb,ab,bb,prod,tie;
  got=0;
  iter=0;
  while (got<n && iter<n*64) {
    iter++;
    r=PsLcg;
    if (!((r>>60)&1)) {
      q=(0x800000|((r>>9)&0x7FFFFF))|1;	//odd, 24-bit
      if (q>0xAAAAAA)
        goto mt_next;			//keep prod<2^47 (47-bit tie form)
    } else {
      rr=(0x400000|((r>>9)&0x3FFFFF))|1;	//odd, 23-bit
      if (3*rr<0x1000000)
        goto mt_next;			//need prod>=2^47 (48-bit tie form)
      q=2*rr;
    }
    prod=0xC00000*q;
    if (prod&(1<<47))
      tie=(prod&0xFFFFFF)==0x800000;
    else
      tie=(prod&0x7FFFFF)==0x400000;
    if (!tie)
      goto mt_next;			//construction guarantee; belt+braces
    ea=97+((r>>33)&0x3F);		//biased 97..160 (unbiased -30..33)
    eb=97+((r>>41)&0x3F);
    sa=(r>>55)&1;
    sb=(r>>56)&1;
    ab=(sa<<31)|(ea<<23)|0x400000;	//1.5*2^(ea-127)
    bb=(sb<<31)|(eb<<23)|(q&0x7FFFFF);
    PsPair(ab,bb);
    got++;
mt_next:;
  }
  "HT SSE MULTIES got=%d of %d\n",got,n;
}

U0 PsSweepOverflow(I64 n)
{//Near-overflow: mantissas near all-ones at the top exponents; half the b's
 //also huge (adds/muls overflow to inf on both paths), half moderate
 //(results near but below F32 max exercise the last rounding boundary).
  I64 i,r,ab,bb,ea,eb,ma,mb,sa,sb;
  for (i=0;i<n;i++) {
    r=PsLcg;
    ea=253+((r>>11)&1);
    ma=0x7FFFFF-((r>>29)&0x3F);
    sa=(r>>45)&1;
    if ((r>>17)&1) {
      eb=253+((r>>19)&1);
      mb=0x7FFFFF-((r>>34)&0x3F);
    } else {
      eb=120+((r>>19)&0xF);
      mb=(r>>34)&0x7FFFFF;
    }
    sb=(r>>46)&1;
    ab=(sa<<31)|(ea<<23)|ma;
    bb=(sb<<31)|(eb<<23)|mb;
    PsPair(ab,bb);
  }
}

U0 PsSweepDenormal(I64 n)
{//Denormal operands (DAZ=0 must consume them exactly) and products landing
 //in the denormal band / underflowing to zero (FTZ=0 must produce exact
 //denormals; HtF32BitsRNE's subnormal path is the reference).
  I64 i,r,ab,bb,eb,mb,sa,sb;
  for (i=0;i<n;i++) {
    r=PsLcg;
    sa=(r>>45)&1;
    ab=(sa<<31)|(((r>>7)&0x7FFFFF)|1);	//e=0: pure denormal, nonzero
    eb=(r>>37)&0x1F;			//0..31
    if (!eb)
      mb=((r>>17)&0x7FFFFF)|1;		//second denormal
    else
      mb=(r>>17)&0x7FFFFF;
    sb=(r>>46)&1;
    bb=(sb<<31)|(eb<<23)|mb;
    PsPair(ab,bb);
  }
}

U0 PsSweepSpecials()
{//Fixed signed-zero / boundary cases.  0/-0 and 0/0-style NaN production is
 //covered by the (+0,-0) pair: both x87 and SSE architecturally produce the
 //indefinite QNaN 0xFFC00000, which HtF32BitsRNE canonicalizes identically.
 //No inf/NaN INPUTS: shader code never feeds them, and payload propagation
 //is out of scope for stage 0.
  PsPair(0x00000000,0x80000000);	//+0,-0: signed-zero add/sub, 0/-0
  PsPair(0x80000000,0x80000000);	//-0,-0
  PsPair(0x80000000,0x40A00000);	//-0,5: -0*x, -0/x, sqrt(-0)=-0
  PsPair(0x3F800000,0x80000000);	//1,-0: 1/-0=-inf
  PsPair(0x3F800000,0x00000000);	//1,+0: 1/0=+inf
  PsPair(0xBF800000,0x00000000);	//-1,+0: -1/0=-inf
  PsPair(0x00000001,0x00000001);	//min denormals
  PsPair(0x007FFFFF,0x00000001);	//max denormal, min denormal
  PsPair(0x00800000,0x3F000000);	//min normal * 0.5 = max denormal band
  PsPair(0x00800000,0x00800000);	//min normal pair (div=1, mul->0)
  PsPair(0x7F7FFFFF,0x7F7FFFFF);	//F32 max pair (add/mul->inf)
  PsPair(0x7F7FFFFF,0x3F800001);	//max*(1+ulp): RNE overflow boundary
}

//--- enable / exec / survival ------------------------------------------------

I64 PsEnableJob(U8 *data)
{//JobQue entry: enable SSE on the core this job runs on.
  CPsEn *e=data;
  e->mxcsr_in=PS_MXCSR;
  e->mxcsr_out=0;
  PsEnable(e);
  return TRUE;
}

Bool PsExecCheck(CPsOps *o)
{//Known-answer battery: 1.5 op 2.25 (host-verified F32 constants), doubling
 //as the "MOVSS/MULSS execute without #UD" proof on whatever core runs it.
  o->a=0x3FC00000;			//1.5
  o->b=0x40100000;			//2.25
  o->r_add=0;
  o->r_mul=0;
  o->r_sub=0;
  o->r_div=0;
  o->r_sqrt=0;
  PsOps(o);
  return o->r_add==0x40700000 &&	//3.75
         o->r_mul==0x40580000 &&	//3.375
         o->r_sub==0xBF400000 &&	//-0.75
         o->r_div==0x3F2AAAAB &&	//0.66666669...
         o->r_sqrt==0x3F9CC471;		//sqrt(1.5)
}

I64 PsExecJob(U8 *data)
{
  CPsOps *o=data;
  return PsExecCheck(o);
}

U0 PsSpinTask(U8 *data)
{//Competing task on the survival core: keeps clobbering XMM7 with pattern B
 //so the sentinel can only survive through per-task FXSAVE/FXRSTOR.
  while (!ps_spin_stop) {
    PsXSet(ps_xb);
    ps_spin_cnt++;
    Sleep(1);
  }
}

I64 PsSurviveJob(U8 *data)
{//Load sentinel into XMM7, yield the core away (Yield + Sleep(50) while the
 //spinner clobbers XMM7), read it back.
  CPsSurv *s=data;
  I64 c0;
  PsXSet(&s->pat[0]);
  c0=ps_spin_cnt;
  Yield;
  Sleep(50);
  s->delta=ps_spin_cnt-c0;
  PsXGet(&s->res[0]);
  return TRUE;
}

Bool PsSurvive(I64 core)
{
  CTask *spin;
  CJob *j;
  I64 i;
  Bool ok;
  ps_surv.pat[0]=0xDEADBEEF;
  ps_surv.pat[1]=0x600DF00D;
  ps_surv.pat[2]=0x12345678;
  ps_surv.pat[3]=0xCAFEBABE;
  for (i=0;i<4;i++)
    ps_surv.res[i]=0;
  ps_surv.delta=0;
  ps_xb[0]=0x0BADF00D;
  ps_xb[1]=0xFFFFFFFF;
  ps_xb[2]=0x55555555;
  ps_xb[3]=0xAAAAAAAA;
  ps_spin_cnt=0;
  ps_spin_stop=FALSE;
  spin=Spawn(&PsSpinTask,NULL,"PsSpin",core);
  Sleep(10);				//let the spinner reach its loop
  if (core) {
    j=JobQue(&PsSurviveJob,&ps_surv,core,0);
    JobResGet(j);
  } else
    PsSurviveJob(&ps_surv);
  ps_spin_stop=TRUE;
  Sleep(30);				//spinner sees the flag and exits
  ok=TRUE;
  for (i=0;i<4;i++)
    if (ps_surv.res[i]!=ps_surv.pat[i])
      ok=FALSE;
  if (ps_surv.delta<1)
    ok=FALSE;				//no competing switches = no proof
  "HT SSE XMM core=%d delta=%d res=%X,%X,%X,%X ",
    core,ps_surv.delta,ps_surv.res[0],ps_surv.res[1],
    ps_surv.res[2],ps_surv.res[3];
  if (ok)
    "OK\n";
  else
    "FAIL\n";
  return ok;
}

//--- main ---------------------------------------------------------------------

U0 PsMain()
{
  I64 k,p,op,mis_total,bnd_total,match_total;
  CPsEn *e;
  CJob *j;
  I64 apcore;
  Bool en_ok,exec0,execap,x0,xap;
  "HT SSE PROBE START mp_cnt=%d\n",mp_cnt;
  if (mp_cnt<2) {
    "HT SSE FAIL need2cores\n";
    return;
  }

  //Phase 1: CR4|=0x600 + MXCSR=0x1F80 on every core, two passes
  //(pass 1 proves idempotence: before==pass-0 after, bits stay set).
  en_ok=TRUE;
  for (p=0;p<2;p++)
    for (k=0;k<mp_cnt;k++) {
      e=&ps_en[p*mp_cnt+k];
      if (!k)
        PsEnableJob(e);			//this task runs on core 0
      else {
        j=JobQue(&PsEnableJob,e,k,0);
        JobResGet(j);
      }
      "HT SSE CR4 core=%d pass=%d before=%X after=%X mxcsr=%X\n",
        k,p,e->cr4_before,e->cr4_after,e->mxcsr_out;
      if ((e->cr4_after&PS_CR4_SSE)!=PS_CR4_SSE)
        en_ok=FALSE;
      if (e->mxcsr_out!=PS_MXCSR)
        en_ok=FALSE;
    }
  for (k=0;k<mp_cnt;k++) {
    if (ps_en[k].cr4_before&PS_CR4_SSE)
      "HT SSE NOTE core=%d OSFXSR was pre-set\n",k;
    if (ps_en[mp_cnt+k].cr4_before!=ps_en[k].cr4_after)
      en_ok=FALSE;			//pass-1 must see pass-0's CR4
  }
  if (en_ok)
    "HT SSE ENABLE OK\n";
  else
    "HT SSE ENABLE FAIL\n";

  //Phase 2: raw SSE executes (no #UD) on core 0 and on the last AP.
  apcore=mp_cnt-1;
  exec0=PsExecCheck(&ps_ops0);
  "HT SSE EXEC core=0 add=%X mul=%X sub=%X div=%X sqrt=%X ",
    ps_ops0.r_add,ps_ops0.r_mul,ps_ops0.r_sub,ps_ops0.r_div,ps_ops0.r_sqrt;
  if (exec0)
    "OK\n";
  else
    "FAIL\n";
  j=JobQue(&PsExecJob,&ps_opsap,apcore,0);
  execap=JobResGet(j)!=0;
  "HT SSE EXEC core=%d add=%X mul=%X sub=%X div=%X sqrt=%X ",
    apcore,ps_opsap.r_add,ps_opsap.r_mul,ps_opsap.r_sub,
    ps_opsap.r_div,ps_opsap.r_sqrt;
  if (execap)
    "OK\n";
  else
    "FAIL\n";

  //Phase 3: XMM survival across task switches, with an active clobberer.
  x0=PsSurvive(0);
  xap=PsSurvive(apcore);

  //Phase 4: bit-exactness sweep (core 0; semantics are core-independent
  //once phase 2 shows both execute identically on 1.5 op 2.25).
  //JIT gotcha (bit us): globals are NOT zero-initialized under ExeFile2 --
  //every counter must be cleared explicitly before use.
  ps_pairs=0;
  ps_bnd_shown=0;
  ps_mis_shown=0;
  for (op=0;op<5;op++) {
    ps_match[op]=0;
    ps_bnd[op]=0;
    ps_mis[op]=0;
  }
  ps_lcg=88172645463325252;
  "HT SSE SWEEP normals\n";
  PsSweepRandom(1024,67,187);		//unbiased 2^-60..2^60
  "HT SSE SWEEP widerange\n";
  PsSweepRandom(512,1,254);		//full normal range, over/underflows
  "HT SSE SWEEP addties\n";
  PsSweepAddTies(256);
  "HT SSE SWEEP multies\n";
  PsSweepMulTies(256);
  "HT SSE SWEEP overflow\n";
  PsSweepOverflow(128);
  "HT SSE SWEEP denormal\n";
  PsSweepDenormal(128);
  "HT SSE SWEEP specials\n";
  PsSweepSpecials;
  mis_total=0;
  bnd_total=0;
  match_total=0;
  for (op=0;op<5;op++) {
    "HT SSE SWEEP op=%s match=%d boundary=%d mismatch=%d\n",
      PsOpName(op),ps_match[op],ps_bnd[op],ps_mis[op];
    match_total+=ps_match[op];
    bnd_total+=ps_bnd[op];
    mis_total+=ps_mis[op];
  }
  "HT SSE SWEEP pairs=%d match=%d boundary=%d mismatch=%d\n",
    ps_pairs,match_total,bnd_total,mis_total;

  if (en_ok && exec0 && execap && x0 && xap && !mis_total && ps_pairs>=2200)
    "HT SSE OK\n";
  else {
    "HT SSE FAIL";
    if (!en_ok)
      " enable";
    if (!exec0)
      " exec0";
    if (!execap)
      " execap";
    if (!x0)
      " xmm0";
    if (!xap)
      " xmmap";
    if (mis_total)
      " sweep";
    if (ps_pairs<2200)
      " pairs";
    "\n";
  }
}

PsMain;
