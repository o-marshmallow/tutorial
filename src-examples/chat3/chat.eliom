
{shared{

  open Eliom_lib
  open Eliom_lib.Lwt_ops
  open Eliom_content
  open Lib

}}

(******************************************************************************)
(*                               User management                              *)

{shared{

  module User = struct
    type t = {
      name : string;
      color : string;
    } deriving (Json)
    let create name =
      let color =
        Printf.sprintf "#%02x%02x%02x"
          (56+Random.int 200) (56+Random.int 200) (56+Random.int 200)
      in
      { name; color }
    let to_string { name } = name
    let group_name = to_string
    let compare user1 user2 =
      String.compare user1.name user2.name
  end
  module User_set = struct
    include Set.Make (User)
    let from_list li =
      List.fold_right add li empty
    let to_string users =
      String.concat ", "
        (List.map User.to_string
           (elements users))
  end

}}

let user_verify ~username ~password =
(*     if username = password then *)
    Some (User.create username)
(*     else None *)

(******************************************************************************)
(*                               Chat intestine                               *)

{shared{

  type message = {
    author : User.t;
    content : string;
  } deriving (Json)

  type conversation_event =
    | Message of message
    deriving (Json)

  type conversation = {
    id : int;
    bus : conversation_event Eliom_bus.t;
    users : User_set.t;
    elt_id : Html5_types.div Html5.Id.id;
    prompt_id : Html5_types.input Html5.Id.id;
  }

  type chat_event =
    | Append_conversation of conversation * User.t
    | Remove_conversation of conversation

}}

type user_info = {
  user : User.t;
  chat_events : chat_event React.E.t;
  send_chat_event : chat_event -> unit;
}

let create_user_info user =
  let chat_events, send_chat_event = React.E.create () in
  { user; chat_events; send_chat_event }

(******************************************************************************)
(*                         Book keeping conversations                         *)

let conversation_table = Hashtbl.create 13

let create_conversation =
  let next = counter () in
  fun users ->
    let id = next () in
    let conversation = {
      id; users;
      bus = Eliom_bus.create ~scope:Eliom_common.site Json.t<conversation_event>;
      elt_id = Html5.Id.new_elt_id ~global:false ();
      prompt_id = Html5.Id.new_elt_id ~global:false ();
    } in
    Hashtbl.replace conversation_table id conversation;
    conversation

let get_conversation id =
  try Some (Hashtbl.find conversation_table id)
  with Not_found -> None

let get_conversations user =
  let f _ conversation sofar =
    if User_set.mem user conversation.users then
      conversation :: sofar
    else sofar
  in
  List.rev (Hashtbl.fold f conversation_table [])

let forget_conversation conversation =
  Hashtbl.remove conversation_table conversation.id

(******************************************************************************)
(*                                 User info                                  *)

let user_info_eref = Eliom_reference.eref ~scope:Eliom_common.session_group None

let get_user_info other =
  try_lwt
    let state = Eliom_state.External_states.volatile_data_group_state (User.group_name other) in
    Eliom_reference.Ext.get state user_info_eref
  with Eliom_reference.Eref_not_intialized ->
    Lwt.return None

(******************************************************************************)
(*                 RPC Functions for starting/ending dialogs                  *)

let connected_server_function f =
  server_function
    (get_eref_option user_info_eref
       (fun _ -> Lwt.fail Not_allowed)
       f)

let rpc_create_dialog =
  connected_server_function
    (fun user_info other ->
       match_lwt get_user_info other with
         | Some other_user_info ->
             let users = User_set.from_list [user_info.user; other] in
             let conversation = create_conversation users in
             user_info.send_chat_event (Append_conversation (conversation, other));
             other_user_info.send_chat_event (Append_conversation (conversation, user_info.user));
             ignore {unit{
               show_message "Dialog with %s created" (User.to_string %other)
             }};
             Lwt.return ()
         | None ->
            ignore {unit{
              show_message "Could not create dialog"
            }};
            Lwt.return ())

let cancel_dialog conversation =
  forget_conversation conversation;
  User_set.iter
    (fun other ->
       Lwt.async
         (fun () ->
            match_lwt get_user_info other with
              | Some other_user_info ->
                  other_user_info.send_chat_event (Remove_conversation conversation);
                  Lwt.return ()
              | None -> Lwt.return ()))
    conversation.users;
  Lwt.return ()

let rpc_cancel_dialog =
  connected_server_function
    (fun _ conversation_id ->
       (match get_conversation conversation_id with
          | Some conversation ->
              lwt () = cancel_dialog conversation in
              ignore {unit{
                show_message "Dialog with %s canceled" (User_set.to_string %(conversation.users))
              }};
              Lwt.return ()
          | None ->
              ignore {unit{
                show_message "Could not cancel dialog"
              }};
              Lwt.return ()))

