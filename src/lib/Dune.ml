(*
   Interpretation of 'dune' files into a dependency graph.

   This is not a strict interpretation.
   Pros: may work with older and newer versions of the dune format.
   Cons: may be incorrect with respect to the actual dune language.
*)

open Printf

type sexp =
  | Atom of string
  | List of sexp list

(*
   Conversion from the dune AST to a simpler AST similar
   to sexplib.

   We could also keep the locations in the AST so as to emit better error
   messages, but the benefits are not clear.
*)
let rec simplify (ast : Dune_file.t) : sexp =
  match ast with
  | Atom (A s) -> Atom s
  | Quoted_string s -> Atom s
  | List l -> List (List.map simplify l)
  | Template template ->
      (* not sure how to deal with templates or if it matters *)
      Atom (Dune_file.Template.to_string template)

let extract_node_kind entry : Dep_graph.Node.kind option =
  match entry with
  | Atom ("executable" | "executables") :: _ -> Some Dep_graph.Node.Exe
  | Atom ("library" | "libraries") :: _ -> Some Dep_graph.Node.Lib
  | _ -> None

let find_list names sexp_list =
  let found =
    Compat.List.filter_map (function
      | List [Atom s; List data]
      | List (Atom s :: data) when List.mem s names -> Some data
      | _ -> None
    ) sexp_list
  in
  match found with
  | [] -> None
  | ll -> Some (List.flatten ll)

let extract_strings sexp_list =
  Compat.List.filter_map (function
    | Atom s -> Some s
    | List _ -> None
  ) sexp_list

let extract_names entry =
  let public_names =
    match find_list ["public_names"; "public_name"] entry with
    | None -> None
    | Some l -> Some (extract_strings l)
  in
  match public_names with
  | Some names -> names
  | None ->
      match find_list ["names"; "name"] entry with
      | None -> []
      | Some l -> extract_strings l

let extract_deps entry =
  match find_list ["libraries"] entry with
  | None -> []
  | Some l -> extract_strings l

(* 'get_index' is a function that returns a fresh numeric identifier for the
   source file 'path'. *)
let read_node path get_index sexp_entry =
  match sexp_entry with
  | Atom _ -> []
  | List entry ->
      match extract_node_kind entry with
      | None -> []
      | Some kind ->
          let names = extract_names entry in
          let deps = extract_deps entry in
          List.map (fun name_string ->
            let loc = { Dep_graph.Loc.path; index = get_index () } in
            let name =
              match kind with
              | Dep_graph.Node.Exe ->
                  let id = Dep_graph.Loc.id loc in
                  let basename = name_string in
                  let path = (* dune file folder + executable name *)
                    Filename.concat (Filename.dirname path) basename in
                  Dep_graph.Name.Exe { id; basename; path }
              | Dep_graph.Node.Lib -> Dep_graph.Name.Lib name_string
              | Dep_graph.Node.Ext -> assert false
            in
            { Dep_graph.Node.name; kind; deps; loc }
          ) names

let load_file path =
  let entries =
    try
      Dune_file.Parser.load path ~mode:Many
      |> List.map Dune_file.Ast.remove_locs
    with
    | Dune_file.Lexer.Parse_error (loc, msg) ->
        let msg =
          sprintf "%s\n%s"
            (Dune_file.Loc.to_human_readable_location loc)
            msg
        in
        failwith msg
    | e ->
        failwith (
          sprintf "Cannot parse dune file %s: exception %s"
            path (Printexc.to_string e)
      )
  in
  let sexp_entries = List.map simplify entries in
  let index = ref (-1) in
  let get_index () =
    incr index;
    !index
  in
  List.map (read_node path get_index) sexp_entries
  |> List.flatten

let load_files paths =
  List.map load_file paths
  |> List.flatten
  |> Dep_graph.fixup
  |> Filterable.of_dep_graph
