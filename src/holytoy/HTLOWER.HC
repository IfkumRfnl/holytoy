//HolyToy typed semantic pass (sema). Annotates the full-grammar AST with
//packed types, symbol bindings, member/swizzle resolutions, and call
//dispatch (constructor / struct constructor / builtin / user function),
//then the emitter walks the annotated tree. Symbols are persistent for the
//whole compile: scope exit marks entries dead instead of reusing slots, so
//node->c symbol references stay valid during emission.

#define HT_SYM_LOCAL	0
#define HT_SYM_GLOBAL	1
#define HT_SYM_PARAM	2

class CHtSym
{
  I64 tok,type,flags,kind,decl;
  I64 const_i;			//folded integer value (const int symbols)
  Bool has_const_i;
  Bool dead;			//out of scope
  Bool per_inv;			//global lives in CHtCtx (per-invocation), plan 011
};

//NAME binds
#define HT_BIND_NONE	0
#define HT_BIND_SYM	1
#define HT_BIND_IRES	2
#define HT_BIND_ITIME	3
#define HT_BIND_IMOUSE	4
#define HT_BIND_IDATE	5
#define HT_BIND_IFRAME	6
#define HT_BIND_ITDELTA	7
#define HT_BIND_IFRATE	8
#define HT_BIND_TRUE	9
#define HT_BIND_FALSE	10

//CALL binds
#define HT_CALL_CTOR	1
#define HT_CALL_STRUCT	2
#define HT_CALL_USER	3
#define HT_CALL_BI	4

//MEMBER binds
#define HT_MEM_SWZ	1	//c = count | i0<<4 | i1<<8 | i2<<12 | i3<<16
#define HT_MEM_FIELD	2	//c = member DECL node

//builtin ids
#define HT_BI_SIN	1
#define HT_BI_COS	2
#define HT_BI_TAN	3
#define HT_BI_ASIN	4
#define HT_BI_ACOS	5
#define HT_BI_ATAN	6	//1 or 2 args
#define HT_BI_POW	7
#define HT_BI_EXP	8
#define HT_BI_LOG	9
#define HT_BI_EXP2	10
#define HT_BI_LOG2	11
#define HT_BI_SQRT	12
#define HT_BI_INVSQRT	13
#define HT_BI_ABS	14
#define HT_BI_SIGN	15
#define HT_BI_FLOOR	16
#define HT_BI_CEIL	17
#define HT_BI_FRACT	18
#define HT_BI_MOD	19
#define HT_BI_MIN	20
#define HT_BI_MAX	21
#define HT_BI_CLAMP	22
#define HT_BI_MIX	23
#define HT_BI_STEP	24
#define HT_BI_SSTEP	25
#define HT_BI_LENGTH	26
#define HT_BI_DISTANCE	27
#define HT_BI_DOT	28
#define HT_BI_CROSS	29
#define HT_BI_NORMALIZE	30
#define HT_BI_REFLECT	31
#define HT_BI_REFRACT	32
#define HT_BI_FACEFWD	33
#define HT_BI_RADIANS	34
#define HT_BI_DEGREES	35
#define HT_BI_ROUND	36
#define HT_BI_TRUNC	37
#define HT_BI_LT	38	//lessThan
#define HT_BI_LE	39
#define HT_BI_GT	40
#define HT_BI_GE	41
#define HT_BI_EQ	42
#define HT_BI_NE	43
#define HT_BI_ANY	44
#define HT_BI_ALL	45
#define HT_BI_NOT	46
#define HT_BI_MATCOMP	47
#define HT_BI_TRANSPOSE	48
#define HT_BI_FB2I	49	//floatBitsToInt
#define HT_BI_FB2U	50	//floatBitsToUint
#define HT_BI_I2FB	51	//intBitsToFloat
#define HT_BI_U2FB	52	//uintBitsToFloat
#define HT_BI_ISNAN	53
#define HT_BI_ISINF	54

class CHtSema
{
  CHtProgram *p;
  I64 fn;			//current FUNC node (-1 at global scope)
  I64 loop_depth;
};

U0 HtSemaError(CHtProgram *p,I64 tok,U8 *msg)
{
  CHtToken *t;
  if (*p->error) return;
  if (tok<0 || tok>=p->lex->count) tok=0;
  t=&p->lex->tok[tok];
  StrPrint(p->error,"line %d:%d: %s",t->line,t->col,msg);
}

//--- type predicates ---------------------------------------------------------

Bool HtTIsVec(I64 k)   { return HTT_VEC2<=k<=HTT_BVEC4; }
Bool HtTIsFVec(I64 k)  { return HTT_VEC2<=k<=HTT_VEC4; }
Bool HtTIsIVec(I64 k)  { return HTT_IVEC2<=k<=HTT_IVEC4; }
Bool HtTIsUVec(I64 k)  { return HTT_UVEC2<=k<=HTT_UVEC4; }
Bool HtTIsBVec(I64 k)  { return HTT_BVEC2<=k<=HTT_BVEC4; }
Bool HtTIsMat(I64 k)   { return HTT_MAT2<=k<=HTT_MAT4; }
Bool HtTIsScalar(I64 k){ return HTT_BOOL<=k<=HTT_FLOAT; }
Bool HtTIsNumScalar(I64 k) { return HTT_INT<=k<=HTT_FLOAT; }
Bool HtTIsIntish(I64 k){ return k==HTT_INT || k==HTT_UINT; }

I64 HtVecSize(I64 k)
{
  if (HTT_VEC2<=k<=HTT_VEC4) return k-HTT_VEC2+2;
  if (HTT_IVEC2<=k<=HTT_IVEC4) return k-HTT_IVEC2+2;
  if (HTT_UVEC2<=k<=HTT_UVEC4) return k-HTT_UVEC2+2;
  if (HTT_BVEC2<=k<=HTT_BVEC4) return k-HTT_BVEC2+2;
  return 0;
}

I64 HtVecElem(I64 k)
{
  if (HTT_VEC2<=k<=HTT_VEC4) return HTT_FLOAT;
  if (HTT_IVEC2<=k<=HTT_IVEC4) return HTT_INT;
  if (HTT_UVEC2<=k<=HTT_UVEC4) return HTT_UINT;
  if (HTT_BVEC2<=k<=HTT_BVEC4) return HTT_BOOL;
  return HTT_NONE;
}

I64 HtVecOf(I64 elem,I64 size)
{
  if (size==1) return elem;
  if (elem==HTT_FLOAT) return HTT_VEC2+size-2;
  if (elem==HTT_INT) return HTT_IVEC2+size-2;
  if (elem==HTT_UINT) return HTT_UVEC2+size-2;
  if (elem==HTT_BOOL) return HTT_BVEC2+size-2;
  return HTT_NONE;
}

I64 HtMatSize(I64 k)
{
  if (k==HTT_MAT2) return 2;
  if (k==HTT_MAT3) return 3;
  if (k==HTT_MAT4) return 4;
  return 0;
}

I64 HtCompCount(I64 k)
{//scalar 1, vec N, mat N*N; 0 for anything else
  if (HtTIsScalar(k)) return 1;
  if (HtTIsVec(k)) return HtVecSize(k);
  if (HtTIsMat(k)) return HtMatSize(k)*HtMatSize(k);
  return 0;
}

