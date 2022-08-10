(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech  <contact@trili.tech>                       *)
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

open QCheck_alcotest
open QCheck2
open Chunked_byte_vector

let create_works =
  Test.make ~name:"create works" Gen.ui64 (fun len ->
      let vector = create len in
      length vector = len)

let store_load_byte_works =
  Test.make ~name:"store_byte and load_byte work" Gen.string (fun str ->
      let bytes = Bytes.of_string str in
      let len = Int64.of_int (Bytes.length bytes) in
      let vector = create len in
      let mapping =
        List.init (Bytes.length bytes) (fun i ->
            let index = Int64.of_int i in
            let byte = Bytes.get_uint8 bytes i in
            store_byte vector index byte ;
            (index, byte))
      in
      List.for_all (fun (i, c) -> load_byte vector i = c) mapping)

let grow_works =
  Test.make
    ~name:"grow works"
    Gen.(pair string small_int)
    (fun (init_str, grow_len) ->
      let grow_len = Int64.of_int grow_len in
      let vector = of_string init_str in
      let check_contents () =
        List.init (String.length init_str) (fun i ->
            let index = Int64.of_int i in
            load_byte vector index = Char.code (String.get init_str i))
        |> List.for_all Fun.id
      in
      let check1 = check_contents () in
      grow vector grow_len ;
      let check2 = check_contents () in
      let check3 =
        Int64.(length vector = add grow_len (of_int (String.length init_str)))
      in
      check1 && check2 && check3)

let can_write_after_grow =
  Test.make
    ~name:"can write after grow"
    Gen.(string_size (101 -- 1_000))
    (fun append_str ->
      let chunk_size = Chunked_byte_vector.Chunk.size in
      (* We initialize the vector with a string of a size slightly
         under [chunk_size]. This is to be sure that the previous
         value remains accessible after [store_bytes] on the last
         chunk of [vector], that was filled in the process. *)
      let init_size = Int64.(sub chunk_size 100L) in
      let vector =
        create
          ~get_chunk:(function
            | 0L -> Chunk.of_bytes @@ Bytes.make (Int64.to_int chunk_size) 'a'
            | _otherwise -> assert false)
          init_size
      in
      assert (load_byte vector 0L = Char.code 'a') ;
      grow vector (String.length append_str |> Int64.of_int) ;
      store_bytes vector init_size @@ Bytes.of_string append_str ;
      assert (load_byte vector 0L = Char.code 'a') ;
      assert (load_byte vector init_size = Char.code (String.get append_str 0)) ;
      assert (
        load_byte vector chunk_size = Char.code (String.get append_str 100)) ;
      true)

let internal_num_pages_edge_case =
  let test () =
    let open Alcotest in
    check int64 "exact value" 0L (Chunk.num_needed 0L) ;
    check int64 "exact value" 1L (Chunk.num_needed Chunk.size) ;
    check int64 "exact value" 1L (Chunk.num_needed (Int64.pred Chunk.size)) ;
    check int64 "exact value" 2L (Chunk.num_needed (Int64.succ Chunk.size))
  in
  ("internal: num_pages edge case", `Quick, test)

let tests =
  [
    to_alcotest create_works;
    to_alcotest store_load_byte_works;
    to_alcotest grow_works;
    to_alcotest can_write_after_grow;
    internal_num_pages_edge_case;
  ]