(******************************************************************************)
(*                            Client processes                                *)

module Client_processes_user =
  Client_processes.Make
    (struct
       type t = User.t
       let get () =
         match_lwt Eliom_reference.get user_info_eref with
           | Some { user } -> Lwt.return user
           | None -> Lwt.fail (Failure "Client_processes_user.get")
     end)

let connected_users =
  React.S.map ~eq:User_set.equal
    (Client_processes.accumulate_infos User_set.from_list)
    Client_processes_user.signal

let connected_users_down = Eliom_react.S.Down.of_react ~scope:Eliom_common.site connected_users

(* Debug user client processes *)
let () =
  Lwt_react.E.keep
    (React.E.map
       (fun processes ->
          debug "Client processes: %s"
            (String.concat ", "
               (List.map (fun (id, user) -> Printf.sprintf "%d:%s" id (User.to_string user))
                  (Int_map.bindings processes))))
       (React.S.changes Client_processes_user.signal))

(* Remove all conversations of a user when is disappears. *)
let () =
  let remove_user user =
    List.iter
      (fun conversation ->
         Lwt.async
           (fun () ->
              cancel_dialog conversation))
      (get_conversations user)
  in
  let removed_users =
    singleton_diff_event
      (fun s1 s2 -> User_set.diff s2 s1)
      User_set.elements connected_users
  in
  Lwt_react.E.keep (React.E.map remove_user removed_users)

let () =
  let add_user user =
    () (* TODO Revive his dialogs *)
  in
  let added_users =
    singleton_diff_event User_set.diff User_set.elements connected_users
  in
  Lwt_react.E.keep (React.E.map add_user added_users)

(******************************************************************************)
(*                              User service                                  *)

let login_service =
  Eliom_service.post_coservice'
    ~post_params:Eliom_parameter.(string "name" ** string "password") ()

let logout_service =
  Eliom_service.post_coservice' ~post_params:Eliom_parameter.unit ()

let login_message_eref = Eliom_reference.Volatile.eref ~scope:Eliom_common.request None

