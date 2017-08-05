:- module(
  http_client2,
  [
    http_default_port/2, % +Scheme, -DefaultPort
    http_status_label/2  % +Code, -Label
  ]
).
:- reexport(library(http/http_header)).
:- reexport(library(http/http_json)).
:- reexport(library(http/http_path)).
:- reexport(library(http/json)).

/** <module> HTTP Client

@author Wouter Beek
@version 2017/05-2017/07
*/

:- use_module(library(apply)).
:- use_module(library(atom_ext)).
:- use_module(library(call_ext)).
:- use_module(library(dcg/dcg_ext)).
:- use_module(library(debug)).
:- use_module(library(dict_ext)).
:- use_module(library(error)).
:- use_module(library(http/http_client), []).
:- use_module(library(http/http_cookie), []).
:- use_module(library(http/http_exception)).
:- use_module(library(http/http_open), []).
:- use_module(library(http/rfc5988)).
:- use_module(library(http/rfc7230)).
:- use_module(library(http/rfc7231)).
:- use_module(library(http/rfc7232)).
:- use_module(library(http/rfc7233)).
:- use_module(library(http/rfc7234)).
:- use_module(library(http/rfc7235)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(stream_ext)).
:- use_module(library(uri/uri_ext)).

:- dynamic
    http:http_separable/1.

:- meta_predicate
    call_on_http(+, 3, -, +),
    call_on_http_stream(+, 3, +, -, +, +).

:- multifile
    http:http_separable/1,
    http:post_data_hook/3.

:- public
    ssl_verify/5.

ssl_verify(_SSL, _ProblemCertificate, _AllCertificates, _FirstCertificate,
           _Error).





%! http_default_port(+Scheme:oneof([http,https]),
%!                   -DefaultPort:between(0,inf)) is det.

http_default_port(http, 80).
http_default_port(https, 443).



%! call_on_http(+Uri:atom, :Goal_3, -Metadata:list(dict),
%!              +Options:list(compound)) is nondet.
%
% @arg Metadata A list of dictionaries, each of which describing an
%      HTTP(S) request/response interaction as well metadata about the
%      stream.
%
% @arg Options The following options are supported:
%
%   * number_of_hops(+positive_integer)
%
%     The maximum number of consecutive redirects that is followed.
%     The default is 5.
%
%   * number_of_repeats(+positive_integer)
%
%     The maximum number of times the same URI is allowed to be
%     addressed during a redirect cycle.  The default
%     is 2.
%
%   * number_of_retries(+positive_integer)
%
%     The maximum number of times the same HTTP request is retries upon
%     receiving an HTTP error code (i.e., HTTP status codes 400
%     through 599).  The default is 1.
%
%   * Other options are passed to http_open/3 and stream_open/4.

