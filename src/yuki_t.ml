(* Auto-generated from "yuki.atd" *)


type rlist = (int * string) list

type node = (int * string * string list)

type heap = string list

type bootstrap = [ `E | `H of (string * heap) ]