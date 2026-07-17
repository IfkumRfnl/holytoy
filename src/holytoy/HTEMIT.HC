//HolyToy HolyC emitter -- three-address statement lowering of the typed AST.
//
//Emission rules (the HolyC constraints that shaped them):
//  * every subexpression is materialized in a uniquely named temp exactly
//    once; leaf references (literals, variables) are used directly;
//  * everything is fully parenthesized (HolyC precedence differs from C);
//  * no ternary / && / || value expressions: lowered to if/else on temps
//    (&&/|| keep GLSL short-circuit semantics);
//  * no continue: loops emit a per-loop label and continue becomes goto;
//    all loops take the normal form while(1){cond;if(!c)break;body;lbl:;step}
//  * no casts are emitted; ToF64/ToI64 convert values (ToI64 truncates,
//    matching GLSL int()); mixed arithmetic auto-converts like C;
//  * GLSL uint is I64 masked to 32 bits after every wrapping operation;
//    GLSL int is I64 (unmasked; recorded deviation);
//  * vectors/matrices/structs are by-pointer at function boundaries, and
//    componentwise operations are expanded inline; cross-component work
//    calls HTLIB helpers;
//  * HolyC has no function prototypes, so user functions are emitted in
//    callee-first (post-order) call-graph order; GLSL forbids recursion.
//
//Generated unit layout: struct classes, uniform globals, user globals,
//functions (topo order), MainImage ABI glue, HtShaderInit (global
//initializers), and a trailing `HtShaderInit;` statement that runs at
//install time. HtInstallHoly appends the ht_new_fp binding itself.

class CHtVal
{
  I64 type;
  U8 text[96];
  Bool is_ptr;
};

#define HT_LV_PLAIN	0
#define HT_LV_SWZ	1
#define HT_LV_VECDYN	2
#define HT_LV_MATCOL	3

class CHtLval
{
  I64 kind,type,swz;
  U8 text[96];		//base (component-addressable)
  U8 idx[48];		//index temp text for VECDYN/MATCOL
  Bool is_ptr;
};

class CHtEmitter
{
  CHtProgram *prog;
  U8 *buf;
  I64 len,cap;
  I64 tmp;		//temp name counter
  I64 lbl;		//loop label counter
  I64 loop_lbl[64];	//continue label id per active loop (-1 = none)
  I64 loop_top;
  I64 *needs_ctx;	//plan 011: per-func-node, threads CHtCtx *ctx
  Bool has_ctx;		//plan 011: any per-invocation global exists
  Bool f32;		//plan 013: emit llvmpipe-reproducing F32 semantics
};

//plan 013: F32-semantics mode default (ON). HT.HC flips it off from the
//HOLYTOY_F32=0 escape knob (E:/F32.TXT), mirroring the SCALE.TXT plumbing.
Bool ht_f32_mode=TRUE;

Bool HtF32Elem(I64 t)
{//value whose components are floats (scalar float, float vector, or matrix)
  I64 k=HtTKind(t);
  return k==HTT_FLOAT || HtTIsFVec(k) || HtTIsMat(k);
}

Bool HtOutGrow(CHtEmitter *e,I64 extra)
{
  U8 *next;
  I64 cap=e->cap;
  if (e->len+extra+1<=cap) return TRUE;
  while (e->len+extra+1>cap) cap=cap*2;
  next=MAlloc(cap);
  if (e->buf) MemCpy(next,e->buf,e->len+1);
  else next[0]=0;
  Free(e->buf);
  e->buf=next;
  e->cap=cap;
  return TRUE;
}

U0 HtOutRaw(CHtEmitter *e,U8 *s,I64 n)
{
  HtOutGrow(e,n);
  MemCpy(e->buf+e->len,s,n);
  e->len+=n;
  e->buf[e->len]=0;
}

U0 HtOut(CHtEmitter *e,U8 *s)
{
  HtOutRaw(e,s,StrLen(s));
}

U0 HtOutF(CHtEmitter *e,U8 *fmt,...)
{
  U8 *s=StrPrintJoin(NULL,fmt,argc,argv);
  HtOut(e,s);
  Free(s);
}

U0 HtEmitError(CHtEmitter *e,I64 tok,U8 *msg)
{
  HtSemaError(e->prog,tok,msg);
}

//--- names and types ---------------------------------------------------------

U0 HtShortTok(CHtEmitter *e,I64 tok,U8 *buf)
{//identifier text truncated for generated names
  HtTokText(e->prog->lex,tok,buf,24);
}

U0 HtSymText(CHtEmitter *e,I64 s,U8 *buf)
{
  U8 nm[24];
  CHtSym *sym=&e->prog->sym[s];
  HtShortTok(e,sym->tok,nm);
  if (sym->kind==HT_SYM_GLOBAL)
    StrPrint(buf,"ug%d_%s",s,nm);
  else
    StrPrint(buf,"v%d_%s",s,nm);
}

U0 HtSymRef(CHtEmitter *e,I64 s,U8 *buf)
{//plan 011: reference text for a symbol. Per-invocation globals live in the
 //stack-allocated CHtCtx and are reached through ctx->; everything else
 //(shared-const globals, params, locals) uses its plain storage name.
  U8 nm[96];
  if (HtGlobalPerInvocation(e->prog,s)) {
    HtSymText(e,s,nm);
    StrPrint(buf,"ctx->%s",nm);
  } else
    HtSymText(e,s,buf);
}

U0 HtStructName(CHtEmitter *e,I64 sid,U8 *buf)
{
  U8 nm[24];
  HtShortTok(e,e->prog->struct_tok[sid],nm);
  StrPrint(buf,"US%d_%s",sid,nm);
}

U0 HtFuncName(CHtEmitter *e,I64 f,U8 *buf)
{
  U8 nm[24];
  HtShortTok(e,e->prog->node[f].tok,nm);
  StrPrint(buf,"uf%d_%s",f,nm);
}

Bool HtTIsComposite(I64 t)
{//needs a named storage location (not an I64/F64 rvalue)
  I64 k=HtTKind(t);
  if (HtTArr(t)) return TRUE;
  return HtTIsVec(k) || HtTIsMat(k) || k==HTT_STRUCT;
}

U0 HtTypeText(CHtEmitter *e,I64 t,U8 *buf)
{//HolyC type name for declarations (element type when array)
  I64 k=HtTKind(t);
  if (k==HTT_FLOAT) StrCpy(buf,"F64");
  else if (k==HTT_INT || k==HTT_UINT || k==HTT_BOOL) StrCpy(buf,"I64");
  else if (k==HTT_VEC2) StrCpy(buf,"CHtV2");
  else if (k==HTT_VEC3) StrCpy(buf,"CHtV3");
  else if (k==HTT_VEC4) StrCpy(buf,"CHtV4");
  else if (HTT_IVEC2<=k<=HTT_BVEC4) {
    if (HtVecSize(k)==2) StrCpy(buf,"CHtI2");
    else if (HtVecSize(k)==3) StrCpy(buf,"CHtI3");
    else StrCpy(buf,"CHtI4");
  } else if (k==HTT_MAT2) StrCpy(buf,"CHtM2");
  else if (k==HTT_MAT3) StrCpy(buf,"CHtM3");
  else if (k==HTT_MAT4) StrCpy(buf,"CHtM4");
  else if (k==HTT_STRUCT) HtStructName(e,HtTStruct(t),buf);
  else StrCpy(buf,"I64");
}

U8 *HtCompLetter(I64 k)
{
  if (k==0) return "x";
  if (k==1) return "y";
  if (k==2) return "z";
  return "w";
}

U0 HtValComp(CHtEmitter *e,CHtVal *v,I64 comp,U8 *buf)
{//text for component comp of value v (scalars splat)
  I64 k=HtTKind(v->type);
  U8 *sep=".";
  if (v->is_ptr) sep="->";
  if (HtTIsScalar(k)) {
    StrCpy(buf,v->text);
    return;
  }
  if (HtTIsVec(k)) {
    StrPrint(buf,"%s%s%s",v->text,sep,HtCompLetter(comp));
    return;
  }
  if (HtTIsMat(k)) {
    StrPrint(buf,"%s%sm[%d]",v->text,sep,comp);
    return;
  }
  StrCpy(buf,v->text);
}

U0 HtValAddr(CHtEmitter *e,CHtVal *v,U8 *buf)
{//address text of a composite value
  if (v->is_ptr) StrCpy(buf,v->text);
  else StrPrint(buf,"&%s",v->text);
}

I64 HtNewTmp(CHtEmitter *e,I64 type,CHtVal *out)
{//declare a fresh temp of packed type; fills out with its reference
  U8 ty[48];
  I64 id=e->tmp++;
  HtTypeText(e,type,ty);
  StrPrint(out->text,"t%d",id);
  out->type=type;
  out->is_ptr=FALSE;
  if (HtTArr(type))
    HtOutF(e,"%s t%d[%d];\n",ty,id,HtTArr(type));
  else
    HtOutF(e,"%s t%d;\n",ty,id);
  return id;
}

Bool HtElemIsUint(I64 t)
{
  I64 k=HtTKind(t);
  return k==HTT_UINT || HtTIsUVec(k);
}

//--- number literals -----------------------------------------------------------

U0 HtEmNumText(CHtEmitter *e,I64 tok,U8 *buf)
{
  CHtProgram *p=e->prog;
  CHtToken *t=&p->lex->tok[tok];
  U8 *s=p->lex->src+t->start;
  I64 n=t->len,i,mant_end,has_dot=FALSE,has_exp=FALSE;
  U8 m0[64],m1[32];
  if (HtNumType(p,tok)!=HTT_FLOAT) {
    StrPrint(buf,"%d",HtNumIntVal(p,tok));
    return;
  }
  //float: normalize to digits '.' digits [e[+-]digits]
  if (n>62) n=62;
  mant_end=n;
  for (i=0;i<n;i++) {
    if (s[i]=='.') has_dot=TRUE;
    if (s[i]=='e' || s[i]=='E') {
      has_exp=TRUE;
      mant_end=i;
      break;
    }
    if (s[i]=='f' || s[i]=='F') {
      mant_end=i;
      break;
    }
  }
  MemCpy(m0,s,mant_end);
  m0[mant_end]=0;
  if (!has_dot)
    CatPrint(m0,".0");
  else {
    if (m0[0]=='.') {
      StrCpy(m1,m0);
      StrCpy(m0,"0");
      CatPrint(m0,"%s",m1);
    }
    if (m0[StrLen(m0)-1]=='.')
      CatPrint(m0,"0");
  }
  if (has_exp) {
    i=mant_end;
    CatPrint(m0,"e");
    i++;
    if (s[i]=='+' || s[i]=='-') {
      if (s[i]=='-') CatPrint(m0,"-");
      i++;
    }
    while (i<n && '0'<=s[i]<='9') {
      CatPrint(m0,"%c",s[i]);
      i++;
    }
  }
  //plan 013: in F32 mode wrap float literals so the constant is used as an
  //exact F32 value (HtF32 returns the exact F64 image of the rounded F32),
  //keeping downstream products exact-in-F64. Non-float literals are unchanged.
  if (e->f32)
    StrPrint(buf,"HtF32(%s)",m0);
  else
    StrCpy(buf,m0);
}

