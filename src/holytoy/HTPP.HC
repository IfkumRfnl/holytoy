//HolyToy GLSL preprocessor (HTPP) -- text to text, before the lexer.
//
//Supports object-like and function-like #define, #undef, #if/#ifdef/
//#ifndef/#elif/#else/#endif with defined() and an integer constant
//expression evaluator; #version/#extension/#pragma/#line are ignored.
//Comments are stripped first (GLSL treats them as whitespace everywhere,
//including inside directives). Output preserves the input LINE COUNT
//exactly so downstream diagnostics keep pointing at editor lines:
//directive lines and inactive-region lines become empty lines, and joined
//continuation lines re-emit their newlines.
//
//All storage belongs to one compile attempt; HtPpDel releases it.

#define HTPP_MAX_MACROS	256
#define HTPP_MAX_PARAMS	10
#define HTPP_NAME_LEN	64
#define HTPP_MAX_DEPTH	32
#define HTPP_MAX_COND	32

class CHtMacro
{
  U8 name[HTPP_NAME_LEN];
  U8 *body;			//MAlloc'ed, single line, no newline
  I64 n_params;			//-1 = object-like
  U8 *param;			//MAlloc'ed HTPP_MAX_PARAMS*HTPP_NAME_LEN
};

class CHtPp
{
  CHtMacro *macro;		//CAlloc'ed HTPP_MAX_MACROS entries
  I64 macro_count;
  I64 line;			//current input line, for errors
  U8 error[160];
};

class CHtPpBuf
{
  U8 *p;
  I64 len,cap;
};

U0 HtPpBufInit(CHtPpBuf *b,I64 cap)
{
  if (cap<256) cap=256;
  b->p=MAlloc(cap);
  b->p[0]=0;
  b->len=0;
  b->cap=cap;
}

U0 HtPpBufPutN(CHtPpBuf *b,U8 *s,I64 n)
{
  U8 *next;
  I64 cap=b->cap;
  if (b->len+n+1>cap) {
    while (b->len+n+1>cap) cap=cap*2;
    next=MAlloc(cap);
    MemCpy(next,b->p,b->len+1);
    Free(b->p);
    b->p=next;
    b->cap=cap;
  }
  MemCpy(b->p+b->len,s,n);
  b->len+=n;
  b->p[b->len]=0;
}

U0 HtPpBufPut(CHtPpBuf *b,U8 *s)
{
  HtPpBufPutN(b,s,StrLen(s));
}

U0 HtPpBufPutCh(CHtPpBuf *b,I64 ch)
{
  U8 tmp[2];
  tmp[0]=ch;
  tmp[1]=0;
  HtPpBufPutN(b,tmp,1);
}

U0 HtPpError(CHtPp *pp,U8 *msg)
{
  if (*pp->error) return;
  StrPrint(pp->error,"line %d: %s",pp->line,msg);
}

Bool HtPpIsIdent0(U8 ch)
{
  return ch=='_' || 'a'<=ch<='z' || 'A'<=ch<='Z';
}

Bool HtPpIsIdent(U8 ch)
{
  return HtPpIsIdent0(ch) || '0'<=ch<='9';
}

U0 HtPpDel(CHtPp *pp)
{
  I64 i;
  if (pp->macro) {
    for (i=0;i<pp->macro_count;i++) {
      Free(pp->macro[i].body);
      Free(pp->macro[i].param);
    }
    Free(pp->macro);
    pp->macro=NULL;
  }
  pp->macro_count=0;
}

I64 HtPpFind(CHtPp *pp,U8 *name)
{
  I64 i;
  for (i=pp->macro_count-1;i>=0;i--)
    if (pp->macro[i].body && !StrCmp(pp->macro[i].name,name)) return i;
  return -1;
}

U0 HtPpUndef(CHtPp *pp,U8 *name)
{
  I64 i=HtPpFind(pp,name);
  if (i>=0) {
    Free(pp->macro[i].body);
    pp->macro[i].body=NULL;
  }
}

//--- comment stripping ------------------------------------------------------