Bool HtTImplicit(I64 from,I64 to)
{//GLSL-lenient implicit conversion between packed scalar/vector types.
  if (from==to) return TRUE;
  if (HtTArr(from) || HtTArr(to)) return FALSE;
  if (HtTIsScalar(from) && HtTIsScalar(to))
    return HtTIsNumScalar(from) && HtTIsNumScalar(to);
  if (HtTIsVec(from) && HtTIsVec(to))
    return HtVecSize(from)==HtVecSize(to) &&
           HtTIsNumScalar(HtVecElem(from)) && HtTIsNumScalar(HtVecElem(to));
  return FALSE;
}

I64 HtTPromote(I64 a,I64 b)
{//numeric scalar promotion: float > uint > int
  if (a==HTT_FLOAT || b==HTT_FLOAT) return HTT_FLOAT;
  if (a==HTT_UINT || b==HTT_UINT) return HTT_UINT;
  return HTT_INT;
}

//--- number literal classification --------------------------------------------

I64 HtNumType(CHtProgram *p,I64 tok)
{
  CHtToken *t=&p->lex->tok[tok];
  U8 *s=p->lex->src+t->start;
  I64 i;
  if (t->len>2 && s[0]=='0' && (s[1]=='x' || s[1]=='X')) {
    if (s[t->len-1]=='u' || s[t->len-1]=='U') return HTT_UINT;
    return HTT_INT;
  }
  for (i=0;i<t->len;i++)
    if (s[i]=='.' || s[i]=='e' || s[i]=='E' || s[i]=='f' || s[i]=='F')
      return HTT_FLOAT;
  if (s[t->len-1]=='u' || s[t->len-1]=='U') return HTT_UINT;
  return HTT_INT;
}

I64 HtNumIntVal(CHtProgram *p,I64 tok)
{//integer literal value (dec/hex/octal), suffix ignored
  CHtToken *t=&p->lex->tok[tok];
  U8 *s=p->lex->src+t->start;
  I64 i=0,v=0,base=10;
  if (t->len>2 && s[0]=='0' && (s[1]=='x' || s[1]=='X')) {
    base=16;
    i=2;
  } else if (t->len>1 && s[0]=='0') {
    base=8;
    i=1;
  }
  while (i<t->len) {
    if ('0'<=s[i]<='9') v=v*base+s[i]-'0';
    else if ('a'<=s[i]<='f') v=v*base+s[i]-'a'+10;
    else if ('A'<=s[i]<='F') v=v*base+s[i]-'A'+10;
    else break;
    i++;
  }
  return v;
}

//--- symbols -------------------------------------------------------------------

I64 HtSymFind(CHtProgram *p,I64 tok)
{
  I64 i;
  for (i=p->sym_count-1;i>=0;i--)
    if (!p->sym[i].dead && HtTokSame(p->lex,p->sym[i].tok,tok)) return i;
  return -1;
}

I64 HtSymAdd(CHtProgram *p,I64 tok,I64 type,I64 flags,I64 kind,I64 decl)
{
  CHtSym *s;
  if (p->sym_count>=p->sym_cap) {
    HtSemaError(p,tok,"internal symbol capacity");
    return -1;
  }
  s=&p->sym[p->sym_count];
  MemSet(s,0,sizeof(CHtSym));
  s->tok=tok;
  s->type=type;
  s->flags=flags;
  s->kind=kind;
  s->decl=decl;
  return p->sym_count++;
}

U0 HtScopeExit(CHtProgram *p,I64 save)
{
  I64 i;
  for (i=save;i<p->sym_count;i++)
    p->sym[i].dead=TRUE;
}

Bool HtGlobalPerInvocation(CHtProgram *p,I64 s)
{//plan 011: does global symbol s live in the per-invocation CHtCtx?
  if (s<0 || s>=p->sym_count) return FALSE;
  if (p->sym[s].kind!=HT_SYM_GLOBAL) return FALSE;
  return p->sym[s].per_inv;
}

extern Bool HtInitStaticSafe(CHtProgram *p,I64 i);

Bool HtInitStaticSafeChain(CHtProgram *p,I64 i)
{//every element/argument of a next-linked chain is static-safe
  while (i>=0) {
    if (!HtInitStaticSafe(p,i)) return FALSE;
    i=p->node[i].next;
  }
  return TRUE;
}

Bool HtInitStaticSafe(CHtProgram *p,I64 i)
{//plan 011 sec1: can this global initializer run once at install (shared),
 //or must it re-run per invocation?  Recursive over the initializer AST;
 //true only for constants and references to earlier shared-read-only globals.
  CHtAst *n;
  if (i<0) return TRUE;			//no initializer: trivially safe
  n=&p->node[i];
  if (n->kind==HT_AST_NUMBER) return TRUE;
  if (n->kind==HT_AST_NAME) {
    if (n->bind==HT_BIND_TRUE || n->bind==HT_BIND_FALSE) return TRUE;
    if (n->bind==HT_BIND_SYM) {
      if (p->sym[n->c].kind!=HT_SYM_GLOBAL) return FALSE;
      return !p->sym[n->c].per_inv;	//earlier shared-read-only global
    }
    return FALSE;			//uniforms and everything else
  }
  if (n->kind==HT_AST_UNARY)
    return HtInitStaticSafe(p,n->a);
  if (n->kind==HT_AST_MEMBER)
    return HtInitStaticSafe(p,n->a);
  if (n->kind==HT_AST_BINARY || n->kind==HT_AST_INDEX ||
      n->kind==HT_AST_SEQ)
    return HtInitStaticSafe(p,n->a) && HtInitStaticSafe(p,n->b);
  if (n->kind==HT_AST_TERNARY)
    return HtInitStaticSafe(p,n->a) && HtInitStaticSafe(p,n->b) &&
           HtInitStaticSafe(p,n->c);
  if (n->kind==HT_AST_CALL) {
    if (n->bind==HT_CALL_CTOR || n->bind==HT_CALL_BI ||
        n->bind==HT_CALL_STRUCT)
      return HtInitStaticSafeChain(p,n->b);
    return FALSE;			//HT_CALL_USER
  }
  if (n->kind==HT_AST_ARRCTOR)
    return HtInitStaticSafeChain(p,n->b);
  return FALSE;
}

//--- integer constant folding ---------------------------------------------------

Bool HtConstI(CHtProgram *p,I64 i,I64 *out)
{
  CHtAst *n;
  I64 a,b,s;
  if (i<0) return FALSE;
  n=&p->node[i];
  if (n->kind==HT_AST_NUMBER) {
    if (HtNumType(p,n->tok)==HTT_FLOAT) return FALSE;
    *out=HtNumIntVal(p,n->tok);
    return TRUE;
  }
  if (n->kind==HT_AST_NAME) {
    s=HtSymFind(p,n->tok);
    if (s<0 || !p->sym[s].has_const_i) return FALSE;
    *out=p->sym[s].const_i;
    return TRUE;
  }
  if (n->kind==HT_AST_UNARY) {
    if (!HtConstI(p,n->a,&a)) return FALSE;
    if (HtTokEq(p->lex,n->tok,"-")) *out=-a;
    else if (HtTokEq(p->lex,n->tok,"+")) *out=a;
    else if (HtTokEq(p->lex,n->tok,"~")) *out=~a;
    else if (HtTokEq(p->lex,n->tok,"!")) *out=!a;
    else return FALSE;
    return TRUE;
  }
  if (n->kind==HT_AST_BINARY) {
    if (!HtConstI(p,n->a,&a) || !HtConstI(p,n->b,&b)) return FALSE;
    if (HtTokEq(p->lex,n->tok,"+")) *out=a+b;
    else if (HtTokEq(p->lex,n->tok,"-")) *out=a-b;
    else if (HtTokEq(p->lex,n->tok,"*")) *out=a*b;
    else if (HtTokEq(p->lex,n->tok,"/")) {
      if (!b) return FALSE;
      *out=a/b;
    } else if (HtTokEq(p->lex,n->tok,"%")) {
      if (!b) return FALSE;
      *out=a%b;
    } else if (HtTokEq(p->lex,n->tok,"<<")) *out=a<<b;
    else if (HtTokEq(p->lex,n->tok,">>")) *out=a>>b;
    else if (HtTokEq(p->lex,n->tok,"&")) *out=a&b;
    else if (HtTokEq(p->lex,n->tok,"|")) *out=a|b;
    else if (HtTokEq(p->lex,n->tok,"^")) *out=a^b;
    else return FALSE;
    return TRUE;
  }
  return FALSE;
}