//--- expression emission ---------------------------------------------------------

extern U0 HtEmExpr(CHtEmitter *e,I64 i,CHtVal *out);
extern U0 HtEmLval(CHtEmitter *e,I64 i,CHtLval *lv);
extern U0 HtEmStmt(CHtEmitter *e,I64 i);
extern U0 HtEmCtorConv(CHtEmitter *e,I64 dst_kind,I64 src_kind,U8 *d,U8 *s);

U0 HtLvalComp(CHtEmitter *e,CHtLval *lv,I64 comp,U8 *buf)
{//text of target component comp of an lvalue
  I64 k=HtTKind(lv->type),idx;
  U8 *sep=".";
  if (lv->is_ptr) sep="->";
  if (lv->kind==HT_LV_VECDYN) {
    StrPrint(buf,"(&%s%sx)[(%s)]",lv->text,sep,lv->idx);
    return;
  }
  if (lv->kind==HT_LV_MATCOL) {
    StrPrint(buf,"%s%sm[((%s)*%d)+%d]",lv->text,sep,lv->idx,
             HtVecSize(k),comp);
    return;
  }
  if (lv->kind==HT_LV_SWZ) {
    idx=(lv->swz>>(4+comp*4))&15;
    StrPrint(buf,"%s%s%s",lv->text,sep,HtCompLetter(idx));
    return;
  }
  if (HtTIsScalar(k)) {
    StrCpy(buf,lv->text);
    return;
  }
  if (HtTIsVec(k)) {
    StrPrint(buf,"%s%s%s",lv->text,sep,HtCompLetter(comp));
    return;
  }
  if (HtTIsMat(k)) {
    StrPrint(buf,"%s%sm[%d]",lv->text,sep,comp);
    return;
  }
  StrCpy(buf,lv->text);
}

U0 HtEmStore(CHtEmitter *e,CHtLval *lv,CHtVal *v)
{//store value v into lvalue lv, componentwise / MemCpy for structs+arrays
  I64 k=HtTKind(lv->type),cnt,c;
  U8 dst[112],src[112],a1[112],a2[112];
  if (HtTArr(lv->type) || k==HTT_STRUCT) {
    U8 ty[48];
    if (lv->is_ptr) StrCpy(a1,lv->text);
    else StrPrint(a1,"&%s",lv->text);
    HtValAddr(e,v,a2);
    HtTypeText(e,lv->type,ty);
    if (HtTArr(lv->type))
      HtOutF(e,"MemCpy(%s,%s,sizeof(%s)*%d);\n",a1,a2,ty,HtTArr(lv->type));
    else
      HtOutF(e,"MemCpy(%s,%s,sizeof(%s));\n",a1,a2,ty);
    return;
  }
  if (HtTIsScalar(k)) {
    HtLvalComp(e,lv,0,dst);
    HtOutF(e,"%s=(%s);\n",dst,v->text);
    return;
  }
  if (lv->kind==HT_LV_SWZ)
    cnt=lv->swz&15;
  else
    cnt=HtCompCount(k);
  for (c=0;c<cnt;c++) {
    HtLvalComp(e,lv,c,dst);
    HtValComp(e,v,c,src);
    HtOutF(e,"%s=(%s);\n",dst,src);
  }
}

U0 HtEmLval(CHtEmitter *e,I64 i,CHtLval *lv)
{//resolve an lvalue expression into a storable target descriptor
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtSym *s;
  CHtVal idx;
  CHtLval base;
  U8 nm[96],mn[24];
  I64 bk,inner,c0,cnt,c,src_i;
  MemSet(lv,0,sizeof(CHtLval));
  if (n->kind==HT_AST_NAME) {
    s=&p->sym[n->c];
    HtSymRef(e,n->c,nm);
    lv->type=n->type;
    if (s->kind==HT_SYM_PARAM) {
      if (HtTIsComposite(s->type)) {
        StrCpy(lv->text,nm);
        lv->is_ptr=TRUE;
      } else if (s->flags&HTF_OUT) {
        StrPrint(lv->text,"(*%s)",nm);
      } else
        StrCpy(lv->text,nm);
    } else
      StrCpy(lv->text,nm);
    return;
  }
  if (n->kind==HT_AST_MEMBER) {
    HtEmLval(e,n->a,&base);
    if (n->bind==HT_MEM_FIELD) {
      if (base.kind!=HT_LV_PLAIN) {
        HtEmitError(e,n->tok,"unsupported member target");
        return;
      }
      HtShortTok(e,p->node[n->c].tok,mn);
      lv->kind=HT_LV_PLAIN;
      lv->type=n->type;
      if (base.is_ptr)
        StrPrint(lv->text,"%s->m_%s",base.text,mn);
      else
        StrPrint(lv->text,"%s.m_%s",base.text,mn);
      return;
    }
    //swizzle store target
    if (base.kind==HT_LV_SWZ) {
      //compose swizzles
      cnt=n->c&15;
      lv->swz=cnt;
      for (c=0;c<cnt;c++) {
        src_i=(n->c>>(4+c*4))&15;
        inner=(base.swz>>(4+src_i*4))&15;
        lv->swz|=inner<<(4+c*4);
      }
      lv->kind=HT_LV_SWZ;
      lv->type=n->type;
      StrCpy(lv->text,base.text);
      lv->is_ptr=base.is_ptr;
      return;
    }
    if (base.kind!=HT_LV_PLAIN) {
      HtEmitError(e,n->tok,"unsupported swizzle target");
      return;
    }
    lv->kind=HT_LV_SWZ;
    lv->swz=n->c;
    lv->type=n->type;
    StrCpy(lv->text,base.text);
    lv->is_ptr=base.is_ptr;
    return;
  }
  if (n->kind==HT_AST_INDEX) {
    HtEmExpr(e,n->b,&idx);
    HtEmLval(e,n->a,&base);
    bk=HtTKind(p->node[n->a].type);
    if (HtTArr(p->node[n->a].type)) {
      if (base.kind!=HT_LV_PLAIN) {
        HtEmitError(e,n->tok,"unsupported array target");
        return;
      }
      lv->kind=HT_LV_PLAIN;
      lv->type=n->type;
      lv->is_ptr=FALSE;
      if (base.is_ptr)
        StrPrint(lv->text,"%s[(%s)]",base.text,idx.text);
      else
        StrPrint(lv->text,"%s[(%s)]",base.text,idx.text);
      return;
    }
    if (HtTIsVec(bk)) {
      lv->kind=HT_LV_VECDYN;
      lv->type=n->type;
      StrCpy(lv->text,base.text);
      lv->is_ptr=base.is_ptr;
      StrCpy(lv->idx,idx.text);
      return;
    }
    if (HtTIsMat(bk)) {
      lv->kind=HT_LV_MATCOL;
      lv->type=n->type;
      StrCpy(lv->text,base.text);
      lv->is_ptr=base.is_ptr;
      StrCpy(lv->idx,idx.text);
      return;
    }
    HtEmitError(e,n->tok,"unsupported index target");
    return;
  }
  HtEmitError(e,n->tok,"unsupported assignment target");
  no_warn c0;
}

U0 HtLvalToVal(CHtEmitter *e,CHtLval *lv,CHtVal *out)
{//read the current value of an lvalue into a value descriptor
  I64 k=HtTKind(lv->type),cnt,c;
  U8 src[112],dst[112];
  CHtVal t;
  if (lv->kind==HT_LV_PLAIN && !HtTArr(lv->type)) {
    out->type=lv->type;
    StrCpy(out->text,lv->text);
    out->is_ptr=lv->is_ptr;
    return;
  }
  //materialize into a temp
  HtNewTmp(e,lv->type,&t);
  if (HtTIsScalar(k))
    cnt=1;
  else if (lv->kind==HT_LV_SWZ)
    cnt=lv->swz&15;
  else
    cnt=HtCompCount(k);
  for (c=0;c<cnt;c++) {
    HtLvalComp(e,lv,c,src);
    HtValComp(e,&t,c,dst);
    HtOutF(e,"%s=(%s);\n",dst,src);
  }
  MemCpy(out,&t,sizeof(CHtVal));
}

U0 HtEmLvalAddr(CHtEmitter *e,I64 i,U8 *buf,I64 *copyback_node)
{//address text for an out/inout argument; *copyback_node set to the node
 //when a copy-in/copy-out temp had to be used (swizzle/vecdyn targets).
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtSym *s;
  CHtLval lv;
  U8 nm[96];
  *copyback_node=-1;
  if (n->kind==HT_AST_NAME) {
    s=&p->sym[n->c];
    HtSymRef(e,n->c,nm);
    if (s->kind==HT_SYM_PARAM &&
        (HtTIsComposite(s->type) || (s->flags&HTF_OUT))) {
      StrCpy(buf,nm);			//already a pointer
      return;
    }
    StrPrint(buf,"&%s",nm);
    return;
  }
  HtEmLval(e,i,&lv);
  if (lv.kind==HT_LV_PLAIN) {
    if (lv.is_ptr) StrCpy(buf,lv.text);
    else StrPrint(buf,"&%s",lv.text);
    return;
  }
  *copyback_node=i;			//caller manages a temp
  buf[0]=0;
}

U0 HtEmSplat(CHtEmitter *e,CHtVal *dst,CHtVal *src)
{//componentwise copy with scalar splat, int->float auto-conversion
  I64 cnt=HtCompCount(HtTKind(dst->type)),c;
  U8 d[112],s2[112];
  for (c=0;c<cnt;c++) {
    HtValComp(e,dst,c,d);
    HtValComp(e,src,c,s2);
    HtOutF(e,"%s=(%s);\n",d,s2);
  }
}

//componentwise scalar operation text builders --------------------------------