U8 *HtPpStripComments(U8 *src)
{//Newline-preserving copy with // and /* */ comments blanked to spaces.
  I64 n=StrLen(src),i=0;
  U8 *out=MAlloc(n+1);
  MemCpy(out,src,n+1);
  while (i<n) {
    if (out[i]=='/' && out[i+1]=='/') {
      while (i<n && out[i]!='\n') out[i++]=' ';
    } else if (out[i]=='/' && out[i+1]=='*') {
      out[i++]=' ';
      out[i++]=' ';
      while (i<n && !(out[i]=='*' && out[i+1]=='/')) {
        if (out[i]!='\n') out[i]=' ';
        i++;
      }
      if (i<n) {
        out[i++]=' ';
        out[i++]=' ';
      }
    } else
      i++;
  }
  return out;
}

//--- macro expansion --------------------------------------------------------

extern U0 HtPpExpandInto(CHtPp *pp,CHtPpBuf *out,U8 *text,I64 depth);

U0 HtPpSubstBody(CHtPp *pp,CHtPpBuf *out,CHtMacro *mac,
                 U8 **arg,I64 n_args,I64 depth)
{//Copy the macro body with parameters replaced by (already expanded) args.
  U8 *s=mac->body,name[HTPP_NAME_LEN];
  I64 i,k;
  Bool hit;
  while (*s && !*pp->error) {
    if (HtPpIsIdent0(*s)) {
      i=0;
      while (HtPpIsIdent(*s) && i<HTPP_NAME_LEN-1) name[i++]=*s++;
      while (HtPpIsIdent(*s)) s++;	//overlong tail
      name[i]=0;
      hit=FALSE;
      for (k=0;k<mac->n_params;k++)
        if (!StrCmp(mac->param+k*HTPP_NAME_LEN,name)) {
          //Space-wrap the substituted argument so adjacent operator
          //characters never paste into new tokens ("-x" with arg "-1"
          //must not become "--1"). Whitespace is token-safe: there is
          //no stringize/paste support.
          if (k<n_args) {
            HtPpBufPutCh(out,' ');
            HtPpBufPut(out,arg[k]);
            HtPpBufPutCh(out,' ');
          }
          hit=TRUE;
          break;
        }
      if (!hit) HtPpBufPut(out,name);
    } else
      HtPpBufPutCh(out,*s++);
  }
}

U0 HtPpExpandMacro(CHtPp *pp,CHtPpBuf *out,CHtMacro *mac,U8 **s_io,I64 depth)
{//*s_io points just past the macro name. Function-like macros consume the
 //argument list; each argument is fully expanded before substitution.
  U8 *s=*s_io,*raw;
  U8 *arg[HTPP_MAX_PARAMS];
  I64 n_args=0,plevel,start,i;
  CHtPpBuf sub,ex;
  for (i=0;i<HTPP_MAX_PARAMS;i++) arg[i]=NULL;
  if (mac->n_params>=0) {
    while (*s==' ' || *s=='\t') s++;
    if (*s!='(') {			//fn-like name without call: literal
      HtPpBufPut(out,mac->name);
      *s_io=s;
      return;
    }
    s++;
    plevel=0;
    start=0;
    raw=s;
    while (TRUE) {
      if (!*s) {
        HtPpError(pp,"unterminated macro arguments");
        break;
      }
      if (*s=='(') plevel++;
      else if (*s==')' && plevel>0) plevel--;
      else if ((*s==',' && !plevel) || (*s==')' && !plevel)) {
        if (n_args<HTPP_MAX_PARAMS) {
          i=s-raw;
          arg[n_args]=MAlloc(i+1);
          MemCpy(arg[n_args],raw,i);
          arg[n_args][i]=0;
          n_args++;
        } else
          HtPpError(pp,"too many macro arguments");
        if (*s==')') {
          s++;
          break;
        }
        raw=s+1;
      }
      s++;
    }
    //A zero-parameter macro called as FOO() collects one empty arg; drop it.
    if (mac->n_params==0 && n_args==1 && !arg[0][0]) {
      Free(arg[0]);
      arg[0]=NULL;
      n_args=0;
    }
    if (!*pp->error && n_args!=mac->n_params)
      HtPpError(pp,"macro argument count mismatch");
    //Expand each argument in place.
    for (i=0;i<n_args && !*pp->error;i++) {
      HtPpBufInit(&ex,StrLen(arg[i])*2+16);
      HtPpExpandInto(pp,&ex,arg[i],depth+1);
      Free(arg[i]);
      arg[i]=ex.p;
    }
  }
  if (!*pp->error) {
    HtPpBufInit(&sub,StrLen(mac->body)*2+16);
    HtPpSubstBody(pp,&sub,mac,arg,n_args,depth);
    if (!*pp->error)
      HtPpExpandInto(pp,out,sub.p,depth+1);	//rescan
    Free(sub.p);
  }
  for (i=0;i<n_args;i++) Free(arg[i]);
  *s_io=s;
}

