(*
 * @TAG(OTHER_PRINCETON_OSS)
 *)
(* Modified by sweeks@acm.org on 2000-8-24.
 * Ported to MLton.
 *)

(* ML-Yacc Parser Generator (c) 1989 Andrew W. Appel, David R. Tarditi
 *
 * $Log$
 * Revision 1.1  2006/06/22 07:40:27  michaeln
 * Add a MoscowML compilable implementation of MLyacc, using the MLton sources
 * as the base.
 *
 * Revision 1.1.1.1  1997/01/14 01:38:05  george
 *   Version 109.24
 *
 * Revision 1.1.1.1  1996/01/31  16:01:44  george
 * Version 109
 *
 *)

signature ABSYN =
    sig
       datatype exp = EVAR of string
                    | EAPP of exp * exp
                    | ETUPLE of exp list
                    | EINT of int
                    | FN of pat * exp
                    | LET of decl list * exp
                    | UNIT
                    | SEQ of exp * exp
                    | CODE of string
       and      pat = PVAR of string
                    | PAPP of string * pat
                    | PTUPLE of pat list
                    | PLIST of pat list
                    | PINT of int
                    | WILD
                    | AS of pat * pat
       and     decl = VB of pat * exp
       and     rule = RULE of pat * exp
       val printRule : ((string -> unit) * (string -> unit)) -> rule -> unit
    end

