//HolyToy guest GLSL parser -- full-grammar AST for the corpus-v1 language
//slice: expressions with ternary/assignment/comma, swizzles and indexing,
//declarations (const, arrays, multiple declarators), structs, functions
//with in/out/inout parameters, and all control flow. The AST is one
//CAlloc'ed node array owned by CHtProgram.

//--- packed type encoding ---------------------------------------------------
//kind (low byte) | struct id << 8 | array count << 16 (0 = scalar of kind)

#define HTT_NONE	0
#define HTT_VOID	1
#define HTT_BOOL	2
#define HTT_INT		3
#define HTT_UINT	4
#define HTT_FLOAT	5
#define HTT_VEC2	6
#define HTT_VEC3	7
#define HTT_VEC4	8
#define HTT_IVEC2	9
#define HTT_IVEC3	10
#define HTT_IVEC4	11
#define HTT_UVEC2	12
#define HTT_UVEC3	13
#define HTT_UVEC4	14
#define HTT_BVEC2	15
#define HTT_BVEC3	16
#define HTT_BVEC4	17
#define HTT_MAT2	18
#define HTT_MAT3	19
#define HTT_MAT4	20
#define HTT_STRUCT	21

#define HT_MAX_STRUCTS	32

I64 HtTKind(I64 t)   { return t&0xFF; }
I64 HtTStruct(I64 t) { return (t>>8)&0xFF; }
I64 HtTArr(I64 t)    { return t>>16; }
I64 HtTMk(I64 kind,I64 sid,I64 arr) { return kind|(sid<<8)|(arr<<16); }
I64 HtTElem(I64 t)   { return t&0xFFFF; }	//array type -> element type

//--- AST node kinds ----------------------------------------------------------

#define HT_AST_NUMBER		1
#define HT_AST_NAME		2
#define HT_AST_BINARY		3
#define HT_AST_UNARY		4
#define HT_AST_CALL		5
#define HT_AST_MEMBER		6
#define HT_AST_INDEX		7
#define HT_AST_TERNARY		8
#define HT_AST_ASSIGN		9
#define HT_AST_PREINC		10
#define HT_AST_POSTINC		11
#define HT_AST_DECL		12
#define HT_AST_EXPR_STMT	13
#define HT_AST_BLOCK		14
#define HT_AST_IF		15
#define HT_AST_FOR		16
#define HT_AST_WHILE		17
#define HT_AST_DO		18
#define HT_AST_BREAK		19
#define HT_AST_CONTINUE		20
#define HT_AST_RETURN		21
#define HT_AST_EMPTY		22
#define HT_AST_FUNC		23
#define HT_AST_PARAM		24
#define HT_AST_STRUCT		25
#define HT_AST_SEQ		26
#define HT_AST_ARRCTOR		27

//--- flags -------------------------------------------------------------------

#define HTF_CONST	1
#define HTF_IN		2
#define HTF_OUT		4

class CHtAst
{
  I64 kind,tok,a,b,c,d,next,type,bind,flags;
};

extern class CHtSym;

class CHtProgram
{
  CHtLexer *lex;
  I64 pos,node_count,node_cap,root;
  I64 struct_tok[HT_MAX_STRUCTS];	//struct name tokens (parse time)
  I64 struct_node[HT_MAX_STRUCTS];
  I64 struct_count;
  I64 main_node;			//mainImage FUNC node (sema)
  CHtAst *node;
  CHtSym *sym;				//sema-owned symbol storage
  I64 sym_count,sym_cap;
  U8 error[160];
};

U0 HtProgramDel(CHtProgram *p)
{
  Free(p->node);
  p->node=NULL;
  p->node_count=0;
  p->node_cap=0;
  Free(p->sym);
  p->sym=NULL;
  p->sym_count=0;
}

U0 HtParseError(CHtProgram *p,I64 tok,U8 *msg)
{
  CHtToken *t;
  if (*p->error) return;
  if (tok<0 || tok>=p->lex->count) tok=p->pos;
  if (tok>=p->lex->count) tok=p->lex->count-1;
  t=&p->lex->tok[tok];
  StrPrint(p->error,"line %d:%d: %s",t->line,t->col,msg);
}

