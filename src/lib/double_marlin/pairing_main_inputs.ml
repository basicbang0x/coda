open Core_kernel
open Common
open Snarky_bn382_backend
module Impl = Impls.Pairing_based

let sponge_params_constant =
  Sponge.Params.(map bn382_p ~f:Impl.Field.Constant.of_string)

let fp_random_oracle ?length s = Fp.of_bits (bits_random_oracle ?length s)

let group_map = unstage (group_map (module Fp) ~a:Fp.zero ~b:(Fp.of_int 7))

let unrelated_g (x, y) =
  let str = Fn.compose bits_to_bytes Fp.to_bits in
  group_map (fp_random_oracle (str x ^ str y))

let crs_max_degree = 1 lsl 22

open Impl
module Fq = Snarky_bn382_backend.Fq

module App_state = struct
  type t = Field.t

  type _ Tag.t += Tag : Field.Constant.t Tag.t

  module Constant = struct
    include Field.Constant

    let tag = Tag

    let is_base_case = Field.Constant.(equal zero)
  end

  let to_field_elements x = [|x|]

  let typ = Typ.field

  let check_update x0 x1 = Field.(equal x1 (x0 + one))

  let is_base_case x = Field.(equal x zero)
end

let sponge_params =
  Sponge.Params.(map sponge_params_constant ~f:Impl.Field.constant)

module Sponge = struct
  module S = Sponge.Make_sponge (Sponge.Poseidon (Sponge_inputs.Make (Impl)))

  include Sponge.Make_bit_sponge (struct
              type t = Impl.Boolean.var
            end)
            (struct
              include Impl.Field

              let to_bits t =
                Bitstring_lib.Bitstring.Lsb_first.to_list
                  (Impl.Field.unpack_full t)
            end)
            (S)

  let absorb t input =
    match input with
    | `Field x ->
        absorb t x
    | `Bits bs ->
        absorb t (Field.pack bs)
end

module Input_domain = struct
  let domain = Domain.Pow_2_roots_of_unity 5

  (* TODO: Make the real values *)
  let lagrange_commitments =
    let domain_size = Domain.size domain in
    let u = Unsigned.Size_t.of_int in
    time "lagrange" (fun () ->
        Array.init domain_size ~f:(fun i ->
            Snarky_bn382_backend.G.Affine.of_backend
              (Snarky_bn382.Fq_urs.lagrange_commitment
                 (Lazy.force Snarky_bn382_backend.Dlog_based.Keypair.urs)
                 (u domain_size) (u i)) ) )

end

module G = struct
  module Inputs = struct
    module Impl = Impl

    module Params = struct
      open Impl.Field.Constant

      let a = zero

      let b = of_int 7

      let one = G.to_affine_exn G.one

      let group_size_in_bits = 382
    end

    module F = struct
      include struct
        open Impl.Field

        type nonrec t = t

        let ( * ), ( + ), ( - ), inv_exn, square, scale, if_, typ, constant =
          (( * ), ( + ), ( - ), inv, square, scale, if_, typ, constant)

        let negate x = scale x Constant.(negate one)
      end

      module Constant = struct
        open Impl.Field.Constant

        type nonrec t = t

        let ( * ), ( + ), ( - ), inv_exn, square, negate =
          (( * ), ( + ), ( - ), inv, square, negate)
      end

      let assert_square x y = Impl.assert_square x y

      let assert_r1cs x y z = Impl.assert_r1cs x y z
    end

    module Constant = struct
      include G.Affine

      let random () = G.(to_affine_exn (random ()))

      let ( + ) x y = G.(to_affine_exn (of_affine x + of_affine y))

      let negate x = G.(to_affine_exn (negate (of_affine x)))

      let to_affine_exn = Fn.id

      let of_affine = Fn.id
    end
  end

  module Params = Inputs.Params
  module Constant = Inputs.Constant
  module T = Snarky_curve.For_native_base_field (Inputs)

  include (
    T :
      module type of T
      with module Scaling_precomputation := T.Scaling_precomputation )

  module Scaling_precomputation = struct
    include T.Scaling_precomputation

    let create t = create ~unrelated_base:(unrelated_g t) t
  end

  let ( + ) = T.add_exn

  (* TODO: Make real *)
  let scale t bs =
    let x, y = t in
    let constraints_per_bit =
      if Option.is_some (Field.to_constant x) then 2 else 6
    in
    let x = exists Field.typ ~compute:(fun () -> As_prover.read_var x)
    and x2 =
      exists Field.typ ~compute:(fun () ->
          Field.Constant.square (As_prover.read_var x) )
    in
    ksprintf Impl.with_label "scale %s" __LOC__ (fun () ->
        (* Dummy constraints *)
        let num_bits = List.length bs in
        for _ = 1 to constraints_per_bit * num_bits do
          assert_r1cs x x x2
        done ;
        (x, y) )

  (*         T.scale t (Bitstring_lib.Bitstring.Lsb_first.of_list bs) *)
  let to_field_elements (x, y) = [x; y]

  let assert_equal (x1, y1) (x2, y2) =
    Field.Assert.equal x1 x2 ; Field.Assert.equal y1 y2

  let scale_inv t bs =
    let res =
      exists typ
        ~compute:
          As_prover.(
            fun () ->
              G.scale
                (G.of_affine (read typ t))
                (Fq.inv (Fq.of_bits (List.map ~f:(read Boolean.typ) bs)))
              |> G.to_affine_exn)
    in
    (* TODO: assert_equal t (scale res bs) ; *)
    ignore (scale res bs) ;
    res

  (* g -> 7 * g *)
  let scale_by_quadratic_nonresidue t =
    let t2 = T.double t in
    let t4 = T.double t2 in
    t + t2 + t4

  let one_seventh = Fq.(inv (of_int 7))

  let scale_by_quadratic_nonresidue_inv t =
    let res =
      exists typ
        ~compute:
          As_prover.(
            fun () ->
              G.to_affine_exn (G.scale (G.of_affine (read typ t)) one_seventh))
    in
    (*TODO:assert_equal t (scale_by_quadratic_nonresidue res) ; *)
    ignore (scale_by_quadratic_nonresidue res) ;
    res

  let negate = T.negate

  let one = T.one

  let if_ b ~then_:(tx, ty) ~else_:(ex, ey) =
    (Field.if_ b ~then_:tx ~else_:ex, Field.if_ b ~then_:ty ~else_:ey)
end

let domain_k = Domain.Pow_2_roots_of_unity 18

let domain_h = Domain.Pow_2_roots_of_unity 18

module Generators = struct
  let g = G.one

  let h =
    Snarky_bn382.Fq_urs.h
      (Lazy.force Snarky_bn382_backend.Dlog_based.Keypair.urs)
    |> Snarky_bn382_backend.G.Affine.of_backend
    |> G.constant
end