//--- struct helpers --------------------------------------------------------------

I64 HtStructMember(CHtProgram *p,I64 sid,I64 name_tok)
{//member DECL node of struct sid matching name token text, or -1
  I64 m;
  if (sid<0 || sid>=p->struct_count) return -1;
  m=p->node[p->struct_node[sid]].a;
  while (m>=0) {
    if (HtTokSame(p->lex,p->node[m].tok,name_tok)) return m;
    m=p->node[m].next;
  }
  return -1;
}

I64 HtStructMemberCount(CHtProgram *p,I64 sid)
{
  I64 m=p->node[p->struct_node[sid]].a,c=0;
  while (m>=0) {
    c++;
    m=p->node[m].next;
  }
  return c;
}

//--- expression sema --------------------------------------------------------------

extern I64 HtSemaExpr(CHtSema *se,I64 i);

I64 HtArgCount(CHtProgram *p,I64 i)
{
  I64 n=0;
  while (i>=0) {
    n++;
    i=p->node[i].next;
  }
  return n;
}

I64 HtArgAt(CHtProgram *p,I64 i,I64 wanted)
{
  while (i>=0 && wanted) {
    i=p->node[i].next;
    wanted--;
  }
  return i;
}

Bool HtSemaIsLval(CHtSema *se,I64 i)
{//after sema: is node i a writable lvalue?
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  CHtSym *s;
  if (n->kind==HT_AST_NAME) {
    if (n->bind!=HT_BIND_SYM) return FALSE;
    s=&p->sym[n->c];
    if (s->flags&HTF_CONST) return FALSE;
    return TRUE;
  }
  if (n->kind==HT_AST_MEMBER) {
    if (n->bind==HT_MEM_SWZ) {
      //no duplicated components in a swizzle store
      I64 c=n->c,cnt=c&15,k,j,ci,cj;
      for (k=0;k<cnt;k++)
        for (j=k+1;j<cnt;j++) {
          ci=(c>>(4+k*4))&15;
          cj=(c>>(4+j*4))&15;
          if (ci==cj) return FALSE;
        }
    }
    return HtSemaIsLval(se,n->a);
  }
  if (n->kind==HT_AST_INDEX)
    return HtSemaIsLval(se,n->a);
  return FALSE;
}

I64 HtSemaName(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  I64 s;
  CHtLexer *l=p->lex;
  if (HtTokEq(l,n->tok,"true")) {
    n->bind=HT_BIND_TRUE;
    return n->type=HTT_BOOL;
  }
  if (HtTokEq(l,n->tok,"false")) {
    n->bind=HT_BIND_FALSE;
    return n->type=HTT_BOOL;
  }
  s=HtSymFind(p,n->tok);
  if (s>=0) {
    n->bind=HT_BIND_SYM;
    n->c=s;
    return n->type=p->sym[s].type;
  }
  if (HtTokEq(l,n->tok,"iResolution")) {
    n->bind=HT_BIND_IRES;
    return n->type=HTT_VEC3;
  }
  if (HtTokEq(l,n->tok,"iTime")) {
    n->bind=HT_BIND_ITIME;
    return n->type=HTT_FLOAT;
  }
  if (HtTokEq(l,n->tok,"iMouse")) {
    n->bind=HT_BIND_IMOUSE;
    return n->type=HTT_VEC4;
  }
  if (HtTokEq(l,n->tok,"iDate")) {
    n->bind=HT_BIND_IDATE;
    return n->type=HTT_VEC4;
  }
  if (HtTokEq(l,n->tok,"iFrame")) {
    n->bind=HT_BIND_IFRAME;
    return n->type=HTT_INT;
  }
  if (HtTokEq(l,n->tok,"iTimeDelta")) {
    n->bind=HT_BIND_ITDELTA;
    return n->type=HTT_FLOAT;
  }
  if (HtTokEq(l,n->tok,"iFrameRate")) {
    n->bind=HT_BIND_IFRATE;
    return n->type=HTT_FLOAT;
  }
  HtSemaError(p,n->tok,"unknown name");
  return HTT_NONE;
}

I64 HtSwzIdx(U8 ch)
{
  if (ch=='x' || ch=='r' || ch=='s') return 0;
  if (ch=='y' || ch=='g' || ch=='t') return 1;
  if (ch=='z' || ch=='b' || ch=='p') return 2;
  if (ch=='w' || ch=='a' || ch=='q') return 3;
  return -1;
}

I64 HtSemaMember(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  I64 base=HtSemaExpr(se,n->a),bk=HtTKind(base),m,idx,k,packed,cnt;
  CHtToken *t;
  U8 *s;
  if (base==HTT_NONE) return HTT_NONE;
  if (HtTArr(base)) {
    HtSemaError(p,n->tok,"member on array");
    return HTT_NONE;
  }
  if (bk==HTT_STRUCT) {
    m=HtStructMember(p,HtTStruct(base),n->tok);
    if (m<0) {
      HtSemaError(p,n->tok,"unknown struct member");
      return HTT_NONE;
    }
    n->bind=HT_MEM_FIELD;
    n->c=m;
    return n->type=p->node[m].type;
  }
  if (HtTIsVec(bk)) {
    t=&p->lex->tok[n->tok];
    s=p->lex->src+t->start;
    cnt=t->len;
    if (cnt<1 || cnt>4) {
      HtSemaError(p,n->tok,"bad swizzle");
      return HTT_NONE;
    }
    packed=cnt;
    for (k=0;k<cnt;k++) {
      idx=HtSwzIdx(s[k]);
      if (idx<0 || idx>=HtVecSize(bk)) {
        HtSemaError(p,n->tok,"bad swizzle component");
        return HTT_NONE;
      }
      packed|=idx<<(4+k*4);
    }
    n->bind=HT_MEM_SWZ;
    n->c=packed;
    return n->type=HtVecOf(HtVecElem(bk),cnt);
  }
  HtSemaError(p,n->tok,"member on non-composite value");
  return HTT_NONE;
}

I64 HtSemaIndex(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  I64 base=HtSemaExpr(se,n->a),idx=HtSemaExpr(se,n->b),bk=HtTKind(base);
  if (base==HTT_NONE || idx==HTT_NONE) return HTT_NONE;
  if (!HtTIsIntish(HtTKind(idx))) {
    HtSemaError(p,n->tok,"index must be integer");
    return HTT_NONE;
  }
  if (HtTArr(base))
    return n->type=HtTElem(base);
  if (HtTIsVec(bk))
    return n->type=HtVecElem(bk);
  if (HtTIsMat(bk))
    return n->type=HtVecOf(HTT_FLOAT,HtMatSize(bk));
  HtSemaError(p,n->tok,"cannot index this value");
  return HTT_NONE;
}