Bool HtTake(CHtProgram *p,U8 *s)
{
  if (HtTokEq(p->lex,p->pos,s)) {
    p->pos++;
    return TRUE;
  }
  return FALSE;
}

Bool HtNeed(CHtProgram *p,U8 *s)
{
  U8 *msg;
  if (HtTake(p,s)) return TRUE;
  msg=MStrPrint("expected '%s'",s);
  HtParseError(p,p->pos,msg);
  Free(msg);
  return FALSE;
}

I64 HtNode(CHtProgram *p,I64 kind,I64 tok)
{
  I64 i;
  CHtAst *n;
  if (p->node_count>=p->node_cap) {
    HtParseError(p,tok,"internal AST capacity");
    return -1;
  }
  i=p->node_count++;
  n=&p->node[i];
  MemSet(n,0,sizeof(CHtAst));
  n->kind=kind;
  n->tok=tok;
  n->a=-1;
  n->b=-1;
  n->c=-1;
  n->d=-1;
  n->next=-1;
  return i;
}

//--- type name recognition ---------------------------------------------------

I64 HtStructByTok(CHtProgram *p,I64 tok)
{
  I64 i;
  for (i=0;i<p->struct_count;i++)
    if (HtTokSame(p->lex,p->struct_tok[i],tok)) return i;
  return -1;
}

I64 HtTypeAt(CHtProgram *p,I64 tok)
{//Packed base type named by token tok, or HTT_NONE.
  I64 s;
  CHtLexer *l=p->lex;
  if (tok>=l->count || l->tok[tok].kind!=HT_TOK_IDENT) return HTT_NONE;
  if (HtTokEq(l,tok,"float")) return HTT_FLOAT;
  if (HtTokEq(l,tok,"int")) return HTT_INT;
  if (HtTokEq(l,tok,"uint")) return HTT_UINT;
  if (HtTokEq(l,tok,"bool")) return HTT_BOOL;
  if (HtTokEq(l,tok,"void")) return HTT_VOID;
  if (HtTokEq(l,tok,"vec2")) return HTT_VEC2;
  if (HtTokEq(l,tok,"vec3")) return HTT_VEC3;
  if (HtTokEq(l,tok,"vec4")) return HTT_VEC4;
  if (HtTokEq(l,tok,"ivec2")) return HTT_IVEC2;
  if (HtTokEq(l,tok,"ivec3")) return HTT_IVEC3;
  if (HtTokEq(l,tok,"ivec4")) return HTT_IVEC4;
  if (HtTokEq(l,tok,"uvec2")) return HTT_UVEC2;
  if (HtTokEq(l,tok,"uvec3")) return HTT_UVEC3;
  if (HtTokEq(l,tok,"uvec4")) return HTT_UVEC4;
  if (HtTokEq(l,tok,"bvec2")) return HTT_BVEC2;
  if (HtTokEq(l,tok,"bvec3")) return HTT_BVEC3;
  if (HtTokEq(l,tok,"bvec4")) return HTT_BVEC4;
  if (HtTokEq(l,tok,"mat2")) return HTT_MAT2;
  if (HtTokEq(l,tok,"mat3")) return HTT_MAT3;
  if (HtTokEq(l,tok,"mat4")) return HTT_MAT4;
  s=HtStructByTok(p,tok);
  if (s>=0) return HtTMk(HTT_STRUCT,s,0);
  return HTT_NONE;
}

U0 HtSkipPrecision(CHtProgram *p)
{
  if (HtTokEq(p->lex,p->pos,"highp") || HtTokEq(p->lex,p->pos,"mediump") ||
      HtTokEq(p->lex,p->pos,"lowp"))
    p->pos++;
}