U0 HtEmBinComp(CHtEmitter *e,CHtVal *out,CHtVal *a,CHtVal *b,U8 *op,
               Bool mask)
{
  I64 cnt=HtCompCount(HtTKind(out->type)),c;
  Bool f=e->f32 && HtF32Elem(out->type);	//plan 013: round float results
  U8 d[112],x[112],y[112];
  for (c=0;c<cnt;c++) {
    HtValComp(e,out,c,d);
    HtValComp(e,a,c,x);
    HtValComp(e,b,c,y);
    if (mask)
      HtOutF(e,"%s=(((%s)%s(%s))&0xFFFFFFFF);\n",d,x,op,y);
    else if (f)
      HtOutF(e,"%s=HtF32((%s)%s(%s));\n",d,x,op,y);
    else
      HtOutF(e,"%s=((%s)%s(%s));\n",d,x,op,y);
  }
}

U0 HtEmBinary(CHtEmitter *e,I64 i,CHtVal *out)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtVal a,b,t;
  I64 at,bt,ak,bk,rk=HtTKind(n->type),c,cnt,msz;
  U8 op[4],d[112],x[112],y[112],pa[112],pb[112];
  CHtLexer *l=p->lex;
  Bool mask=HtElemIsUint(n->type);
  U8 *fs="";			//plan 013: F32 suffix for matrix helpers
  if (e->f32) fs="F32";
  HtTokText(l,n->tok,op,4);
  //short-circuit logical ops
  if (HtTokEq(l,n->tok,"&&") || HtTokEq(l,n->tok,"||")) {
    HtEmExpr(e,n->a,&a);
    HtNewTmp(e,HTT_BOOL,&t);
    HtOutF(e,"%s=((%s)!=0);\n",t.text,a.text);
    if (HtTokEq(l,n->tok,"&&"))
      HtOutF(e,"if (%s) {\n",t.text);
    else
      HtOutF(e,"if (!%s) {\n",t.text);
    HtEmExpr(e,n->b,&b);
    HtOutF(e,"%s=((%s)!=0);\n",t.text,b.text);
    HtOut(e,"}\n");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  HtEmExpr(e,n->a,&a);
  HtEmExpr(e,n->b,&b);
  at=p->node[n->a].type;
  bt=p->node[n->b].type;
  ak=HtTKind(at);
  bk=HtTKind(bt);
  if (HtTokEq(l,n->tok,"^^")) {
    HtNewTmp(e,HTT_BOOL,&t);
    HtOutF(e,"%s=(((%s)!=0)!=((%s)!=0));\n",t.text,a.text,b.text);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  //vector aggregate equality
  if ((HtTokEq(l,n->tok,"==") || HtTokEq(l,n->tok,"!=")) && HtTIsVec(ak)) {
    HtNewTmp(e,HTT_BOOL,&t);
    cnt=HtVecSize(ak);
    HtOutF(e,"%s=(",t.text);
    for (c=0;c<cnt;c++) {
      HtValComp(e,&a,c,x);
      HtValComp(e,&b,c,y);
      if (c) HtOut(e," && ");
      HtOutF(e,"((%s)==(%s))",x,y);
    }
    HtOut(e,");\n");
    if (HtTokEq(l,n->tok,"!="))
      HtOutF(e,"%s=!%s;\n",t.text,t.text);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  //matrix cases
  if (HtTIsMat(ak) || HtTIsMat(bk)) {
    if (HtTokEq(l,n->tok,"*")) {
      if (HtTIsMat(ak) && HtTIsMat(bk)) {
        msz=HtMatSize(ak);
        HtNewTmp(e,n->type,&t);
        HtValComp(e,&t,0,d);		//force materialization path
        HtValAddr(e,&a,pa);
        HtValAddr(e,&b,pb);
        //helpers take raw F64* column-major arrays
        if (a.is_ptr) StrPrint(x,"%s->m",a.text);
        else StrPrint(x,"%s.m",a.text);
        if (b.is_ptr) StrPrint(y,"%s->m",b.text);
        else StrPrint(y,"%s.m",b.text);
        if (t.is_ptr) StrPrint(d,"%s->m",t.text);
        else StrPrint(d,"%s.m",t.text);
        HtOutF(e,"HtMMulM%s(%s,%s,%s,%d);\n",fs,d,x,y,msz);
        MemCpy(out,&t,sizeof(CHtVal));
        return;
      }
      if (HtTIsMat(ak) && HtTIsFVec(bk)) {
        HtNewTmp(e,n->type,&t);
        HtValAddr(e,&t,d);
        HtValAddr(e,&a,pa);
        HtValAddr(e,&b,pb);
        HtOutF(e,"HtM%dMulV%s(%s,%s,%s);\n",HtMatSize(ak),fs,d,pa,pb);
        MemCpy(out,&t,sizeof(CHtVal));
        return;
      }
      if (HtTIsFVec(ak) && HtTIsMat(bk)) {
        HtNewTmp(e,n->type,&t);
        HtValAddr(e,&t,d);
        HtValAddr(e,&a,pa);
        HtValAddr(e,&b,pb);
        HtOutF(e,"HtVMulM%d%s(%s,%s,%s);\n",HtMatSize(bk),fs,d,pa,pb);
        MemCpy(out,&t,sizeof(CHtVal));
        return;
      }
    }
    //componentwise mat op mat/scalar
    HtNewTmp(e,n->type,&t);
    HtEmBinComp(e,&t,&a,&b,op,FALSE);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  //scalar result
  if (HtTIsScalar(rk)) {
    HtNewTmp(e,n->type,&t);
    if (mask)
      HtOutF(e,"%s=(((%s)%s(%s))&0xFFFFFFFF);\n",t.text,a.text,op,b.text);
    else if (e->f32 && rk==HTT_FLOAT)	//plan 013: round float arithmetic
      HtOutF(e,"%s=HtF32((%s)%s(%s));\n",t.text,a.text,op,b.text);
    else
      HtOutF(e,"%s=((%s)%s(%s));\n",t.text,a.text,op,b.text);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  //vector componentwise (with scalar splat on either side)
  HtNewTmp(e,n->type,&t);
  HtEmBinComp(e,&t,&a,&b,op,mask);
  MemCpy(out,&t,sizeof(CHtVal));
}

//--- constructors ----------------------------------------------------------------

U0 HtEmCtor(CHtEmitter *e,I64 i,CHtVal *out)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtVal t,av[16];
  I64 k=HtTKind(n->type),arg,n_args=0,c,cnt,total,src,ai,msz,at;
  U8 d[112],s2[112];
  arg=n->b;
  while (arg>=0) {
    HtEmExpr(e,arg,&av[n_args]);
    av[n_args].type=p->node[arg].type;
    n_args++;
    arg=p->node[arg].next;
  }
  if (HtTIsScalar(k)) {
    HtNewTmp(e,k,&t);
    at=HtTKind(av[0].type);
    HtValComp(e,&av[0],0,s2);
    if (k==HTT_BOOL)
      HtOutF(e,"%s=((%s)!=0);\n",t.text,s2);
    else if (k==HTT_FLOAT) {
      if (e->f32)			//plan 013: float(int) rounds to F32
        HtOutF(e,"%s=HtF32(%s);\n",t.text,s2);
      else
        HtOutF(e,"%s=(%s);\n",t.text,s2);	//auto int->float
    }
    else if (at==HTT_FLOAT) {
      if (k==HTT_UINT)
        HtOutF(e,"%s=(ToI64(%s)&0xFFFFFFFF);\n",t.text,s2);
      else
        HtOutF(e,"%s=ToI64(%s);\n",t.text,s2);
    } else {
      if (k==HTT_UINT)
        HtOutF(e,"%s=((%s)&0xFFFFFFFF);\n",t.text,s2);
      else
        HtOutF(e,"%s=(%s);\n",t.text,s2);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (HtTIsVec(k)) {
    cnt=HtVecSize(k);
    HtNewTmp(e,n->type,&t);
    total=0;
    for (ai=0;ai<n_args;ai++)
      total+=HtCompCount(HtTKind(av[ai].type));
    if (n_args==1 && total==1) {
      for (c=0;c<cnt;c++) {
        HtValComp(e,&t,c,d);
        HtValComp(e,&av[0],0,s2);
        HtEmCtorConv(e,k,HtTKind(av[0].type),d,s2);
      }
    } else {
      c=0;
      for (ai=0;ai<n_args && c<cnt;ai++) {
        for (src=0;src<HtCompCount(HtTKind(av[ai].type)) && c<cnt;src++) {
          HtValComp(e,&t,c,d);
          HtValComp(e,&av[ai],src,s2);
          HtEmCtorConv(e,k,HtTKind(av[ai].type),d,s2);
          c++;
        }
      }
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (HtTIsMat(k)) {
    msz=HtMatSize(k);
    HtNewTmp(e,n->type,&t);
    total=0;
    for (ai=0;ai<n_args;ai++)
      total+=HtCompCount(HtTKind(av[ai].type));
    if (n_args==1 && total==1) {
      HtValComp(e,&av[0],0,s2);
      for (c=0;c<msz*msz;c++) {
        HtValComp(e,&t,c,d);
        if ((c%msz)==(c/msz))
          HtOutF(e,"%s=(%s);\n",d,s2);
        else
          HtOutF(e,"%s=0.0;\n",d);
      }
    } else {
      c=0;
      for (ai=0;ai<n_args && c<msz*msz;ai++) {
        for (src=0;src<HtCompCount(HtTKind(av[ai].type)) &&
             c<msz*msz;src++) {
          HtValComp(e,&t,c,d);
          HtValComp(e,&av[ai],src,s2);
          HtOutF(e,"%s=(%s);\n",d,s2);
          c++;
        }
      }
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  HtEmitError(e,n->tok,"cannot emit constructor");
}

U0 HtEmCtorConv(CHtEmitter *e,I64 dst_kind,I64 src_kind,U8 *d,U8 *s)
{//one component store inside a vec constructor, with value conversion
  I64 de=HtVecElem(dst_kind),se;
  if (HtTIsScalar(src_kind)) se=src_kind;
  else se=HtVecElem(src_kind);
  if (de==HTT_NONE) de=dst_kind;
  if (de==HTT_FLOAT) {
    if (e->f32)				//plan 013: int->float rounds to F32
      HtOutF(e,"%s=HtF32(%s);\n",d,s);
    else
      HtOutF(e,"%s=(%s);\n",d,s);
  } else if (de==HTT_BOOL)
    HtOutF(e,"%s=((%s)!=0);\n",d,s);
  else if (se==HTT_FLOAT) {
    if (de==HTT_UINT)
      HtOutF(e,"%s=(ToI64(%s)&0xFFFFFFFF);\n",d,s);
    else
      HtOutF(e,"%s=ToI64(%s);\n",d,s);
  } else {
    if (de==HTT_UINT)
      HtOutF(e,"%s=((%s)&0xFFFFFFFF);\n",d,s);
    else
      HtOutF(e,"%s=(%s);\n",d,s);
  }
}

U0 HtEmStructCtor(CHtEmitter *e,I64 i,CHtVal *out)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtVal t,a;
  CHtLval mlv;
  I64 arg=n->b,m;
  U8 mn[24];
  HtNewTmp(e,n->type,&t);
  m=p->node[p->struct_node[HtTStruct(n->type)]].a;
  while (m>=0 && arg>=0) {
    HtEmExpr(e,arg,&a);
    MemSet(&mlv,0,sizeof(CHtLval));
    HtShortTok(e,p->node[m].tok,mn);
    mlv.kind=HT_LV_PLAIN;
    mlv.type=p->node[m].type;
    StrPrint(mlv.text,"%s.m_%s",t.text,mn);
    HtEmStore(e,&mlv,&a);
    m=p->node[m].next;
    arg=p->node[arg].next;
  }
  MemCpy(out,&t,sizeof(CHtVal));
}

//--- builtins ----------------------------------------------------------------------

U0 HtEmCompwise1(CHtEmitter *e,CHtVal *out,CHtVal *a,U8 *fn)
{
  I64 cnt=HtCompCount(HtTKind(out->type)),c;
  U8 d[112],x[112];
  for (c=0;c<cnt;c++) {
    HtValComp(e,out,c,d);
    HtValComp(e,a,c,x);
    HtOutF(e,"%s=%s((%s));\n",d,fn,x);
  }
}

U0 HtEmCompwise2(CHtEmitter *e,CHtVal *out,CHtVal *a,CHtVal *b,U8 *fn)
{
  I64 cnt=HtCompCount(HtTKind(out->type)),c;
  U8 d[112],x[112],y[112];
  for (c=0;c<cnt;c++) {
    HtValComp(e,out,c,d);
    HtValComp(e,a,c,x);
    HtValComp(e,b,c,y);
    HtOutF(e,"%s=%s((%s),(%s));\n",d,fn,x,y);
  }
}

U0 HtEmCompwise3(CHtEmitter *e,CHtVal *out,CHtVal *a,CHtVal *b,CHtVal *c2,
                 U8 *fn)
{
  I64 cnt=HtCompCount(HtTKind(out->type)),c;
  U8 d[112],x[112],y[112],z[112];
  for (c=0;c<cnt;c++) {
    HtValComp(e,out,c,d);
    HtValComp(e,a,c,x);
    HtValComp(e,b,c,y);
    HtValComp(e,c2,c,z);
    HtOutF(e,"%s=%s((%s),(%s),(%s));\n",d,fn,x,y,z);
  }
}

U0 HtEmBuiltin(CHtEmitter *e,I64 i,CHtVal *out)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtVal av[4],t;
  I64 arg=n->b,n_args=0,bi=n->c,c,cnt,vs,msz,r;
  U8 d[112],x[112],y[112],pa[112],pb[112],pc[112];
  U8 *fn1=NULL;
  U8 *fs="";		//plan 013: F32 suffix for cross-component helpers
  if (e->f32) fs="F32";
  while (arg>=0 && n_args<4) {
    HtEmExpr(e,arg,&av[n_args]);
    av[n_args].type=p->node[arg].type;
    n_args++;
    arg=p->node[arg].next;
  }
  //simple componentwise 1-arg float builtins. plan 013: in F32 mode route
  //sin/cos to the gallivm Cephes-F32 replica and wrap sqrt/inversesqrt/fract
  //so the result is rounded to F32 (the design's builtin table).
  if (bi==HT_BI_SIN) { if (e->f32) fn1="HtSinF32"; else fn1="HtSinF"; }
  else if (bi==HT_BI_COS) { if (e->f32) fn1="HtCosF32"; else fn1="HtCosF"; }
  else if (bi==HT_BI_TAN) fn1="HtTanF";
  else if (bi==HT_BI_ASIN) fn1="HtASinF";
  else if (bi==HT_BI_ACOS) fn1="HtACosF";
  else if (bi==HT_BI_EXP) fn1="Exp";
  else if (bi==HT_BI_LOG) fn1="Ln";
  else if (bi==HT_BI_EXP2) fn1="HtExp2F";
  else if (bi==HT_BI_LOG2) fn1="Log2";
  else if (bi==HT_BI_SQRT) { if (e->f32) fn1="HtSqrtF32"; else fn1="Sqrt"; }
  else if (bi==HT_BI_INVSQRT) {
    if (e->f32) fn1="HtInvSqrtF32"; else fn1="HtInvSqrt";
  }
  else if (bi==HT_BI_FLOOR) fn1="Floor";
  else if (bi==HT_BI_CEIL) fn1="Ceil";
  else if (bi==HT_BI_FRACT) { if (e->f32) fn1="HtFractF32"; else fn1="HtFract"; }
  else if (bi==HT_BI_ROUND) fn1="Round";
  else if (bi==HT_BI_TRUNC) fn1="Trunc";
  if (fn1) {
    HtNewTmp(e,n->type,&t);
    HtEmCompwise1(e,&t,&av[0],fn1);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_RADIANS || bi==HT_BI_DEGREES) {
    HtNewTmp(e,n->type,&t);
    cnt=HtCompCount(HtTKind(n->type));
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],c,x);
      if (bi==HT_BI_RADIANS)
        HtOutF(e,"%s=((%s)*0.0174532925199433);\n",d,x);
      else
        HtOutF(e,"%s=((%s)*57.2957795130823);\n",d,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_ABS || bi==HT_BI_SIGN) {
    HtNewTmp(e,n->type,&t);
    if (HtTKind(n->type)==HTT_FLOAT || HtTIsFVec(HtTKind(n->type))) {
      if (bi==HT_BI_ABS) HtEmCompwise1(e,&t,&av[0],"Abs");
      else HtEmCompwise1(e,&t,&av[0],"HtSignF");
    } else {
      if (bi==HT_BI_ABS) HtEmCompwise1(e,&t,&av[0],"AbsI64");
      else HtEmCompwise1(e,&t,&av[0],"HtSignI");
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_ATAN) {
    HtNewTmp(e,n->type,&t);
    if (n_args==1)
      HtEmCompwise1(e,&t,&av[0],"HtAtanF");
    else
      HtEmCompwise2(e,&t,&av[0],&av[1],"HtAtan2F");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_POW || bi==HT_BI_MOD) {
    HtNewTmp(e,n->type,&t);
    if (bi==HT_BI_POW) HtEmCompwise2(e,&t,&av[0],&av[1],"Pow");
    else if (e->f32) HtEmCompwise2(e,&t,&av[0],&av[1],"HtModF32");
    else HtEmCompwise2(e,&t,&av[0],&av[1],"HtModF");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_MIN || bi==HT_BI_MAX) {
    HtNewTmp(e,n->type,&t);
    if (HtTKind(n->type)==HTT_FLOAT || HtTIsFVec(HtTKind(n->type))) {
      if (bi==HT_BI_MIN) HtEmCompwise2(e,&t,&av[0],&av[1],"HtMinF");
      else HtEmCompwise2(e,&t,&av[0],&av[1],"HtMaxF");
    } else {
      if (bi==HT_BI_MIN) HtEmCompwise2(e,&t,&av[0],&av[1],"MinI64");
      else HtEmCompwise2(e,&t,&av[0],&av[1],"MaxI64");
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_CLAMP) {
    HtNewTmp(e,n->type,&t);
    if (HtTKind(n->type)==HTT_FLOAT || HtTIsFVec(HtTKind(n->type)))
      HtEmCompwise3(e,&t,&av[0],&av[1],&av[2],"HtClampF");
    else
      HtEmCompwise3(e,&t,&av[0],&av[1],&av[2],"HtClampI");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_MIX) {
    HtNewTmp(e,n->type,&t);
    if (e->f32) HtEmCompwise3(e,&t,&av[0],&av[1],&av[2],"HtMixF32");
    else HtEmCompwise3(e,&t,&av[0],&av[1],&av[2],"HtMixF");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_STEP) {
    HtNewTmp(e,n->type,&t);
    HtEmCompwise2(e,&t,&av[0],&av[1],"HtStepF");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_SSTEP) {
    HtNewTmp(e,n->type,&t);
    HtEmCompwise3(e,&t,&av[0],&av[1],&av[2],"HtSStepF");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  //cross-component helpers
  vs=HtVecSize(HtTKind(av[0].type));
  if (bi==HT_BI_LENGTH || bi==HT_BI_NORMALIZE) {
    HtValAddr(e,&av[0],pa);
    if (bi==HT_BI_LENGTH) {
      HtNewTmp(e,HTT_FLOAT,&t);
      HtOutF(e,"%s=HtV%dLen%s(%s);\n",t.text,vs,fs,pa);
    } else {
      HtNewTmp(e,n->type,&t);
      HtValAddr(e,&t,d);
      HtOutF(e,"HtV%dNorm%s(%s,%s);\n",vs,fs,d,pa);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_DOT || bi==HT_BI_DISTANCE) {
    HtValAddr(e,&av[0],pa);
    HtValAddr(e,&av[1],pb);
    HtNewTmp(e,HTT_FLOAT,&t);
    if (bi==HT_BI_DOT)
      HtOutF(e,"%s=HtV%dDot%s(%s,%s);\n",t.text,vs,fs,pa,pb);
    else
      HtOutF(e,"%s=HtV%dDist%s(%s,%s);\n",t.text,vs,fs,pa,pb);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_CROSS) {
    HtValAddr(e,&av[0],pa);
    HtValAddr(e,&av[1],pb);
    HtNewTmp(e,n->type,&t);
    HtValAddr(e,&t,d);
    HtOutF(e,"HtV3Cross%s(%s,%s,%s);\n",fs,d,pa,pb);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_REFLECT) {
    HtValAddr(e,&av[0],pa);
    HtValAddr(e,&av[1],pb);
    HtNewTmp(e,n->type,&t);
    HtValAddr(e,&t,d);
    HtOutF(e,"HtV%dReflect%s(%s,%s,%s);\n",vs,fs,d,pa,pb);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_REFRACT) {
    HtValAddr(e,&av[0],pa);
    HtValAddr(e,&av[1],pb);
    HtValComp(e,&av[2],0,pc);
    HtNewTmp(e,n->type,&t);
    HtValAddr(e,&t,d);
    HtOutF(e,"HtV%dRefract(%s,%s,%s,(%s));\n",vs,d,pa,pb,pc);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_FACEFWD) {
    HtValAddr(e,&av[0],pa);
    HtValAddr(e,&av[1],pb);
    HtValAddr(e,&av[2],pc);
    HtNewTmp(e,n->type,&t);
    HtValAddr(e,&t,d);
    HtOutF(e,"HtV%dFaceFwd(%s,%s,%s,%s);\n",vs,d,pa,pb,pc);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (HT_BI_LT<=bi<=HT_BI_NE) {
    HtNewTmp(e,n->type,&t);
    cnt=HtVecSize(HtTKind(n->type));
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],c,x);
      HtValComp(e,&av[1],c,y);
      if (bi==HT_BI_LT) HtOutF(e,"%s=((%s)<(%s));\n",d,x,y);
      else if (bi==HT_BI_LE) HtOutF(e,"%s=((%s)<=(%s));\n",d,x,y);
      else if (bi==HT_BI_GT) HtOutF(e,"%s=((%s)>(%s));\n",d,x,y);
      else if (bi==HT_BI_GE) HtOutF(e,"%s=((%s)>=(%s));\n",d,x,y);
      else if (bi==HT_BI_EQ) HtOutF(e,"%s=((%s)==(%s));\n",d,x,y);
      else HtOutF(e,"%s=((%s)!=(%s));\n",d,x,y);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_ANY || bi==HT_BI_ALL) {
    HtNewTmp(e,HTT_BOOL,&t);
    cnt=HtVecSize(HtTKind(av[0].type));
    HtOutF(e,"%s=(",t.text);
    for (c=0;c<cnt;c++) {
      HtValComp(e,&av[0],c,x);
      if (c) {
        if (bi==HT_BI_ANY) HtOut(e," || ");
        else HtOut(e," && ");
      }
      HtOutF(e,"((%s)!=0)",x);
    }
    HtOut(e,");\n");
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_NOT) {
    HtNewTmp(e,n->type,&t);
    cnt=HtVecSize(HtTKind(n->type));
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],c,x);
      HtOutF(e,"%s=!(%s);\n",d,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_MATCOMP) {
    HtNewTmp(e,n->type,&t);
    HtEmBinComp(e,&t,&av[0],&av[1],"*",FALSE);
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_TRANSPOSE) {
    msz=HtMatSize(HtTKind(n->type));
    HtNewTmp(e,n->type,&t);
    for (c=0;c<msz*msz;c++) {
      r=((c%msz)*msz)+(c/msz);
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],r,x);
      HtOutF(e,"%s=(%s);\n",d,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_FB2I || bi==HT_BI_FB2U) {
    HtNewTmp(e,n->type,&t);
    cnt=HtCompCount(HtTKind(n->type));
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],c,x);
      if (bi==HT_BI_FB2U)
        HtOutF(e,"%s=HtF32Bits((%s));\n",d,x);
      else
        HtOutF(e,"%s=((HtF32Bits((%s))<<32)>>32);\n",d,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_I2FB || bi==HT_BI_U2FB) {
    HtNewTmp(e,n->type,&t);
    cnt=HtCompCount(HtTKind(n->type));
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],c,x);
      HtOutF(e,"%s=HtF32FromBits((%s));\n",d,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (bi==HT_BI_ISNAN || bi==HT_BI_ISINF) {
    HtNewTmp(e,n->type,&t);
    cnt=HtCompCount(HtTKind(n->type));
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&av[0],c,x);
      if (bi==HT_BI_ISNAN)
        HtOutF(e,"%s=(!((%s)==(%s)));\n",d,x,x);
      else
        HtOutF(e,"%s=(((%s)>1e300) || ((%s)<-1e300));\n",d,x,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  HtEmitError(e,n->tok,"cannot emit builtin");
}

//--- user calls -------------------------------------------------------------------

U0 HtEmUserCall(CHtEmitter *e,I64 i,CHtVal *out)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i],*par;
  CHtVal a,t,cb_tmp[8];
  CHtLval cb_lv[8];
  I64 cb_node[8],cb_count=0;
  I64 f=n->c,arg=n->b,m=p->node[f].a,cbn;
  U8 fname[64],atext[8192],one[160],addr[112],ty[48];
  Bool first=TRUE,composite_ret=HtTIsComposite(p->node[f].type);
  Bool cctx=e->needs_ctx && e->needs_ctx[f];	//plan 011: forward ctx?
  atext[0]=0;
  HtFuncName(e,f,fname);
  while (m>=0) {
    par=&p->node[m];
    one[0]=0;
    if (par->flags&HTF_OUT) {
      HtEmLvalAddr(e,arg,addr,&cbn);
      if (cbn>=0) {
        //swizzle/dynamic target: copy-in temp, copy-back after the call
        HtEmLval(e,cbn,&cb_lv[cb_count]);
        HtLvalToVal(e,&cb_lv[cb_count],&a);
        if (HtTIsComposite(a.type) && !a.is_ptr) {
          StrPrint(addr,"&%s",a.text);
        } else if (HtTIsComposite(a.type)) {
          StrCpy(addr,a.text);
        } else {
          //scalar in a temp: take its address
          MemCpy(&cb_tmp[cb_count],&a,sizeof(CHtVal));
          StrPrint(addr,"&%s",a.text);
        }
        MemCpy(&cb_tmp[cb_count],&a,sizeof(CHtVal));
        cb_node[cb_count]=cbn;
        cb_count++;
      }
      StrCpy(one,addr);
    } else if (HtTIsComposite(par->type)) {
      //GLSL in-params are fresh copies: materialize a callee-writable temp
      HtEmExpr(e,arg,&a);
      if (HtTArr(par->type)) {
        //array parameter: pass the array base directly (copy semantics
        //deviation, recorded)
        StrCpy(one,a.text);
      } else {
        CHtLval tmp_lv;
        HtNewTmp(e,par->type,&t);
        MemSet(&tmp_lv,0,sizeof(CHtLval));
        tmp_lv.kind=HT_LV_PLAIN;
        tmp_lv.type=par->type;
        StrCpy(tmp_lv.text,t.text);
        HtEmStore(e,&tmp_lv,&a);
        StrPrint(one,"&%s",t.text);
      }
    } else {
      HtEmExpr(e,arg,&a);
      StrPrint(one,"(%s)",a.text);
    }
    if (!first) CatPrint(atext,",");
    CatPrint(atext,"%s",one);
    first=FALSE;
    m=par->next;
    arg=p->node[arg].next;
  }
  //plan 011: forward ctx as the first argument to a callee that touches a
  //per-invocation global, ahead of the composite-return pointer and args.
  if (HtTKind(p->node[f].type)==HTT_VOID) {
    if (cctx) {
      if (atext[0]) HtOutF(e,"%s(ctx,%s);\n",fname,atext);
      else HtOutF(e,"%s(ctx);\n",fname);
    } else
      HtOutF(e,"%s(%s);\n",fname,atext);
    out->type=HTT_VOID;
    StrCpy(out->text,"0");
    out->is_ptr=FALSE;
  } else if (composite_ret) {
    HtNewTmp(e,p->node[f].type,&t);
    HtValAddr(e,&t,addr);
    if (cctx) {
      if (atext[0]) HtOutF(e,"%s(ctx,%s,%s);\n",fname,addr,atext);
      else HtOutF(e,"%s(ctx,%s);\n",fname,addr);
    } else {
      if (atext[0]) HtOutF(e,"%s(%s,%s);\n",fname,addr,atext);
      else HtOutF(e,"%s(%s);\n",fname,addr);
    }
    MemCpy(out,&t,sizeof(CHtVal));
  } else {
    HtNewTmp(e,p->node[f].type,&t);
    if (cctx) {
      if (atext[0]) HtOutF(e,"%s=%s(ctx,%s);\n",t.text,fname,atext);
      else HtOutF(e,"%s=%s(ctx);\n",t.text,fname);
    } else
      HtOutF(e,"%s=%s(%s);\n",t.text,fname,atext);
    MemCpy(out,&t,sizeof(CHtVal));
  }
  //copy-back for swizzle/dynamic out-args
  while (cb_count--) {
    HtEmStore(e,&cb_lv[cb_count],&cb_tmp[cb_count]);
  }
  no_warn ty;
}

//--- main expression dispatcher ------------------------------------------------------

U0 HtEmExpr(CHtEmitter *e,I64 i,CHtVal *out)
{
  CHtProgram *p=e->prog;
  CHtAst *n;
  CHtVal a,b,t;
  CHtLval lv;
  I64 k,cnt,c,bt;
  U8 d[112],x[112],y[112],op[4];
  U8 *sep;
  CHtLexer *l=p->lex;
  MemSet(out,0,sizeof(CHtVal));
  if (i<0 || *p->error) {
    StrCpy(out->text,"0");
    out->type=HTT_INT;
    return;
  }
  n=&p->node[i];
  out->type=n->type;
  if (n->kind==HT_AST_NUMBER) {
    HtEmNumText(e,n->tok,out->text);
    return;
  }
  if (n->kind==HT_AST_NAME) {
    if (n->bind==HT_BIND_TRUE) {
      StrCpy(out->text,"1");
      return;
    }
    if (n->bind==HT_BIND_FALSE) {
      StrCpy(out->text,"0");
      return;
    }
    if (n->bind==HT_BIND_ITIME) {
      StrCpy(out->text,"ht_frame.itime");
      return;
    }
    if (n->bind==HT_BIND_IRES) {
      StrCpy(out->text,"ht_frame.ires");
      return;
    }
    if (n->bind==HT_BIND_IMOUSE) {
      StrCpy(out->text,"ht_frame.imouse");
      return;
    }
    if (n->bind==HT_BIND_IDATE) {
      StrCpy(out->text,"ht_frame.idate");
      return;
    }
    if (n->bind==HT_BIND_IFRAME) {
      StrCpy(out->text,"ht_frame.iframe");
      return;
    }
    if (n->bind==HT_BIND_ITDELTA) {
      StrCpy(out->text,"ht_frame.itdelta");
      return;
    }
    if (n->bind==HT_BIND_IFRATE) {
      StrCpy(out->text,"ht_frame.ifrate");
      return;
    }
    //symbol
    {
      CHtSym *s=&p->sym[n->c];
      U8 nm[96];
      HtSymRef(e,n->c,nm);
      if (s->kind==HT_SYM_PARAM) {
        if (HtTIsComposite(s->type)) {
          StrCpy(out->text,nm);
          out->is_ptr=TRUE;
        } else if (s->flags&HTF_OUT)
          StrPrint(out->text,"(*%s)",nm);
        else
          StrCpy(out->text,nm);
      } else
        StrCpy(out->text,nm);
    }
    return;
  }
  if (n->kind==HT_AST_UNARY) {
    HtTokText(l,n->tok,op,4);
    HtEmExpr(e,n->a,&a);
    if (op[0]=='+') {
      MemCpy(out,&a,sizeof(CHtVal));
      out->type=n->type;
      return;
    }
    k=HtTKind(n->type);
    HtNewTmp(e,n->type,&t);
    cnt=HtCompCount(k);
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&a,c,x);
      if (op[0]=='!')
        HtOutF(e,"%s=(!(%s));\n",d,x);
      else if (op[0]=='~') {
        if (HtElemIsUint(n->type))
          HtOutF(e,"%s=((~(%s))&0xFFFFFFFF);\n",d,x);
        else
          HtOutF(e,"%s=(~(%s));\n",d,x);
      } else {
        if (HtElemIsUint(n->type))
          HtOutF(e,"%s=((-(%s))&0xFFFFFFFF);\n",d,x);
        else
          HtOutF(e,"%s=(-(%s));\n",d,x);
      }
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (n->kind==HT_AST_BINARY) {
    HtEmBinary(e,i,out);
    return;
  }
  if (n->kind==HT_AST_MEMBER) {
    if (n->bind==HT_MEM_FIELD) {
      U8 mn[24];
      HtEmExpr(e,n->a,&a);
      HtShortTok(e,p->node[n->c].tok,mn);
      out->type=n->type;
      if (a.is_ptr)
        StrPrint(out->text,"%s->m_%s",a.text,mn);
      else
        StrPrint(out->text,"%s.m_%s",a.text,mn);
      return;
    }
    //swizzle read
    HtEmExpr(e,n->a,&a);
    cnt=n->c&15;
    if (cnt==1) {
      c=(n->c>>4)&15;
      HtValComp(e,&a,c,out->text);
      out->type=n->type;
      return;
    }
    HtNewTmp(e,n->type,&t);
    for (c=0;c<cnt;c++) {
      HtValComp(e,&t,c,d);
      HtValComp(e,&a,(n->c>>(4+c*4))&15,x);
      HtOutF(e,"%s=(%s);\n",d,x);
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (n->kind==HT_AST_INDEX) {
    bt=p->node[n->a].type;
    HtEmExpr(e,n->a,&a);
    HtEmExpr(e,n->b,&b);
    if (HtTArr(bt)) {
      out->type=n->type;
      StrPrint(out->text,"%s[(%s)]",a.text,b.text);
      out->is_ptr=FALSE;
      return;
    }
    k=HtTKind(bt);
    if (HtTIsVec(k)) {
      sep=".";
      if (a.is_ptr) sep="->";
      out->type=n->type;
      StrPrint(out->text,"(&%s%sx)[(%s)]",a.text,sep,b.text);
      return;
    }
    if (HtTIsMat(k)) {
      sep=".";
      if (a.is_ptr) sep="->";
      HtNewTmp(e,n->type,&t);
      cnt=HtMatSize(k);
      for (c=0;c<cnt;c++) {
        HtValComp(e,&t,c,d);
        HtOutF(e,"%s=%s%sm[((%s)*%d)+%d];\n",d,a.text,sep,b.text,cnt,c);
      }
      MemCpy(out,&t,sizeof(CHtVal));
      return;
    }
    HtEmitError(e,n->tok,"cannot emit index");
    return;
  }
  if (n->kind==HT_AST_TERNARY) {
    HtEmExpr(e,n->a,&a);
    HtNewTmp(e,n->type,&t);
    HtOutF(e,"if (%s) {\n",a.text);
    {
      CHtLval tl;
      MemSet(&tl,0,sizeof(CHtLval));
      tl.kind=HT_LV_PLAIN;
      tl.type=n->type;
      StrCpy(tl.text,t.text);
      HtEmExpr(e,n->b,&b);
      HtEmStore(e,&tl,&b);
      HtOut(e,"} else {\n");
      HtEmExpr(e,n->c,&b);
      HtEmStore(e,&tl,&b);
      HtOut(e,"}\n");
    }
    MemCpy(out,&t,sizeof(CHtVal));
    return;
  }
  if (n->kind==HT_AST_ASSIGN) {
    HtTokText(l,n->tok,op,4);
    HtEmExpr(e,n->b,&b);
    HtEmLval(e,n->a,&lv);
    if (op[1]==0) {			// plain '='
      HtEmStore(e,&lv,&b);
      HtLvalToVal(e,&lv,out);
      return;
    }
    //compound: read, combine, store
    {
      CHtVal cur,res;
      U8 op2[4],pa2[112],pb2[112],pd2[112];
      Bool mask=HtElemIsUint(lv.type);
      U8 *fs="";			//plan 013: F32 suffix (HolyC has no ternary)
      if (e->f32) fs="F32";
      op2[0]=op[0];			//first char is the operator
      op2[1]=0;
      if (op[0]=='<' || op[0]=='>') {
        op2[1]=op[0];
        op2[2]=0;
      }
      HtLvalToVal(e,&lv,&cur);
      k=HtTKind(lv.type);
      HtNewTmp(e,lv.type,&res);
      if (HtTIsScalar(k)) {
        if (mask)
          HtOutF(e,"%s=(((%s)%s(%s))&0xFFFFFFFF);\n",
                 res.text,cur.text,op2,b.text);
        else if (e->f32 && k==HTT_FLOAT)	//plan 013: round float result
          HtOutF(e,"%s=HtF32((%s)%s(%s));\n",res.text,cur.text,op2,b.text);
        else
          HtOutF(e,"%s=((%s)%s(%s));\n",res.text,cur.text,op2,b.text);
      } else if (HtTIsMat(k) && op[0]=='*' &&
                 HtTIsMat(HtTKind(p->node[n->b].type))) {
        if (cur.is_ptr) StrPrint(pa2,"%s->m",cur.text);
        else StrPrint(pa2,"%s.m",cur.text);
        if (b.is_ptr) StrPrint(pb2,"%s->m",b.text);
        else StrPrint(pb2,"%s.m",b.text);
        StrPrint(pd2,"%s.m",res.text);
        HtOutF(e,"HtMMulM%s(%s,%s,%s,%d);\n",
               fs,pd2,pa2,pb2,HtMatSize(k));
      } else if (HtTIsFVec(k) && op[0]=='*' &&
                 HtTIsMat(HtTKind(p->node[n->b].type))) {
        HtValAddr(e,&cur,pa2);
        HtValAddr(e,&b,pb2);
        StrPrint(pd2,"&%s",res.text);
        HtOutF(e,"HtVMulM%d%s(%s,%s,%s);\n",
               HtMatSize(HtTKind(p->node[n->b].type)),fs,
               pd2,pa2,pb2);
      } else
        HtEmBinComp(e,&res,&cur,&b,op2,mask);
      HtEmStore(e,&lv,&res);
      MemCpy(out,&res,sizeof(CHtVal));
    }
    return;
  }
  if (n->kind==HT_AST_PREINC || n->kind==HT_AST_POSTINC) {
    U8 *delta="1";
    HtTokText(l,n->tok,op,4);
    if (op[0]=='-') delta="1";
    HtEmLval(e,n->a,&lv);
    k=HtTKind(lv.type);
    if (n->kind==HT_AST_POSTINC) {
      //Post-inc/dec must yield the ORIGINAL value. HtLvalToVal aliases a
      //plain lvalue by name, so the update lines below would leak the
      //NEW value into the result (found as corpus v2 mtlfRs quick_sort
      //GP fault: pairs[rw++] indexed one slot ahead). Snapshot into a
      //fresh temp instead.
      HtNewTmp(e,lv.type,out);
      cnt=HtCompCount(k);
      for (c=0;c<cnt;c++) {
        HtValComp(e,out,c,x);
        HtLvalComp(e,&lv,c,d);
        HtOutF(e,"%s=(%s);\n",x,d);
      }
    }
    cnt=HtCompCount(k);
    for (c=0;c<cnt;c++) {
      HtLvalComp(e,&lv,c,d);
      if (op[0]=='+') {
        if (HtElemIsUint(lv.type))
          HtOutF(e,"%s=(((%s)+1)&0xFFFFFFFF);\n",d,d);
        else
          HtOutF(e,"%s=((%s)+1);\n",d,d);
      } else {
        if (HtElemIsUint(lv.type))
          HtOutF(e,"%s=(((%s)-1)&0xFFFFFFFF);\n",d,d);
        else
          HtOutF(e,"%s=((%s)-1);\n",d,d);
      }
    }
    if (n->kind==HT_AST_PREINC)
      HtLvalToVal(e,&lv,out);
    no_warn delta;
    return;
  }
  if (n->kind==HT_AST_CALL) {
    if (n->bind==HT_CALL_CTOR) {
      HtEmCtor(e,i,out);
      return;
    }
    if (n->bind==HT_CALL_STRUCT) {
      HtEmStructCtor(e,i,out);
      return;
    }
    if (n->bind==HT_CALL_BI) {
      HtEmBuiltin(e,i,out);
      return;
    }
    if (n->bind==HT_CALL_USER) {
      HtEmUserCall(e,i,out);
      return;
    }
    HtEmitError(e,n->tok,"cannot emit call");
    return;
  }
  if (n->kind==HT_AST_ARRCTOR) {
    HtEmitError(e,n->tok,"array constructor only allowed as initializer");
    return;
  }
  if (n->kind==HT_AST_SEQ) {
    HtEmExpr(e,n->a,&a);
    HtEmExpr(e,n->b,out);
    return;
  }
  HtEmitError(e,n->tok,"cannot emit expression");
}

//--- statements -------------------------------------------------------------------

Bool HtHasContinue(CHtProgram *p,I64 i)
{//does this statement subtree contain a continue for THIS loop level?
  CHtAst *n;
  if (i<0) return FALSE;
  n=&p->node[i];
  if (n->kind==HT_AST_CONTINUE) return TRUE;
  if (n->kind==HT_AST_FOR || n->kind==HT_AST_WHILE || n->kind==HT_AST_DO)
    return FALSE;			//nested loop owns its continues
  if (n->kind==HT_AST_BLOCK) {
    I64 s=n->a;
    while (s>=0) {
      if (HtHasContinue(p,s)) return TRUE;
      s=p->node[s].next;
    }
    return FALSE;
  }
  if (n->kind==HT_AST_IF)
    return HtHasContinue(p,n->b) || HtHasContinue(p,n->c);
  return FALSE;
}

U0 HtEmDeclInit(CHtEmitter *e,I64 i)
{//initializer part of a DECL node (declaration text already emitted)
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  CHtVal v;
  CHtLval lv;
  U8 nm[96];
  I64 arg,c;
  if (n->a<0) return;
  HtSymRef(e,n->c,nm);
  if (p->node[n->a].kind==HT_AST_ARRCTOR) {
    arg=p->node[n->a].b;
    c=0;
    while (arg>=0) {
      HtEmExpr(e,arg,&v);
      MemSet(&lv,0,sizeof(CHtLval));
      lv.kind=HT_LV_PLAIN;
      lv.type=HtTElem(n->type);
      StrPrint(lv.text,"%s[%d]",nm,c);
      HtEmStore(e,&lv,&v);
      c++;
      arg=p->node[arg].next;
    }
    return;
  }
  HtEmExpr(e,n->a,&v);
  MemSet(&lv,0,sizeof(CHtLval));
  lv.kind=HT_LV_PLAIN;
  lv.type=n->type;
  StrCpy(lv.text,nm);
  HtEmStore(e,&lv,&v);
}

U0 HtEmDecl(CHtEmitter *e,I64 i)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i];
  U8 ty[48],nm[96];
  HtTypeText(e,n->type,ty);
  HtSymText(e,n->c,nm);
  if (HtTArr(n->type))
    HtOutF(e,"%s %s[%d];\n",ty,nm,HtTArr(n->type));
  else
    HtOutF(e,"%s %s;\n",ty,nm);
  HtEmDeclInit(e,i);
}

U0 HtEmStmt(CHtEmitter *e,I64 i)
{
  CHtProgram *p=e->prog;
  CHtAst *n;
  CHtVal v;
  I64 s,lbl,fn_node;
  Bool has_cont;
  if (i<0 || *p->error) return;
  n=&p->node[i];
  if (n->kind==HT_AST_BLOCK) {
    HtOut(e,"{\n");
    s=n->a;
    while (s>=0 && !*p->error) {
      HtEmStmt(e,s);
      s=p->node[s].next;
    }
    HtOut(e,"}\n");
    return;
  }
  if (n->kind==HT_AST_DECL) {
    HtEmDecl(e,i);
    return;
  }
  if (n->kind==HT_AST_EXPR_STMT) {
    HtEmExpr(e,n->a,&v);
    return;
  }
  if (n->kind==HT_AST_EMPTY) return;
  if (n->kind==HT_AST_IF) {
    HtEmExpr(e,n->a,&v);
    HtOutF(e,"if (%s) {\n",v.text);
    HtEmStmt(e,n->b);
    if (n->c>=0) {
      HtOut(e,"} else {\n");
      HtEmStmt(e,n->c);
    }
    HtOut(e,"}\n");
    return;
  }
  if (n->kind==HT_AST_FOR || n->kind==HT_AST_WHILE || n->kind==HT_AST_DO) {
    I64 body,cond,step=-1,init=-1;
    Bool is_do=n->kind==HT_AST_DO;
    if (n->kind==HT_AST_FOR) {
      init=n->a;
      cond=n->b;
      step=n->c;
      body=n->d;
    } else if (n->kind==HT_AST_WHILE) {
      cond=n->a;
      body=n->b;
    } else {
      body=n->a;
      cond=n->b;
    }
    has_cont=HtHasContinue(p,body);
    lbl=e->lbl++;
    if (e->loop_top<63) {
      e->loop_top++;
      if (has_cont) e->loop_lbl[e->loop_top]=lbl;
      else e->loop_lbl[e->loop_top]=-1;
    }
    HtOut(e,"{\n");
    if (init>=0) {
      s=init;
      while (s>=0 && !*p->error) {
        HtEmStmt(e,s);
        s=p->node[s].next;
      }
    }
    HtOut(e,"while (1) {\n");
    if (!is_do && cond>=0) {
      HtEmExpr(e,cond,&v);
      HtOutF(e,"if (!(%s)) break;\n",v.text);
    }
    HtEmStmt(e,body);
    if (has_cont)
      HtOutF(e,"htc%d:;\n",lbl);
    if (step>=0) {
      HtEmExpr(e,step,&v);
    }
    if (is_do) {
      HtEmExpr(e,cond,&v);
      HtOutF(e,"if (!(%s)) break;\n",v.text);
    }
    HtOut(e,"}\n}\n");
    if (e->loop_top>=0) e->loop_top--;
    return;
  }
  if (n->kind==HT_AST_BREAK) {
    HtOut(e,"break;\n");
    return;
  }
  if (n->kind==HT_AST_CONTINUE) {
    s=e->loop_top;
    if (s>=0 && e->loop_lbl[s]>=0)
      HtOutF(e,"goto htc%d;\n",e->loop_lbl[s]);
    else
      HtEmitError(e,n->tok,"internal: continue without label");
    return;
  }
  if (n->kind==HT_AST_RETURN) {
    fn_node=e->prog->main_node;	//not used; kept for clarity
    if (n->a<0) {
      HtOut(e,"return;\n");
      return;
    }
    HtEmExpr(e,n->a,&v);
    if (HtTIsComposite(v.type) || HtTIsComposite(p->node[n->a].type)) {
      CHtLval rl;
      MemSet(&rl,0,sizeof(CHtLval));
      rl.kind=HT_LV_PLAIN;
      rl.type=p->node[n->a].type;
      StrCpy(rl.text,"ht_ret");
      rl.is_ptr=TRUE;
      HtEmStore(e,&rl,&v);
      HtOut(e,"return;\n");
    } else
      HtOutF(e,"return (%s);\n",v.text);
    no_warn fn_node;
    return;
  }
  HtEmitError(e,n->tok,"cannot emit statement");
}

//--- functions, globals, glue -------------------------------------------------------

U0 HtEmFuncDef(CHtEmitter *e,I64 f)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[f],*par;
  U8 fname[64],ty[48],nm[96];
  I64 m;
  Bool first=TRUE,composite_ret=HtTIsComposite(n->type);
  HtFuncName(e,f,fname);
  if (HtTKind(n->type)==HTT_VOID || composite_ret)
    HtOutF(e,"U0 %s(",fname);
  else {
    HtTypeText(e,n->type,ty);
    HtOutF(e,"%s %s(",ty,fname);
  }
  //plan 011 canonical order: ctx (if touching), then composite-return ptr,
  //then declared params.
  if (e->needs_ctx && e->needs_ctx[f]) {
    HtOut(e,"CHtCtx *ctx");
    first=FALSE;
  }
  if (composite_ret) {
    if (!first) HtOut(e,",");
    HtTypeText(e,n->type,ty);
    HtOutF(e,"%s *ht_ret",ty);
    first=FALSE;
  }
  m=n->a;
  while (m>=0) {
    par=&p->node[m];
    if (!first) HtOut(e,",");
    first=FALSE;
    HtTypeText(e,par->type,ty);
    HtSymText(e,par->c,nm);
    if (HtTArr(par->type))
      HtOutF(e,"%s *%s",ty,nm);
    else if (HtTIsComposite(par->type) || (par->flags&HTF_OUT))
      HtOutF(e,"%s *%s",ty,nm);
    else
      HtOutF(e,"%s %s",ty,nm);
    m=par->next;
  }
  HtOut(e,")\n");
  e->loop_top=-1;
  HtEmStmt(e,n->b);
}

extern U0 HtEmCollectChain(CHtProgram *p,I64 i,I64 *list,I64 *count);

U0 HtEmCollectCalls(CHtProgram *p,I64 i,I64 *list,I64 *count)
{//user-call targets in subtree i; only true child links are followed
  CHtAst *n;
  I64 k;
  if (i<0) return;
  n=&p->node[i];
  if (n->kind==HT_AST_CALL) {
    if (n->bind==HT_CALL_USER) {
      for (k=0;k<*count;k++)
        if (list[k]==n->c) break;
      if (k==*count && *count<128) {
        list[*count]=n->c;
        (*count)++;
      }
    }
    HtEmCollectChain(p,n->b,list,count);
    return;
  }
  if (n->kind==HT_AST_BLOCK || n->kind==HT_AST_ARRCTOR) {
    if (n->kind==HT_AST_ARRCTOR)
      HtEmCollectChain(p,n->b,list,count);
    else
      HtEmCollectChain(p,n->a,list,count);
    return;
  }
  if (n->kind==HT_AST_FOR) {
    HtEmCollectChain(p,n->a,list,count);
    HtEmCollectCalls(p,n->b,list,count);
    HtEmCollectCalls(p,n->c,list,count);
    HtEmCollectCalls(p,n->d,list,count);
    return;
  }
  if (n->kind==HT_AST_MEMBER || n->kind==HT_AST_EXPR_STMT ||
      n->kind==HT_AST_RETURN || n->kind==HT_AST_PREINC ||
      n->kind==HT_AST_POSTINC || n->kind==HT_AST_UNARY ||
      n->kind==HT_AST_DECL) {
    HtEmCollectCalls(p,n->a,list,count);
    return;
  }
  if (n->kind==HT_AST_BINARY || n->kind==HT_AST_ASSIGN ||
      n->kind==HT_AST_INDEX || n->kind==HT_AST_SEQ ||
      n->kind==HT_AST_WHILE || n->kind==HT_AST_DO) {
    HtEmCollectCalls(p,n->a,list,count);
    HtEmCollectCalls(p,n->b,list,count);
    return;
  }
  if (n->kind==HT_AST_TERNARY || n->kind==HT_AST_IF) {
    HtEmCollectCalls(p,n->a,list,count);
    HtEmCollectCalls(p,n->b,list,count);
    HtEmCollectCalls(p,n->c,list,count);
    return;
  }
}

U0 HtEmCollectChain(CHtProgram *p,I64 i,I64 *list,I64 *count)
{//walk a next-linked chain (statements, arguments, declarators)
  while (i>=0) {
    HtEmCollectCalls(p,i,list,count);
    i=p->node[i].next;
  }
}

extern Bool HtCtxTouchChain(CHtProgram *p,I64 i);

Bool HtCtxTouchNode(CHtProgram *p,I64 i)
{//plan 011: does subtree i directly reference a per-invocation global?
 //Same traversal shape as HtEmCollectCalls, adding NAME-leaf inspection.
  CHtAst *n;
  if (i<0) return FALSE;
  n=&p->node[i];
  if (n->kind==HT_AST_NAME)
    return n->bind==HT_BIND_SYM && HtGlobalPerInvocation(p,n->c);
  if (n->kind==HT_AST_CALL)
    return HtCtxTouchChain(p,n->b);	//callee is a name, not a symbol ref
  if (n->kind==HT_AST_BLOCK)
    return HtCtxTouchChain(p,n->a);
  if (n->kind==HT_AST_ARRCTOR)
    return HtCtxTouchChain(p,n->b);
  if (n->kind==HT_AST_FOR)
    return HtCtxTouchChain(p,n->a) || HtCtxTouchNode(p,n->b) ||
           HtCtxTouchNode(p,n->c) || HtCtxTouchNode(p,n->d);
  if (n->kind==HT_AST_MEMBER || n->kind==HT_AST_EXPR_STMT ||
      n->kind==HT_AST_RETURN || n->kind==HT_AST_PREINC ||
      n->kind==HT_AST_POSTINC || n->kind==HT_AST_UNARY ||
      n->kind==HT_AST_DECL)
    return HtCtxTouchNode(p,n->a);
  if (n->kind==HT_AST_BINARY || n->kind==HT_AST_ASSIGN ||
      n->kind==HT_AST_INDEX || n->kind==HT_AST_SEQ ||
      n->kind==HT_AST_WHILE || n->kind==HT_AST_DO)
    return HtCtxTouchNode(p,n->a) || HtCtxTouchNode(p,n->b);
  if (n->kind==HT_AST_TERNARY || n->kind==HT_AST_IF)
    return HtCtxTouchNode(p,n->a) || HtCtxTouchNode(p,n->b) ||
           HtCtxTouchNode(p,n->c);
  return FALSE;
}

Bool HtCtxTouchChain(CHtProgram *p,I64 i)
{
  while (i>=0) {
    if (HtCtxTouchNode(p,i)) return TRUE;
    i=p->node[i].next;
  }
  return FALSE;
}

U0 HtEmComputeNeedsCtx(CHtEmitter *e)
{//plan 011 sec3: needs_ctx[F] = F directly touches a per-invocation global
 //OR any (transitive) callee does. Fixpoint over the call graph; GLSL
 //forbids recursion so it converges. main is forced on when ctx is used.
  CHtProgram *p=e->prog;
  CHtAst *n;
  I64 i,k,list[128],count;
  Bool changed=TRUE;
  if (!e->has_ctx) return;
  i=p->root;
  while (i>=0) {
    n=&p->node[i];
    if (n->kind==HT_AST_FUNC && n->b>=0)
      e->needs_ctx[i]=HtCtxTouchNode(p,n->b);
    i=n->next;
  }
  while (changed) {
    changed=FALSE;
    i=p->root;
    while (i>=0) {
      n=&p->node[i];
      if (n->kind==HT_AST_FUNC && n->b>=0 && !e->needs_ctx[i]) {
        count=0;
        HtEmCollectCalls(p,n->b,list,&count);
        for (k=0;k<count;k++)
          if (e->needs_ctx[list[k]]) {
            e->needs_ctx[i]=TRUE;
            changed=TRUE;
            break;
          }
      }
      i=n->next;
    }
  }
  if (p->main_node>=0)
    e->needs_ctx[p->main_node]=TRUE;
}

U0 HtEmFuncTopo(CHtEmitter *e,I64 f,I64 *emitted,I64 *visiting)
{//emit callees before callers (GLSL forbids recursion, so this terminates)
  CHtProgram *p=e->prog;
  I64 list[128],count=0,k;
  if (emitted[f] || *p->error) return;
  if (visiting[f]) {
    HtSemaError(p,p->node[f].tok,"recursive function");
    return;
  }
  visiting[f]=TRUE;
  HtEmCollectCalls(p,p->node[f].b,list,&count);
  for (k=0;k<count;k++)
    if (list[k]!=f)
      HtEmFuncTopo(e,list[k],emitted,visiting);
  if (!*p->error) {
    HtEmFuncDef(e,f);
    emitted[f]=TRUE;
  }
  visiting[f]=FALSE;
}

U8 *HtEmit(CHtProgram *p)
{
  CHtEmitter e;
  CHtAst *n;
  I64 i,m,sid;
  U8 ty[48],nm[96],mn[24],fname[64];
  I64 *emitted,*visiting;
  MemSet(&e,0,sizeof(CHtEmitter));
  e.prog=p;
  e.f32=ht_f32_mode;		//plan 013: F32 semantics (default ON)
  e.cap=p->lex->src_len*8+4096;
  e.buf=MAlloc(e.cap);
  e.buf[0]=0;
  e.loop_top=-1;
  //struct classes
  for (sid=0;sid<p->struct_count;sid++) {
    HtStructName(&e,sid,nm);
    HtOutF(&e,"class %s\n{\n",nm);
    m=p->node[p->struct_node[sid]].a;
    while (m>=0) {
      HtTypeText(&e,p->node[m].type,ty);
      HtShortTok(&e,p->node[m].tok,mn);
      if (HtTArr(p->node[m].type))
        HtOutF(&e,"  %s m_%s[%d];\n",ty,mn,HtTArr(p->node[m].type));
      else
        HtOutF(&e,"  %s m_%s;\n",ty,mn);
      m=p->node[m].next;
    }
    HtOut(&e,"};\n");
  }
  //plan 011: the standard Shadertoy uniforms are runtime-owned (CHtFrame
  //ht_frame in HT.HC), filled once per frame by HtFrameSetup before any
  //worker runs. No per-unit uniform globals and no stamp-rebind block.
  //User globals split: shared read-only const globals stay process globals
  //(initialized once at install); per-invocation globals move into CHtCtx.
  i=p->root;
  while (i>=0) {
    n=&p->node[i];
    if (n->kind==HT_AST_DECL) {
      if (HtGlobalPerInvocation(p,n->c))
        e.has_ctx=TRUE;
      else {
        HtTypeText(&e,n->type,ty);
        HtSymText(&e,n->c,nm);
        if (HtTArr(n->type))
          HtOutF(&e,"%s %s[%d];\n",ty,nm,HtTArr(n->type));
        else
          HtOutF(&e,"%s %s;\n",ty,nm);
      }
    }
    i=n->next;
  }
  //per-invocation context class (after struct classes, before functions);
  //nothing is emitted when the per-invocation set is empty.
  if (e.has_ctx) {
    HtOut(&e,"class CHtCtx\n{\n");
    i=p->root;
    while (i>=0) {
      n=&p->node[i];
      if (n->kind==HT_AST_DECL && HtGlobalPerInvocation(p,n->c)) {
        HtTypeText(&e,n->type,ty);
        HtSymText(&e,n->c,nm);
        if (HtTArr(n->type))
          HtOutF(&e,"  %s %s[%d];\n",ty,nm,HtTArr(n->type));
        else
          HtOutF(&e,"  %s %s;\n",ty,nm);
      }
      i=n->next;
    }
    HtOut(&e,"};\n");
  }
  //which functions thread CHtCtx *ctx (only-if-touches, transitive)
  e.needs_ctx=CAlloc(p->node_count*sizeof(I64));
  HtEmComputeNeedsCtx(&e);
  //functions in callee-first order
  emitted=CAlloc(p->node_count*sizeof(I64));
  visiting=CAlloc(p->node_count*sizeof(I64));
  i=p->root;
  while (i>=0 && !*p->error) {
    n=&p->node[i];
    if (n->kind==HT_AST_FUNC && n->b>=0)
      HtEmFuncTopo(&e,i,emitted,visiting);
    i=n->next;
  }
  Free(emitted);
  Free(visiting);
  //per-invocation context init (defined before MainImage, which calls it):
  //MemSet then re-run each per-invocation global initializer in decl order.
  if (!*p->error && e.has_ctx) {
    HtOut(&e,"U0 HtCtxInit(CHtCtx *ctx)\n{\n");
    HtOut(&e,"MemSet(ctx,0,sizeof(CHtCtx));\n");
    i=p->root;
    while (i>=0 && !*p->error) {
      n=&p->node[i];
      if (n->kind==HT_AST_DECL && HtGlobalPerInvocation(p,n->c))
        HtEmDeclInit(&e,i);
      i=n->next;
    }
    HtOut(&e,"}\n");
  }
  //MainImage ABI glue (plan 011 signature; reentrant, no stamp block)
  if (!*p->error) {
    HtFuncName(&e,p->main_node,fname);
    HtOut(&e,
      "U0 MainImage(F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n{\n"
      "  CHtV2 htg_fc;\n  CHtV4 htg_col;\n");
    if (e.has_ctx)
      HtOut(&e,
        "  CHtCtx ctx_store;\n"
        "  CHtCtx *ctx=&ctx_store;\n"
        "  HtCtxInit(ctx);\n");
    HtOut(&e,
      "  htg_fc.x=frag_x;\n  htg_fc.y=frag_y;\n"
      "  htg_col.x=0.0;\n  htg_col.y=0.0;\n"
      "  htg_col.z=0.0;\n  htg_col.w=1.0;\n");
    if (e.has_ctx)
      HtOutF(&e,"  %s(ctx,&htg_col,&htg_fc);\n",fname);
    else
      HtOutF(&e,"  %s(&htg_col,&htg_fc);\n",fname);
    HtOut(&e,
      "  out_color->r=htg_col.x;\n"
      "  out_color->g=htg_col.y;\n"
      "  out_color->b=htg_col.z;\n"
      "  out_color->a=htg_col.w;\n}\n");
    //shared-const global initializers, in declaration order (may be empty)
    HtOut(&e,"U0 HtShaderInit()\n{\n");
    i=p->root;
    while (i>=0 && !*p->error) {
      n=&p->node[i];
      if (n->kind==HT_AST_DECL && !HtGlobalPerInvocation(p,n->c))
        HtEmDeclInit(&e,i);
      i=n->next;
    }
    HtOut(&e,"}\nHtShaderInit;\n");
  }
  Free(e.needs_ctx);
  if (*p->error) {
    Free(e.buf);
    return NULL;
  }
  return e.buf;
}