U0 HtPpExpandInto(CHtPp *pp,CHtPpBuf *out,U8 *text,I64 depth)
{//Scan text, expanding macros; numbers are copied atomically so "2e3" never
 //feeds its 'e' into identifier matching.
  U8 *s=text,name[HTPP_NAME_LEN];
  I64 i,m;
  if (depth>HTPP_MAX_DEPTH) {
    HtPpError(pp,"macro expansion too deep (recursive define?)");
    return;
  }
  while (*s && !*pp->error) {
    if (HtPpIsIdent0(*s)) {
      i=0;
      while (HtPpIsIdent(*s) && i<HTPP_NAME_LEN-1) name[i++]=*s++;
      while (HtPpIsIdent(*s)) s++;
      name[i]=0;
      m=HtPpFind(pp,name);
      if (m>=0) {
        //Space-wrap the whole expansion: "#define D -0.136" used as
        //"-D" must expand to "- -0.136", not the decrement "--0.136".
        HtPpBufPutCh(out,' ');
        HtPpExpandMacro(pp,out,&pp->macro[m],&s,depth);
        HtPpBufPutCh(out,' ');
      } else
        HtPpBufPut(out,name);
    } else if ('0'<=*s<='9' ||
               (*s=='.' && '0'<=s[1]<='9')) {
      //number: digits, dots, exponents (with sign), suffix letters
      while ('0'<=*s<='9' || *s=='.' || *s=='x' || *s=='X' ||
             'a'<=*s<='f' || 'A'<=*s<='F' || *s=='u' || *s=='U') {
        if ((*s=='e' || *s=='E') && (s[1]=='+' || s[1]=='-')) {
          HtPpBufPutCh(out,*s++);
          HtPpBufPutCh(out,*s++);
        } else
          HtPpBufPutCh(out,*s++);
      }
    } else
      HtPpBufPutCh(out,*s++);
  }
}

//--- #if expression evaluator ----------------------------------------------

class CHtPpEval
{
  CHtPp *pp;
  U8 *s;
};

extern I64 HtPpEvalTernary(CHtPpEval *ev);

U0 HtPpEvalWs(CHtPpEval *ev)
{
  while (*ev->s==' ' || *ev->s=='\t') ev->s++;
}

I64 HtPpEvalPrim(CHtPpEval *ev)
{
  I64 v=0;
  U8 *s;
  HtPpEvalWs(ev);
  s=ev->s;
  if (*s=='(') {
    ev->s=s+1;
    v=HtPpEvalTernary(ev);
    HtPpEvalWs(ev);
    if (*ev->s==')') ev->s++;
    else HtPpError(ev->pp,"expected ) in #if");
    return v;
  }
  if (*s=='!') {
    ev->s=s+1;
    return !HtPpEvalPrim(ev);
  }
  if (*s=='~') {
    ev->s=s+1;
    return ~HtPpEvalPrim(ev);
  }
  if (*s=='-') {
    ev->s=s+1;
    return -HtPpEvalPrim(ev);
  }
  if (*s=='+') {
    ev->s=s+1;
    return HtPpEvalPrim(ev);
  }
  if ('0'<=*s<='9') {
    if (*s=='0' && (s[1]=='x' || s[1]=='X')) {
      s+=2;
      while ('0'<=*s<='9' || 'a'<=*s<='f' || 'A'<=*s<='F') {
        v=v*16;
        if ('0'<=*s<='9') v+=*s-'0';
        else if ('a'<=*s<='f') v+=*s-'a'+10;
        else v+=*s-'A'+10;
        s++;
      }
    } else {
      while ('0'<=*s<='9') {
        v=v*10+*s-'0';
        s++;
      }
    }
    while (*s=='u' || *s=='U' || *s=='l' || *s=='L') s++;
    ev->s=s;
    return v;
  }
  if (HtPpIsIdent0(*s)) {			//undefined identifier -> 0
    while (HtPpIsIdent(*s)) s++;
    ev->s=s;
    return 0;
  }
  HtPpError(ev->pp,"bad #if expression");
  ev->s=s+1;
  return 0;
}