Bool HtIsKeywordTok(CHtProgram *p,I64 tok)
{//Statement/declaration keywords that can never be expression names.
  CHtLexer *l=p->lex;
  return HtTokEq(l,tok,"if") || HtTokEq(l,tok,"else") ||
         HtTokEq(l,tok,"for") || HtTokEq(l,tok,"while") ||
         HtTokEq(l,tok,"do") || HtTokEq(l,tok,"return") ||
         HtTokEq(l,tok,"break") || HtTokEq(l,tok,"continue") ||
         HtTokEq(l,tok,"const") || HtTokEq(l,tok,"struct");
}

//--- expressions --------------------------------------------------------------

extern I64 HtParseAssign(CHtProgram *p);
extern I64 HtParseExpr(CHtProgram *p);

I64 HtPrec(CHtProgram *p,I64 tok)
{//GLSL binary operator precedence (higher binds tighter).
  CHtLexer *l=p->lex;
  if (l->tok[tok].kind!=HT_TOK_OP) return 0;
  //compound assignment is NOT a binary op
  if (HtTokEq(l,tok,"||")) return 1;
  if (HtTokEq(l,tok,"^^")) return 2;
  if (HtTokEq(l,tok,"&&")) return 3;
  if (HtTokEq(l,tok,"|")) return 4;
  if (HtTokEq(l,tok,"^")) return 5;
  if (HtTokEq(l,tok,"&")) return 6;
  if (HtTokEq(l,tok,"==") || HtTokEq(l,tok,"!=")) return 7;
  if (HtTokEq(l,tok,"<") || HtTokEq(l,tok,">") ||
      HtTokEq(l,tok,"<=") || HtTokEq(l,tok,">=")) return 8;
  if (HtTokEq(l,tok,"<<") || HtTokEq(l,tok,">>")) return 9;
  if (HtTokEq(l,tok,"+") || HtTokEq(l,tok,"-")) return 10;
  if (HtTokEq(l,tok,"*") || HtTokEq(l,tok,"/") || HtTokEq(l,tok,"%"))
    return 11;
  return 0;
}

Bool HtIsAssignOp(CHtProgram *p,I64 tok)
{
  CHtLexer *l=p->lex;
  if (l->tok[tok].kind!=HT_TOK_OP) return FALSE;
  return HtTokEq(l,tok,"=") || HtTokEq(l,tok,"+=") || HtTokEq(l,tok,"-=") ||
         HtTokEq(l,tok,"*=") || HtTokEq(l,tok,"/=") || HtTokEq(l,tok,"%=") ||
         HtTokEq(l,tok,"&=") || HtTokEq(l,tok,"|=") || HtTokEq(l,tok,"^=") ||
         HtTokEq(l,tok,"<<=") || HtTokEq(l,tok,">>=");
}

I64 HtParseArgs(CHtProgram *p)
{//'(' already eaten; returns first arg node (chained by next) or -1.
  I64 first=-1,last=-1,arg;
  if (HtTake(p,")")) return -1;
  while (!*p->error) {
    arg=HtParseAssign(p);
    if (arg<0) return -1;
    if (first<0) first=arg;
    else p->node[last].next=arg;
    last=arg;
    if (HtTake(p,")")) break;
    if (!HtNeed(p,",")) return -1;
  }
  return first;
}

I64 HtParsePrimary(CHtProgram *p)
{
  I64 t=p->pos,n,ty,size=-1;
  CHtLexer *l=p->lex;
  if (HtTake(p,"(")) {
    n=HtParseExpr(p);
    HtNeed(p,")");
    return n;
  }
  if (l->tok[t].kind==HT_TOK_NUMBER) {
    p->pos++;
    return HtNode(p,HT_AST_NUMBER,t);
  }
  if (l->tok[t].kind==HT_TOK_IDENT) {
    ty=HtTypeAt(p,t);
    if (ty!=HTT_NONE && HtTokEq(l,t+1,"[")) {
      //array constructor: type '[' [size] ']' '(' args ')'
      p->pos+=2;
      if (!HtTake(p,"]")) {
        size=HtParseAssign(p);
        if (!HtNeed(p,"]")) return -1;
      }
      if (!HtNeed(p,"(")) return -1;
      n=HtNode(p,HT_AST_ARRCTOR,t);
      if (n<0) return -1;
      p->node[n].type=ty;
      p->node[n].b=HtParseArgs(p);
      p->node[n].d=size;
      return n;
    }
    p->pos++;
    return HtNode(p,HT_AST_NAME,t);
  }
  HtParseError(p,t,"expected expression");
  return -1;
}

