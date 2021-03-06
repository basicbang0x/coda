open Core_kernel

[%%versioned
module Stable = struct
  module V1 = struct
    type ('a, 'h) t = {data: 'a; hash: 'h}
    [@@deriving sexp, compare, to_yojson]
  end
end]

type ('a, 'h) t = ('a, 'h) Stable.Latest.t = {data: 'a; hash: 'h}
[@@deriving sexp, compare, to_yojson]

let data {data; _} = data

let hash {hash; _} = hash

let map t ~f = {t with data= f t.data}

let of_data data ~hash_data = {data; hash= hash_data data}
