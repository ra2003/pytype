%defines  // Creates a .h file.

// Prefix is not needed since we are including the whole parser within a
// namespace.  But use it anyway because using a prefix is a recommended
// practice.
%name-prefix = "pytype"
%locations

// Use a reentrant parser, wire it up to a reentrant lexer.
%pure-parser
%lex-param {void* scanner}
%parse-param {void* scanner}
// Plumb our Context object through the parser.
%parse-param {pytype::Context* ctx}

%error-verbose

%code requires {
#include <Python.h>
}

/* We cannot use %code here because we are intentionally leaving the
 * pytype namespace open, thus we don't close as many braces as we open.  That
 * confuses %code, thus we have to use %{ %} instead.
 */
%{
#include "lexer.h"
#include "parser.h"

namespace pytype {
// Note that the pytype namespace is not closed until the trailing block of
// code after the parser skeleton is emitted.  Thus the entire parser (except
// for a few #defines) is in the pytype namespace.

namespace {
PyObject* DOT_STRING = PyString_FromString(".");

int pytypeerror(YYLTYPE* llocp, void* scanner, pytype::Context* ctx,
    const char *p);

/* Helper functions for building up lists. */
PyObject* StartList(PyObject* item);
PyObject* AppendList(PyObject* list, PyObject* item);
PyObject* ExtendList(PyObject* dst, PyObject* src);

}  // end namespace


// Check that a python value is not NULL.  The must be a macro because it
// calls YYERROR (which is a goto).
#define CHECK(x, loc) do { if (x == NULL) {\
    ctx->SetErrorLocation(&loc); \
    YYERROR; \
  }} while(0)

%}

%union {
  PyObject* obj;
  const char* str;
}

/* This token value is defined by flex, give it a nice name. */
%token END 0              "end of file"

/* Tokens with PyObject values */
%token <obj> NAME NUMBER LEXERROR

/* Reserved words. */
%token CLASS DEF ELSE ELIF IF OR PASS IMPORT FROM AS RAISE PYTHONCODE
%token NOTHING NAMEDTUPLE TYPEVAR
/* Punctuation. */
%token ARROW COLONEQUALS ELLIPSIS EQ NE LE GE
/* Other. */
%token INDENT DEDENT TRIPLEQUOTED TYPECOMMENT

/* Most nonterminals have an obj value. */
%type <obj> start unit alldefs if_stmt if_and_elifs
%type <obj> class_if_stmt class_if_and_elifs
%type <obj> if_cond elif_cond else_cond condition version_tuple
%type <obj> constantdef alias_or_constant
%type <obj> typevardef typevar_args typevar_kwargs typevar_kwarg
%type <obj> classdef class_name parents parent_list parent maybe_class_funcs
%type <obj> class_funcs funcdefs
%type <obj> importdef import_items import_item from_list from_items from_item
%type <obj> funcdef decorators decorator params param_list param param_type
%type <obj> param_default param_star_name return maybe_body
%type <obj> body body_stmt
%type <obj> type type_parameters type_parameter
%type <obj> named_tuple_fields named_tuple_field_list named_tuple_field
%type <obj> maybe_type_list type_list
%type <obj> dotted_name
%type <obj> getitem_key
%type <obj> maybe_number

/* Decrement ref counts of any non-null lvals. */
%destructor { Py_CLEAR($$); } <*>

/* Nonterminals that use non-object values.  Note that these also require
 * a custom %destructor.
 */
%type <str> condition_op
%destructor { } <condition_op>

/* The following nonterminals do not have a value, and are not included in
 * the above %type directives.
 *
 * pass_or_ellipsis empty_body maybe_comma
 */

%left OR

%start start


%%

/* The value stack (i.e. $1) should be treated as new references, owned
 * by the stack up until the action is called, at which point the action
 * is responsible for properly decrementing the refcount.  The action is
 * also responsible for pushing a new reference back onto the stack ($$).
 * When an action uses ctx->Call(), these references can be properly counted
 * simply by using N instead of O in the argument format string.  In fact, N
 * is almost always going to be the right choice for values that are coming
 * from the stack or ctx->Value() since those are all new references.
 * O should be used only when working with a borrowed reference (i.e. Py_None).
 */

start
  : unit END { ctx->SetAndDelResult($1); $$ = NULL; }
  | TRIPLEQUOTED unit END { ctx->SetAndDelResult($2); $$ = NULL; }
  ;

unit
  : alldefs
  ;

