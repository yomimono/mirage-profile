(* Copyright (C) 2014, Thomas Leonard *)

(** This is the [Trace] module when we're compiled with tracing support.
 *
 * Note: we expect some kind of logger to process the trace buffer to collect
 * events, but currently we don't have any barriers to ensure that the buffer
 * is in a consistent state (although it usually is). So for now, you should
 * pause tracing before trying to parse the buffer. In particular, GC events
 * complicate things because we may need to add a GC event while in the middle
 * of adding some other event. *)

open Bigarray

type log_buffer = (char, int8_unsigned_elt, c_layout) Array1.t

external timestamp : log_buffer -> int -> unit = "stub_mprof_get_monotonic_time"

let current_thread = ref (-1L)

let int_of_thread_type t =
  let open Lwt_tracing in
  match t with
  | Wait -> 0
  | Task -> 1
  | Bind -> 2
  | Try -> 3
  | Choose -> 4
  | Pick -> 5
  | Join -> 6
  | Map -> 7
  | Condition -> 8

module Packet = struct
  let magic = 0xc1fc1fc1l
  let uuid = "\x05\x88\x3b\x8d\x52\x1a\x48\x7b\xb3\x97\x45\x6a\xb1\x50\x68\x0c"

  cstruct packet_header {
    uint32_t magic;
    uint8_t  uuid[16];
    uint32_t size;
    uint16_t content_size_low;    (* 2x16 bit to avoid allocating an Int32 *)
    uint16_t content_size_high;
  } as little_endian
  let () =
    ignore (copy_packet_header_uuid, hexdump_packet_header, blit_packet_header_uuid)

  type t = {
    packet_start : int;
    header : Cstruct.t;
    packet_end : int;
  }

  let first_event packet =
    packet.packet_start + sizeof_packet_header

  let packet_end packet =
    packet.packet_end

  let set_content_end packet content_end =
    let header = packet.header in
    let bits = (content_end - packet.packet_start) * 8 in
    set_packet_header_content_size_low header (bits land 0xffff);
    set_packet_header_content_size_high header (bits lsr 16)

  let clear packet =
    set_content_end packet sizeof_packet_header

  let make ~off ~len buffer =
    let header = Cstruct.of_bigarray ~off ~len:sizeof_packet_header buffer in
    set_packet_header_magic header magic;
    set_packet_header_uuid uuid 0 header;
    set_packet_header_size header (Int32.of_int (len * 8));
    let packet = {
      packet_start = off;
      header;
      packet_end = off + len;
    } in
    clear packet;
    packet

end

module Control = struct
  (* Following LTT, our trace buffer is divided into a small number of
   * fixed-sized "packets", each of which contains many events. When there
   * isn't room in the current packet for the next event, we move to the next
   * packet. This wastes a few bytes at the end of each packet, but it allows
   * us to discard whole packets at a time when we need to overwrite something.
   *)
  type t = {
    log : log_buffer;
    mutable next_event : int;     (* Index to write next event (always < packet_end) *)
    mutable packet_end: int;
    packets : Packet.t array;
    mutable active_packet : int;
  }

  let event_log = ref None

  let stop log =
    if Some log <> !event_log then
      failwith "Log is not currently tracing!";
    Lwt_tracing.tracer := Lwt_tracing.null_tracer;
    event_log := None;
    let last_packet = log.packets.(log.active_packet) in
    Packet.set_content_end last_packet log.next_event

  let op_creates = 0
  let op_read = 1
  let op_fulfills = 2
  let op_fails = 3
  let op_becomes = 4
  let op_label = 5
  let op_increase = 6
  let op_switch = 7
  let op_gc = 8

  let write64 log v i =
    EndianBigstring.LittleEndian.set_int64 log i v;
    i + 8

  let write8 log v i =
    EndianBigstring.LittleEndian.set_int8 log i v;
    i + 1

  let write_string log v i =
    let l = String.length v in
    for idx = 0 to l - 1 do
      Array1.set log (i + idx) v.[idx]
    done;
    Array1.set log (i + l) '\x00';
    i + l + 1

  (* The current packet is full. Move to the next one. *)
  let next_packet log =
    log.active_packet <- (log.active_packet + 1) mod Array.length log.packets;
    let packet = log.packets.(log.active_packet) in
    log.packet_end <- Packet.packet_end packet;
    log.next_event <- Packet.first_event packet;
    Packet.clear packet

  let rec add_event log op len =
    (* Note: be careful about allocation here, as doing GC will add another event... *)
    let i = log.next_event in
    let new_i = i + 9 + len in
    (* >= rather than > is slightly wasteful, but avoids next_event overlapping the next packet *)
    if new_i >= log.packet_end then (
      (* Printf.printf "can't write %d at %d\n%!" (9 + len) i; *)
      let old_packet = log.packets.(log.active_packet) in
      assert (i > Packet.first_event old_packet);
      Packet.set_content_end old_packet i;
      next_packet log;
      add_event log op len
    ) else (
      (* Printf.printf "writing at %d\n%!" i; *)
      log.next_event <- new_i;
      timestamp log.log i;
      i + 8 |> write8 log.log op
    )

  (* This is faster than [let end_event = ignore]! *)
  external end_event : int -> unit = "%ignore"