I64 HtSemaBinary(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  I64 a=HtSemaExpr(se,n->a),b=HtSemaExpr(se,n->b);
  I64 ak,bk,elem,size;
  CHtLexer *l=p->lex;
  if (a==HTT_NONE || b==HTT_NONE) return HTT_NONE;
  if (HtTArr(a) || HtTArr(b)) {
    HtSemaError(p,n->tok,"operator on array");
    return HTT_NONE;
  }
  ak=HtTKind(a);
  bk=HtTKind(b);
  if (HtTokEq(l,n->tok,"&&") || HtTokEq(l,n->tok,"||") ||
      HtTokEq(l,n->tok,"^^")) {
    if (ak!=HTT_BOOL || bk!=HTT_BOOL) {
      HtSemaError(p,n->tok,"logical operator needs bool operands");
      return HTT_NONE;
    }
    return n->type=HTT_BOOL;
  }
  if (HtTokEq(l,n->tok,"==") || HtTokEq(l,n->tok,"!=")) {
    if (HtTIsScalar(ak) && HtTIsScalar(bk))
      return n->type=HTT_BOOL;
    if (HtTIsVec(ak) && HtTIsVec(bk) && HtVecSize(ak)==HtVecSize(bk))
      return n->type=HTT_BOOL;
    HtSemaError(p,n->tok,"cannot compare these values");
    return HTT_NONE;
  }
  if (HtTokEq(l,n->tok,"<") || HtTokEq(l,n->tok,">") ||
      HtTokEq(l,n->tok,"<=") || HtTokEq(l,n->tok,">=")) {
    if (HtTIsNumScalar(ak) && HtTIsNumScalar(bk))
      return n->type=HTT_BOOL;
    HtSemaError(p,n->tok,"relational operator needs numeric scalars");
    return HTT_NONE;
  }
  if (HtTokEq(l,n->tok,"%") || HtTokEq(l,n->tok,"<<") ||
      HtTokEq(l,n->tok,">>") || HtTokEq(l,n->tok,"&") ||
      HtTokEq(l,n->tok,"|") || HtTokEq(l,n->tok,"^")) {
    //integer-domain ops: scalars or ivec/uvec, vec-vec or vec-scalar
    if (HtTIsIntish(ak) && HtTIsIntish(bk))
      return n->type=HtTPromote(ak,bk);
    if ((HtTIsIVec(ak) || HtTIsUVec(ak)) &&
        (HtTIsIntish(bk) || HtVecSize(bk)==HtVecSize(ak)))
      return n->type=ak;
    if (HtTIsIntish(ak) && (HtTIsIVec(bk) || HtTIsUVec(bk)))
      return n->type=bk;
    HtSemaError(p,n->tok,"integer operator on non-integer operands");
    return HTT_NONE;
  }
  //arithmetic + - * /
  if (HtTIsNumScalar(ak) && HtTIsNumScalar(bk))
    return n->type=HtTPromote(ak,bk);
  if (HtTIsVec(ak) && HtTIsVec(bk)) {
    if (HtVecSize(ak)!=HtVecSize(bk)) {
      HtSemaError(p,n->tok,"vector size mismatch");
      return HTT_NONE;
    }
    elem=HtTPromote(HtVecElem(ak),HtVecElem(bk));
    return n->type=HtVecOf(elem,HtVecSize(ak));
  }
  if (HtTIsVec(ak) && HtTIsNumScalar(bk)) {
    elem=HtTPromote(HtVecElem(ak),bk);
    return n->type=HtVecOf(elem,HtVecSize(ak));
  }
  if (HtTIsNumScalar(ak) && HtTIsVec(bk)) {
    elem=HtTPromote(ak,HtVecElem(bk));
    return n->type=HtVecOf(elem,HtVecSize(bk));
  }
  if (HtTIsMat(ak) || HtTIsMat(bk)) {
    if (HtTokEq(l,n->tok,"*")) {
      if (HtTIsMat(ak) && HtTIsMat(bk) && ak==bk)
        return n->type=ak;
      if (HtTIsMat(ak) && HtTIsFVec(bk) && HtVecSize(bk)==HtMatSize(ak))
        return n->type=bk;
      if (HtTIsFVec(ak) && HtTIsMat(bk) && HtVecSize(ak)==HtMatSize(bk))
        return n->type=ak;
      if (HtTIsMat(ak) && HtTIsNumScalar(bk))
        return n->type=ak;
      if (HtTIsNumScalar(ak) && HtTIsMat(bk))
        return n->type=bk;
    } else if (HtTIsMat(ak) && ak==bk)
      return n->type=ak;			//componentwise + - /
    else if (HtTIsMat(ak) && HtTIsNumScalar(bk))
      return n->type=ak;
    else if (HtTIsNumScalar(ak) && HtTIsMat(bk))
      return n->type=bk;
    HtSemaError(p,n->tok,"bad matrix operands");
    return HTT_NONE;
  }
  HtSemaError(p,n->tok,"incompatible operands");
  return HTT_NONE;
}

//--- builtin resolution ------------------------------------------------------------

Bool HtBiGen1(I64 t)
{//float scalar or float vector
  return HtTKind(t)==HTT_FLOAT || HtTIsFVec(HtTKind(t));
}