alldefs
  : alldefs constantdef { $$ = AppendList($1, $2); }
  | alldefs funcdef { $$ = AppendList($1, $2); }
  | alldefs importdef { $$ = $1; Py_DECREF($2); }
  | alldefs alias_or_constant { $$ = $1; Py_DECREF($2); }
  | alldefs classdef { $$ = $1; Py_DECREF($2); }
  | alldefs typevardef { $$ = $1; Py_DECREF($2); }
  | alldefs if_stmt {
      PyObject* tmp = ctx->Call(kIfEnd, "(N)", $2);
      CHECK(tmp, @2);
      $$ = ExtendList($1, tmp);
    }
  | { $$ = PyList_New(0); }
  ;

classdef
  : CLASS class_name parents ':' maybe_class_funcs {
      $$ = ctx->Call(kAddClass, "(NNN)", $2, $3, $5);
      CHECK($$, @$);
    }
  ;

class_name
  : NAME {
      // Do not borrow the $1 reference since it is also returned later
      // in $$.  Use O instead of N in the format string.
      PyObject* tmp = ctx->Call(kRegisterClassName, "(O)", $1);
      CHECK(tmp, @$);
      Py_DECREF(tmp);
      $$ = $1;
    }
  ;

parents
  : '(' parent_list ')' { $$ = $2; }
  | '(' ')' { $$ = PyList_New(0); }
  |  /* EMPTY */ { $$ = PyList_New(0); }
  ;

parent_list
  : parent_list ',' parent { $$ = AppendList($1, $3); }
  | parent { $$ = StartList($1); }
  ;

parent
  : type { $$ = $1; }
  | NAME '=' type { $$ = Py_BuildValue("(NN)", $1, $3); }
  ;

maybe_class_funcs
  : pass_or_ellipsis { $$ = PyList_New(0); }
  | INDENT class_funcs DEDENT { $$ = $2; }
  | INDENT TRIPLEQUOTED class_funcs DEDENT { $$ = $3; }
  ;

class_funcs
  : pass_or_ellipsis { $$ = PyList_New(0); }
  | funcdefs
  ;

funcdefs
  : funcdefs constantdef { $$ = AppendList($1, $2); }
  | funcdefs funcdef { $$ = AppendList($1, $2); }
  | funcdefs class_if_stmt {
      PyObject* tmp = ctx->Call(kIfEnd, "(N)", $2);
      CHECK(tmp, @2);
      $$ = ExtendList($1, tmp);
    }
  | /* EMPTY */ { $$ = PyList_New(0); }
  ;

if_stmt
  /* Optional ELSE clause after all IF/ELIF/... clauses. */
  : if_and_elifs else_cond ':' INDENT alldefs DEDENT {
      $$ = AppendList($1, Py_BuildValue("(NN)", $2, $5));
    }
  | if_and_elifs
  ;

if_and_elifs
  /* Always start with IF */
  : if_cond ':' INDENT alldefs DEDENT {
      $$ = Py_BuildValue("[(NN)]", $1, $4);
    }
  /* Then zero or more ELIF clauses */
  | if_and_elifs elif_cond ':' INDENT alldefs DEDENT {
      $$ = AppendList($1, Py_BuildValue("(NN)", $2, $5));
    }
  ;

/* Classes accept a smaller set of definitions (funcdefs instead of
 * alldefs).  The corresponding "if" statement thus requires its own
 * set of productions which are similar to the top level if, except they
 * recurse to funcdefs instead of alldefs.
 *
 * TODO(dbaum): Consider changing the grammar such that it accepts all
 * definitions within a class and then raises an error during semantic
 * checks.  This will probably be cleaner as the differences between
 * funcdefs and alldefs grow smaller (i.e. if support for nested classes
 * is added).
 */

class_if_stmt
  /* Optional ELSE clause after all IF/ELIF/... clauses. */
  : class_if_and_elifs else_cond ':' INDENT funcdefs DEDENT {
      $$ = AppendList($1, Py_BuildValue("(NN)", $2, $5));
    }
  | class_if_and_elifs
  ;

class_if_and_elifs
  /* Always start with IF */
  : if_cond ':' INDENT funcdefs DEDENT {
      $$ = Py_BuildValue("[(NN)]", $1, $4);
    }
  /* Then zero or more ELIF clauses */
  | class_if_and_elifs elif_cond ':' INDENT funcdefs DEDENT {
      $$ = AppendList($1, Py_BuildValue("(NN)", $2, $5));
    }
  ;

/* if_cond, elif_cond, and else_cond appear in their own rules in order
 * to trigger an action before processing the body of the corresponding
 * clause.  Although Bison does support mid-rule actions, they don't
 * work well with %type declarations and destructors.
 */

