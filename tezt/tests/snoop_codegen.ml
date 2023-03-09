(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 DaiLambda, Inc. <contact@dailambda.jp>                 *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

let generate_code_using_solution_test () =
  Test.register ~title:"snoop codegen" ~tags:["snoop"; "codegen"] ~__FILE__
  @@ fun () ->
  let open Lwt.Syntax in
  let snoop = Snoop.create () in
  let* res =
    Snoop.generate_code_using_solution
      ~solution:"tezt/tests/snoop_codegen/lsl_bytes.sol"
      ~fixed_point:"tezt/tests/snoop_codegen/fp.json"
      snoop
  in
  let outfn = Temp.file "codegen.ml" in
  let oc = open_out outfn in
  output_string oc res ;
  close_out oc ;
  let diff = Diff.files outfn "tezt/tests/snoop_codegen/lsl_bytes.ml.expect" in
  if diff.different then (
    Diff.log ~level:Error diff ;
    assert false)
  else Lwt.return_unit

let register_protocol_independent () = generate_code_using_solution_test ()