I64 HtSemaBuiltin(CHtSema *se,I64 i,I64 *arg_t,I64 n_args)
{//resolve builtin call at node i; returns result type, sets bind/c.
 //arg_t holds packed arg types. -1 result means "not a builtin".
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  CHtAst *callee=&p->node[n->a];
  CHtLexer *l=p->lex;
  I64 tok=callee->tok,bi=0,rt=HTT_NONE;
  I64 a0=HTT_NONE,a1=HTT_NONE,a2=HTT_NONE;
  I64 k0=HTT_NONE,k1=HTT_NONE,k2=HTT_NONE;
  if (n_args>=1) { a0=arg_t[0]; k0=HtTKind(a0); }
  if (n_args>=2) { a1=arg_t[1]; k1=HtTKind(a1); }
  if (n_args>=3) { a2=arg_t[2]; k2=HtTKind(a2); }
  //1-arg float componentwise
  if (HtTokEq(l,tok,"sin")) bi=HT_BI_SIN;
  else if (HtTokEq(l,tok,"cos")) bi=HT_BI_COS;
  else if (HtTokEq(l,tok,"tan")) bi=HT_BI_TAN;
  else if (HtTokEq(l,tok,"asin")) bi=HT_BI_ASIN;
  else if (HtTokEq(l,tok,"acos")) bi=HT_BI_ACOS;
  else if (HtTokEq(l,tok,"exp")) bi=HT_BI_EXP;
  else if (HtTokEq(l,tok,"log")) bi=HT_BI_LOG;
  else if (HtTokEq(l,tok,"exp2")) bi=HT_BI_EXP2;
  else if (HtTokEq(l,tok,"log2")) bi=HT_BI_LOG2;
  else if (HtTokEq(l,tok,"sqrt")) bi=HT_BI_SQRT;
  else if (HtTokEq(l,tok,"inversesqrt")) bi=HT_BI_INVSQRT;
  else if (HtTokEq(l,tok,"floor")) bi=HT_BI_FLOOR;
  else if (HtTokEq(l,tok,"ceil")) bi=HT_BI_CEIL;
  else if (HtTokEq(l,tok,"fract")) bi=HT_BI_FRACT;
  else if (HtTokEq(l,tok,"radians")) bi=HT_BI_RADIANS;
  else if (HtTokEq(l,tok,"degrees")) bi=HT_BI_DEGREES;
  else if (HtTokEq(l,tok,"round")) bi=HT_BI_ROUND;
  else if (HtTokEq(l,tok,"trunc")) bi=HT_BI_TRUNC;
  if (bi) {
    if (n_args!=1 || !HtBiGen1(a0)) {
      HtSemaError(p,tok,"bad builtin arguments");
      return HTT_NONE;
    }
    n->bind=HT_CALL_BI;
    n->c=bi;
    return n->type=a0;
  }
  if (HtTokEq(l,tok,"atan")) {
    if (n_args==1 && HtBiGen1(a0)) rt=a0;
    else if (n_args==2 && HtBiGen1(a0) && a1==a0) rt=a0;
    else {
      HtSemaError(p,tok,"bad atan arguments");
      return HTT_NONE;
    }
    n->bind=HT_CALL_BI;
    n->c=HT_BI_ATAN;
    return n->type=rt;
  }
  if (HtTokEq(l,tok,"abs") || HtTokEq(l,tok,"sign")) {
    if (n_args!=1 ||
        !(HtBiGen1(a0) || HtTIsIntish(k0) || HtTIsIVec(k0))) {
      HtSemaError(p,tok,"bad builtin arguments");
      return HTT_NONE;
    }
    n->bind=HT_CALL_BI;
    if (HtTokEq(l,tok,"abs")) n->c=HT_BI_ABS;
    else n->c=HT_BI_SIGN;
    return n->type=a0;
  }
  if (HtTokEq(l,tok,"pow")) {
    if (n_args!=2 || !HtBiGen1(a0) || (a1!=a0 && k1!=HTT_FLOAT)) {
      HtSemaError(p,tok,"bad pow arguments");
      return HTT_NONE;
    }
    n->bind=HT_CALL_BI;
    n->c=HT_BI_POW;
    return n->type=a0;
  }
  if (HtTokEq(l,tok,"mod")) {
    if (n_args==2 && HtBiGen1(a0) && (a1==a0 || k1==HTT_FLOAT)) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_MOD;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad mod arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"min") || HtTokEq(l,tok,"max")) {
    if (n_args==2 &&
        ((HtTIsNumScalar(k0) && HtTIsNumScalar(k1)) ||
         (HtTIsVec(k0) && (a1==a0 || HtTIsNumScalar(k1))))) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"min")) n->c=HT_BI_MIN;
      else n->c=HT_BI_MAX;
      if (HtTIsNumScalar(k0) && HtTIsNumScalar(k1))
        return n->type=HtTPromote(k0,k1);
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad min/max arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"clamp")) {
    if (n_args==3 &&
        ((HtTIsNumScalar(k0) && HtTIsNumScalar(k1) && HtTIsNumScalar(k2)) ||
         (HtTIsVec(k0) && ((a1==a0 && a2==a0) ||
                           (HtTIsNumScalar(k1) && HtTIsNumScalar(k2)))))) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_CLAMP;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad clamp arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"mix")) {
    if (n_args==3 && HtBiGen1(a0) && a1==a0 &&
        (a2==a0 || k2==HTT_FLOAT)) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_MIX;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad mix arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"step")) {
    if (n_args==2 && HtBiGen1(a1) && (a0==a1 || k0==HTT_FLOAT)) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_STEP;
      return n->type=a1;
    }
    HtSemaError(p,tok,"bad step arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"smoothstep")) {
    if (n_args==3 && HtBiGen1(a2) &&
        ((a0==a2 && a1==a2) || (k0==HTT_FLOAT && k1==HTT_FLOAT))) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_SSTEP;
      return n->type=a2;
    }
    HtSemaError(p,tok,"bad smoothstep arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"length") || HtTokEq(l,tok,"normalize")) {
    if (n_args==1 && HtTIsFVec(k0)) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"length")) {
        n->c=HT_BI_LENGTH;
        return n->type=HTT_FLOAT;
      }
      n->c=HT_BI_NORMALIZE;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad vector builtin arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"distance") || HtTokEq(l,tok,"dot")) {
    if (n_args==2 && HtTIsFVec(k0) && a1==a0) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"distance")) n->c=HT_BI_DISTANCE;
      else n->c=HT_BI_DOT;
      return n->type=HTT_FLOAT;
    }
    HtSemaError(p,tok,"bad vector builtin arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"cross")) {
    if (n_args==2 && k0==HTT_VEC3 && k1==HTT_VEC3) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_CROSS;
      return n->type=HTT_VEC3;
    }
    HtSemaError(p,tok,"bad cross arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"reflect")) {
    if (n_args==2 && HtTIsFVec(k0) && a1==a0) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_REFLECT;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad reflect arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"refract")) {
    if (n_args==3 && HtTIsFVec(k0) && a1==a0 && k2==HTT_FLOAT) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_REFRACT;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad refract arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"faceforward")) {
    if (n_args==3 && HtTIsFVec(k0) && a1==a0 && a2==a0) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_FACEFWD;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad faceforward arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"lessThan") || HtTokEq(l,tok,"lessThanEqual") ||
      HtTokEq(l,tok,"greaterThan") || HtTokEq(l,tok,"greaterThanEqual") ||
      HtTokEq(l,tok,"equal") || HtTokEq(l,tok,"notEqual")) {
    if (n_args==2 && HtTIsVec(k0) && HtTIsVec(k1) &&
        HtVecSize(k0)==HtVecSize(k1)) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"lessThan")) n->c=HT_BI_LT;
      else if (HtTokEq(l,tok,"lessThanEqual")) n->c=HT_BI_LE;
      else if (HtTokEq(l,tok,"greaterThan")) n->c=HT_BI_GT;
      else if (HtTokEq(l,tok,"greaterThanEqual")) n->c=HT_BI_GE;
      else if (HtTokEq(l,tok,"equal")) n->c=HT_BI_EQ;
      else n->c=HT_BI_NE;
      return n->type=HtVecOf(HTT_BOOL,HtVecSize(k0));
    }
    HtSemaError(p,tok,"bad relational builtin arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"any") || HtTokEq(l,tok,"all")) {
    if (n_args==1 && HtTIsBVec(k0)) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"any")) n->c=HT_BI_ANY;
      else n->c=HT_BI_ALL;
      return n->type=HTT_BOOL;
    }
    HtSemaError(p,tok,"bad any/all arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"not")) {
    if (n_args==1 && HtTIsBVec(k0)) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_NOT;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad not arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"matrixCompMult")) {
    if (n_args==2 && HtTIsMat(k0) && a1==a0) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_MATCOMP;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad matrixCompMult arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"transpose")) {
    if (n_args==1 && HtTIsMat(k0)) {
      n->bind=HT_CALL_BI;
      n->c=HT_BI_TRANSPOSE;
      return n->type=a0;
    }
    HtSemaError(p,tok,"bad transpose arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"floatBitsToInt") || HtTokEq(l,tok,"floatBitsToUint")) {
    if (n_args==1 && HtBiGen1(a0)) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"floatBitsToInt")) {
        n->c=HT_BI_FB2I;
        if (k0==HTT_FLOAT) return n->type=HTT_INT;
        return n->type=HtVecOf(HTT_INT,HtVecSize(k0));
      }
      n->c=HT_BI_FB2U;
      if (k0==HTT_FLOAT) return n->type=HTT_UINT;
      return n->type=HtVecOf(HTT_UINT,HtVecSize(k0));
    }
    HtSemaError(p,tok,"bad floatBitsTo* arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"intBitsToFloat") || HtTokEq(l,tok,"uintBitsToFloat")) {
    if (n_args==1 && (HtTIsIntish(k0) || HtTIsIVec(k0) || HtTIsUVec(k0))) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"intBitsToFloat")) n->c=HT_BI_I2FB;
      else n->c=HT_BI_U2FB;
      if (HtTIsIntish(k0)) return n->type=HTT_FLOAT;
      return n->type=HtVecOf(HTT_FLOAT,HtVecSize(k0));
    }
    HtSemaError(p,tok,"bad intBitsToFloat arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"isnan") || HtTokEq(l,tok,"isinf")) {
    if (n_args==1 && HtBiGen1(a0)) {
      n->bind=HT_CALL_BI;
      if (HtTokEq(l,tok,"isnan")) n->c=HT_BI_ISNAN;
      else n->c=HT_BI_ISINF;
      if (k0==HTT_FLOAT) return n->type=HTT_BOOL;
      return n->type=HtVecOf(HTT_BOOL,HtVecSize(k0));
    }
    HtSemaError(p,tok,"bad isnan/isinf arguments");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"texture") || HtTokEq(l,tok,"texture2D") ||
      HtTokEq(l,tok,"textureLod") || HtTokEq(l,tok,"texelFetch")) {
    HtSemaError(p,tok,"textures are outside corpus v1 scope");
    return HTT_NONE;
  }
  if (HtTokEq(l,tok,"dFdx") || HtTokEq(l,tok,"dFdy") ||
      HtTokEq(l,tok,"fwidth")) {
    HtSemaError(p,tok,"derivatives not supported");
    return HTT_NONE;
  }
  return -1;				//not a builtin
}