if_cond
  : IF condition { $$ = ctx->Call(kIfBegin, "(N)", $2); CHECK($$, @$); }
  ;

elif_cond
  : ELIF condition { $$ = ctx->Call(kIfElif, "(N)", $2); CHECK($$, @$); }
  ;

else_cond
  : ELSE { $$ = ctx->Call(kIfElse, "()"); CHECK($$, @$); }
  ;

condition
  : dotted_name condition_op NAME {
      $$ = Py_BuildValue("((NO)sN)", $1, Py_None, $2, $3);
    }
  | dotted_name condition_op version_tuple {
      $$ = Py_BuildValue("((NO)sN)", $1, Py_None, $2, $3);
    }
  | dotted_name '[' getitem_key ']' condition_op NUMBER {
      $$ = Py_BuildValue("((NN)sN)", $1, $3, $5, $6);
    }
  | dotted_name '[' getitem_key ']' condition_op version_tuple {
      $$ = Py_BuildValue("((NN)sN)", $1, $3, $5, $6);
    }
  | condition OR condition { $$ = Py_BuildValue("(NsN)", $1, "or", $3); }
  | '(' condition ')' { $$ = $2; }
  ;

/* TODO(dbaum): Consider more general rules for tuple parsing. */
version_tuple
  : '(' NUMBER ',' ')' { $$ = Py_BuildValue("(N)", $2); }
  | '(' NUMBER ',' NUMBER ')' { $$ = Py_BuildValue("(NN)", $2, $4); }
  | '(' NUMBER ',' NUMBER ',' NUMBER ')' {
      $$ = Py_BuildValue("(NNN)", $2, $4, $6);
    }
  ;

condition_op
  : '<' { $$ = "<"; }
  | '>' { $$ = ">"; }
  | LE  { $$ = "<="; }
  | GE  { $$ = ">="; }
  | EQ  { $$ = "=="; }
  | NE  { $$ = "!="; }
  ;

constantdef
  : NAME '=' NUMBER {
      $$ = ctx->Call(kNewConstant, "(NN)", $1, $3);
      CHECK($$, @$);
    }
  | NAME '=' ELLIPSIS {
      $$ = ctx->Call(kNewConstant, "(NN)", $1, ctx->Value(kAnything));
      CHECK($$, @$);
    }
  | NAME '=' ELLIPSIS TYPECOMMENT type {
      $$ = ctx->Call(kNewConstant, "(NN)", $1, $5);
      CHECK($$, @$);
    }
  | NAME ':' type {
      $$ = ctx->Call(kNewConstant, "(NN)", $1, $3);
      CHECK($$, @$);
    }
  | NAME ':' type '=' ELLIPSIS {
      $$ = ctx->Call(kNewConstant, "(NN)", $1, $3);
      CHECK($$, @$);
    }
  ;

importdef
  : IMPORT import_items {
      $$ = ctx->Call(kAddImport, "(ON)", Py_None, $2);
      CHECK($$, @$);
    }
  | FROM dotted_name IMPORT from_list {
      $$ = ctx->Call(kAddImport, "(NN)", $2, $4);
      CHECK($$, @$);
    }
  ;

import_items
  : import_items ',' import_item { $$ = AppendList($1, $3); }
  | import_item { $$ = StartList($1); }

import_item
  : dotted_name
  | dotted_name AS NAME { $$ = Py_BuildValue("(NN)", $1, $3); }
  ;

from_list
  : from_items
  | '(' from_items ')' { $$ = $2; }
  | '(' from_items ',' ')' { $$ = $2; }
  ;

from_items
  : from_items ',' from_item { $$ = AppendList($1, $3); }
  | from_item { $$ = StartList($1); }
  ;

from_item
  : NAME
  | NAMEDTUPLE { $$ = PyString_FromString("NamedTuple"); }
  | TYPEVAR { $$ = PyString_FromString("TypeVar"); }
  | '*' { $$ = PyString_FromString("*"); }
  | NAME AS NAME { $$ = Py_BuildValue("(NN)", $1, $3); }
  ;

alias_or_constant
  : NAME '=' type {
      $$ = ctx->Call(kAddAliasOrConstant, "(NN)", $1, $3);
      CHECK($$, @$);
    }
  ;

typevardef
  : NAME '=' TYPEVAR '(' NAME typevar_args ')' {
      $$ = ctx->Call(kAddTypeVar, "(NNN)", $1, $5, $6);
      CHECK($$, @$);
    }
  ;

