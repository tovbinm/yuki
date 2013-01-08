open Lwt
open Riak

exception Empty
exception Subscript

module Make(Conn:Make.Conn)(Elem:Make.Elem) = struct
  module Client = Client.Make(Conn)(Elem)
  open Client

  let empty = []
  let is_empty ts = ts = []

  let leaf ?key x = lwt t = put ?key x [] in return t.key
  let node ?key x t1 t2 = lwt t = put ?key x [t1; t2] in return t.key

  let cons ?key x = function
    | (w1, t1) :: (w2, t2) :: ts' as ts ->
        if w1 = w2 then
          lwt t = node ?key x t1 t2 in
          return ((1 + w1 + w2, t) :: ts')
        else
          lwt t = leaf ?key x in
          return ((1, t) :: ts)
    | ts ->
        lwt t = leaf ?key x in
        return ((1, t) :: ts)

  let head = function
    | [] -> raise Empty
    | (w, t) :: _ ->
        lwt { value = x } = get t in
        return x

  let pop = function
    | [] -> raise Empty
    | (w, t) :: ts ->
        match_lwt get t with
          | { value = x; links = [] } -> return (x, ts)
          | { value = x; links = [t1; t2] } -> return (x, (w/2, t1) :: (w/2, t2) :: ts)
          | _ -> assert false

  let rec lookup_tree w i t = match w, i, t with
    | 1, 0, { value = x; links = [] } -> return x
    | 1, _, { links = [] } -> raise Subscript
    | _, 0, { value = x; links = [t1; t2] } -> return x
    | _, _, { links = [t1; t2] } ->
        if i <= w/2 then get t1 >>= lookup_tree (w/2) (i - 1)
        else get t2 >>= lookup_tree (w/2) (i - 1 - w/2)
    | _ -> assert false

  let rec lookup i = function
    | [] -> raise Subscript
    | (w, t) :: ts ->
        if i < w then get t >>= lookup_tree w i
        else lookup (i - w) ts

  let rec update_tree w i y t = match w, i, t with
    | 1, 0, { links = [] } -> leaf y
    | 1, _, { links = [] } -> raise Subscript
    | _, 0, { links = [t1; t2] } -> node y t1 t2
    | _, _, { value = x; links = [t1; t2] } ->
        if i <= w/2 then
          lwt t1' = get t1 >>= update_tree (w/2) (i - 1) y in
          node x t1' t2
        else
          lwt t2' = get t2 >>= update_tree (w/2) (i - 1 - w/2) y in
          node x t1 t2'
    | _ -> assert false

  let rec update i y = function
    | [] -> raise Subscript
    | (w, t) :: ts ->
        if i < w then
          lwt t' = get t >>= update_tree w i y in
          return ((w, t') :: ts)
        else
          lwt ts' = update (i - w) y ts in
          return ((w, t) :: ts')

  let rec page_tree w i n t =
    if n = 0 then return []
    else match w, i, t with
      | 1, 0, { value = x; links = [] } -> return [x]
      | 1, _, { links = [] } -> return []
      | _, 0, { value = x; links = [t1; t2] } ->
          if n <= w/2 then
            lwt t1' = get t1 >>= page_tree (w/2) 0 (n - 1) in
            return (x :: t1')
          else
            lwt t1' = get t1 >>= page_tree (w/2) 0 (n - 1)
            and t2' = get t2 >>= page_tree (w/2) 0 (n - 1 - w/2) in
            return (x :: t1' @ t2')
      | _, _, { value = x; links = [t1; t2] } ->
          if i <= w/2 then
            if i + n <= w/2 then
              get t1 >>= page_tree (w/2) (i - 1) n
            else
              lwt t1' = get t1 >>= page_tree (w/2) (i - 1) n
              and t2' = get t2 >>= page_tree (w/2) 0 (i + n - 1 - w/2) in
              return (t1' @ t2')
          else
            get t2 >>= page_tree (w/2) (i - 1 - w/2) n
      | _ -> assert false

  let rec page i n = function
    | [] -> return ([], false)
    | (w, t) :: ts ->
        if i < w then
          if i + n < w then
            lwt t' = get t >>= page_tree w i n in
            return (t', true)
          else
            lwt t1 = get t >>= page_tree w i n
            and (t2, has_more) = page 0 (i + n - w) ts in
            return (t1 @ t2, has_more)
        else page (i - w) n ts

  let rec take_while_tree p = function
      | { value = x; links = [] } ->
          if p x then return ([x], true)
          else return ([], false)
      | { value = x; links = [t1; t2] } ->
          if p x then
            lwt (acc, has_more) = get t1 >>= take_while_tree p in
            if has_more then
              lwt (acc', has_more) = get t2 >>= take_while_tree p in
              return (x :: acc @ acc', has_more)
            else return (x :: acc, false)
          else return ([], false)
      | _ -> assert false

  let rec take_while p = function
    | [] -> return []
    | (w, t) :: ts ->
        lwt (acc, has_more) = get t >>= take_while_tree p in
        if has_more then
          lwt acc' = take_while p ts in
          return (acc @ acc')
        else return acc

  let rec fold_left_tree f acc = function
    | { value = x; links = [] } -> f acc x
    | { value = x; links = [t1; t2] } ->
        lwt acc = f acc x in
        get t1 >>= fold_left_tree f acc >>= fun acc ->
        get t2 >>= fold_left_tree f acc
    | _ -> assert false

  let rec fold_left f acc = function
    | [] -> return acc
    | (w, t) :: ts ->
        lwt acc = get t >>= fold_left_tree f acc in
        fold_left f acc ts

  let rec fold_right_tree f acc = function
    | { value = x; links = [] } -> f x acc
    | { value = x; links = [t1; t2] } ->
        lwt acc = get t2 >>= fold_right_tree f acc in
        get t1 >>= fold_right_tree f acc >>= f x
    | _ -> assert false

  let rec fold_right f acc = function
    | [] -> return acc
    | (w, t) :: ts ->
        lwt acc = fold_right f acc ts in
        get t >>= fold_right_tree f acc
end