let login_handler () (username, password) =
  match user_verify username password with
    | Some user ->
        Eliom_state.set_volatile_data_session_group
          ~scope:Eliom_common.session (User.group_name user);
        (match_lwt Eliom_reference.get user_info_eref with
           | Some _ ->
               Eliom_reference.Volatile.set login_message_eref (Some "Already logged in");
               Eliom_registration.Action.send ()
           | None ->
               let user_info = create_user_info user in
               lwt () = Eliom_reference.set user_info_eref (Some user_info) in
               Eliom_registration.Redirection.send Eliom_service.void_hidden_coservice')
    | None ->
        Eliom_reference.Volatile.set login_message_eref (Some "Wrong credentials");
        Eliom_registration.Action.send ()

let logout_handler () () =
  match_lwt Eliom_reference.get user_info_eref with
    | Some _ ->
        Client_processes_user.erase_process ();
        lwt () = Eliom_state.discard ~scope:Eliom_common.session () in
        Eliom_registration.Redirection.send Eliom_service.void_hidden_coservice'
    | None ->
        Eliom_registration.Action.send ()

(******************************************************************************)
(*                                  Widgets                                   *)

let conversations_id = Html5.Id.new_elt_id ~global:true ()
let connected_users_list_id = Html5.Id.new_elt_id ~global:true ()

{shared{

  let user_widget ?self user =
    let open Html5.F in
    let self_class =
      let self_class user' =
        if 0 = User.compare user user' then
          ["self"]
        else []
      in
      Option.get (fun () -> [])
        (Option.map self_class self)
    in
    span ~a:[a_class ("user_name" :: self_class);
             a_style ("background-color:"^user.User.color); ]
      [ pcdata user.User.name ]

  let message_widget user message =
    let open Html5.F in
    li ~a:[a_class ["message"]] [
      user_widget ~self:user message.author;
      span ~a:[a_class ["content"]]
        [pcdata message.content]
    ]

  let users_attr =
    Html5.Custom_data.create_json ~name:"users" Json.t<User.t list>
}}

{client{

  let find_conversation ?disabled users =
    let suffix =
      match disabled with
        | None -> ""
        | Some true -> ".disabled"
        | Some false -> ":not(.disabled)"
    in
    List.find
      (fun conversation_dom ->
         let users' =
           Html5.Custom_data.get_dom conversation_dom users_attr
         in
         users' = User_set.elements users)
      (Dom.list_of_nodeList
         Dom_html.window##document##querySelectorAll
           (js_stringf ".conversation%s" suffix))

  let user_list_user_widget user other =
    let onclick ev =
      Js.Optdef.iter
        (ev##currentTarget)
        (fun user_dom ->
           try
             let users = User_set.from_list [other; user] in
             let conversation_dom = find_conversation ~disabled:false users in
             show_message "Focus conversation with %s" (User.to_string other);
             Js.Opt.iter
               (Js.Opt.bind
                  (conversation_dom##querySelector(Js.string ".prompt"))
                  Dom_html.CoerceTo.input)
               (fun prompt_dom -> prompt_dom##focus ())
           with Not_found ->
             Lwt.async
               (fun () -> %rpc_create_dialog other))
    in
    let open Html5.F in
      span ~a:[a_class ["user"]; a_onclick onclick]
      [ user_widget ~self:user other ]

}}

{client{

  let is_disabled dom =
    Js.to_bool dom##classList##contains(Js.string "disabled")
  let set_disabled dom =
    dom##classList##add(Js.string "disabled")

  (* To access those variables in the client_value within the shared section below *)
  let rpc_cancel_dialog = %rpc_cancel_dialog
  let conversations_id = %conversations_id
}}

{shared{

  let conversation_widget user others conversation old_messages =
    let open Html5.F in
    let participants =
      let elts =
        List.map (fun other -> li [user_widget ~self:user other])
          (User_set.elements others)
      in
      Html5.D.ul ~a:[a_class ["participants"]] elts
    in
    let close =
      Html5.D.span ~a:[a_class ["close"]] [pcdata ""]
      (*WTF entity "#10060" - inserted in CSS*)
    in
    let messages = Html5.D.ul ~a:[a_class ["messages"]] old_messages in
    let prompt =
      Html5.Id.create_named_elt ~id:conversation.prompt_id
        (Html5.D.input ~a:[a_class ["prompt"]; a_autofocus `Autofocus] ())
    in
    let participants_complete =
      div ~a:[a_class ["participants_complete"]] [
        span ~a:[a_class ["info_label"]] [ pcdata "With " ];
        participants;
        close;
      ]
    in
    let conversation_elt =
      let users = User_set.elements (User_set.add user others) in
      Html5.Id.create_named_elt ~id:conversation.elt_id
        (Html5.D.div
           ~a:[
             a_class ["conversation"];
             Html5.Custom_data.attrib users_attr users
           ] [
             participants_complete;
             messages;
             (prompt :> Html5_types.div_content_fun Html5.elt);
           ])
    in
    ignore {unit{
      Eliom_client.withdom
        (fun () ->
           Lwt.async
             (fun () ->
                let dispatch_message = function
                  | Message msg ->
                      Html5.Manip.appendChild %messages (message_widget %user msg);
                      (let messages_dom = Html5.To_dom.of_element %messages in
                       messages_dom##scrollTop <- messages_dom##scrollHeight)
                in
                try_lwt
                  Lwt_stream.iter dispatch_message
                   (Eliom_bus.stream %(conversation.bus))
                with exn ->
                  debug_exn "Error during streaming conversation %d" exn %(conversation.id);
                  error "Error during streaming conversation %d" %(conversation.id));
           Lwt_js_events.async
             (fun () ->
                Lwt_js_events.keypresses (Html5.To_dom.of_element %prompt)
                  (fun ev ->
                     if ev##keyCode = 13 then
                       (let prompt_dom = Html5.To_dom.of_input %prompt in
                        let content = Js.to_string prompt_dom##value in
                        prompt_dom##value <- Js.string "";
                        Eliom_bus.write %(conversation.bus)
                          (Message { author = %user; content }))
                      else Lwt.return ()));
           Lwt_js_events.async
             (fun () ->
                Lwt_js_events.clicks (Html5.To_dom.of_element %close)
                  (fun ev ->
                     Dom_html.stopPropagation ev;
                     if is_disabled (Html5.To_dom.of_element %conversation_elt) then
                       (Html5.Manip.Named.removeChild conversations_id %conversation_elt;
                        Lwt.return ())
                     else
                       %rpc_cancel_dialog %(conversation.id)));
           ())
    }};
    conversation_elt
}}

{client{

  let append_conversation conversation user other =
    let conversation_widget' =
      conversation_widget user (User_set.from_list [other]) conversation
    in
    try
      let old_conversation_dom = find_conversation (User_set.from_list [user; other]) in
      let old_messages =
        let message_doms =
          Js.Opt.case
            (old_conversation_dom##querySelector(Js.string ".messages"))
            (fun () -> error "append_conversation: no messages")
            (fun messages -> Dom.list_of_nodeList messages##childNodes)
        in
        List.map
          (fun message_dom ->
             Js.Opt.case
               (Js.Opt.bind
                  (Dom_html.CoerceTo.element message_dom)
                  Dom_html.CoerceTo.li)
               (fun () -> error "append_conversation: message not li")
               Html5.Of_dom.of_li)
          message_doms
      in
      Html5.Manip.Named.replaceChild conversations_id
        (conversation_widget' old_messages)
        (Html5.Of_dom.of_element old_conversation_dom)
    with Not_found ->
      Html5.Manip.Named.appendChild conversations_id
        (conversation_widget' [])

  let remove_conversation conversation user =
    let conversation_elt = Html5.Id.get_element conversation.elt_id in
    set_disabled (Html5.To_dom.of_element conversation_elt);
    Html5.Manip.removeChild conversation_elt
      (Html5.Id.get_element conversation.prompt_id)

  let dispatch_chat_event user = function
    | Append_conversation (conversation, other) ->
        append_conversation conversation user other
    | Remove_conversation conversation ->
        remove_conversation conversation user
}}

(******************************************************************************)
(*                              Main service                                  *)

let main_service =
  Eliom_service.service ~path:[] ~get_params:Eliom_parameter.unit ()

let connected_main_handler { user; chat_events } =
  fun () () ->
    lwt id, fresh_process = Client_processes_user.assert_process () in
    if fresh_process then
      ignore {unit{
        Eliom_client.onload
          (fun () ->
             Lwt_react.E.keep
               (React.E.map
                  (dispatch_chat_event %user)
                  %(Eliom_react.Down.of_react chat_events)))
      }};
    let connected_users_list =
      let onload = {{
        fun ev ->
          reflect_list_signal
            (Html5.Id.get_element %connected_users_list_id)
            (fun other -> [user_list_user_widget %user other])
            (React.S.map (fun users -> User_set.(elements (remove %user users)))
               %connected_users_down)
      }} in
      Html5.Id.create_named_elt ~id:connected_users_list_id
        (Html5.D.ul ~a:Html5.F.([a_class ["users_list"]; a_onload onload]) [])
    in
    let conversations_elt =
      Html5.Id.create_named_elt ~id:conversations_id
        (Html5.D.div
           ~a:Html5.F.([
             a_class ["conversations"];
           ])
           (List.map
              (fun conversation ->
                 conversation_widget user
                   (User_set.remove user conversation.users)
                   conversation
                   [])
              (get_conversations user)))
    in
    Lwt.return Html5.F.(
      html
        (Eliom_tools.Html5.head ~title:"Chat with eliom" ~css:[["chat.css"]] ())
        (body [
          h3 [pcdata "Chat with Eliom"];
          (* FIXME reload does not retain all conversations *)
          (* p [a ~service:Eliom_service.void_coservice' [pcdata "Reload in app"] ()]; *)
          div [
            span [
              b [pcdataf "Hello "];
              user_widget user;
              pcdataf " (at %d)" id;
              pcdata " ";
            ];
            post_form ~a:[a_class ["logout_form"]] ~service:logout_service
              (fun () -> [
                string_input ~input_type:`Submit ~value:"Logout" ();
              ]) ();
          ];
          div [
            b [pcdata "Users "];
            connected_users_list;
            span ~a:[a_class["note"]]
              [ pcdata " (Click one to start a conversation)" ];
          ];
          conversations_elt;
          messages;
        ]))

let disconnected_main_handler () () =
  Lwt.return Html5.F.(
    html
      (Eliom_tools.Html5.head ~title:"Chat with eliom" ~css:[["chat.css"]] ())
      (body [
        h3 [pcdata "Chat with Eliom"];
        div [
          post_form ~xhr:false ~service:login_service
            (fun (username, password) -> [
              string_input ~a:[a_id "name"; a_autofocus `Autofocus; a_placeholder "Name"]
                ~input_type:`Text ~name:username ();
              br ();
              string_input ~a:[a_id "password"; a_placeholder "Password"]
                ~input_type:`Password ~name:password ();
              br ();
              string_input ~input_type:`Submit ~value:"Login" ();
            ] @
            (match Eliom_reference.Volatile.get login_message_eref with
               | Some msg -> [div [pcdata msg]]
               | None -> []))
            ()
        ]
      ]))

module Chat_app =
  Eliom_registration.App
    (struct let application_name = "chat" end)

let () =
  Chat_app.register ~service:main_service
    (get_eref_option_2 user_info_eref disconnected_main_handler connected_main_handler);
  Eliom_registration.Any.register ~service:login_service login_handler;
  Eliom_registration.Any.register ~service:logout_service logout_handler

{client{
  let () =
    Lwt.async_exception_hook :=
      fun exn ->
        debug_exn "Lwt.async_exception_hook" exn;
        alert "Error: %s" (Printexc.to_string exn);
        Eliom_client.exit_to ~service:Eliom_service.void_coservice' () ()
}}
