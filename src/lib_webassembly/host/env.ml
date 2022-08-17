(*
 * Emulation of (a subset of) the `env` module currently used by Binaryen,
 * so that we can run modules generated by Binaryen. This is a stopgap until
 * we have agreement on what libc should look like.
 *)

open Values
open Types
open Instance

let error msg = raise (Eval.Crash (Source.no_region, msg))

let type_error v t =
  error
    ("type error, expected " ^ string_of_value_type t ^ ", got "
    ^ string_of_value_type (type_of_value v))

let empty = function [] -> () | _ -> error "type error, too many arguments"

let single = function
  | [] -> error "type error, missing arguments"
  | [v] -> v
  | _ -> error "type error, too many arguments"

let int = function
  | Num (I32 i) -> Int32.to_int i
  | v -> type_error v (NumType I32Type)

let abort =
  Host_funcs.Host_func
    (fun _input _mod_inst vs ->
      empty vs ;
      print_endline "Abort!" ;
      exit (-1))

let exit =
  Host_funcs.Host_func (fun _input _mod_inst vs -> exit (int (single vs)))

let register_host_funcs registry =
  Host_funcs.register ~global_name:"abort" abort registry ;
  Host_funcs.register ~global_name:"abort" exit registry

let lookup name =
  let open Lwt.Syntax in
  let+ name = Utf8.encode name in
  match name with
  | "abort" ->
      let global_name = "env_abort" in
      ExternFunc
        (Func.alloc_host
           ~global_name
           (FuncType (Vector.of_list [], Vector.of_list [])))
  | "exit" ->
      let global_name = "env_exit" in
      ExternFunc
        (Func.alloc_host
           ~global_name
           (FuncType
              (Vector.of_list [Types.(NumType I32Type)], Vector.of_list [])))
  | _ -> raise Not_found