I64 HtPpEvalBin(CHtPpEval *ev,I64 min_prec)
{//Precedence climbing over C-precedence binary operators.
  I64 left=HtPpEvalPrim(ev),right,prec,v;
  U8 op0,op1;
  while (!*ev->pp->error) {
    HtPpEvalWs(ev);
    op0=ev->s[0];
    op1=ev->s[1];
    prec=0;
    if (op0=='|' && op1=='|') prec=1;
    else if (op0=='&' && op1=='&') prec=2;
    else if (op0=='|' && op1!='|') prec=3;
    else if (op0=='^') prec=4;
    else if (op0=='&' && op1!='&') prec=5;
    else if ((op0=='=' && op1=='=') || (op0=='!' && op1=='=')) prec=6;
    else if (op0=='<' || op0=='>') {
      if (op1==op0) prec=8;			//shift
      else prec=7;
    } else if (op0=='+' || op0=='-') prec=9;
    else if (op0=='*' || op0=='/' || op0=='%') prec=10;
    if (!prec || prec<min_prec) return left;
    if (prec==1 || prec==2 || prec==6 || prec==8 ||
        ((prec==7) && (op1=='='))) ev->s+=2;
    else ev->s++;
    right=HtPpEvalBin(ev,prec+1);
    v=0;
    if (prec==1) v=left || right;
    else if (prec==2) v=left && right;
    else if (prec==3) v=left|right;
    else if (prec==4) v=left^right;
    else if (prec==5) v=left&right;
    else if (prec==6) {
      if (op1=='=' && op0=='=') v=left==right;
      else v=left!=right;
    } else if (prec==7) {
      if (op0=='<') {
        if (op1=='=') v=left<=right;
        else v=left<right;
      } else {
        if (op1=='=') v=left>=right;
        else v=left>right;
      }
    } else if (prec==8) {
      if (op0=='<') v=left<<right;
      else v=left>>right;
    } else if (prec==9) {
      if (op0=='+') v=left+right;
      else v=left-right;
    } else {
      if (op0=='*') v=left*right;
      else if (op0=='/') {
        if (right) v=left/right;
        else HtPpError(ev->pp,"division by zero in #if");
      } else {
        if (right) v=left%right;
        else HtPpError(ev->pp,"division by zero in #if");
      }
    }
    left=v;
  }
  return left;
}

I64 HtPpEvalTernary(CHtPpEval *ev)
{
  I64 c=HtPpEvalBin(ev,1),a,b;
  HtPpEvalWs(ev);
  if (*ev->s=='?') {
    ev->s++;
    a=HtPpEvalTernary(ev);
    HtPpEvalWs(ev);
    if (*ev->s==':') ev->s++;
    else HtPpError(ev->pp,"expected : in #if");
    b=HtPpEvalTernary(ev);
    if (c) return a;
    return b;
  }
  return c;
}

I64 HtPpCond(CHtPp *pp,U8 *text)
{//Evaluate an #if/#elif expression: resolve defined(), macro-expand, eval.
  CHtPpBuf def,ex;
  CHtPpEval ev;
  U8 *s=text,name[HTPP_NAME_LEN];
  I64 i,v;
  Bool paren;
  HtPpBufInit(&def,StrLen(text)*2+16);
  while (*s) {
    if (HtPpIsIdent0(*s)) {
      i=0;
      while (HtPpIsIdent(*s) && i<HTPP_NAME_LEN-1) name[i++]=*s++;
      while (HtPpIsIdent(*s)) s++;
      name[i]=0;
      if (!StrCmp(name,"defined")) {
        while (*s==' ' || *s=='\t') s++;
        paren=FALSE;
        if (*s=='(') {
          paren=TRUE;
          s++;
          while (*s==' ' || *s=='\t') s++;
        }
        i=0;
        while (HtPpIsIdent(*s) && i<HTPP_NAME_LEN-1) name[i++]=*s++;
        name[i]=0;
        if (paren) {
          while (*s==' ' || *s=='\t') s++;
          if (*s==')') s++;
          else HtPpError(pp,"expected ) after defined(");
        }
        if (HtPpFind(pp,name)>=0)
          HtPpBufPut(&def," 1 ");
        else
          HtPpBufPut(&def," 0 ");
      } else
        HtPpBufPut(&def,name);
    } else
      HtPpBufPutCh(&def,*s++);
  }
  HtPpBufInit(&ex,def.len*2+16);
  HtPpExpandInto(pp,&ex,def.p,0);
  Free(def.p);
  ev.pp=pp;
  ev.s=ex.p;
  v=HtPpEvalTernary(&ev);
  Free(ex.p);
  return v;
}

