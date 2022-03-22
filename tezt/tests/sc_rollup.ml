(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

(* Testing
   -------
   Component:    Smart Contract Optimistic Rollups
   Invocation:   dune exec tezt/tests/main.exe -- --file sc_rollup.ml
*)

open Base

let hooks = Tezos_regression.hooks

(*

   Helpers
   =======

*)

let test ~__FILE__ ?output_file ?(tags = []) title f =
  let tags = "sc_rollup" :: tags in
  match output_file with
  | Some output_file ->
      Protocol.register_regression_test ~output_file ~__FILE__ ~title ~tags f
  | None -> Protocol.register_test ~__FILE__ ~title ~tags f

let setup f ~protocol =
  let sc_rollup_enable = [(["sc_rollup_enable"], Some "true")] in
  let base = Either.right (protocol, None) in
  let* parameter_file = Protocol.write_parameter_file ~base sc_rollup_enable in
  let* (node, client) =
    Client.init_with_protocol ~parameter_file `Client ~protocol ()
  in
  let bootstrap1_key = Constant.bootstrap1.public_key_hash in
  f node client bootstrap1_key

let sc_rollup_node_rpc sc_node service =
  let* curl = RPC.Curl.get () in
  match curl with
  | None -> return None
  | Some curl ->
      let url =
        Printf.sprintf "%s/%s" (Sc_rollup_node.endpoint sc_node) service
      in
      let* response = curl ~url in
      return (Some response)

(*

   Tests
   =====

*)

(* Originate a new SCORU of the arithmetic kind
   --------------------------------------------

   - Rollup addresses are fully determined by operation hashes and origination nonce.

*)
let test_origination =
  let output_file _ = "sc_rollup_origination" in
  test
    ~__FILE__
    ~output_file
    "origination of a SCORU executes without error"
    (fun protocol ->
      setup ~protocol @@ fun _node client bootstrap1_key ->
      let* _rollup_address =
        Client.Sc_rollup.originate
          ~hooks
          ~burn_cap:Tez.(of_int 9999999)
          ~src:bootstrap1_key
          ~kind:"arith"
          ~boot_sector:""
          client
      in
      Client.bake_for client)

(* Configuration of a rollup node
   ------------------------------

   A rollup node has a configuration file that must be initialized.

*)
let with_fresh_rollup f tezos_node tezos_client bootstrap1_key =
  let* rollup_address =
    Client.Sc_rollup.originate
      ~hooks
      ~burn_cap:Tez.(of_int 9999999)
      ~src:bootstrap1_key
      ~kind:"arith"
      ~boot_sector:""
      tezos_client
  in
  let sc_rollup_node = Sc_rollup_node.create tezos_node in
  let* configuration_filename =
    Sc_rollup_node.config_init sc_rollup_node rollup_address
  in
  let* () = Client.bake_for tezos_client in
  f rollup_address sc_rollup_node configuration_filename

let with_fresh_rollups n f node client bootstrap1 =
  let rec go n addrs k =
    if n < 1 then k addrs
    else
      with_fresh_rollup
        (fun addr _ _ -> go (n - 1) (String_set.add addr addrs) k)
        node
        client
        bootstrap1
  in
  go n String_set.empty f

let test_rollup_node_configuration =
  let output_file _ = "sc_rollup_node_configuration" in
  test
    ~__FILE__
    ~output_file
    "configuration of a smart contract optimistic rollup node"
    (fun protocol ->
      setup ~protocol @@ with_fresh_rollup
      @@ fun _rollup_address _sc_rollup_node filename ->
      let read_configuration =
        let open Ezjsonm in
        match from_channel (open_in filename) with
        | `O fields ->
            (* Remove "data-dir" and "rpc-port" as they are non deterministic. *)
            `O
              (List.filter
                 (fun (s, _) ->
                   match s with "data-dir" | "rpc-port" -> false | _ -> true)
                 fields)
            |> to_string
        | _ ->
            failwith "The configuration file does not have the expected format."
      in
      Log.info "Read configuration:\n %s" read_configuration ;
      return ())

(* Launching a rollup node
   -----------------------

   A running rollup node can be asked the address of the rollup it is
   interacting with.

*)
let test_rollup_node_running =
  test
    ~__FILE__
    ~tags:["run"]
    "running a smart contract rollup node"
    (fun protocol ->
      setup ~protocol @@ with_fresh_rollup
      @@ fun rollup_address sc_rollup_node _filename ->
      let* () = Sc_rollup_node.run sc_rollup_node in
      let* rollup_address_from_rpc =
        sc_rollup_node_rpc sc_rollup_node "sc_rollup_address"
      in
      match rollup_address_from_rpc with
      | None ->
          (* No curl, no check. *)
          failwith "Please install curl"
      | Some rollup_address_from_rpc ->
          let rollup_address = "\"" ^ rollup_address ^ "\"" in
          if String.trim rollup_address_from_rpc <> rollup_address then
            failwith
              (Printf.sprintf
                 "Expecting %s, got %s when we query the sc rollup node RPC \
                  address"
                 rollup_address
                 rollup_address_from_rpc)
          else return ())

(* Interacting with a rollup node through a rollup client
   ------------------------------------------------------

   When a rollup node is running, a rollup client can ask this
   node its rollup address.

*)
let test_rollup_client_gets_address =
  let output_file _ = "sc_rollup_client_gets_address" in
  test
    ~__FILE__
    ~output_file
    ~tags:["run"; "client"]
    "getting a smart-contract rollup address through the client"
    (fun protocol ->
      setup ~protocol @@ with_fresh_rollup
      @@ fun rollup_address sc_rollup_node _filename ->
      let* () = Sc_rollup_node.run sc_rollup_node in
      let sc_client = Sc_rollup_client.create sc_rollup_node in
      let* rollup_address_from_client =
        Sc_rollup_client.sc_rollup_address sc_client
      in
      if rollup_address_from_client <> rollup_address then
        failwith
          (Printf.sprintf
             "Expecting %s, got %s when the client asks for the sc rollup \
              address"
             rollup_address
             rollup_address_from_client) ;
      return ())

(* Pushing message in the inbox
   ----------------------------

   A message can be pushed to a smart-contract rollup inbox through
   the Tezos node. Then we can observe that the messages are included in the
   inbox.
*)
let test_rollup_inbox =
  let output_file _ = "sc_rollup_inbox" in
  test
    ~__FILE__
    ~output_file
    ~tags:["inbox"]
    "pushing messages in the inbox"
    (fun protocol ->
      setup ~protocol @@ fun node client ->
      ( with_fresh_rollup @@ fun sc_rollup_address _sc_rollup_node _filename ->
        let send msg =
          let* () =
            Client.Sc_rollup.send_message
              ~hooks
              ~src:"bootstrap1"
              ~dst:sc_rollup_address
              ~msg
              client
          in
          Client.bake_for client
        in
        let n = 10 in
        let messages =
          range 1 n |> fun is ->
          List.map
            (fun i ->
              Printf.sprintf "text:[%s]" @@ String.concat ", "
              @@ List.map (fun _ -> Printf.sprintf "\"CAFEBABE\"") (range 1 i))
            is
        in
        let* () = Lwt_list.iter_s send messages in
        let* () = Client.bake_for client in
        let* inbox = RPC.Sc_rollup.get_inbox ~sc_rollup_address client in
        (List.assoc_opt "inbox_size" (JSON.as_object inbox) |> function
         | None -> failwith "inbox_size is undefined"
         | Some inbox_size ->
             Check.(
               (JSON.as_int inbox_size = n * (n + 1) / 2)
                 int
                 ~error_msg:"expected value %R, got %L")) ;
        return () )
        node
        client)

(* Fetching the initial level of a sc rollup
   -----------------------------------------

  We can fetch the level when a smart contract rollup was 
  originated from the context.
*)
let test_rollup_get_initial_level =
  let output_file _ = "sc_rollup_get_initial_level" in
  test
    ~__FILE__
    ~output_file
    ~tags:["initial_level"]
    "get initial level of a sc rollup"
    (fun protocol ->
      setup ~protocol @@ fun node client bootstrap ->
      let* current_level = RPC.get_current_level client in
      ( with_fresh_rollup @@ fun sc_rollup_address _sc_rollup_node _filename ->
        (* Bake 10 blocks to be sure that the initial level of rollup is different
           from the current level. *)
        let rec bake_blocks n =
          match n with
          | 0 -> return ()
          | _ ->
              Lwt.bind (Client.bake_for client) (fun _ -> bake_blocks (n - 1))
        in
        let* _ = bake_blocks 10 in
        let* initial_level =
          RPC.Sc_rollup.get_initial_level ~sc_rollup_address client
        in
        (* 1 Block for activating alpha + 1 block for originating the rollup
           the rollup initial level should be 2 *)
        Check.(
          (JSON.as_int initial_level
          = JSON.as_int (JSON.get "level" current_level) + 1)
            int
            ~error_msg:"expected value %L, got %R") ;
        return () )
        node
        client
        bootstrap)

let test_rollup_list =
  let open Lwt.Syntax in
  let go node client bootstrap1 =
    let* rollups = RPC.Sc_rollup.list client in
    let rollups = JSON.as_list rollups in
    let () =
      match rollups with
      | _ :: _ ->
          failwith "Expected initial list of originated SCORUs to be empty"
      | [] -> ()
    in

    with_fresh_rollups
      10
      (fun scoru_addresses ->
        let* () = Client.bake_for client in
        let+ rollups = RPC.Sc_rollup.list client in
        let rollups =
          JSON.as_list rollups |> List.map JSON.as_string |> String_set.of_list
        in
        Check.(
          (rollups = scoru_addresses)
            (comparable_module (module String_set))
            ~error_msg:"%L %R"))
      node
      client
      bootstrap1
  in

  test
    ~__FILE__
    ~output_file:(fun _ -> "sc_rollup_list")
    ~tags:["list"]
    "list originated rollups"
    (fun protocol -> setup ~protocol go)

let register ~protocols =
  test_origination protocols ;
  test_rollup_node_configuration protocols ;
  test_rollup_node_running protocols ;
  test_rollup_client_gets_address protocols ;
  test_rollup_inbox protocols ;
  test_rollup_get_initial_level protocols ;
  test_rollup_list protocols