I64 HtParsePostfix(CHtProgram *p)
{
  I64 left=HtParsePrimary(p),n,t;
  CHtLexer *l=p->lex;
  while (left>=0 && !*p->error) {
    t=p->pos;
    if (HtTake(p,"(")) {
      n=HtNode(p,HT_AST_CALL,t);
      if (n<0) return -1;
      p->node[n].a=left;
      p->node[n].b=HtParseArgs(p);
      left=n;
    } else if (HtTake(p,"[")) {
      n=HtNode(p,HT_AST_INDEX,t);
      if (n<0) return -1;
      p->node[n].a=left;
      p->node[n].b=HtParseExpr(p);
      HtNeed(p,"]");
      left=n;
    } else if (HtTake(p,".")) {
      t=p->pos;
      if (l->tok[t].kind!=HT_TOK_IDENT) {
        HtParseError(p,t,"expected member name");
        return -1;
      }
      p->pos++;
      n=HtNode(p,HT_AST_MEMBER,t);
      if (n<0) return -1;
      p->node[n].a=left;
      left=n;
    } else if (HtTokEq(l,t,"++") || HtTokEq(l,t,"--")) {
      p->pos++;
      n=HtNode(p,HT_AST_POSTINC,t);
      if (n<0) return -1;
      p->node[n].a=left;
      left=n;
    } else
      break;
  }
  return left;
}

I64 HtParseUnary(CHtProgram *p)
{
  I64 t=p->pos,n;
  CHtLexer *l=p->lex;
  if (HtTokEq(l,t,"!") || HtTokEq(l,t,"~") ||
      HtTokEq(l,t,"+") || HtTokEq(l,t,"-")) {
    p->pos++;
    n=HtNode(p,HT_AST_UNARY,t);
    if (n<0) return -1;
    p->node[n].a=HtParseUnary(p);
    return n;
  }
  if (HtTokEq(l,t,"++") || HtTokEq(l,t,"--")) {
    p->pos++;
    n=HtNode(p,HT_AST_PREINC,t);
    if (n<0) return -1;
    p->node[n].a=HtParseUnary(p);
    return n;
  }
  return HtParsePostfix(p);
}

I64 HtParseBin(CHtProgram *p,I64 min_prec)
{
  I64 left=HtParseUnary(p),op,prec,right,n;
  while (left>=0 && !*p->error) {
    op=p->pos;
    prec=HtPrec(p,op);
    if (!prec || prec<min_prec) break;
    if (HtIsAssignOp(p,op)) break;
    p->pos++;
    right=HtParseBin(p,prec+1);
    if (right<0) return -1;
    n=HtNode(p,HT_AST_BINARY,op);
    if (n<0) return -1;
    p->node[n].a=left;
    p->node[n].b=right;
    left=n;
  }
  return left;
}

I64 HtParseTernary(CHtProgram *p)
{
  I64 c=HtParseBin(p,1),n;
  if (c<0 || *p->error) return c;
  if (HtTake(p,"?")) {
    n=HtNode(p,HT_AST_TERNARY,p->pos-1);
    if (n<0) return -1;
    p->node[n].a=c;
    p->node[n].b=HtParseExpr(p);
    if (!HtNeed(p,":")) return -1;
    p->node[n].c=HtParseAssign(p);
    return n;
  }
  return c;
}

I64 HtParseAssign(CHtProgram *p)
{
  I64 left=HtParseTernary(p),n,op;
  if (left<0 || *p->error) return left;
  op=p->pos;
  if (HtIsAssignOp(p,op)) {
    p->pos++;
    n=HtNode(p,HT_AST_ASSIGN,op);
    if (n<0) return -1;
    p->node[n].a=left;
    p->node[n].b=HtParseAssign(p);
    return n;
  }
  return left;
}