//--- directives -------------------------------------------------------------

U0 HtPpDefine(CHtPp *pp,U8 *text)
{//text is everything after "#define".
  U8 *s=text,*b;
  CHtMacro *mac;
  I64 i,e;
  while (*s==' ' || *s=='\t') s++;
  if (!HtPpIsIdent0(*s)) {
    HtPpError(pp,"expected macro name");
    return;
  }
  if (pp->macro_count>=HTPP_MAX_MACROS) {
    HtPpError(pp,"too many macros");
    return;
  }
  mac=&pp->macro[pp->macro_count];
  MemSet(mac,0,sizeof(CHtMacro));
  i=0;
  while (HtPpIsIdent(*s) && i<HTPP_NAME_LEN-1) mac->name[i++]=*s++;
  while (HtPpIsIdent(*s)) s++;
  mac->name[i]=0;
  mac->n_params=-1;
  mac->param=MAlloc(HTPP_MAX_PARAMS*HTPP_NAME_LEN);
  if (*s=='(') {				//function-like: no space before (
    mac->n_params=0;
    s++;
    while (*s==' ' || *s=='\t') s++;
    if (*s==')')
      s++;
    else {
      while (TRUE) {
        while (*s==' ' || *s=='\t') s++;
        if (!HtPpIsIdent0(*s)) {
          HtPpError(pp,"expected macro parameter name");
          return;
        }
        if (mac->n_params>=HTPP_MAX_PARAMS) {
          HtPpError(pp,"too many macro parameters");
          return;
        }
        b=mac->param+mac->n_params*HTPP_NAME_LEN;
        i=0;
        while (HtPpIsIdent(*s) && i<HTPP_NAME_LEN-1) b[i++]=*s++;
        while (HtPpIsIdent(*s)) s++;
        b[i]=0;
        mac->n_params++;
        while (*s==' ' || *s=='\t') s++;
        if (*s==',') {
          s++;
        } else if (*s==')') {
          s++;
          break;
        } else {
          HtPpError(pp,"expected , or ) in macro parameters");
          return;
        }
      }
    }
  }
  while (*s==' ' || *s=='\t') s++;
  e=StrLen(s);
  while (e>0 && (s[e-1]==' ' || s[e-1]=='\t')) e--;
  mac->body=MAlloc(e+1);
  MemCpy(mac->body,s,e);
  mac->body[e]=0;
  pp->macro_count++;
}

