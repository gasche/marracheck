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

  let commit_new_head (st: 'a t) ~(sync : 'a -> unit) msg : unit =
    let open OpamProcess in
    let repo_s = OpamFilename.Dir.to_string st.git_repo in
    match st.head with
    | None -> assert false
    | Some data ->
      sync data;
      let msg = if msg = "" then "-" else msg in
      Job.of_list [
        command ~dir:repo_s "git" [ "add"; "*"; ];
        command ~dir:repo_s "git" [ "commit"; "-a"; "-m"; msg ];
      ] |> Job.run
      |> OpamStd.Option.iter (fun (cmd, res) -> must_succeed cmd res)
end

module Serialized = struct
  type 'a t = {
    data : 'a;
    path : filename;
  }

  let load_raw ~file : string t =
    { data = OpamSystem.read (OpamFilename.to_string file);
      path = file }

  let sync_raw (s : string t) =
    OpamSystem.write (OpamFilename.to_string s.path) s.data

  let load_json ~file (of_json : Json.t -> 'a) : 'a t =
    let j = read_json file in
    { data = of_json j; path = file }

  let sync_json (s : 'a t) (to_json : 'a -> Json.t) =
    let cout = open_out (OpamFilename.to_string s.path) in
    Json.to_channel ~minify:false cout (to_json s.data);
    close_out cout
end

type timestamp = string (* git hash *)
type build_log = string list
type changes = Changes (* fixme *)
type error_cause = [ `Fetch | `Build | `Install ]

type package_report =
  | Success of { log : build_log; changes : changes }
  | Error of { log : build_log; cause : error_cause }
  | Aborted of { deps : OpamPackage.Set.t }
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
      let deps = match OpamPackage.Set.of_json (List.assoc "deps" l) with
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
         ("deps", OpamPackage.Set.to_json deps) ]

module Cover = struct
  type t = Lib.cover_elt list

  (* Allow some packages of the input selection to not be installable *)
  let compute_with_uninst
      (u : universe) (selection : OpamPackage.Set.t) :
    t * package list =
    let (cover, remain) = Lib.compute_cover u selection in
    if OpamPackage.Set.is_empty selection then
      assert (cover = []);
    let uninst = match remain with
      | Ok () -> []
      | Error uninst -> uninst
    in
    cover, uninst

  let compute (u: universe) (selection: OpamPackage.Set.t): t =
    let cover, uninst = compute_with_uninst u selection in
    assert (uninst = []);
    cover

  let of_json (j: Json.t): t =
    let cover_elt_of_json j =
      try
        let l = Json.get_dict j in
        let get_opt = function Some x -> x | None -> raise Not_found in
        Lib.{ solution =
                OpamSolver.solution_of_json (List.assoc "solution" l)
                |> get_opt;
              useful =
                OpamPackage.Set.of_json (List.assoc "useful" l) |> get_opt; }
      with Not_found -> Json.parse_error `Null "" (* XX *)
    in
    Json.get_list cover_elt_of_json (Json.value j)

  let to_json (cover: t): Json.t =
    let cover_elt_to_json elt =
      `O [ ("solution", OpamSolver.solution_to_json elt.Lib.solution);
           ("useful", OpamPackage.Set.to_json elt.Lib.useful) ]
    in
    Json.list cover_elt_to_json cover
end

module Cover_state = struct
  type report = (OpamPackage.t * package_report) list
  type build_status =
    | Building_element of int (* index of the cover element in the [Cover.t] *)
    | Build_finished

  type t = {
    timestamp : timestamp Serialized.t;
    cover : Cover.t Serialized.t;
    report : report Serialized.t;
    build_status : build_status Serialized.t;
  }

  let initial_build_status ~cover =
    if cover = [] then Build_finished
    else Building_element 0

  let create ~dir ~timestamp ~cover =
    let open OpamFilename in
    { timestamp = { data = timestamp; path = Op.(dir // timestamp_path) };
      cover = { data = cover; path = Op.(dir // cover_path) };
      report = { data = []; path = Op.(dir // report_path) };
      build_status = { data = initial_build_status ~cover;
                      path = Op.(dir // build_status_path) };
    }

  let update_cover ~cover st =
    { st with
      cover = { st.cover with data = cover };
      build_status = { st.build_status with
                       data = initial_build_status ~cover } }

  let go_to_next_elt (st: t): t =
    match st.build_status.data with
    | Build_finished ->
      (* Be conservative *)
      assert false
    | Building_element id ->
      assert (0 <= id && id < List.length st.cover.data);
      let build_status =
        if id = List.length st.cover.data - 1 then Build_finished
        else Building_element (id + 1)
      in
      { st with build_status = { st.build_status with data = build_status } }

  let add_to_report report (st: t): t =
    let (@) l l' = List.rev_append (List.rev l) l' in
    { st with report = { st.report with data = st.report.data @ report } }

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
      let l = Json.get_dict j in
      let pkg = assoc "package" l in
      let pkg_report = assoc "report" l in
      (get_opt (OpamPackage.of_json pkg),
       package_report_of_json pkg_report)
    in
    let report_of_json j =
      try Json.get_list pkg_report_of_json (Json.value j) with
        Json.Parse_error (_,_) ->
        fatal "In %s: invalid format"
          OpamFilename.(prettify Op.(dir // report_path)) in
    let build_status_of_json = function
      | `O [ "building_element", `Float id ] -> Building_element (truncate id)
      | `O [ "build_finished", `Null ] -> Build_finished
      | _ -> fatal "In %s: invalid format"
               (OpamFilename.(prettify Op.(dir // build_status_path)))
    in
    { timestamp = Serialized.load_raw ~file:Op.(dir // timestamp_path);
      cover = Serialized.load_json ~file:Op.(dir // cover_path) Cover.of_json;
      report =
        Serialized.load_json ~file:Op.(dir // report_path) report_of_json;
      build_status =
        Serialized.load_json ~file:Op.(dir // build_status_path)
          build_status_of_json; }

  let sync state : unit =
    let report_to_json r =
      Json.list (fun (pkg, pkg_report) ->
          `O [ ("package", OpamPackage.to_json pkg);
               ("report", package_report_to_json pkg_report) ]
      ) r
    in
    let build_status_to_json = function
      | Building_element id -> `O [ "building_element", `Float (float id) ]
      | Build_finished -> `O [ "build_finished", `Null ]
    in
    Serialized.sync_raw state.timestamp;
    Serialized.sync_json state.cover Cover.to_json;
    Serialized.sync_json state.report report_to_json;
    Serialized.sync_json state.build_status build_status_to_json
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
    type t = Switch_state.t OpamPackage.Map.t
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