I64 HtParseExpr(CHtProgram *p)
{//full expression: assignment (',' assignment)*
  I64 left=HtParseAssign(p),n;
  while (left>=0 && !*p->error && HtTokEq(p->lex,p->pos,",")) {
    p->pos++;
    n=HtNode(p,HT_AST_SEQ,p->pos-1);
    if (n<0) return -1;
    p->node[n].a=left;
    p->node[n].b=HtParseAssign(p);
    left=n;
  }
  return left;
}

//--- declarations and statements ----------------------------------------------

I64 HtParseDeclarators(CHtProgram *p,I64 base,I64 flags,I64 arr_pre)
{//After base type: name[arr][=init][,name...]';'. arr_pre carries a
 //type-prefix array suffix (`int[5] a` / `int[] c`): -1 none, -2 unsized,
 //else a size-expression node. Returns first DECL node.
  I64 first=-1,last=-1,name,d;
  while (!*p->error) {
    name=p->pos;
    if (p->lex->tok[name].kind!=HT_TOK_IDENT) {
      HtParseError(p,name,"expected variable name");
      return -1;
    }
    p->pos++;
    d=HtNode(p,HT_AST_DECL,name);
    if (d<0) return -1;
    p->node[d].type=base;
    p->node[d].flags=flags;
    if (HtTake(p,"[")) {
      if (HtTake(p,"]"))
        p->node[d].b=-2;		//unsized: infer from initializer
      else {
        p->node[d].b=HtParseAssign(p);
        if (!HtNeed(p,"]")) return -1;
      }
    } else if (arr_pre!=-1)
      p->node[d].b=arr_pre;
    if (HtTake(p,"="))
      p->node[d].a=HtParseAssign(p);
    if (first<0) first=d;
    else p->node[last].next=d;
    last=d;
    if (HtTake(p,",")) {
    } else {
      if (!HtNeed(p,";")) return -1;
      break;
    }
  }
  return first;
}

Bool HtDeclAhead(CHtProgram *p)
{//Is a declaration starting at p->pos? (const/precision/type followed by
 //a name, or a type-prefix array like `int[] c`)
  I64 i=p->pos,depth;
  if (HtTokEq(p->lex,i,"const")) return TRUE;
  if (HtTokEq(p->lex,i,"highp") || HtTokEq(p->lex,i,"mediump") ||
      HtTokEq(p->lex,i,"lowp")) i++;
  if (HtTypeAt(p,i)==HTT_NONE) return FALSE;
  if (HtTokEq(p->lex,i+1,"[")) {
    //skip the balanced bracket suffix; a name means declaration,
    //a '(' means an array-constructor expression
    depth=0;
    i++;
    while (i<p->lex->count && p->lex->tok[i].kind!=HT_TOK_EOF) {
      if (HtTokEq(p->lex,i,"[")) depth++;
      else if (HtTokEq(p->lex,i,"]")) {
        depth--;
        if (!depth) break;
      }
      i++;
    }
    return p->lex->tok[i+1].kind==HT_TOK_IDENT &&
           HtTypeAt(p,i+1)==HTT_NONE && !HtIsKeywordTok(p,i+1);
  }
  return p->lex->tok[i+1].kind==HT_TOK_IDENT &&
         HtTypeAt(p,i+1)==HTT_NONE && !HtIsKeywordTok(p,i+1);
}

extern I64 HtParseStmt(CHtProgram *p);

I64 HtParseBlock(CHtProgram *p)
{
  I64 block,first=-1,last=-1,stmt;
  if (!HtNeed(p,"{")) return -1;
  block=HtNode(p,HT_AST_BLOCK,p->pos-1);
  while (!*p->error && !HtTake(p,"}")) {
    if (p->lex->tok[p->pos].kind==HT_TOK_EOF) {
      HtParseError(p,p->pos,"expected '}'");
      break;
    }
    stmt=HtParseStmt(p);
    if (stmt<0) break;
    if (first<0) first=stmt;
    else p->node[last].next=stmt;
    //declarator chains: advance to the chain tail
    while (p->node[stmt].next>=0) stmt=p->node[stmt].next;
    last=stmt;
  }
  if (block>=0) p->node[block].a=first;
  return block;
}

