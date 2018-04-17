open Core
open Async
open Kademlia
open Nanobit_base
open Blockchain_snark

module Rpcs = struct
  module Ping = struct
    type query = unit [@@deriving bin_io]
    type response = unit [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Ping" ~version:0
        ~bin_query ~bin_response
  end

  module Main = struct
    type query = 
      { storage_location: string
      ; initial_peers: Host_and_port.t list
      ; should_mine: bool
      ; me: Host_and_port.t
      }
    [@@deriving bin_io, sexp]

    type response = unit [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Main" ~version:0
        ~bin_query ~bin_response
  end

  module Get_peers = struct
    type query = unit [@@deriving bin_io]
    type response = Host_and_port.t list Option.t [@@deriving bin_io]

    let rpc : (query, response) Rpc.Rpc.t =
      Rpc.Rpc.create ~name:"Get_peers" ~version:0
        ~bin_query ~bin_response
  end

  module Get_strongest_blocks = struct
    type query = unit [@@deriving bin_io]
    type response = Blockchain.Stable.V1.t [@@deriving bin_io]
    type error = unit [@@deriving bin_io]

    let rpc : (query, response, error) Rpc.Pipe_rpc.t =
      Rpc.Pipe_rpc.create ~name:"Get_strongest_blocks" ~version:0
        ~bin_query ~bin_response ~bin_error ()
  end
end

let main () =
  Random.self_init ();

  let rand_name () = 
    let rand_char () = Char.of_int_exn (Char.to_int 'a' + Random.int 26) in
    String.init 10 ~f:(fun _ -> rand_char ())
  in

  let name = rand_name ()
  in

  printf "name: %s\n" name;

  let membership_ref = ref None in
  let strongest_block_reader, strongest_block_writer = Linear_pipe.create () in

  let init_pipes () : (Main.pipes * Blockchain.t Linear_pipe.Reader.t) =
    let gossip_net_strongest_block_reader,
        gossip_net_strongest_block_propagator,
        body_changes_strongest_block_reader,
        storage_strongest_block_reader,
        latest_strongest_block_reader,
        rpc_strongest_block_reader =
      Linear_pipe.fork6 strongest_block_reader in
    let body_changes_reader, body_changes_writer = Linear_pipe.create () in
    { strongest_block_writer
    ; gossip_net_strongest_block_reader
    ; gossip_net_strongest_block_propagator
    ; body_changes_strongest_block_reader
    ; storage_strongest_block_reader
    ; latest_strongest_block_reader
    ; body_changes_reader
    ; body_changes_writer
    }
   , rpc_strongest_block_reader 
  in

  let run_main _ { Rpcs.Main.storage_location; initial_peers; should_mine; me } = 
    let log = Logger.create () in
    let pipes, rpc_strongest_block_reader = init_pipes () in
    don't_wait_for begin
      Linear_pipe.iter
        rpc_strongest_block_reader 
        ~f:(fun blockchain -> 
          Pipe.write_without_pushback strongest_block_writer blockchain;
          Deferred.unit
        );
    end;
    let%map membership = 
      let%bind prover = Prover.create ~conf_dir:storage_location in
      let%bind genesis_proof = Prover.genesis_proof prover >>| Or_error.ok_exn in
      let genesis_blockchain =
        { Blockchain.state = Blockchain.State.zero; proof = genesis_proof }
      in
      let%bind () = Main.assert_chain_verifies prover genesis_blockchain in
      Main.main_nowait
        ~log
        ~prover
        ~storage_location
        ~genesis_blockchain
        ~initial_peers 
        ~should_mine
        ~me
        ~remap_addr_port:(fun addr -> Host_and_port.create ~port:(Host_and_port.port addr + 1) ~host:(Host_and_port.host addr))
        ~client_port:((Host_and_port.port me) + 2)
        ~pipes
    in
    membership_ref := Some membership
  in

  let get_peers _ () = 
    return (Option.map !membership_ref ~f:(fun membership -> Membership.Haskell.peers membership))
  in

  let get_strongest_blocks _ () = 
    return (Result.Ok strongest_block_reader.Linear_pipe.Reader.pipe)
  in

  let implementations = 
    [ Rpc.Rpc.implement Rpcs.Main.rpc run_main
    ; Rpc.Rpc.implement Rpcs.Ping.rpc (fun _ () -> return ())
    ; Rpc.Rpc.implement Rpcs.Get_peers.rpc get_peers
    ; Rpc.Pipe_rpc.implement Rpcs.Get_strongest_blocks.rpc get_strongest_blocks
    ]
  in

  let implementations = 
    Rpc.Implementations.create_exn 
      ~implementations
      ~on_unknown_rpc:`Close_connection
  in

  let _ = 
    Tcp.Server.create 
      ~on_handler_error:(`Call (fun net exn -> eprintf "%s\n" (Exn.to_string_mach exn)))
      (Tcp.Where_to_listen.of_port 8010)
      (fun address reader writer -> 
         Rpc.Connection.server_with_close 
           reader writer
           ~implementations
           ~connection_state:(fun _ -> ())
           ~on_handshake_error:`Ignore)
  in
  Async.never ()
;;

let command : Command.t = 
  Command.async 
    ~summary:"nanobit rpc server" 
    (Command.Param.return main)