//--- calls --------------------------------------------------------------------------

I64 HtSemaCall(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i],*callee,*fn,*par;
  I64 arg_t[16];
  I64 arg,n_args=0,ty,k,total,need,f,best,m,rt;
  if (n->a<0 || p->node[n->a].kind!=HT_AST_NAME) {
    HtSemaError(p,n->tok,"callee must be a name");
    return HTT_NONE;
  }
  callee=&p->node[n->a];
  arg=n->b;
  while (arg>=0) {
    if (n_args>=16) {
      HtSemaError(p,n->tok,"too many call arguments");
      return HTT_NONE;
    }
    ty=HtSemaExpr(se,arg);
    if (ty==HTT_NONE) return HTT_NONE;
    arg_t[n_args++]=ty;
    arg=p->node[arg].next;
  }
  //constructor?
  ty=HtTypeAt(p,callee->tok);
  if (ty!=HTT_NONE) {
    k=HtTKind(ty);
    if (k==HTT_STRUCT) {
      need=HtStructMemberCount(p,HtTStruct(ty));
      if (n_args!=need) {
        HtSemaError(p,n->tok,"struct constructor argument count");
        return HTT_NONE;
      }
      m=p->node[p->struct_node[HtTStruct(ty)]].a;
      for (arg=0;arg<n_args;arg++) {
        if (!HtTImplicit(arg_t[arg],p->node[m].type) &&
            arg_t[arg]!=p->node[m].type) {
          HtSemaError(p,n->tok,"struct constructor argument type");
          return HTT_NONE;
        }
        m=p->node[m].next;
      }
      n->bind=HT_CALL_STRUCT;
      return n->type=ty;
    }
    if (HtTIsScalar(k)) {
      if (n_args!=1 || HtCompCount(HtTKind(arg_t[0]))<1) {
        HtSemaError(p,n->tok,"scalar constructor takes one value");
        return HTT_NONE;
      }
      n->bind=HT_CALL_CTOR;
      return n->type=k;
    }
    if (HtTIsVec(k)) {
      need=HtVecSize(k);
      total=0;
      for (arg=0;arg<n_args;arg++) {
        m=HtCompCount(HtTKind(arg_t[arg]));
        if (!m) {
          HtSemaError(p,n->tok,"bad vector constructor argument");
          return HTT_NONE;
        }
        total+=m;
      }
      //GLSL drops extra trailing components of the LAST argument (the
      //same rule that lets vec3(v4) truncate); only an argument that
      //contributes nothing is an error. m holds the last argument's
      //component count after the loop; the emitter already stops copying
      //at the destination size (HtEmCtor's c<cnt bound).
      if (!(n_args==1 && total==1) &&		//splat
          (total<need || total-m>=need)) {
        HtSemaError(p,n->tok,"vector constructor component count");
        return HTT_NONE;
      }
      n->bind=HT_CALL_CTOR;
      return n->type=k;
    }
    if (HtTIsMat(k)) {
      need=HtMatSize(k)*HtMatSize(k);
      total=0;
      for (arg=0;arg<n_args;arg++) {
        m=HtCompCount(HtTKind(arg_t[arg]));
        if (!m && !HtTIsMat(HtTKind(arg_t[arg]))) {
          HtSemaError(p,n->tok,"bad matrix constructor argument");
          return HTT_NONE;
        }
        total+=m;
      }
      if (!(n_args==1 && total==1) &&		//diagonal
          total!=need) {
        HtSemaError(p,n->tok,"matrix constructor component count");
        return HTT_NONE;
      }
      n->bind=HT_CALL_CTOR;
      return n->type=k;
    }
    HtSemaError(p,n->tok,"cannot construct this type");
    return HTT_NONE;
  }
  //builtin?
  rt=HtSemaBuiltin(se,i,arg_t,n_args);
  if (rt!=-1) return rt;
  //user function: match name, arg count, implicit-convertible types;
  //prefer an exact match, then a convertible one; definitions only.
  best=-1;
  for (f=0;f<p->node_count;f++) {
    fn=&p->node[f];
    if (fn->kind!=HT_AST_FUNC || fn->b<0) goto ovl_next;
    if (!HtTokSame(p->lex,fn->tok,callee->tok)) goto ovl_next;
    m=fn->a;
    need=0;
    while (m>=0) {
      need++;
      m=p->node[m].next;
    }
    if (need!=n_args) goto ovl_next;
    m=fn->a;
    total=TRUE;				//exact
    for (arg=0;arg<n_args;arg++) {
      par=&p->node[m];
      if (arg_t[arg]!=par->type) {
        total=FALSE;
        if (!HtTImplicit(arg_t[arg],par->type)) {
          total=-1;
          break;
        }
      }
      m=par->next;
    }
    if (total==-1) goto ovl_next;
    if (total==TRUE) {
      best=f;
      break;
    }
    if (best<0) best=f;
ovl_next:;
  }
  if (best<0) {
    HtSemaError(p,callee->tok,"unknown function");
    return HTT_NONE;
  }
  //out/inout arguments must be lvalues of the exact parameter type
  fn=&p->node[best];
  m=fn->a;
  arg=n->b;
  while (m>=0) {
    if (p->node[m].flags&HTF_OUT) {
      if (!HtSemaIsLval(se,arg)) {
        HtSemaError(p,n->tok,"out argument must be assignable");
        return HTT_NONE;
      }
    }
    m=p->node[m].next;
    arg=p->node[arg].next;
  }
  n->bind=HT_CALL_USER;
  n->c=best;
  return n->type=fn->type;
}

//--- remaining expressions ------------------------------------------------------------