I64 HtParseTypeArraySuffix(CHtProgram *p)
{//optional `[size]`/`[]` right after a type name; -1 none, -2 unsized,
 //else size-expression node
  I64 arr_pre=-1;
  if (HtTake(p,"[")) {
    if (HtTake(p,"]"))
      arr_pre=-2;
    else {
      arr_pre=HtParseAssign(p);
      HtNeed(p,"]");
    }
  }
  return arr_pre;
}

I64 HtParseDeclStmt(CHtProgram *p)
{
  I64 flags=0,base,arr_pre;
  while (TRUE) {
    if (HtTake(p,"const")) flags|=HTF_CONST;
    else if (HtTokEq(p->lex,p->pos,"highp") ||
             HtTokEq(p->lex,p->pos,"mediump") ||
             HtTokEq(p->lex,p->pos,"lowp")) p->pos++;
    else break;
  }
  base=HtTypeAt(p,p->pos);
  if (base==HTT_NONE) {
    HtParseError(p,p->pos,"expected type");
    return -1;
  }
  p->pos++;
  arr_pre=HtParseTypeArraySuffix(p);
  return HtParseDeclarators(p,base,flags,arr_pre);
}

I64 HtParseStmt(CHtProgram *p)
{
  I64 n,t=p->pos;
  CHtLexer *l=p->lex;
  if (HtTokEq(l,t,"{"))
    return HtParseBlock(p);
  if (HtTake(p,"if")) {
    n=HtNode(p,HT_AST_IF,t);
    if (n<0) return -1;
    if (!HtNeed(p,"(")) return -1;
    p->node[n].a=HtParseExpr(p);
    if (!HtNeed(p,")")) return -1;
    p->node[n].b=HtParseStmt(p);
    if (HtTake(p,"else"))
      p->node[n].c=HtParseStmt(p);
    return n;
  }
  if (HtTake(p,"for")) {
    n=HtNode(p,HT_AST_FOR,t);
    if (n<0) return -1;
    if (!HtNeed(p,"(")) return -1;
    if (HtTake(p,";"))
      p->node[n].a=HtNode(p,HT_AST_EMPTY,t);
    else if (HtDeclAhead(p))
      p->node[n].a=HtParseDeclStmt(p);
    else {
      p->node[n].a=HtParseExpr(p);
      if (p->node[n].a>=0) {
        I64 w=HtNode(p,HT_AST_EXPR_STMT,t);
        if (w<0) return -1;
        p->node[w].a=p->node[n].a;
        p->node[n].a=w;
      }
      if (!HtNeed(p,";")) return -1;
    }
    if (!HtTokEq(l,p->pos,";"))
      p->node[n].b=HtParseExpr(p);
    if (!HtNeed(p,";")) return -1;
    if (!HtTokEq(l,p->pos,")"))
      p->node[n].c=HtParseExpr(p);
    if (!HtNeed(p,")")) return -1;
    p->node[n].d=HtParseStmt(p);
    return n;
  }
  if (HtTake(p,"while")) {
    n=HtNode(p,HT_AST_WHILE,t);
    if (n<0) return -1;
    if (!HtNeed(p,"(")) return -1;
    p->node[n].a=HtParseExpr(p);
    if (!HtNeed(p,")")) return -1;
    p->node[n].b=HtParseStmt(p);
    return n;
  }
  if (HtTake(p,"do")) {
    n=HtNode(p,HT_AST_DO,t);
    if (n<0) return -1;
    p->node[n].a=HtParseStmt(p);
    if (!HtNeed(p,"while")) return -1;
    if (!HtNeed(p,"(")) return -1;
    p->node[n].b=HtParseExpr(p);
    if (!HtNeed(p,")")) return -1;
    if (!HtNeed(p,";")) return -1;
    return n;
  }
  if (HtTake(p,"return")) {
    n=HtNode(p,HT_AST_RETURN,t);
    if (n<0) return -1;
    if (!HtTake(p,";")) {
      p->node[n].a=HtParseExpr(p);
      if (!HtNeed(p,";")) return -1;
    }
    return n;
  }
  if (HtTake(p,"break")) {
    n=HtNode(p,HT_AST_BREAK,t);
    HtNeed(p,";");
    return n;
  }
  if (HtTake(p,"continue")) {
    n=HtNode(p,HT_AST_CONTINUE,t);
    HtNeed(p,";");
    return n;
  }
  if (HtTake(p,";"))
    return HtNode(p,HT_AST_EMPTY,t);
  if (HtTokEq(l,t,"struct")) {
    HtParseError(p,t,"local struct not supported");
    return -1;
  }
  if (HtDeclAhead(p))
    return HtParseDeclStmt(p);
  n=HtNode(p,HT_AST_EXPR_STMT,t);
  if (n<0) return -1;
  p->node[n].a=HtParseExpr(p);
  if (p->node[n].a<0) return -1;
  if (!HtNeed(p,";")) return -1;
  return n;
}

