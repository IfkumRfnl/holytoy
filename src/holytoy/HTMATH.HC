//holytoy fixed-point math library (HTMATH) -- LUT sin/cos for per-pixel code.
//
//Angle convention: ANGLES ARE TURNS in the caller's fixed-point format
//(1.0 turn = 2*pi radians). A power-of-two turn makes wrap a mask:
//  16.16: one turn = 0x10000  (quarter turn = 0x4000)
//  10.22: one turn = 0x400000 (quarter turn = 0x100000)
//Results are in the SAME format: HTMSin16 returns sin in 16.16 (+-0x10000),
//HTMSin22 in 10.22 (+-0x400000). Negative angles and angles beyond one turn
//are fine (mask wraps; I64>>n is SAR -- Compiler/BackA.HC ICShift emits the
//signed opcode set for I64).
//
//One shared 4096-entry table stores sin scaled by 2^30, generated once at
//startup from F64 Sin by HTMInit (call it before any lookup). Lookups
//linearly interpolate between adjacent entries, so intrinsic table error is
//~(2*pi/4096)^2/8 =~ 3e-7 of full scale; end-to-end error is dominated by
//the caller's angle quantization (16.16: 2*pi/65536 rad =~ 6.3/65536).
//
//ACCURACY GATE: whenever this file changes, rerun src/bench-math.HC (which
//embeds a copy -- keep in sync) and check its "BENCH maxerr ... OK" line:
//max |LUT sin - Sin| over 10k angles must stay <= 10/65536 of full scale.

#define HTM_BITS	12
#define HTM_N		4096
#define HTM_MASK	4095

I64 htm_sin_tbl[HTM_N];   //sin(2*pi*i/HTM_N) * 2^30

U0 HTMInit()
{//Build the sine table. Once, at startup; NOT per frame.
  I64 i;
  for (i=0;i<HTM_N;i++)
    htm_sin_tbl[i]=ToI64(Round(Sin(2*pi*i/HTM_N)*0x40000000));
}

I64 HTMSin16(I64 a)
{//sin of angle a (turns, 16.16); returns 16.16 in [-0x10000,0x10000].
  I64 i=(a>>4)&HTM_MASK,f=a&15,s0=htm_sin_tbl[i];
  return (s0+(((htm_sin_tbl[(i+1)&HTM_MASK]-s0)*f)>>4))>>14;
}

I64 HTMCos16(I64 a)
{//cos = quarter-turn-shifted sin.
  return HTMSin16(a+0x4000);
}

I64 HTMSin22(I64 a)
{//sin of angle a (turns, 10.22); returns 10.22 in [-0x400000,0x400000].
  I64 i=(a>>10)&HTM_MASK,f=a&1023,s0=htm_sin_tbl[i];
  return (s0+(((htm_sin_tbl[(i+1)&HTM_MASK]-s0)*f)>>10))>>8;
}

I64 HTMCos22(I64 a)
{
  return HTMSin22(a+0x100000);
}

I64 HTMRad16(F64 r)
{//Radians -> turns in 16.16 (per-frame phase setup, not per-pixel).
  return ToI64(Round(r*(0x10000/(2*pi))));
}

I64 HTMRad22(F64 r)
{//Radians -> turns in 10.22.
  return ToI64(Round(r*(0x400000/(2*pi))));
}