call_on_http(Uri1, Goal_3, Metadata2, Options) :-
  copy_term(Options, Options0),
  option(number_of_hops(MaxHops), Options, 5),
  option(number_of_repeats(MaxRepeats), Options, 2),
  option(number_of_retries(MaxRetries), Options, 1),
  http_open2(Uri1, In, Options, MaxHops, MaxRepeats, 1-MaxRetries, [],
             Metadata0),
  reverse(Metadata0, Metadata1),
  % status code
  [Dict|_] = Metadata1,
  metadata_status_code([Dict], Status),
  between(200, 299, Status),
  % Check whether the body is empty.
  (   % The from-encoding can be determined based on the value of the
      % `Content-Type' header.
      metadata_content_type([Dict], MediaType)
  ->  once(media_type_encoding(MediaType, FromEncoding)),
      merge_options([from_encoding(FromEncoding)], Options, StreamOptions)
  ;   % If there is no `Content-Type' header, the stream must be
      % empty and `Content-Length' -- if present -- must be 0.
      empty_body_warning(In),
      StreamOptions = Options
  ),
  % `Link' reply header
  (   dict_get(link, Dict.headers, Link),
      atom_phrase(link(Uri1,Links), Link),
      once((
        member(link(Uri2,Params), Links),
        memberchk(rel-next, Params)
      ))
  ->  (   call_on_http_stream(In, Goal_3, Metadata1, Metadata2, StreamOptions,
                              Options)
      ;   % Detect cyclic `Link' headers.
          cyclic_link_warning(Uri1, Uri2),
          call_on_http(Uri2, Goal_3, Metadata2, Options0)
      )
  ;   call_on_http_stream(In, Goal_3, Metadata1, Metadata2, StreamOptions,
                          Options)
  ).

call_on_http_stream(In, Goal_3, Metadata1, Metadata3, StreamOptions,
                    Options) :- !,
  call_cleanup(
    (
      stream_ext:call_on_stream(In, Goal_3, Metadata1, Metadata2,
                                StreamOptions),
      stream_hash_metadata(In, Metadata2, Metadata3, Options)
    ),
    close(In)
  ).

empty_body_warning(In) :-
  at_end_of_stream(In), !.
empty_body_warning(_) :-
  print_message(warning, "No `Content-Type' header but non-empty body.").

cyclic_link_warning(Uri, Uri) :- !,
  print_message(warning, pagination_loop(Uri)).
cyclic_link_warning(_, _).

media_type_encoding(media(application/json,_), utf8).
media_type_encoding(media(application/'n-quads',_), utf8).
media_type_encoding(media(application/'n-triples',_), utf8).
media_type_encoding(media(application/'sparql-query',_), utf8).
media_type_encoding(media(application/'x-prolog',_), utf8).
media_type_encoding(media(image/jpeg,_), octet).
media_type_encoding(media(image/png,_), octet).
media_type_encoding(media(text/turtle,_), utf8).
media_type_encoding(media(_,Params), Encoding3) :-
  memberchk(charset-Encoding1, Params), !,
  % @tbd Are values to the `charset' parameter case-insensitive?
  downcase_atom(Encoding1, Encoding2),
  once(translate_encoding(Encoding2, Encoding3)).
media_type_encoding(MediaType, octet) :-
  format(
    string(Msg),
    "Cannot determine encoding for Media Type ~w (assuming octet).",
    [MediaType]
  ),
  print_message(warning, Msg).

translate_encoding('us-ascii', ascii).
translate_encoding('utf-8', utf8).
translate_encoding(Encoding, Encoding).

http_open2(Uri, In2, Options1, MaxHops, MaxRepeats, Retries, Visited,
           [Dict|Dicts]) :-
  debug(http_client, "\n% [REQUEST] ~a", [Uri]),
  (   select_option(status_code(Status), Options1, Options2)
  ->  true
  ;   Options2 = Options1
  ),
  call_statistics(
    http_open1(
      Uri,
      In1,
      [
        authenticate(false),
        cert_verify_hook(cert_accept_any),
        header(location,Location),
        raw_headers(Lines),
        redirect(false),
        status_code(Status),
        timeout(60),
        version(Major-Minor)
      | Options2]
    ),
    walltime,
    Walltime
  ),
  http_lines_pairs0(Lines, Pairs),
  dict_pairs(HeadersDict, Pairs),
  debug(http_client, "\n% [RESPONSE] ~d ~a", [Status,Uri]),
  (debugging(http_client) -> maplist(debug_reply_header, Pairs) ; true),
  Dict = http{
    headers: HeadersDict,
    status: Status,
    uri: Uri,
    version: Major-Minor,
    walltime: Walltime
  },
  http_open2(Uri, In1, Options2, Location, Status, MaxHops, MaxRepeats,
             Retries, Visited, In2, Dicts).


debug_reply_header(Key1-Value) :-
  pp_http_header_key(Key1, Key2),
  debug(http_client, "< ~a: ~a", [Key2,Value]).


pp_http_header_key(Key1, Key2) :-
  atomic_list_concat(Comps1, -, Key1),
  maplist(atom_capitalize, Comps1, Comps2),
  atomic_list_concat(Comps2, -, Key2).


% authentication error
http_open2(_, In, _, _, Status, _, _, _, _, _, []) :-
  Status =:= 401,
  close(In),
  print_message(warning, http_error_code(Status)).
% non-authentication error
http_open2(Uri, In1, Options, _, Status, MaxHops, MaxRepeats,
           NumRetries1-MaxRetries, Visited, In2, Dicts) :-
  between(400, 599, Status), !,
  NumRetries2 is NumRetries1 + 1,
  (   NumRetries2 >= MaxRetries
  ->  print_message(warning, http_error_code(Status)),
      forall(
        read_line_to_atom(In1, Line),
        print_message(warning, Line)
      ),
      close(In1),
      Dicts = []
  ;   http_open2(Uri, In2, Options, MaxHops, MaxRepeats,
                 NumRetries2-MaxRetries, Visited, Dicts)
  ).
% redirect
http_open2(Uri1, In1, Options, Location, Status, MaxHops, MaxRepeats, Retries,
           Visited1, In2, Dicts) :-
  between(300, 399, Status), !,
  close(In1),
  uri_resolve(Location, Uri1, Uri2),
  Visited2 = [Uri2|Visited1],
  (   length(Visited2, NumVisited),
      NumVisited >= MaxHops
  ->  close(In1),
      Dicts = [],
      print_message(warning, http_max_redirect(5,Uri2))
  ;   include(==(Uri2), Visited2, Visited3),
      length(Visited3, NumRepeats),
      NumRepeats >= MaxRepeats
  ->  close(In1),
      Dicts = [],
      print_message(warning, http_redirect_loop(Uri2))
  ;   http_open2(Uri2, In2, Options, MaxHops, MaxRepeats, Retries, Visited2,
                 Dicts)
  ).
% succes
http_open2(_, In, _, _, _, _, _, _, _, In, []).


http_lines_pairs0(Lines, MergedPairs) :-
  maplist(http_parse_header_pair0, Lines, Pairs),
  keysort(Pairs, SortedPairs),
  group_pairs_by_key(SortedPairs, Groups),
  maplist(merge_separable_header, Groups, MergedPairs).


http_parse_header_pair0(Line, Key-Val) :-
  phrase(http_parse_header_simple0(Key, Val), Line).


http_parse_header_simple0(Key, Val) -->
  'field-name'(Key),
  ":",
  'OWS',
  rest(Val0),
  {atom_codes(Val, Val0)}.


%! merge_separable_header(+Pair1:pair(atom,list(term)),
%!                        -Pair2:pair(atom,term)) is det.
%
% Succeeds iff the given HTTP Key is separable.
%
% “Multiple message-header fields with the same field-name MAY be
% present in a message if and only if the entire field-value for that
% header field is defined as a comma-separated list [i.e., #(values)].
% It MUST be possible to combine the multiple header fields into one
% "field-name: field-value" pair, without changing the semantics of
% the message, by appending each subsequent field-value to the first,
% each separated by a comma.  The order in which header fields with
% the same field-name are received is therefore significant to the
% interpretation of the combined field value, and thus a proxy MUST
% NOT change the order of these field values when a message is
% forwarded.”

merge_separable_header(Key-[Val], Key-Val) :- !.
merge_separable_header(Key-Vals, Key-Val) :-
  http:http_separable(Key), !,
  atomic_list_concat(Vals, ', ', Val).
merge_separable_header(Key-[H|T], Key-H) :-
  print_message(warning, http_nonseparable(Key,[H|T])).


% COPIED FROM swipl-devel/packages/http/http_open %
http_open1(Uri, In, QOptions) :-
  meta_options(http_open:is_meta, QOptions, Options),
  (atomic(Uri) -> http_open:parse_url_ex(Uri, Parts) ; Parts = Uri),
  http_open:autoload_https(Parts),
  http_open:add_authorization(Parts, Options, Options1),
  findall(HostOptions, http:open_options(Parts, HostOptions), AllHostOptions),
  foldl(http_open:merge_options_rev, AllHostOptions, Options1, Options2),
  (   option(bypass_proxy(true), Options)
  ->  try_http_proxy(direct, Parts, In, Options2)
  ;   term_variables(Options2, Vars2),
      findall(Result-Vars2, try_a_proxy(Parts, Result, Options2), ResultList),
      last(ResultList, Status-Vars2)
  ->  (   Status = true(_Proxy, In)
      ->  true
      ;   throw(error(proxy_error(tried(ResultList)), _))
      )
  ;   try_http_proxy(direct, Parts, In, Options2)
  ).


try_a_proxy(Parts, Result, Options) :-
  http_open:parts_uri(Parts, AtomicUri),
  option(host(Host), Parts),
  (   (   option(proxy(ProxyHost:ProxyPort), Options)
      ;   is_list(Options),
          memberchk(proxy(ProxyHost,ProxyPort), Options)
      )
  ->  Proxy = proxy(ProxyHost, ProxyPort)
  ;   socket:proxy_for_url(AtomicUri, Host, Proxy)
  ),
  debug(http(proxy), "http_open: Connecting via ~w to ~w", [Proxy,AtomicUri]),
    (   catch(try_http_proxy(Proxy, Parts, In, Options), E, true)
    ->  (var(E) -> !, Result = true(Proxy, In) ; Result = error(Proxy, E))
    ;   Result = false(Proxy)
    ),
    debug(http(proxy), "http_open: ~w: ~p", [Proxy,Result]).


try_http_proxy(Method, Parts, In, Options0) :-
    option(host(Host), Parts),
    (   Method == direct
    ->  http_open:parts_request_uri(Parts, RequestUri)
    ;   http_open:parts_uri(Parts, RequestUri)
    ),
    select_option(visited(Visited0), Options0, OptionsV, []),
    Options = [visited([Parts|Visited0])|OptionsV],
    http_open:parts_scheme(Parts, Scheme),
    http_open:default_port(Scheme, DefPort),
    http_open:url_part(port(Port), Parts, DefPort),
    http_open:host_and_port(Host, DefPort, Port, HostPort),
    (   option(connection(Connection), Options0),
        http_open:keep_alive(Connection),
        http_open:get_from_pool(Host:Port, InPair),
        debug(http(connection), "Trying Keep-alive to ~p using ~p", [Host:Port,
                                                                     InPair]),
        catch(
          send_rec_header(InPair, In, HostPort, RequestUri, Parts, Options),
          error(E,_),
          http_open:keep_alive_error(E)
        )
    ->  true
    ;   http:http_connection_over_proxy(Method, Parts, Host:Port, SocketInPair,
                                        Options, Options1),
        (   catch(
              http:http_protocol_hook(Scheme, Parts, SocketInPair, InPair,
                                      Options),
              E,
              (close(SocketInPair, [force(true)]), throw(E))
            )
        ->  true
        ;   InPair = SocketInPair
        ),
        send_rec_header(InPair, In, HostPort, RequestUri, Parts, Options1)
    ),
    http_open:return_final_url(Options).


send_rec_header(InPair, In, Host, RequestUri, Parts, Options) :-
  (   catch(
        guarded_send_rec_header(InPair, In, Host, RequestUri, Parts, Options),
        E,
        true
      )
  ->  (   var(E)
      ->  (option(output(InPair), Options) -> true ; true)
      ;   close(InPair, [force(true)]),
          throw(E)
      )
  ;   close(InPair, [force(true)]),
      fail
  ).


guarded_send_rec_header(InPair, In, Host, RequestUri, Parts, Options) :-
  http_open:user_agent(Agent, Options),
  http_open:method(Options, Method),
  http_open:http_version(Version),
  option(connection(Connection), Options, close),
  debug(http(send_request), "> ~w ~w HTTP/~w", [Method,RequestUri,Version]),
  debug(http(send_request), "> Host: ~w", [Host]),
  debug(http(send_request), "> User-Agent: ~w", [Agent]),
  debug(http(send_request), "> Connection: ~w", [Connection]),
  format(
    InPair,
    "~w ~w HTTP/~w\r\nHost: ~w\r\nUser-Agent: ~w\r\nConnection: ~w\r\n",
    [Method,RequestUri,Version,Host,Agent,Connection]
  ),
  http_open:parts_uri(Parts, Uri),
  http_open:x_headers(Options, Uri, InPair),
  http_open:write_cookies(InPair, Parts, Options),
  (   option(post(PostData), Options)
  ->  http_header:http_post_data(PostData, InPair, [])
  ;   format(InPair, "\r\n", [])
  ),
  flush_output(InPair),
  http_open:read_header(InPair, Parts, ReplyVersion, Code, Comment, Lines),
  http_open:update_cookies(Lines, Parts, Options),
  ignore(option(raw_headers(Lines), Options)),
  http_open:do_open(ReplyVersion, Code, Comment, Lines, Options, Parts, Host,
                    InPair, In).


http:post_data_hook(string(String), Out, HdrExtra) :-
  atom_string(Atom, String),
  http_header:http_post_data(atom(Atom), Out, HdrExtra).
http:post_data_hook(string(MediaType,String), Out, HdrExtra) :-
  atom_string(Atom, String),
  http_header:http_post_data(atom(MediaType,Atom), Out, HdrExtra).



%! http_status_label(+Code:between(100,599), -Label:atom) is det.

http_status_label(Code, Label):-
  http_header:status_number_fact(Fact, Code),
  string_phrase(http_header:status_comment(Fact), Label).





% MESSAGES %

:- multifile
    prolog:message//1.

prolog:message(http_error_code(Code)) -->
  {http_status_label(Code, Label)}, !,
  ["HTTP error code ~d (~s)."-[Code,Label]].