I64 HtSemaExpr(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n;
  I64 a,b,c,ak,t;
  CHtLexer *l=p->lex;
  if (i<0) return HTT_NONE;
  n=&p->node[i];
  if (n->kind==HT_AST_NUMBER)
    return n->type=HtNumType(p,n->tok);
  if (n->kind==HT_AST_NAME)
    return HtSemaName(se,i);
  if (n->kind==HT_AST_UNARY) {
    a=HtSemaExpr(se,n->a);
    if (a==HTT_NONE) return HTT_NONE;
    ak=HtTKind(a);
    if (HtTokEq(l,n->tok,"!")) {
      if (ak!=HTT_BOOL) {
        HtSemaError(p,n->tok,"! needs bool");
        return HTT_NONE;
      }
      return n->type=HTT_BOOL;
    }
    if (HtTokEq(l,n->tok,"~")) {
      if (!HtTIsIntish(ak) && !HtTIsIVec(ak) && !HtTIsUVec(ak)) {
        HtSemaError(p,n->tok,"~ needs integer");
        return HTT_NONE;
      }
      return n->type=a;
    }
    if (HtTIsNumScalar(ak) || HtTIsVec(ak) || HtTIsMat(ak))
      return n->type=a;
    HtSemaError(p,n->tok,"bad unary operand");
    return HTT_NONE;
  }
  if (n->kind==HT_AST_BINARY)
    return HtSemaBinary(se,i);
  if (n->kind==HT_AST_MEMBER)
    return HtSemaMember(se,i);
  if (n->kind==HT_AST_INDEX)
    return HtSemaIndex(se,i);
  if (n->kind==HT_AST_TERNARY) {
    a=HtSemaExpr(se,n->a);
    b=HtSemaExpr(se,n->b);
    c=HtSemaExpr(se,n->c);
    if (a==HTT_NONE || b==HTT_NONE || c==HTT_NONE) return HTT_NONE;
    if (HtTKind(a)!=HTT_BOOL) {
      HtSemaError(p,n->tok,"?: condition must be bool");
      return HTT_NONE;
    }
    if (b==c) return n->type=b;
    if (HtTIsNumScalar(HtTKind(b)) && HtTIsNumScalar(HtTKind(c)))
      return n->type=HtTPromote(HtTKind(b),HtTKind(c));
    if (HtTImplicit(c,b)) return n->type=b;
    if (HtTImplicit(b,c)) return n->type=c;
    HtSemaError(p,n->tok,"?: branch type mismatch");
    return HTT_NONE;
  }
  if (n->kind==HT_AST_ASSIGN) {
    a=HtSemaExpr(se,n->a);
    b=HtSemaExpr(se,n->b);
    if (a==HTT_NONE || b==HTT_NONE) return HTT_NONE;
    if (!HtSemaIsLval(se,n->a)) {
      HtSemaError(p,n->tok,"target is not assignable");
      return HTT_NONE;
    }
    if (!HtTokEq(l,n->tok,"=")) {
      //compound: same operand rules as the matching binary operator,
      //so vec op= scalar and mat op= scalar are legal
      ak=HtTKind(a);
      if (HtTIsNumScalar(ak) && HtTIsNumScalar(HtTKind(b)))
        return n->type=a;
      if (HtTIsVec(ak) &&
          (b==a || HtTIsNumScalar(HtTKind(b)) ||
           (HtTIsVec(HtTKind(b)) && HtVecSize(HtTKind(b))==HtVecSize(ak))))
        return n->type=a;
      if (HtTIsMat(ak) &&
          (b==a || HtTIsNumScalar(HtTKind(b))))
        return n->type=a;
      if (HtTIsFVec(ak) && HtTIsMat(HtTKind(b)) &&
          HtMatSize(HtTKind(b))==HtVecSize(ak))
        return n->type=a;		//v *= m
      HtSemaError(p,n->tok,"bad compound assignment");
      return HTT_NONE;
    }
    if (a!=b && !HtTImplicit(b,a)) {
      HtSemaError(p,n->tok,"assignment type mismatch");
      return HTT_NONE;
    }
    return n->type=a;
  }
  if (n->kind==HT_AST_PREINC || n->kind==HT_AST_POSTINC) {
    a=HtSemaExpr(se,n->a);
    if (a==HTT_NONE) return HTT_NONE;
    if (!HtSemaIsLval(se,n->a) ||
        !(HtTIsNumScalar(HtTKind(a)) || HtTIsVec(HtTKind(a)))) {
      HtSemaError(p,n->tok,"++/-- needs a numeric variable");
      return HTT_NONE;
    }
    return n->type=a;
  }
  if (n->kind==HT_AST_CALL)
    return HtSemaCall(se,i);
  if (n->kind==HT_AST_ARRCTOR) {
    t=n->type;				//element base from parser
    a=n->b;
    b=0;
    while (a>=0) {
      c=HtSemaExpr(se,a);
      if (c==HTT_NONE) return HTT_NONE;
      if (c!=t && !HtTImplicit(c,t)) {
        HtSemaError(p,n->tok,"array constructor element type");
        return HTT_NONE;
      }
      b++;
      a=p->node[a].next;
    }
    if (n->d>=0) {
      if (!HtConstI(p,n->d,&c) || c!=b) {
        HtSemaError(p,n->tok,"array constructor size mismatch");
        return HTT_NONE;
      }
    }
    return n->type=HtTMk(HtTKind(t),HtTStruct(t),b);
  }
  if (n->kind==HT_AST_SEQ) {
    HtSemaExpr(se,n->a);
    return n->type=HtSemaExpr(se,n->b);
  }
  HtSemaError(p,n->tok,"expected value expression");
  return HTT_NONE;
}

//--- statements -------------------------------------------------------------------------

extern Bool HtSemaStmt(CHtSema *se,I64 i);

Bool HtSemaDecl(CHtSema *se,I64 i,I64 kind)
{//DECL node: fold array size, check initializer, add symbol.
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i];
  I64 sz,it,s;
  if (n->b==-2) {			//unsized array: size from initializer
    if (n->a<0 || p->node[n->a].kind!=HT_AST_ARRCTOR) {
      HtSemaError(p,n->tok,"unsized array needs array initializer");
      return FALSE;
    }
  } else if (n->b>=0) {
    if (!HtConstI(p,n->b,&sz) || sz<1 || sz>4096) {
      HtSemaError(p,n->tok,"array size must be a positive constant");
      return FALSE;
    }
    n->type=HtTMk(HtTKind(n->type),HtTStruct(n->type),sz);
  }
  if (n->a>=0) {
    it=HtSemaExpr(se,n->a);
    if (it==HTT_NONE) return FALSE;
    if (n->b==-2)
      n->type=HtTMk(HtTKind(n->type),HtTStruct(n->type),HtTArr(it));
    if (it!=n->type && !HtTImplicit(it,n->type)) {
      HtSemaError(p,n->tok,"initializer type mismatch");
      return FALSE;
    }
  }
  s=HtSymAdd(p,n->tok,n->type,n->flags,kind,i);
  if (s<0) return FALSE;
  n->c=s;				//emitter finds the symbol here
  //fold const int scalars for later array sizes
  if ((n->flags&HTF_CONST) && HtTKind(n->type)==HTT_INT && !HtTArr(n->type) &&
      n->a>=0)
    p->sym[s].has_const_i=HtConstI(p,n->a,&p->sym[s].const_i);
  return TRUE;
}

