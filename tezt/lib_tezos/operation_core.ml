(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

open Runnable.Syntax

type kind = Manager

type t = {
  branch : string;
  contents : JSON.u;
  kind : kind;
  signer : Account.key;
  mutable raw : Hex.t option;
      (* This is mutable to avoid computing the raw representation several times. *)
}

let get_branch client =
  let* json = RPC.get_branch client in
  return (JSON.as_string json)

let make ~branch ~signer ~kind contents =
  {branch; contents; kind; signer; raw = None}

let json t = `O [("branch", Ezjsonm.string t.branch); ("contents", t.contents)]

let raw t client =
  match t.raw with
  | None ->
      let* raw =
        RPC.post_forge_operations ~data:(json t) client
        |> Lwt.map JSON.as_string
      in
      t.raw <- Some (`Hex raw) ;
      return (`Hex raw)
  | Some raw -> return raw

let hex ?signature t client =
  let* (`Hex raw) = raw t client in
  match signature with
  | None -> return (`Hex raw)
  | Some signature ->
      let (`Hex signature) = Tezos_crypto.Signature.to_hex signature in
      return (`Hex (raw ^ signature))

let sign ({kind; signer; _} as t) client =
  let watermark =
    match kind with Manager -> Tezos_crypto.Signature.Generic_operation
  in
  let* hex = hex t client in
  let bytes = Hex.to_bytes hex in
  return (Account.sign_bytes ~watermark ~signer bytes)

module Tezos_operation = Tezos_base.TzPervasives.Operation

let to_raw_operation t client : Tezos_operation.t Lwt.t =
  let open Tezos_base.TzPervasives in
  let branch = Block_hash.of_string_exn t.branch in
  let* raw = hex t client in
  return Tezos_operation.{shell = {branch}; proto = Hex.to_bytes_exn raw}

let hash t client : string Lwt.t =
  let open Tezos_base.TzPervasives in
  let* op = to_raw_operation t client in
  let hash = Tezos_operation.hash op in
  return (Operation_hash.to_string hash)

let inject ?(request = `Inject) ?(force = false) ?signature ?error t client :
    [`OpHash of string] Lwt.t =
  let* signature =
    match signature with
    | None -> sign t client
    | Some signature -> return signature
  in
  let* (`Hex op) = hex ~signature t client in
  let inject_rpc =
    if force then RPC.private_inject_operation else RPC.inject_operation
  in
  let waiter =
    let mode = Client.get_mode client in
    match Client.mode_to_endpoint mode with
    | None -> Test.fail "Operation.inject: Endpoint expected"
    | Some (Proxy_server _) ->
        Test.fail
          "Operation.inject: Node endpoint expected instead of proxy server"
    | Some (Node node) -> Node.wait_for_request ~request node
  in
  let runnable = inject_rpc ~data:(`String op) client in
  match error with
  | None ->
      let* () = waiter in
      let*! oph_json = runnable in
      return (`OpHash (JSON.as_string oph_json))
  | Some msg ->
      let*? process = runnable in
      let* () = Process.check_error ~msg process in
      let* hash = hash t client in
      return (`OpHash hash)

module Manager = struct
  type payload = Transfer of {amount : int; dest : Account.key}

  let transfer ?(dest = Constant.bootstrap2) ?(amount = 1_000_000) () =
    Transfer {amount; dest}

  type t = {
    source : Account.key;
    counter : int option;
    fee : int;
    gas_limit : int;
    storage_limit : int;
    payload : payload;
  }

  let json_of_account account = Ezjsonm.string account.Account.public_key_hash

  let json_of_tez n = string_of_int n |> Ezjsonm.string

  let json_of_int_as_string n = string_of_int n |> Ezjsonm.string

  let get_next_counter ~source client =
    let*! json =
      RPC.Contracts.get_counter
        ~contract_id:source.Account.public_key_hash
        client
    in
    return (1 + JSON.as_int json)

  let json_payload_binding = function
    | Transfer {amount; dest} ->
        [
          ("kind", `String "transaction");
          ("amount", json_of_tez amount);
          ("destination", json_of_account dest);
        ]

  let json client {source; counter; fee; gas_limit; storage_limit; payload} =
    let* counter =
      match counter with
      | None -> get_next_counter ~source client
      | Some counter -> return counter
    in
    let json_bindings =
      [
        ("source", json_of_account source);
        ("fee", json_of_tez fee);
        ("counter", json_of_int_as_string counter);
        ("gas_limit", json_of_int_as_string gas_limit);
        ("storage_limit", json_of_int_as_string storage_limit);
      ]
      @ json_payload_binding payload
    in
    return (`O json_bindings)

  let operation ?branch ?signer manager_operations client =
    let* json_list = Lwt_list.map_s (json client) manager_operations in
    let json = `A json_list in
    let signer =
      match signer with
      | None -> (
          match manager_operations with
          | [] ->
              Test.fail
                "Operation_core: Cannot sign the operation because no signer \
                 was provided and there is no manager to sign."
          | {source; _} :: _ -> source)
      | Some signer -> signer
    in
    let* branch =
      match branch with
      | None -> get_branch client
      | Some branch -> return branch
    in
    return (make ~branch ~signer ~kind:Manager json)

  let make ?(source = Constant.bootstrap1) ?counter ?fee ?gas_limit
      ?storage_limit payload =
    (* Default value are set individually for each manager
       operation. They are close from the default values set by the
       client. *)
    match payload with
    | Transfer _ ->
        let fee = Option.value fee ~default:1_000 in
        let gas_limit = Option.value gas_limit ~default:1_040 in
        let storage_limit = Option.value storage_limit ~default:257 in
        {source; counter; fee; gas_limit; storage_limit; payload}

  let inject ?request ?force ?branch ?signer ?error managers client =
    let* op = operation ?branch ?signer managers client in
    inject ?request ?force ?error op client
end