(*
  let end_event i =
    match !event_log with
    | None -> assert false
    | Some log -> assert (i = log.next_event || log.next_event = 0)
*)

  let note_created log child thread_type =
    add_event log op_creates 17
    |> write64 log.log !current_thread
    |> write64 log.log child
    |> write8  log.log (int_of_thread_type thread_type)
    |> end_event

  let note_read log input =
    let new_current = Lwt.current_id () in
    (* (avoid expensive caml_modify call if possible) *)
    if new_current <> !current_thread then current_thread := new_current;
    if !current_thread <> input then (
      add_event log op_read 16
      |> write64 log.log !current_thread
      |> write64 log.log input
      |> end_event
    )

  let note_resolved log p ~ex =
    match ex with
    | Some ex ->
        let msg = Printexc.to_string ex in
        add_event log op_fails (17 + String.length msg)
        |> write64 log.log !current_thread
        |> write64 log.log p
        |> write_string log.log msg
        |> end_event
    | None ->
        add_event log op_fulfills 16
        |> write64 log.log !current_thread
        |> write64 log.log p
        |> end_event

  let note_becomes log input main =
    if main <> input then (
      add_event log op_becomes 16
      |> write64 log.log input
      |> write64 log.log main
      |> end_event
    )

  let note_label log thread msg =
    add_event log op_label (9 + String.length msg)
    |> write64 log.log thread
    |> write_string log.log msg
    |> end_event

  let note_increase log counter amount =
    add_event log op_increase (17 + String.length counter)
    |> write64 log.log !current_thread
    |> write64 log.log (Int64.of_int amount)
    |> write_string log.log counter
    |> end_event

  let note_switch log () =
    let id = Lwt.current_id () in
    if id <> !current_thread then (
      current_thread := id;
      add_event log op_switch 8
      |> write64 log.log id
      |> end_event
    )

  let note_suspend log () =
    current_thread := (-1L);
    add_event log op_switch 8
    |> write64 log.log (-1L)
    |> end_event

  let note_gc duration =
    match !event_log with
    | None -> ()
    | Some log ->
        add_event log op_gc 8
        |> write64 log.log (duration *. 1000000000. |> Int64.of_float)
        |> end_event

  let make log =
    let size = Array1.dim log in
    let n_packets = 4 in
    let packet_size = size / n_packets in
    let packets = Array.init n_packets (fun i ->
      let off = i * packet_size in
      let len = if i = n_packets - 1 then size - off else packet_size in
      Packet.make ~off ~len log
    ) in
    let active_packet = 0 in
    {
      log;
      packets;
      active_packet;
      packet_end = Packet.packet_end packets.(active_packet);
      next_event = Packet.first_event packets.(active_packet);
    }

  let start log =
    event_log := Some log;
    Lwt_tracing.tracer := { Lwt_tracing.
      note_created = note_created log;
      note_read = note_read log;
      note_resolved = note_resolved log;
      note_becomes = note_becomes log;
      note_label = note_label log;
      note_switch = note_switch log;
      note_suspend = note_suspend log;
    };
    note_switch log ()

  let () =
    Callback.register "MProf.Trace.note_gc" note_gc
end

let label name =
  match !Control.event_log with
  | None -> ()
  | Some log -> Control.note_label log (Lwt.current_id ()) name

let note_suspend () =
  match !Control.event_log with
  | None -> ()
  | Some log -> Control.note_suspend log ()

let note_resume () =
  match !Control.event_log with
  | None -> ()
  | Some log -> Control.note_switch log ()

let note_increase counter amount =
  match !Control.event_log with
  | None -> ()
  | Some log -> Control.note_increase log counter amount

let named_condition label =
  Lwt_condition.create ~label ()

let named_wait label =
  let pair = Lwt.wait () in
  begin match !Control.event_log with
  | None -> ()
  | Some log -> Control.note_label log (Lwt.id_of_thread (fst pair)) label end;
  pair

let named_task label =
  let pair = Lwt.task () in
  begin match !Control.event_log with
  | None -> ()
  | Some log -> Control.note_label log (Lwt.id_of_thread (fst pair)) label end;
  pair
