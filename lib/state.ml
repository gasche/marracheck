open OpamTypes
open Utils

(* Relative to the workdir *)
let cache_path = "cache"
let switches_path = "switches"
let opamroot_path = "opamroot"

(* Relative to a switch_state directory *)
let log_path = "log"
let current_timestamp_path = "current_timestamp.git"
let past_timestamps_path = "past_timestamps"

(* Relative to a current_timestamp.git directory *)
let timestamp_path = "timestamp"
let cover_path = "cover.json"
let cur_elt_path = "cur_elt.json"
let report_path = "report.json"
let build_status_path = "build_status.json"

module Versioned = struct
  type 'a t = {
    head : 'a option;
    git_repo : dirname;
  }

  let load_and_clean
      ~(repo : dirname)
      ~(load : dir:dirname -> 'a)
    : 'a t =
    let open OpamProcess in
    let repo_s = OpamFilename.Dir.to_string repo in
    mkdir repo;
    if not (OpamGit.VCS.exists repo) then begin
      let cmd = command ~dir:repo_s "git" [ "init" ] in
      run cmd |> must_succeed cmd
    end;
    (* cleanup uncommited modifications *)
    if Job.run (OpamGit.VCS.is_dirty repo) then begin
      Job.of_list [
        command ~dir:repo_s "git" [ "reset"; "--hard"; "HEAD" ];
        command ~dir:repo_s "git" [ "clean"; "-xfd" ];
      ] |> Job.run
      |> OpamStd.Option.iter (fun (cmd, res) -> must_succeed cmd res)
    end;
    match Job.run (OpamGit.VCS.revision repo) with
    | None ->
      (* No commits recorded *)
      { head = None; git_repo = repo }
    | Some _ ->
      { head = Some (load ~dir:repo); git_repo = repo }

  let commit_new_head ~(sync : 'a -> 'a) msg (st: 'a t) : 'a t =
    let open OpamProcess in
    let repo_s = OpamFilename.Dir.to_string st.git_repo in
    match st.head with
    | None -> assert false
    | Some data ->
      let data = sync data in
      let msg = if msg = "" then "-" else msg in
      let () =
        Job.of_list [
          command ~dir:repo_s "git" [ "add"; "*"; ];
          command ~dir:repo_s "git" [ "commit"; "-a"; "--allow-empty"; "-m"; msg ];
        ]
        |> Job.run
        |> OpamStd.Option.iter (fun (cmd, res) -> must_succeed cmd res)
      in
      { st with head = Some data }
end

module Serialized = struct
  type 'a t = {
    data : 'a;
    path : filename;
  }

  let load_raw ~file : string t =
    { data = OpamSystem.read (OpamFilename.to_string file);
      path = file }

  let sync_raw (s : string t) : string t =
    OpamSystem.write (OpamFilename.to_string s.path) s.data;
    s

  let load_json ~file (of_json : Json.t -> 'a) : 'a t =
    let j = read_json file in
    { data = of_json j; path = file }

  let sync_json (s : 'a t) (to_json : 'a -> Json.t) : 'a t =
    let cout = open_out (OpamFilename.to_string s.path) in
    Json.to_channel ~minify:false cout (to_json s.data);
    close_out cout;
    s
end

module SerializedLog = struct
  type 'a t = {
    old_data : 'a list;
    new_data : 'a list;
    path : filename;
  }

  let items t =
    List.rev_append t.new_data t.old_data

  let add_item item t =
    { t with new_data = item :: t.new_data }

  let add_items items t =
    { t with new_data = List.rev_append items t.new_data }

  let load_json ~file (of_json: Json.t -> 'a): 'a t =
    let data =
      let entries = Yojson.Basic.stream_from_file (OpamFilename.to_string file) in
      let r = ref [] in
      let of_yojson x =
        match value_of_yojson x with
          | #Json.t as x -> of_json x
          | not_toplevel ->
             fatal "Invalid toplevel JSON value in %S:\n%s"
               (OpamFilename.to_string file)
               (Json.value_to_string not_toplevel)
      in
      Stream.iter (fun x -> r := of_yojson x :: !r) entries;
      List.rev !r
    in
    {
      old_data = data;
      new_data = [];
      path = file;
    }

  let sync_json (type a) (t : a t) (to_json: a -> Json.t): a t =
    CCIO.with_out_a (OpamFilename.to_string t.path) (fun chan ->
      let ppf = Format.formatter_of_out_channel chan in
      List.iter (fun item ->
          Format.fprintf ppf "%a@."
            Yojson.Basic.pp
            (yojson_of_value (to_json item :> Json.value)))
        (List.rev t.new_data));
    {
      old_data = items t;
      new_data = [];
      path = t.path;
    }
end

type timestamp = string (* git hash *)
type build_log = string list
type changes = Changes (* fixme *)
type error_cause = [ `Fetch | `Build | `Install ]

type package_report =
  | Success of { log : build_log; changes : changes }
  | Error of { log : build_log; cause : error_cause }
  | Aborted of { deps : PkgSet.t }
  (* An [Aborted] status means that the package could not be built
     because _for all possible ways of building the package_
     at least one of its dependencies fails to build. *)

let package_report_of_json (j: Json.value): package_report =
  let l = Json.get_dict j in
  try
    begin match Json.get_string (List.assoc "status" l) with
    | "success" ->
      Success { log = Json.get_list Json.get_string (List.assoc "log" l);
                changes = Changes (* TODO *) }
    | "error" ->
      let cause = match Json.get_string (List.assoc "cause" l) with
        | "fetch" -> `Fetch
        | "build" -> `Build
        | "install" -> `Install
        | _ -> raise Not_found
      in
      Error { log = Json.get_list Json.get_string (List.assoc "log" l); cause }
    | "aborted" ->
      let deps = match PkgSet.of_json (List.assoc "deps" l) with
        | Some deps -> deps
        | None -> raise Not_found
      in
      Aborted { deps }
    | _ -> raise Not_found
    end
  with Not_found -> Json.parse_error `Null "" (* XX *)

let package_report_to_json = function
  | Success { log; changes = Changes (* TODO *) } ->
    `O [ ("status", `String "success");
         ("log", Json.strings log) ]
  | Error { log; cause } ->
    let cause_s = match cause with
      | `Fetch -> "fetch"
      | `Build -> "build"
      | `Install -> "install"
    in
    `O [ ("status", `String "error");
         ("log", Json.strings log);
         ("cause", `String cause_s) ]
  | Aborted { deps } ->
    `O [ ("status", `String "aborted");
         ("deps", PkgSet.to_json deps) ]

module Cover = struct
  type t = Lib.cover_elt list

  let cover_elt_of_json (j: Json.value): Lib.cover_elt =
    try
      let l = Json.get_dict j in
      let get_opt = function Some x -> x | None -> raise Not_found in
      Lib.{ solution =
              OpamSolver.solution_of_json (List.assoc "solution" l)
              |> get_opt;
            useful =
              PkgSet.of_json (List.assoc "useful" l) |> get_opt; }
    with Not_found -> Json.parse_error `Null "" (* XX *)

  let cover_elt_to_json elt =
    `O [ ("solution", OpamSolver.solution_to_json elt.Lib.solution);
         ("useful", PkgSet.to_json elt.Lib.useful) ]

  let of_json (j: Json.t): t =
    Json.get_list cover_elt_of_json (Json.value j)

  let to_json (cover: t): Json.t =
    Json.list cover_elt_to_json cover
end

module Cover_state = struct
  type report_item = OpamPackage.t * package_report
  type build_status =
    | Build_remaining of PkgSet.t
    | Build_finished_with_uninst of PkgSet.t

  let eq_build_status st1 st2 =
    match st1, st2 with
    | Build_remaining s1, Build_remaining s2
    | Build_finished_with_uninst s1, Build_finished_with_uninst s2 ->
      PkgSet.equal s1 s2
    | _ -> false

  type t = {
    timestamp : timestamp Serialized.t;
    cover : Cover.t Serialized.t;
    cur_elt : Lib.cover_elt option Serialized.t;
    report : report_item SerializedLog.t;
    build_status : build_status Serialized.t;
  }

  let already_built st =
    SerializedLog.items st.report
    |> List.filter_map (fun (pkg, report) ->
         match report with
           | Success _ | Error _ -> Some pkg
           | Aborted _ -> None
       )
    |> PkgSet.of_list

  let create ~dir ~timestamp ~packages =
    let open OpamFilename in
    { timestamp = { data = timestamp; path = Op.(dir // timestamp_path) };
      cover = { data = []; path = Op.(dir // cover_path) };
      cur_elt = { data = None; path = Op.(dir // cur_elt_path) };
      report = { old_data = []; new_data = []; path = Op.(dir // report_path) };
      build_status = { data = Build_remaining packages;
                      path = Op.(dir // build_status_path) };
    }

  let archive_cur_elt (st: t): t =
    match st.cur_elt.data with
    | None -> st
    | Some elt ->
      { st with
        cover = { st.cover with data = elt :: st.cover.data };
        cur_elt = { data = None; path = st.cur_elt.path } }

  let set_remaining (remaining: PkgSet.t) (st: t): t =
    { st with
      build_status = { st.build_status with
                       data = Build_remaining remaining } }

  let add_item_to_report item (st: t): t =
    { st with report = SerializedLog.add_item item st.report }

  let add_items_to_report items (st: t): t =
    { st with report = SerializedLog.add_items items st.report }

  (* This assumes that the files already exist on the filesystem in a valid
     state *)
  let load ~dir : t =
    let open OpamFilename in
    let assoc k l =
      try List.assoc k l with Not_found ->
        Json.parse_error `Null "" (* XX *) in
    let get_opt =
      function Some x -> x | None -> Json.parse_error `Null "" (* XX *) in
    let pkg_report_of_json j =
      let j = Json.value j in
      let l = Json.get_dict j in
      let pkg = assoc "package" l in
      let pkg_report = assoc "report" l in
      (get_opt (OpamPackage.of_json pkg),
       package_report_of_json pkg_report)
    in
    let cur_elt_of_json j =
      match j with
      | `A [] -> None
      | `A [ j' ] -> Some (Cover.cover_elt_of_json j')
      | _ ->
        fatal "In %s: invalid format"
          OpamFilename.(prettify Op.(dir // cur_elt_path))
    in
    let build_status_of_json j =
      let err () = fatal "In %s: invalid format"
          (OpamFilename.(prettify Op.(dir // build_status_path))) in
      try
        begin match j with
          | `O [ "build_remaining", pkgs ] ->
            Build_remaining (get_opt (PkgSet.of_json pkgs))
          | `O [ "build_finished_with_uninst", pkgs ] ->
            Build_finished_with_uninst (get_opt (PkgSet.of_json pkgs))
          | _ -> err ()
        end with Json.Parse_error (_,_) -> err ()
    in
    { timestamp = Serialized.load_raw ~file:Op.(dir // timestamp_path);
      cover = Serialized.load_json ~file:Op.(dir // cover_path) Cover.of_json;
      cur_elt = Serialized.load_json ~file:Op.(dir // cur_elt_path)
          cur_elt_of_json;
      report =
        SerializedLog.load_json ~file:Op.(dir // report_path) pkg_report_of_json;
      build_status =
        Serialized.load_json ~file:Op.(dir // build_status_path)
          build_status_of_json; }

  let sync state : t =
    let report_item_to_json (pkg, pkg_report) =
      `O [ ("package", OpamPackage.to_json pkg);
           ("report", package_report_to_json pkg_report) ]
    in
    let cur_elt_to_json = function
      | None -> `A []
      | Some elt -> `A [ Cover.cover_elt_to_json elt ] in
    let build_status_to_json = function
      | Build_remaining pkgs ->
        `O [ "build_remaining", PkgSet.to_json pkgs ]
      | Build_finished_with_uninst pkgs ->
        `O [ "build_finished_with_uninst", PkgSet.to_json pkgs ]
    in
    let timestamp = Serialized.sync_raw state.timestamp in
    let cover = Serialized.sync_json state.cover Cover.to_json in
    let cur_elt = Serialized.sync_json state.cur_elt cur_elt_to_json in
    let report = SerializedLog.sync_json state.report report_item_to_json in
    let build_status = Serialized.sync_json state.build_status build_status_to_json in
    { timestamp; cover; cur_elt; report; build_status }
end

module Switch_state = struct
  type t = {
    path : dirname;
    log : filename;
    current_timestamp : Cover_state.t Versioned.t;
    past_timestamps : dirname;
  }
end

module Work_state = struct
  type 'a t = {
    opamroot : dirname;
    cache : dirname;
    switches : dirname;
    view : 'a;
  }

  module View_single = struct
    type t = Switch_state.t
    let load_or_create (compiler:package) ~workdir : t =
      let open OpamFilename in
      let switch_dir =
        Op.(workdir / switches_path / OpamPackage.to_string compiler) in
      mkdir switch_dir;
      mkdir Op.(switch_dir / current_timestamp_path);
      mkdir Op.(switch_dir / past_timestamps_path);
      let current_timestamp =
        Versioned.load_and_clean
          ~repo:Op.(switch_dir / current_timestamp_path)
          ~load:Cover_state.load
      in
      { path = switch_dir;
        log = Op.(switch_dir // log_path);
        current_timestamp;
        past_timestamps = Op.(switch_dir / past_timestamps_path); }

    let sync ~workdir state =
      let _ = workdir, state in assert false
  end

  module View_all = struct
    type t = Switch_state.t PkgMap.t
    let load ~workdir : t =
      (* load all things that resemble valid switch states;
         errors for any directory that exists in switches/
         but is not valid *)
      let _ = workdir in assert false
    let sync ~workdir state =
      let _ = workdir, state in assert false
  end

  let load_or_create ~(view : workdir:dirname -> 'view) ~workdir : 'view t =
    let open OpamFilename in
    mkdir workdir;
    (* workdir / opamroot_path will be created automatically by the opam
       initialization code. *)
    mkdir Op.(workdir / cache_path);
    mkdir Op.(workdir / switches_path);
    { opamroot = Op.(workdir / opamroot_path);
      cache = Op.(workdir / cache_path);
      switches = Op.(workdir / switches_path);
      view = view ~workdir }

  let sync ~(view : workdir:dirname -> 'view -> unit) ~workdir : unit =
    let _ = (view, workdir) in assert false
end
