open Lwt
open Riak
open Riak_kv_piqi
open Ag_util
open Yuki_tree_j
open Yojson.Safe

exception Empty

module Make(Conn:Yuki_make.Conn)(Elem:Yuki_make.Elem)(Measured:Yuki_make.Measured with type t = Elem.t) = struct
  module Client = Client.Make(Conn)(Elem)
  open Client
  open Measured

  let empty = `Nil
  let is_empty = function `Nil -> true | _ -> false

  let get_fg_aux reader key =
    Conn.with_connection (fun conn ->
      match_lwt riak_get conn Elem.bucket key [] with
        | Some { obj_value = Some value } -> return (Json.from_string (read_fg reader) value)
        | _ -> raise Not_found
    )
  let get_fg reader = function
    | None -> return `Nil
    | Some m -> get_fg_aux reader m

  let put_fg_aux writer ?key ?(ops=[Put_return_head true; Put_if_none_match true]) x =
    Conn.with_connection (fun conn ->
      match_lwt riak_put conn Elem.bucket key (Json.to_string (write_fg writer) x) ops with
        | Some { obj_key = Some key } -> return key
        | _ -> (match key with
            | Some key -> return key
            | None -> raise Not_found
        )
    )
  let put_fg writer = function
    | `Nil -> return None
    | m ->
      lwt m' = put_fg_aux writer m in
      return (Some m')

  let get_elem key =
    lwt { value } = get key in
    return value

  let put_elem x =
    lwt key = put x [] in
    return { key; value = x; links = [] }

  (*---------------------------------*)
  (*              fold               *)
  (*---------------------------------*)
  let fold_left_node : 'acc 'a. ('acc -> 'a -> 'acc Lwt.t) -> 'acc -> 'a node -> 'acc Lwt.t = fun f acc -> function
    | `Node2 (_, a, b) ->
      lwt acc = f acc a in
      f acc b
    | `Node3 (_, a, b, c) ->
      lwt acc = f acc a in
      lwt acc = f acc b in
      f acc c
  let fold_right_node : 'acc 'a. ('a -> 'acc -> 'acc Lwt.t) -> 'acc -> 'a node -> 'acc Lwt.t = fun f acc -> function
    | `Node2 (_, a, b) ->
      lwt acc = f b acc in
      f a acc
    | `Node3 (_, a, b, c) ->
      lwt acc = f c acc in
      lwt acc = f b acc in
      f a acc

  let fold_left_digit : 'acc 'a. ('acc -> 'a -> 'acc Lwt.t) -> 'acc -> 'a digit -> 'acc Lwt.t = fun f acc -> function
    | `One (_, a) -> f acc a
    | `Two (_, a, b) ->
      lwt acc = f acc a in
      f acc b
    | `Three (_, a, b, c) ->
      lwt acc = f acc a in
      lwt acc = f acc b in
      f acc c
    | `Four (_, a, b, c, d) ->
      lwt acc = f acc a in
      lwt acc = f acc b in
      lwt acc = f acc c in
      f acc d
  let fold_right_digit : 'acc 'a. ('a -> 'acc -> 'acc Lwt.t) -> 'acc -> 'a digit -> 'acc Lwt.t = fun f acc -> function
    | `One (_, a) -> f a acc
    | `Two (_, a, b) ->
      lwt acc = f b acc in
      f a acc
    | `Three (_, a, b, c) ->
      lwt acc = f c acc in
      lwt acc = f b acc in
      f a acc
    | `Four (_, a, b, c, d) ->
      lwt acc = f d acc in
      lwt acc = f c acc in
      lwt acc = f b acc in
      f a acc

  let rec fold_left_aux : 'acc 'a. 'a Json.reader -> ('acc -> 'a -> 'acc Lwt.t) -> 'acc -> 'a fg -> 'acc Lwt.t = fun reader f acc -> function
    | `Nil -> return acc
    | `Single x -> f acc x
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node reader in
      lwt acc = fold_left_digit f acc pr
      and m' = get_fg reader' m in
      lwt acc = fold_left_aux reader' (fun acc elt -> fold_left_node f acc elt) acc m' in
      fold_left_digit f acc sf
  let fold_left f =
    fold_left_aux read_string (fun acc elt ->
      lwt elt' = get_elem elt in
      f acc elt'
    )

  let rec fold_right_aux : 'acc 'a. 'a Json.reader -> ('a -> 'acc -> 'acc Lwt.t) -> 'acc -> 'a fg -> 'acc Lwt.t = fun reader f acc -> function
    | `Nil -> return acc
    | `Single x -> f x acc
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node reader in
      lwt acc = fold_right_digit f acc sf
      and m' = get_fg reader' m in
      lwt acc = fold_right_aux reader' (fun elt acc -> fold_right_node f acc elt) acc m' in
      fold_right_digit f acc pr
  let fold_right f =
    fold_right_aux read_string (fun elt acc ->
      lwt elt' = get_elem elt in
      f elt' acc
    )

  (*---------------------------------*)
  (*     measurement functions       *)
  (*---------------------------------*)
  let measure_node : 'a. 'a node -> Monoid.t = function
    | `Node2 (v, _, _)
    | `Node3 (v, _, _, _) -> Monoid.of_string v

  let measure_digit : 'a. 'a digit -> Monoid.t = function
    | `One (v, _)
    | `Two (v, _, _)
    | `Three (v, _, _, _)
    | `Four (v, _, _, _, _) -> Monoid.of_string v

  let measure_t_node : 'a. 'a node fg -> Monoid.t = function
    | `Nil -> Monoid.zero
    | `Single x -> measure_node x
    | `Deep (v, _, _, _) -> Monoid.of_string v
  let measure_t : 'a. measure:('a -> Monoid.t) -> 'a fg -> Monoid.t = fun ~measure -> function
    | `Nil -> Monoid.zero
    | `Single x -> measure x
    | `Deep (v, _, _, _) -> Monoid.of_string v

  (*---------------------------------*)
  (*  a bunch of smart constructors  *)
  (*---------------------------------*)
  let singleton a = `Single a.key

  let node2_node : 'a. 'a node -> 'a node -> 'a node node = fun a b ->
    `Node2 (Monoid.to_string (Monoid.combine (measure_node a) (measure_node b)), a, b)
  let node2 a b =
    `Node2 (Monoid.to_string (Monoid.combine (measure a.value) (measure b.value)), a.key, b.key)

  let node3_node : 'a. 'a node -> 'a node -> 'a node -> 'a node node = fun a b c ->
    `Node3 (Monoid.to_string (Monoid.combine (measure_node a) (Monoid.combine (measure_node b) (measure_node c))), a, b, c)
  let node3 a b c =
    `Node3 (Monoid.to_string (Monoid.combine (measure a.value) (Monoid.combine (measure b.value) (measure c.value))), a.key, b.key, c.key)

  let deep : 'a. 'a node Json.writer -> 'a digit -> 'a node fg -> 'a digit -> 'a fg Lwt.t = fun writer pr m sf ->
    lwt m' = put_fg writer m in
    return (`Deep (Monoid.to_string (Monoid.combine (Monoid.combine (measure_digit pr) (measure_t_node m)) (measure_digit sf)), pr, m', sf))

  let one_node : 'a. 'a node -> 'a node digit = fun a ->
    `One (Monoid.to_string (measure_node a), a)
  let one a =
    `One (Monoid.to_string (measure a.value), a.key)

  let two_node : 'a. 'a node -> 'a node -> 'a node digit = fun a b ->
    `Two (Monoid.to_string (Monoid.combine (measure_node a) (measure_node b)), a, b)
  let two a b =
    `Two (Monoid.to_string (Monoid.combine (measure a.value) (measure b.value)), a.key, b.key)

  let three_node : 'a. 'a node -> 'a node -> 'a node -> 'a node digit = fun a b c ->
    `Three (Monoid.to_string (Monoid.combine (Monoid.combine (measure_node a) (measure_node b)) (measure_node c)), a, b, c)
  let three a b c =
    `Three (Monoid.to_string (Monoid.combine (Monoid.combine (measure a.value) (measure b.value)) (measure c.value)), a.key, b.key, c.key)

  let four_node : 'a. 'a node -> 'a node -> 'a node -> 'a node -> 'a node digit = fun a b c d ->
    `Four (Monoid.to_string (Monoid.combine (Monoid.combine (measure_node a) (measure_node b)) (Monoid.combine (measure_node c) (measure_node d))), a, b, c, d)
  let four a b c d =
    `Four (Monoid.to_string (Monoid.combine (Monoid.combine (measure a.value) (measure b.value)) (Monoid.combine (measure c.value) (measure d.value))), a.key, b.key, c.key, d.key)

  (*---------------------------------*)
  (*          cons / snoc            *)
  (*---------------------------------*)
  let cons_digit_node : 'a. 'a node -> 'a node digit -> 'a node digit = fun x -> function
    | `One (v, a) -> `Two (Monoid.to_string (Monoid.combine (measure_node x) (Monoid.of_string v)), x, a)
    | `Two (v, a, b) -> `Three (Monoid.to_string (Monoid.combine (measure_node x) (Monoid.of_string v)), x, a, b)
    | `Three (v, a, b, c) -> `Four (Monoid.to_string (Monoid.combine (measure_node x) (Monoid.of_string v)), x, a, b, c)
    | `Four _ -> assert false
  let cons_digit x = function
    | `One (v, a) -> `Two (Monoid.to_string (Monoid.combine (measure x.value) (Monoid.of_string v)), x.key, a)
    | `Two (v, a, b) -> `Three (Monoid.to_string (Monoid.combine (measure x.value) (Monoid.of_string v)), x.key, a, b)
    | `Three (v, a, b, c) -> `Four (Monoid.to_string (Monoid.combine (measure x.value) (Monoid.of_string v)), x.key, a, b, c)
    | `Four _ -> assert false

  let snoc_digit_node : 'a. 'a node -> 'a node digit -> 'a node digit = fun x -> function
    | `One (v, a) -> `Two (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure_node x)), a, x)
    | `Two (v, a, b) -> `Three (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure_node x)), a, b, x)
    | `Three (v, a, b, c) -> `Four (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure_node x)), a, b, c, x)
    | `Four _ -> assert false
  let snoc_digit x = function
    | `One (v, a) -> `Two (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure x.value)), a, x.key)
    | `Two (v, a, b) -> `Three (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure x.value)), a, b, x.key)
    | `Three (v, a, b, c) -> `Four (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure x.value)), a, b, c, x.key)
    | `Four _ -> assert false

  let rec cons_aux : 'a. 'a node Json.reader -> 'a node Json.writer -> 'a node -> 'a node fg -> 'a node fg Lwt.t = fun reader writer a -> function
    | `Nil ->
      return (`Single a)
    | `Single b ->
      deep (write_node writer) (one_node a) `Nil (one_node b)
    | `Deep (_, `Four (_, b, c, d, e), m, sf) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt m'' = cons_aux reader' writer' (node3_node c d e) m' in
      deep writer' (two_node a b) m'' sf
    | `Deep (v, pr, m, sf) ->
      return (`Deep (Monoid.to_string (Monoid.combine (measure_node a) (Monoid.of_string v)), cons_digit_node a pr, m, sf))
  let cons a = function
    | `Nil ->
      lwt a' = put_elem a in
      return (singleton a')
    | `Single b ->
      lwt a' = put_elem a and b' = get b in
      deep (write_node write_string) (one a') `Nil (one b')
    | `Deep (_, `Four (_, b, c, d, e), m, sf) ->
      let reader = read_node read_string and writer = write_node write_string in
      lwt a' = put_elem a and b' = get b and c' = get c and d' = get d and e' = get e and m' = get_fg reader m in
      lwt m'' = cons_aux reader writer (node3 c' d' e') m' in
      deep writer (two a' b') m'' sf
    | `Deep (v, pr, m, sf) ->
      lwt a' = put_elem a in
      return (`Deep (Monoid.to_string (Monoid.combine (measure a) (Monoid.of_string v)), cons_digit a' pr, m, sf))

  let rec snoc_aux : 'a. 'a node Json.reader -> 'a node Json.writer -> 'a node -> 'a node fg -> 'a node fg Lwt.t = fun reader writer a -> function
    | `Nil ->
      return (`Single a)
    | `Single b ->
      deep (write_node writer) (one_node b) `Nil (one_node a)
    | `Deep (_, pr, m, `Four (_, b, c, d, e)) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt m'' = snoc_aux reader' writer' (node3_node b c d) m' in
      deep writer' pr m'' (two_node e a)
    | `Deep (v, pr, m, sf) ->
      return (`Deep (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure_node a)), pr, m, snoc_digit_node a sf))
  let snoc a = function
    | `Nil ->
      lwt a' = put_elem a in
      return (singleton a')
    | `Single b ->
      lwt a' = put_elem a and b' = get b in
      deep (write_node write_string) (one b') `Nil (one a')
    | `Deep (_, pr, m, `Four (_, b, c, d, e)) ->
      let reader = read_node read_string and writer = write_node write_string in
      lwt a' = put_elem a and b' = get b and c' = get c and d' = get d and e' = get e and m' = get_fg reader m in
      lwt m'' = snoc_aux reader writer (node3 b' c' d') m' in
      deep writer pr m'' (two e' a')
    | `Deep (v, pr, m, sf) ->
      lwt a' = put_elem a in
      return (`Deep (Monoid.to_string (Monoid.combine (Monoid.of_string v) (measure a)), pr, m, snoc_digit a' sf))

  (*---------------------------------*)
  (*     various conversions         *)
  (*---------------------------------*)
  let to_tree_digit_node : 'a. 'a node digit -> 'a node fg = function
    | `One (_, a) -> `Single a
    | `Two (v, a, b) -> `Deep (v, one_node a, None, one_node b)
    | `Three (v, a, b, c) -> `Deep (v, two_node a b, None, one_node c)
    | `Four (v, a, b, c, d) -> `Deep (v, three_node a b c, None, one_node d)
  let to_tree_digit = function
    | `One (_, a) ->
      lwt a' = get a in
      return (`Single a')
    | `Two (v, a, b) ->
      lwt a' = get a and b' = get b in
      return (`Deep (v, one a', None, one b'))
    | `Three (v, a, b, c) ->
      lwt a' = get a and b' = get b and c' = get c in
      return (`Deep (v, two a' b', None, one c'))
    | `Four (v, a, b, c, d) ->
      lwt a' = get a and b' = get b and c' = get c and d' = get d in
      return (`Deep (v, three a' b' c', None, one d'))
  let to_tree_list ~measure = function
    | [] -> `Nil
    | [a] -> `Single a
    | [a; b] ->
      let m_pr = measure a and m_sf = measure b in
      `Deep (Monoid.to_string (Monoid.combine m_pr m_sf), `One (Monoid.to_string m_pr, a), None, `One (Monoid.to_string m_sf, b))
    | [a; b; c] ->
      let m_pr = Monoid.combine (measure a) (measure b) and m_sf = measure c in
      `Deep (Monoid.to_string (Monoid.combine m_pr m_sf), `Two (Monoid.to_string m_pr, a, b), None, `One (Monoid.to_string m_sf, c))
    | [a; b; c; d] ->
      let m_pr = Monoid.combine (Monoid.combine (measure a) (measure b)) (measure c) and m_sf = measure d in
      `Deep (Monoid.to_string (Monoid.combine m_pr m_sf), `Three (Monoid.to_string m_pr, a, b, c), None, `One (Monoid.to_string m_sf, d))
    | _ -> assert false

  let to_digit_node : 'a. 'a node -> 'a digit = function
    | `Node2 (v, a, b) -> `Two (v, a, b)
    | `Node3 (v, a, b, c) -> `Three (v, a, b, c)
  let to_digit_list = function
    | [a] -> one a
    | [a; b] -> two a b
    | [a; b; c] -> three a b c
    | [a; b; c; d] -> four a b c d
    | _ -> assert false
  let to_digit_list_node : 'a. 'a node list -> 'a node digit = function
    | [a] -> one_node a
    | [a; b] -> two_node a b
    | [a; b; c] -> three_node a b c
    | [a; b; c; d] -> four_node a b c d
    | _ -> assert false

  (*---------------------------------*)
  (*     front / rear / etc.         *)
  (*---------------------------------*)
  let head_digit : 'a. 'a digit -> 'a = function
    | `One (_, a)
    | `Two (_, a, _)
    | `Three (_, a, _, _)
    | `Four (_, a, _, _, _) -> a
  let last_digit : 'a. 'a digit -> 'a = function
    | `One (_, a)
    | `Two (_, _, a)
    | `Three (_, _, _, a)
    | `Four (_, _, _, _, a) -> a
  let tail_digit_node : 'a. 'a node digit -> 'a node digit = function
    | `One _ -> assert false
    | `Two (_, _, a) -> one_node a
    | `Three (_, _, a, b) -> two_node a b
    | `Four (_, _, a, b, c) -> three_node a b c
  let tail_digit = function
    | `One _ -> assert false
    | `Two (_, _, a) -> one a
    | `Three (_, _, a, b) -> two a b
    | `Four (_, _, a, b, c) -> three a b c
  let init_digit_node : 'a. 'a node digit -> 'a node digit = function
    | `One _ -> assert false
    | `Two (_, a, _) -> one_node a
    | `Three (_, a, b, _) -> two_node a b
    | `Four (_, a, b, c, _) -> three_node a b c
  let init_digit = function
    | `One _ -> assert false
    | `Two (_, a, _) -> one a
    | `Three (_, a, b, _) -> two a b
    | `Four (_, a, b, c, _) -> three a b c

  (*type 'a view =
    | Vnil
    | Vcons of 'a * 'a fg

  let rec view_left_aux : 'a. 'a node Json.reader -> 'a node Json.writer -> 'a node fg -> 'a node view Lwt.t = fun reader writer -> function
    | `Nil -> return Vnil
    | `Single x -> return (Vcons (x, `Nil))
    | `Deep (_, `One (_, a), m, sf) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt m'' = view_left_aux reader' writer' m' in
      lwt vcons =
        match m'' with
        | Vnil -> return (to_tree_digit_node sf)
        | Vcons (a, m') -> deep writer' (to_digit_node a) m' sf in
      return (Vcons (a, vcons))
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt vcons = deep writer' (tail_digit_node pr) m' sf in
      return (Vcons (head_digit pr, vcons))
  let view_left : string fg -> Elem.t view Lwt.t = function
    | `Nil -> return Vnil
    | `Single x ->
      lwt x' = get_elem x in
      return (Vcons (x', `Nil))
    | `Deep (_, `One (_, a), m, sf) ->
      let reader = read_node read_string and writer = write_node write_string in
      lwt m' = get_fg reader m in
      lwt m'' = view_left_aux reader writer m' in
      lwt vcons =
        match m'' with
        | Vnil -> to_tree_digit sf
        | Vcons (a, m') -> deep writer (to_digit_node a) m' sf in
      return (Vcons (a, vcons))
    | `Deep (_, pr, m, sf) ->
      let reader = read_node read_string and writer = write_node write_string in
      lwt m' = get_fg reader m in
      lwt vcons = deep writer (tail_digit pr) m' sf in
      return (Vcons (head_digit pr, vcons))

  let rec view_right_aux : 'a. 'a node Json.reader -> 'a node Json.writer -> 'a node fg -> 'a node view Lwt.t = fun reader writer -> function
    | `Nil -> return Vnil
    | `Single x -> return (Vcons (x, `Nil))
    | `Deep (_, pr, m, `One (_, a)) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt m'' = view_right_aux reader' writer' m' in
      lwt vcons =
        match m'' with
        | Vnil -> return (to_tree_digit_node pr)
        | Vcons (a, m') -> deep writer' pr m' (to_digit_node a) in
      return (Vcons (a, vcons))
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt vcons = deep writer' pr m' (init_digit_node sf) in
      return (Vcons (last_digit sf, vcons))
  let view_right = function
    | `Nil -> return Vnil
    | `Single x -> return (Vcons (x, `Nil))
    | `Deep (_, pr, m, `One (_, a)) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt m'' = view_right_aux reader' writer' m' in
      lwt vcons =
        match m'' with
        | Vnil -> return (to_tree_digit pr)
        | Vcons (a, m') -> deep writer' pr m' (to_digit_node a) in
      return (Vcons (a, vcons))
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      lwt vcons = deep writer' pr m' (init_digit ~measure sf) in
      return (Vcons (last_digit sf, vcons))*)

  let head = function
    | `Nil -> raise Empty
    | `Single a -> get_elem a
    | `Deep (_, pr, _, _) -> get_elem (head_digit pr)

  let last = function
    | `Nil -> raise Empty
    | `Single a -> get_elem a
    | `Deep (_, _, _, sf) -> get_elem (last_digit sf)

  (*let tail ~measure t =
    match_lwt view_left ~measure read_string write_string t with
    | Vnil -> raise Empty
    | Vcons (_, tl) -> return tl

  let front ~measure t =
    match_lwt view_left ~measure read_string write_string t with
    | Vnil -> raise Empty
    | Vcons (hd, tl) -> return (tl, hd)

  let init ~measure t =
    match_lwt view_right ~measure read_string write_string t with
    | Vnil -> raise Empty
    | Vcons (_, tl) -> return tl

  let rear ~measure t =
    match_lwt view_right ~measure read_string write_string t with
    | Vnil -> raise Empty
    | Vcons (hd, tl) -> return (tl, hd)

  (*---------------------------------*)
  (*            append               *)
  (*---------------------------------*)
  let nodes : 'a. 'a digit -> 'a list -> 'a digit -> 'a node list =
    let add_digit_to : 'a. 'a digit -> 'a list -> 'a list = fun digit l ->
      match digit with
      | `One (_, a) -> a :: l
      | `Two (_, a, b) -> a :: b :: l
      | `Three (_, a, b, c) -> a :: b :: c :: l
      | `Four (_, a, b, c, d) -> a :: b :: c :: d :: l in

    let rec nodes_aux : 'a. 'a list -> 'a digit -> 'a node list = fun ts sf2 ->
      match ts, sf2 with
      | [], `One _ -> assert false
      | [], `Two (_, a, b)
      | [a], `One (_, b) -> [node2 a b]
      | [], `Three (_, a, b, c)
      | [a], `Two (_, b, c)
      | [a; b], `One (_, c) -> [node3 a b c]
      | [], `Four (_, a, b, c, d)
      | [a], `Three (_, b, c, d)
      | [a; b], `Two (_, c, d)
      | [a; b; c], `One (_, d) -> [node2 a b; node2 c d]
      | a :: b :: c :: ts, _ -> node3 a b c :: nodes_aux ts sf2
      | [a], `Four (_, b, c, d, e)
      | [a; b], `Three (_, c, d, e) -> [node3 a b c; node2 d e]
      | [a; b], `Four (_, c, d, e, f) -> [node3 a b c; node3 d e f] in

    fun sf1 ts sf2 ->
      let ts = add_digit_to sf1 ts in
      nodes_aux ts sf2

  let rec app3 : 'a. measure:('a -> Monoid.t) -> 'a Json.reader -> 'a Json.writer -> 'a fg -> 'a list -> 'a fg -> 'a fg Lwt.t = fun ~measure reader writer t1 elts t2 ->
    match t1, t2 with
    | `Nil, _ ->
      Lwt_list.fold_right_s (fun elt acc -> cons_tree ~measure reader writer acc elt) elts t2
    | _, `Nil ->
      Lwt_list.fold_left_s (fun acc elt -> snoc_tree ~measure reader writer acc elt) t1 elts
    | `Single x1, _ ->
      lwt t = Lwt_list.fold_right_s (fun elt acc -> cons_tree ~measure reader writer acc elt) elts t2 in
      cons_tree ~measure reader writer t x1
    | _, `Single x2 ->
      lwt t = Lwt_list.fold_left_s (fun acc elt -> snoc_tree ~measure reader writer acc elt) t1 elts in
      snoc_tree ~measure reader writer t x2
    | `Deep (_, pr1, m1, sf1), `Deep (_, pr2, m2, sf2) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt m1' = get_fg reader' m1 and m2' = get_fg reader' m2 in
      lwt m = app3 ~measure:measure_node reader' writer' m1' (nodes ~measure sf1 elts pr2) m2' in
      deep writer' pr1 m sf2

  let append ~measure t1 t2 = app3 ~measure read_string write_string t1 [] t2*)

  (*---------------------------------*)
  (*            reverse              *)
  (*---------------------------------*)
  (* unfortunately, when reversing, we need to rebuild every annotation
   * because the monoid does not have to be commutative *)

  let reverse_digit_node : 'a. ('a node -> 'a node Lwt.t) -> 'a node digit -> 'a node digit Lwt.t = fun rev_a -> function
    | `One (_, a) ->
      lwt a' = rev_a a in
      return (one_node a')
    | `Two (_, a, b) ->
      lwt a' = rev_a a and b' = rev_a b in
      return (two_node b' a')
    | `Three (_, a, b, c) ->
      lwt a' = rev_a a and b' = rev_a b and c' = rev_a c in
      return (three_node c' b' a')
    | `Four (_, a, b, c, d) ->
      lwt a' = rev_a a and b' = rev_a b and c' = rev_a c and d' = rev_a d in
      return (four_node d' c' b' a')
  let reverse_digit = function
    | `One _ as d -> return d
    | `Two (_, a, b) ->
      lwt a' = get a and b' = get b in
      return (two b' a')
    | `Three (_, a, b, c) ->
      lwt a' = get a and b' = get b and c' = get c in
      return (three c' b' a')
    | `Four (_, a, b, c, d) ->
      lwt a' = get a and b' = get b and c' = get c and d' = get d in
      return (four d' c' b' a')
  let reverse_node_node : 'a. ('a node -> 'a node Lwt.t) -> 'a node node -> 'a node node Lwt.t = fun rev_a -> function
    | `Node2 (_, a, b) ->
      lwt a' = rev_a a and b' = rev_a b in
      return (node2_node b' a')
    | `Node3 (_, a, b, c) ->
      lwt a' = rev_a a and b' = rev_a b and c' = rev_a c in
      return (node3_node c' b' a')
  let reverse_node = function
    | `Node2 (_, a, b) ->
      lwt a' = get a and b' = get b in
      return (node2 b' a')
    | `Node3 (_, a, b, c) ->
      lwt a' = get a and b' = get b and c' = get c in
      return (node3 c' b' a')

  let rec reverse_aux : 'a. 'a node Json.reader -> 'a node Json.writer -> ('a node -> 'a node Lwt.t) -> 'a node fg -> 'a node fg Lwt.t = fun reader writer reverse_a -> function
    | `Nil -> return `Nil
    | `Single a ->
      lwt a' = reverse_a a in
      return (`Single a')
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node reader and writer' = write_node writer in
      lwt rev_pr = reverse_digit_node reverse_a pr and rev_sf = reverse_digit_node reverse_a sf in
      lwt m' = get_fg reader' m in
      lwt rev_m = reverse_aux reader' writer' (reverse_node_node (reverse_a)) m' in
      deep writer' rev_sf rev_m rev_pr
  let reverse = function
    | `Nil
    | `Single _ as t -> return t
    | `Deep (_, pr, m, sf) ->
      let reader' = read_node read_string and writer' = write_node write_string in
      lwt rev_pr = reverse_digit pr and rev_sf = reverse_digit sf in
      lwt m' = get_fg reader' m in
      lwt rev_m = reverse_aux reader' writer' reverse_node m' in
      deep writer' rev_sf rev_m rev_pr

  (*---------------------------------*)
  (*             split               *)
  (*---------------------------------*)
  let split_digit : 'a. measure:('a -> Monoid.t) -> (Monoid.t -> bool) -> Monoid.t -> 'a digit -> 'a list * 'a * 'a list = fun ~measure p i -> function
    | `One (_, a) -> ([], a, [])
    | `Two (_, a, b) ->
      let i' = Monoid.combine i (measure a) in
      if p i' then ([], a, [b]) else
        ([a], b, [])
    | `Three (_, a, b, c) ->
      let i' = Monoid.combine i (measure a) in
      if p i' then ([], a, [b; c]) else
        let i'' = Monoid.combine i' (measure b) in
        if p i'' then ([a], b, [c]) else
          ([a; b], c, [])
    | `Four (_, a, b, c, d) ->
      let i' = Monoid.combine i (measure a) in
      if p i' then ([], a, [b; c; d]) else
        let i'' = Monoid.combine i' (measure b) in
        if p i'' then ([a], b, [c; d]) else
          let i''' = Monoid.combine i'' (measure c) in
          if p i''' then ([a; b], c, [d]) else
            ([a; b; c], d, [])

  (*let deep_left ~measure reader writer pr m sf =
    match pr with
    | [] -> (
      match_lwt view_left ~measure:measure_node reader writer m with
      | Vnil -> return (to_tree_digit ~measure sf)
      | Vcons (a, m') ->
        deep writer (to_digit_node a) m' sf
    )
    | _ ->
      deep writer (to_digit_list ~measure pr) m sf
  let deep_right ~measure reader writer pr m sf =
    match sf with
    | [] -> (
      match_lwt view_right ~measure:measure_node reader writer m with
      | Vnil -> return (to_tree_digit ~measure pr)
      | Vcons (a, m') -> deep writer pr m' (to_digit_node a)
    )
    | _ ->
      deep writer pr m (to_digit_list ~measure sf)

  let rec split_tree : 'a. measure:('a -> Monoid.t) -> 'a Json.reader -> 'a Json.writer -> (Monoid.t -> bool) -> Monoid.t -> 'a fg -> ('a fg * 'a * 'a fg) Lwt.t = fun ~measure reader writer p i -> function
    | `Nil -> raise Empty
    | `Single x -> return (`Nil, x, `Nil)
    | `Deep (_, pr, m, sf) ->
      let vpr = Monoid.combine i (measure_digit pr) in
      let reader' = read_node reader and writer' = write_node writer in
      lwt m' = get_fg reader' m in
      if p vpr then
        let (l, x, r) = split_digit ~measure p i pr in
        lwt r' = deep_left ~measure reader' writer' r m' sf in
        return (to_tree_list ~measure l, x, r')
      else
        let vm = Monoid.combine vpr (measure_t_node m') in
        if p vm then
          lwt (ml, xs, mr) = split_tree ~measure:measure_node reader' writer' p vpr m' in
          let (l, x, r) = split_digit ~measure p (Monoid.combine vpr (measure_t_node ml)) (to_digit_node xs) in
          lwt l' = deep_right ~measure reader' writer' pr ml l and r' = deep_left ~measure reader' writer' r mr sf in
          return (l', x, r')
        else
          let (l, x, r) = split_digit ~measure p vm sf in
          lwt l' = deep_right ~measure reader' writer' pr m' l in
          return (l', x, to_tree_list ~measure r)

  let split f t =
    match t with
    | `Nil -> return (`Nil, `Nil)
    | _ ->
      if f (measure_t ~measure t) then
        lwt (l, x, r) = split_tree ~measure read_string write_string f Monoid.zero t in
        lwt r' = cons_tree ~measure read_string write_string r x in
        return (l, r')
      else
        return (t, `Nil)*)

  (*---------------------------------*)
  (*            lookup               *)
  (*---------------------------------*)
  let lookup_digit_node : 'a. (Monoid.t -> bool) -> Monoid.t -> 'a node digit -> Monoid.t * 'a node = fun p i -> function
    | `One (_, a) -> Monoid.zero, a
    | `Two (_, a, b) ->
      let m_a = measure_node a in
      let i' = Monoid.combine i m_a in
      if p i' then Monoid.zero, a else m_a, b
    | `Three (_, a, b, c) ->
      let m_a = measure_node a in
      let i' = Monoid.combine i m_a in
      if p i' then Monoid.zero, a else
        let m_b = measure_node b in
        let i'' = Monoid.combine i' m_b in
        if p i'' then m_a, b else Monoid.combine m_a m_b, c
    | `Four (_, a, b, c, d) ->
      let m_a = measure_node a in
      let i' = Monoid.combine i m_a in
      if p i' then Monoid.zero, a else
        let m_b = measure_node b in
        let i'' = Monoid.combine i' m_b in
        if p i'' then m_a, b else
          let m_c = measure_node c in
          let i''' = Monoid.combine i'' m_c in
          if p i''' then Monoid.combine m_a m_b, c else Monoid.combine (Monoid.combine m_a m_b) m_c, d

  let lookup_digit p i = function
    | `One (_, a) -> get_elem a
    | `Two (_, a, b) ->
      lwt a' = get_elem a in
      let i' = Monoid.combine i (measure a') in
      if p i' then return a' else get_elem b
    | `Three (_, a, b, c) ->
      lwt a' = get_elem a in
      let i' = Monoid.combine i (measure a') in
      if p i' then return a' else
        lwt b' = get_elem b in
        let i'' = Monoid.combine i' (measure b') in
        if p i'' then return b' else get_elem c
    | `Four (_, a, b, c, d) ->
      lwt a' = get_elem a in
      let i' = Monoid.combine i (measure a') in
      if p i' then return a' else
        lwt b' = get_elem b in
        let i'' = Monoid.combine i' (measure b') in
        if p i'' then return b' else
          lwt c' = get_elem c in
          let i''' = Monoid.combine i'' (measure c') in
          if p i''' then return c' else get_elem d

  let lookup_node_node : 'a. (Monoid.t -> bool) -> Monoid.t -> 'a node node -> Monoid.t * 'a node = fun p i -> function
    | `Node2 (_, a, b) ->
      let m_a = measure_node a in
      let i' = Monoid.combine i m_a in
      if p i' then Monoid.zero, a else m_a, b
    | `Node3 (_, a, b, c) ->
      let m_a = measure_node a in
      let i' = Monoid.combine i m_a in
      if p i' then Monoid.zero, a else
        let m_b = measure_node b in
        let i'' = Monoid.combine i' m_b in
        if p i'' then m_a, b else Monoid.combine m_a m_b, c

  let lookup_node p i = function
    | `Node2 (_, a, b) ->
      lwt a' = get_elem a in
      let i' = Monoid.combine i (measure a') in
      if p i' then return a' else get_elem b
    | `Node3 (_, a, b, c) ->
      lwt a' = get_elem a in
      let i' = Monoid.combine i (measure a') in
      if p i' then return a' else
        lwt b' = get_elem b in
        let i'' = Monoid.combine i' (measure b') in
        if p i'' then return b' else get_elem c

  let rec lookup_aux : 'a. 'a node Json.reader -> (Monoid.t -> bool) -> Monoid.t -> 'a node fg -> (Monoid.t * 'a node) Lwt.t = fun reader p i -> function
    | `Nil -> raise Empty
    | `Single x -> return (Monoid.zero, x)
    | `Deep (_, pr, m, sf) ->
      let m_pr = measure_digit pr in
      let i' = Monoid.combine i m_pr in
      if p i' then return (lookup_digit_node p i pr) else
        let reader' = read_node reader in
        lwt m' = get_fg reader' m in
        let m_m = measure_t_node m' in
        let i'' = Monoid.combine i' m_m in
        if p i'' then
          lwt v_left, node = lookup_aux reader' p i' m' in
          let v, x = lookup_node_node p (Monoid.combine i' v_left) node in
          return (Monoid.combine (Monoid.combine m_pr v_left) v, x)
        else
          let v, x = lookup_digit_node p i'' sf in
          return (Monoid.combine (Monoid.combine m_pr m_m) v, x)

  let lookup p = function
    | `Nil -> raise Empty
    | `Single x -> get_elem x
    | `Deep (_, pr, m, sf) ->
      let i' = measure_digit pr in
      if p i' then lookup_digit p Monoid.zero pr else
        let reader = read_node read_string in
        lwt m' = get_fg reader m in
        let i'' = Monoid.combine i' (measure_t_node m') in
        if p i'' then
          lwt v_left, node = lookup_aux reader p i' m' in
          lookup_node p (Monoid.combine i' v_left) node
        else
          lookup_digit p i'' sf
end