typevar_args
  : /* EMPTY */ { $$ = Py_BuildValue("(OO)", Py_None, Py_None); }
  | ',' type_list { $$ = Py_BuildValue("(NO)", $2, Py_None); }
  | ',' typevar_kwargs { $$ = Py_BuildValue("(ON)", Py_None, $2); }
  | ',' type_list ',' typevar_kwargs { $$ = Py_BuildValue("(NN)", $2, $4); }
  ;

typevar_kwargs
  : typevar_kwargs ',' typevar_kwarg { $$ = AppendList($1, $3); }
  | typevar_kwarg { $$ = StartList($1); }
  ;

typevar_kwarg
  : NAME '=' type { $$ = Py_BuildValue("(NN)", $1, $3); }
  ;

funcdef
  : decorators DEF NAME '(' params ')' return maybe_body {
      $$ = ctx->Call(kNewFunction, "(NNNNN)", $1, $3, $5, $7, $8);
      // Decorators is nullable and messes up the location tracking by
      // using the previous symbol as the start location for this production,
      // which is very misleading.  It is better to ignore decorators and
      // pretend the production started with DEF.  Even when decorators are
      // present the error line will be close enough to be helpful.
      //
      // TODO(dbaum): Consider making this smarter and only ignoring decorators
      // when they are empty.  Making decorators non-nullable and having two
      // productions for funcdef would be a reasonable solution.
      @$.first_line = @2.first_line;
      @$.first_column = @2.first_column;
      CHECK($$, @$);
    }
  | decorators DEF NAME PYTHONCODE {
      // TODO(dbaum): Is PYTHONCODE necessary?
      $$ = ctx->Call(kNewExternalFunction, "(NN)", $1, $3);
      // See comment above about why @2 is used as the start.
      @$.first_line = @2.first_line;
      @$.first_column = @2.first_column;
      CHECK($$, @$);
    }
  ;

decorators
  : decorators decorator { $$ = AppendList($1, $2); }
  | /* EMPTY */ { $$ = PyList_New(0); }
  ;

decorator
  : '@' dotted_name { $$ = $2; }
  ;

 /* TODO(dbaum): Consider allowing a trailing comma after param_list. */
params
  : param_list { $$ = $1; }
  | /* EMPTY */ { $$ = PyList_New(0); }
  ;

param_list
  : param_list ',' param { $$ = AppendList($1, $3); }
  | param { $$ = StartList($1); }
  ;

param
  : NAME param_type param_default { $$ = Py_BuildValue("(NNN)", $1, $2, $3); }
  | '*' { $$ = Py_BuildValue("(sOO)", "*", Py_None, Py_None); }
  | param_star_name param_type { $$ = Py_BuildValue("(NNO)", $1, $2, Py_None); }
  | ELLIPSIS { $$ = ctx->Value(kEllipsis) }
  ;

param_type
  : ':' type { $$ = $2; }
  | /* EMPTY */ { Py_INCREF(Py_None); $$ = Py_None; }
  ;

param_default
  : '=' NAME { $$ = $2; }
  | '=' NUMBER { $$ = $2; }
  | '=' ELLIPSIS { $$ = ctx->Value(kEllipsis); }
  | { Py_INCREF(Py_None); $$ = Py_None; }
  ;

param_star_name
  : '*' NAME { $$ = PyString_FromFormat("*%s", PyString_AsString($2)); }
  | '*' '*' NAME { $$ = PyString_FromFormat("**%s", PyString_AsString($3)); }
  ;

return
  : ARROW type { $$ = $2; }
  | /* EMPTY */ { $$ = ctx->Value(kAnything); }
  ;

typeignore
  : TYPECOMMENT NAME { Py_DecRef($2); }
  ;

maybe_body
  : ':' typeignore INDENT body DEDENT { $$ = $4; }
  | ':' INDENT body DEDENT { $$ = $3; }
  | empty_body { $$ = PyList_New(0); }
  ;

empty_body
  : ':' pass_or_ellipsis
  | ':' pass_or_ellipsis typeignore
  | ':' typeignore pass_or_ellipsis
  | ':' typeignore INDENT pass_or_ellipsis DEDENT
  | ':' INDENT pass_or_ellipsis DEDENT
  | ':' INDENT TRIPLEQUOTED DEDENT
  | /* EMPTY */
  ;

body
  : body body_stmt { $$ = AppendList($1, $2); }
  | body_stmt { $$ = StartList($1); }
  ;

body_stmt
  : NAME COLONEQUALS type { $$ = Py_BuildValue("(NN)", $1, $3); }
  | RAISE type { $$ = $2; }
  | RAISE type '(' ')' { $$ = $2; }
  ;

