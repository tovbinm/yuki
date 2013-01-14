(* Auto-generated from "yuki.atd" *)


type rlist = (int * string) list

type pair = (string * string)

type digit = [ `Zero | `One of string | `Two of (string * string) ]

type queue = [ `Shallow of digit | `Deep of (digit * string * digit) ]

type node = (int * string * string list)

type heap = string list

type bootstrap = [ `E | `H of (string * heap) ]