//--- top level -----------------------------------------------------------------

I64 HtParseStructDef(CHtProgram *p)
{//'struct' eaten. struct Name { members };
  I64 name=p->pos,n,first=-1,last=-1,base,d,mname;
  if (p->lex->tok[name].kind!=HT_TOK_IDENT) {
    HtParseError(p,name,"expected struct name");
    return -1;
  }
  p->pos++;
  n=HtNode(p,HT_AST_STRUCT,name);
  if (n<0) return -1;
  if (p->struct_count>=HT_MAX_STRUCTS) {
    HtParseError(p,name,"too many structs");
    return -1;
  }
  p->struct_tok[p->struct_count]=name;
  p->struct_node[p->struct_count]=n;
  p->node[n].c=p->struct_count;		//struct id
  p->struct_count++;
  if (!HtNeed(p,"{")) return -1;
  while (!*p->error && !HtTake(p,"}")) {
    if (p->lex->tok[p->pos].kind==HT_TOK_EOF) {
      HtParseError(p,p->pos,"expected '}' in struct");
      return -1;
    }
    HtSkipPrecision(p);
    base=HtTypeAt(p,p->pos);
    if (base==HTT_NONE) {
      HtParseError(p,p->pos,"expected member type");
      return -1;
    }
    p->pos++;
    while (!*p->error) {
      mname=p->pos;
      if (p->lex->tok[mname].kind!=HT_TOK_IDENT) {
        HtParseError(p,mname,"expected member name");
        return -1;
      }
      p->pos++;
      d=HtNode(p,HT_AST_DECL,mname);
      if (d<0) return -1;
      p->node[d].type=base;
      if (HtTake(p,"[")) {
        p->node[d].b=HtParseAssign(p);
        if (!HtNeed(p,"]")) return -1;
      }
      if (first<0) first=d;
      else p->node[last].next=d;
      last=d;
      if (HtTake(p,",")) {
      } else {
        if (!HtNeed(p,";")) return -1;
        break;
      }
    }
  }
  p->node[n].a=first;
  //optional trailing declarator list is not supported: require ';'
  if (!HtNeed(p,";")) return -1;
  return n;
}