type_parameters
  : type_parameters ',' type_parameter { $$ = AppendList($1, $3); }
  | type_parameter { $$ = StartList($1); }
  ;

type_parameter
  : type { $$ = $1; }
  | ELLIPSIS { $$ = ctx->Value(kEllipsis); }
  ;

type
  : dotted_name {
      $$ = ctx->Call(kNewType, "(N)", $1);
      CHECK($$, @$);
    }
  | dotted_name '[' type_parameters ']' {
      $$ = ctx->Call(kNewType, "(NN)", $1, $3);
      CHECK($$, @$);
    }
  | '[' maybe_type_list ']' {
      // TODO(dbaum): Is this rule necessary?  Seems like it may be old cruft.
      //
      // TODO(dbaum): This assumes kNewType will make this a GenericType and
      // not try to convert it to HomogeneousContainerType (like it does with
      // typing.Tuple).  This feels inconsistent and should be revisited once
      // the parser is complete.
      $$ = ctx->Call(kNewType, "(sN)", "tuple", $2);
      CHECK($$, @$);
    }
  | NAMEDTUPLE '(' NAME ',' named_tuple_fields ')' {
      $$ = ctx->Call(kNewNamedTuple, "(NN)", $3, $5);
      CHECK($$, @$);
    }
  | '(' type ')' { $$ = $2; }
  | type OR type { $$ = ctx->Call(kNewUnionType, "([NN])", $1, $3); }
  | '?' { $$ = ctx->Value(kAnything); }
  | NOTHING { $$ = ctx->Value(kNothing); }
  ;

named_tuple_fields
  : '[' named_tuple_field_list maybe_comma ']' { $$ = $2; }
  | '[' ']' { $$ = PyList_New(0); }
  ;

named_tuple_field_list
  : named_tuple_field_list ',' named_tuple_field { $$ = AppendList($1, $3); }
  | named_tuple_field { $$ = StartList($1); }
  ;

named_tuple_field
  : '(' NAME ',' type maybe_comma ')'  { $$ = Py_BuildValue("(NN)", $2, $4); }
  ;

maybe_comma
  : ','
  | /* EMPTY */
  ;

maybe_type_list
  : type_list { $$ = $1; }
  | /* EMPTY */ { $$ = PyList_New(0); }
  ;

type_list
  : type_list ',' type { $$ = AppendList($1, $3); }
  | type { $$ = StartList($1); }
  ;


dotted_name
  : NAME { $$ = $1; }
  | dotted_name '.' NAME {
      PyString_Concat(&$1, DOT_STRING);
      PyString_ConcatAndDel(&$1, $3);
      $$ = $1;
    }
  ;

getitem_key
  : NUMBER { $$ = $1; }
  | maybe_number ':' maybe_number {
      PyObject* slice = PySlice_New($1, $3, NULL);
      CHECK(slice, @$);
      $$ = slice;
    }
  | maybe_number ':' maybe_number ':' maybe_number {
      PyObject* slice = PySlice_New($1, $3, $5);
      CHECK(slice, @$);
      $$ = slice;
    }
  ;

maybe_number
  : NUMBER { $$ = $1; }
  | /* EMPTY */ { $$ = NULL; }
  ;

pass_or_ellipsis
  : PASS
  | ELLIPSIS
  ;

%%

namespace {

int pytypeerror(
    YYLTYPE* llocp, void* scanner, pytype::Context* ctx, const char *p) {
  ctx->SetErrorLocation(llocp);
  Lexer* lexer = pytypeget_extra(scanner);
  if (lexer->error_message_) {
    PyErr_SetObject(ctx->Value(kParseError), lexer->error_message_);
  } else {
    PyErr_SetString(ctx->Value(kParseError), p);
  }
  return 0;
}

PyObject* StartList(PyObject* item) {
  return Py_BuildValue("[N]", item);
}

PyObject* AppendList(PyObject* list, PyObject* item) {
  PyList_Append(list, item);
  Py_DECREF(item);
  return list;
}

PyObject* ExtendList(PyObject* dst, PyObject* src) {
  // Add items from src to dst (both of which must be lists) and return src.
  // Borrows the reference to src.
  Py_ssize_t count = PyList_Size(src);
  for (Py_ssize_t i=0; i < count; ++i) {
    PyList_Append(dst, PyList_GetItem(src, i));
  }
  Py_DECREF(src);
  return dst;
}

}  // end namespace
}  // end namespace pytype