Bool HtSemaBlockStmts(CHtSema *se,I64 first)
{
  CHtProgram *p=se->p;
  I64 i=first;
  while (i>=0 && !*p->error) {
    if (!HtSemaStmt(se,i)) return FALSE;
    i=p->node[i].next;
  }
  return !*p->error;
}

Bool HtSemaStmt(CHtSema *se,I64 i)
{
  CHtProgram *p=se->p;
  CHtAst *n=&p->node[i],*fn;
  I64 save,t;
  if (*p->error) return FALSE;
  if (n->kind==HT_AST_BLOCK) {
    save=p->sym_count;
    HtSemaBlockStmts(se,n->a);
    HtScopeExit(p,save);
    return !*p->error;
  }
  if (n->kind==HT_AST_DECL)
    return HtSemaDecl(se,i,HT_SYM_LOCAL);
  if (n->kind==HT_AST_EXPR_STMT)
    return HtSemaExpr(se,n->a)!=HTT_NONE;
  if (n->kind==HT_AST_EMPTY)
    return TRUE;
  if (n->kind==HT_AST_IF) {
    t=HtSemaExpr(se,n->a);
    if (t==HTT_NONE) return FALSE;
    if (HtTKind(t)!=HTT_BOOL) {
      HtSemaError(p,n->tok,"if condition must be bool");
      return FALSE;
    }
    if (!HtSemaStmt(se,n->b)) return FALSE;
    if (n->c>=0 && !HtSemaStmt(se,n->c)) return FALSE;
    return TRUE;
  }
  if (n->kind==HT_AST_FOR) {
    save=p->sym_count;
    if (n->a>=0 && !HtSemaBlockStmts(se,n->a)) return FALSE;
    if (n->b>=0) {
      t=HtSemaExpr(se,n->b);
      if (t==HTT_NONE) return FALSE;
      if (HtTKind(t)!=HTT_BOOL) {
        HtSemaError(p,n->tok,"for condition must be bool");
        return FALSE;
      }
    }
    if (n->c>=0 && HtSemaExpr(se,n->c)==HTT_NONE) return FALSE;
    se->loop_depth++;
    if (!HtSemaStmt(se,n->d)) return FALSE;
    se->loop_depth--;
    HtScopeExit(p,save);
    return TRUE;
  }
  if (n->kind==HT_AST_WHILE) {
    t=HtSemaExpr(se,n->a);
    if (t==HTT_NONE) return FALSE;
    if (HtTKind(t)!=HTT_BOOL) {
      HtSemaError(p,n->tok,"while condition must be bool");
      return FALSE;
    }
    se->loop_depth++;
    if (!HtSemaStmt(se,n->b)) return FALSE;
    se->loop_depth--;
    return TRUE;
  }
  if (n->kind==HT_AST_DO) {
    se->loop_depth++;
    if (!HtSemaStmt(se,n->a)) return FALSE;
    se->loop_depth--;
    t=HtSemaExpr(se,n->b);
    if (t==HTT_NONE) return FALSE;
    if (HtTKind(t)!=HTT_BOOL) {
      HtSemaError(p,n->tok,"do-while condition must be bool");
      return FALSE;
    }
    return TRUE;
  }
  if (n->kind==HT_AST_BREAK || n->kind==HT_AST_CONTINUE) {
    if (!se->loop_depth) {
      HtSemaError(p,n->tok,"break/continue outside loop");
      return FALSE;
    }
    return TRUE;
  }
  if (n->kind==HT_AST_RETURN) {
    fn=&p->node[se->fn];
    if (n->a<0) {
      if (HtTKind(fn->type)!=HTT_VOID) {
        HtSemaError(p,n->tok,"missing return value");
        return FALSE;
      }
      return TRUE;
    }
    t=HtSemaExpr(se,n->a);
    if (t==HTT_NONE) return FALSE;
    if (t!=fn->type && !HtTImplicit(t,fn->type)) {
      HtSemaError(p,n->tok,"return type mismatch");
      return FALSE;
    }
    return TRUE;
  }
  HtSemaError(p,n->tok,"invalid statement");
  return FALSE;
}

//--- program ------------------------------------------------------------------------------

Bool HtLower(CHtProgram *p)
{
  CHtSema se;
  CHtAst *n,*par;
  I64 i,save,m,sz,s;
  Bool saw_main=FALSE;
  MemSet(&se,0,sizeof(CHtSema));
  se.p=p;
  se.fn=-1;
  p->main_node=-1;
  p->sym_cap=p->node_count+16;
  p->sym=CAlloc(p->sym_cap*sizeof(CHtSym));
  p->sym_count=0;
  //pass 1: struct member array sizes
  for (i=0;i<p->struct_count && !*p->error;i++) {
    m=p->node[p->struct_node[i]].a;
    while (m>=0) {
      if (p->node[m].b>=0) {
        if (!HtConstI(p,p->node[m].b,&sz) || sz<1 || sz>4096) {
          HtSemaError(p,p->node[m].tok,"struct member array size");
          return FALSE;
        }
        p->node[m].type=HtTMk(HtTKind(p->node[m].type),
                              HtTStruct(p->node[m].type),sz);
      }
      m=p->node[m].next;
    }
  }
  //pass 2: walk top level in order; globals and functions
  i=p->root;
  while (i>=0 && !*p->error) {
    n=&p->node[i];
    if (n->kind==HT_AST_DECL) {
      if (!HtSemaDecl(&se,i,HT_SYM_GLOBAL)) break;
      //plan 011: classify in declaration order. A const global with a
      //static-safe initializer stays a shared process global; everything
      //else (mutable, or const-from-uniform) moves into the per-invocation
      //CHtCtx. n->c is the symbol index set by HtSemaDecl.
      if ((n->flags&HTF_CONST) && HtInitStaticSafe(p,n->a))
        p->sym[n->c].per_inv=FALSE;
      else
        p->sym[n->c].per_inv=TRUE;
    } else if (n->kind==HT_AST_FUNC && n->b>=0) {
      se.fn=i;
      se.loop_depth=0;
      save=p->sym_count;
      m=n->a;
      while (m>=0) {
        par=&p->node[m];
        if (par->b>=0) {
          if (!HtConstI(p,par->b,&sz) || sz<1) {
            HtSemaError(p,par->tok,"parameter array size");
            break;
          }
          par->type=HtTMk(HtTKind(par->type),HtTStruct(par->type),sz);
        }
        if (par->tok>=0) {
          s=HtSymAdd(p,par->tok,par->type,par->flags,HT_SYM_PARAM,m);
          if (s<0) break;
          par->c=s;
        }
        m=par->next;
      }
      if (*p->error) break;
      HtSemaBlockStmts(&se,p->node[n->b].a);
      HtScopeExit(p,save);
      se.fn=-1;
      if (*p->error) break;
      //mainImage(out vec4, in vec2)?
      if (HtTokEq(p->lex,n->tok,"mainImage") && HtTKind(n->type)==HTT_VOID) {
        m=n->a;
        if (m>=0 && p->node[m].type==HTT_VEC4 &&
            (p->node[m].flags&HTF_OUT) && p->node[m].next>=0 &&
            p->node[p->node[m].next].type==HTT_VEC2 &&
            p->node[p->node[m].next].next<0) {
          p->main_node=i;
          saw_main=TRUE;
        }
      }
    }
    i=n->next;
  }
  if (!*p->error && !saw_main)
    HtSemaError(p,0,"no mainImage(out vec4, in vec2) found");
  return !*p->error;
}