I64 HtParseParams(CHtProgram *p)
{//'(' eaten; PARAM chain or -1. Accepts 'void' and unnamed parameters.
  I64 first=-1,last=-1,n,flags,base,name,arr_pre;
  if (HtTake(p,")")) return -1;
  if (HtTokEq(p->lex,p->pos,"void") && HtTokEq(p->lex,p->pos+1,")")) {
    p->pos+=2;
    return -1;
  }
  while (!*p->error) {
    flags=0;
    while (TRUE) {
      if (HtTake(p,"const")) flags|=HTF_CONST;
      else if (HtTake(p,"in")) flags|=HTF_IN;
      else if (HtTake(p,"out")) flags|=HTF_OUT;
      else if (HtTake(p,"inout")) flags|=HTF_IN|HTF_OUT;
      else if (HtTokEq(p->lex,p->pos,"highp") ||
               HtTokEq(p->lex,p->pos,"mediump") ||
               HtTokEq(p->lex,p->pos,"lowp")) p->pos++;
      else break;
    }
    if (!(flags&(HTF_IN|HTF_OUT))) flags|=HTF_IN;
    base=HtTypeAt(p,p->pos);
    if (base==HTT_NONE) {
      HtParseError(p,p->pos,"expected parameter type");
      return -1;
    }
    p->pos++;
    //type-prefix array (`vec2[N] v`), same encoding as declarations
    arr_pre=HtParseTypeArraySuffix(p);
    name=-1;
    if (p->lex->tok[p->pos].kind==HT_TOK_IDENT &&
        HtTypeAt(p,p->pos)==HTT_NONE) {
      name=p->pos;
      p->pos++;
    }
    n=HtNode(p,HT_AST_PARAM,name);
    if (n<0) return -1;
    p->node[n].type=base;
    p->node[n].flags=flags;
    if (HtTake(p,"[")) {
      p->node[n].b=HtParseAssign(p);
      if (!HtNeed(p,"]")) return -1;
    } else if (arr_pre!=-1) {
      if (arr_pre==-2) {
        HtParseError(p,p->pos,"array parameter needs a size");
        return -1;
      }
      p->node[n].b=arr_pre;
    }
    if (first<0) first=n;
    else p->node[last].next=n;
    last=n;
    if (HtTake(p,")")) break;
    if (!HtNeed(p,",")) return -1;
  }
  return first;
}

Bool HtParse(CHtProgram *p,CHtLexer *l)
{
  I64 first=-1,last=-1,n,flags,base,name,tail,arr_pre;
  MemSet(p,0,sizeof(CHtProgram));
  p->lex=l;
  p->root=-1;
  p->node_cap=l->count*2+64;
  p->node=CAlloc(p->node_cap*sizeof(CHtAst));
  while (!*p->error && l->tok[p->pos].kind!=HT_TOK_EOF) {
    if (HtTake(p,";")) goto parse_next;
    if (HtTokEq(l,p->pos,"precision")) {
      while (l->tok[p->pos].kind!=HT_TOK_EOF && !HtTake(p,";")) p->pos++;
      goto parse_next;
    }
    if (HtTake(p,"struct")) {
      n=HtParseStructDef(p);
    } else {
      flags=0;
      while (TRUE) {
        if (HtTake(p,"const")) flags|=HTF_CONST;
        else if (HtTokEq(l,p->pos,"highp") || HtTokEq(l,p->pos,"mediump") ||
                 HtTokEq(l,p->pos,"lowp") || HtTokEq(l,p->pos,"uniform"))
          p->pos++;
        else break;
      }
      base=HtTypeAt(p,p->pos);
      if (base==HTT_NONE) {
        HtParseError(p,p->pos,"expected declaration");
        break;
      }
      p->pos++;
      arr_pre=HtParseTypeArraySuffix(p);
      if (*p->error) break;
      name=p->pos;
      if (l->tok[name].kind!=HT_TOK_IDENT) {
        HtParseError(p,name,"expected name");
        break;
      }
      if (arr_pre==-1 && HtTokEq(l,name+1,"(")) {
        p->pos+=2;
        n=HtNode(p,HT_AST_FUNC,name);
        if (n<0) break;
        p->node[n].type=base;
        p->node[n].flags=flags;
        p->node[n].a=HtParseParams(p);
        if (*p->error) break;
        if (HtTake(p,";")) {
          p->node[n].b=-1;		//prototype
        } else {
          p->node[n].b=HtParseBlock(p);
        }
      } else
        n=HtParseDeclarators(p,base,flags,arr_pre);
    }
    if (n<0 || *p->error) break;
    if (first<0) first=n;
    else p->node[last].next=n;
    tail=n;
    while (p->node[tail].next>=0) tail=p->node[tail].next;
    last=tail;
parse_next:;
  }
  p->root=first;
  if (!*p->error && l->tok[p->pos].kind!=HT_TOK_EOF)
    HtParseError(p,p->pos,"expected end of file");
  if (!*p->error && first<0)
    HtParseError(p,0,"empty program");
  return !*p->error;
}