U8 *HtPreprocess(U8 *src,U8 *err_out)
{//Returns a MAlloc'ed preprocessed copy with identical line count, or NULL
 //with err_out (>=160 bytes) filled.
  CHtPp pp;
  CHtPpBuf out;
  U8 *clean,*s,*line,*d,name[HTPP_NAME_LEN];
  I64 n,i,joined,depth;
  I64 cond_active[HTPP_MAX_COND];	//this level's lines emitted?
  I64 cond_taken[HTPP_MAX_COND];	//any branch taken yet at this level?
  I64 cond_else[HTPP_MAX_COND];		//#else seen at this level?
  I64 cond_top=0;			//stack top; level 0 = always active
  Bool active,neg;
  MemSet(&pp,0,sizeof(CHtPp));
  pp.macro=CAlloc(HTPP_MAX_MACROS*sizeof(CHtMacro));
  pp.line=0;
  cond_active[0]=TRUE;
  cond_taken[0]=TRUE;
  cond_else[0]=FALSE;
  clean=HtPpStripComments(src);
  n=StrLen(clean);
  line=MAlloc(n+2);
  HtPpBufInit(&out,n+n/2+64);
  s=clean;
  while (*s && !*pp.error) {
    //Collect one logical line (join backslash continuations).
    d=line;
    joined=0;
    pp.line++;
    while (*s && *s!='\n') {
      if (*s=='\\') {
        //peek: backslash-newline (possibly with trailing spaces) joins
        i=1;
        while (s[i]==' ' || s[i]=='\t') i++;
        if (s[i]=='\n') {
          s+=i+1;
          joined++;
          pp.line++;
          *d++=' ';
        } else
          *d++=*s++;
      } else
        *d++=*s++;
    }
    if (*s=='\n') s++;
    *d=0;
    //Classify.
    d=line;
    while (*d==' ' || *d=='\t') d++;
    active=cond_active[cond_top];
    if (*d=='#') {
      d++;
      while (*d==' ' || *d=='\t') d++;
      i=0;
      while (HtPpIsIdent(*d) && i<HTPP_NAME_LEN-1) name[i++]=*d++;
      name[i]=0;
      if (!StrCmp(name,"define")) {
        if (active) HtPpDefine(&pp,d);
      } else if (!StrCmp(name,"undef")) {
        if (active) {
          while (*d==' ' || *d=='\t') d++;
          i=0;
          while (HtPpIsIdent(*d) && i<HTPP_NAME_LEN-1) name[i++]=*d++;
          name[i]=0;
          HtPpUndef(&pp,name);
        }
      } else if (!StrCmp(name,"if") || !StrCmp(name,"ifdef") ||
                 !StrCmp(name,"ifndef")) {
        if (cond_top>=HTPP_MAX_COND-1) {
          HtPpError(&pp,"conditional nesting too deep");
        } else {
          cond_top++;
          cond_else[cond_top]=FALSE;
          if (!active) {
            cond_active[cond_top]=FALSE;
            cond_taken[cond_top]=TRUE;	//parent dead: never take anything
          } else if (name[2]==0) {	//"if"
            cond_active[cond_top]=HtPpCond(&pp,d)!=0;
            cond_taken[cond_top]=cond_active[cond_top];
          } else {
            neg=name[2]=='n';		//"ifndef" vs "ifdef"
            while (*d==' ' || *d=='\t') d++;
            i=0;
            while (HtPpIsIdent(*d) && i<HTPP_NAME_LEN-1) name[i++]=*d++;
            name[i]=0;
            cond_active[cond_top]=HtPpFind(&pp,name)>=0;
            if (neg) cond_active[cond_top]=!cond_active[cond_top];
            cond_taken[cond_top]=cond_active[cond_top];
          }
        }
      } else if (!StrCmp(name,"elif")) {
        if (!cond_top || cond_else[cond_top])
          HtPpError(&pp,"#elif without #if");
        else if (cond_taken[cond_top])
          cond_active[cond_top]=FALSE;
        else {
          cond_active[cond_top]=HtPpCond(&pp,d)!=0;
          if (cond_active[cond_top]) cond_taken[cond_top]=TRUE;
        }
      } else if (!StrCmp(name,"else")) {
        if (!cond_top || cond_else[cond_top])
          HtPpError(&pp,"#else without #if");
        else {
          cond_else[cond_top]=TRUE;
          cond_active[cond_top]=!cond_taken[cond_top];
          cond_taken[cond_top]=TRUE;
        }
      } else if (!StrCmp(name,"endif")) {
        if (!cond_top)
          HtPpError(&pp,"#endif without #if");
        else
          cond_top--;
      } else if (!StrCmp(name,"version") || !StrCmp(name,"extension") ||
                 !StrCmp(name,"pragma") || !StrCmp(name,"line")) {
        //ignored; Shadertoy sources occasionally carry these
      } else if (!name[0]) {
        //bare '#': legal null directive
      } else
        HtPpError(&pp,"unknown preprocessor directive");
      HtPpBufPutCh(&out,'\n');
    } else if (!active) {
      HtPpBufPutCh(&out,'\n');
    } else {
      HtPpExpandInto(&pp,&out,line,0);
      HtPpBufPutCh(&out,'\n');
    }
    //Preserve the newlines swallowed by continuations.
    for (i=0;i<joined;i++) HtPpBufPutCh(&out,'\n');
  }
  if (!*pp.error && cond_top)
    HtPpError(&pp,"missing #endif");
  Free(line);
  Free(clean);
  if (*pp.error) {
    StrCpy(err_out,pp.error);
    Free(out.p);
    HtPpDel(&pp);
    return NULL;
  }
  HtPpDel(&pp);
  return out.p;
}
