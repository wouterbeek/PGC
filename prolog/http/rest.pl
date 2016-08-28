:- module(
  rest,
  [
    rest_exception/2,  % +MTs, +E
    rest_media_type/3, % +Req, +MTs, :Plural_1
    rest_media_type/4, % +Req, +MTs, +HandleId, Singular_2
    rest_media_type/5, % +Req, +MTs, Plural_1, +HandleId, Singular_2
    rest_method/3      % +Req, +Methods, :Goal_3
  ]
).

/** <module> REST

@author Wouter Beek
@version 2016/02, 2016/04-2016/06, 2016/08
*/

:- use_module(library(http/html_write)). % HTML meta.
:- use_module(library(http/http_ext)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(http/http_write)).
:- use_module(library(http/json)).
:- use_module(library(iri/iri_ext)).
:- use_module(library(lists)).

:- html_meta
   rest_media_type(+, +, 1),
   rest_media_type(+, +, +, 2),
   rest_media_type(+, +, 1, +, 2),
   rest_method(+, +, 3),
   rest_method(+, +, +, 3).





%! rest_exception(+MT, +E) is det.
%! rest_exception(+Req, +MTs, +E) is det.

rest_exception(MT, E) :-
  http_current_request(Req),
  rest_exception(Req, [MT], E).


rest_exception(Req, MTs, error(E,_)) :- !,
  rest_exception(Req, MTs, E).
rest_exception(Req, MTs, E) :-
  member(MT, MTs),
  rest_exception_media_type(Req, MT, E), !.



% HTML errors are already generated by default.
rest_exception_media_type(_, text/html, 401) :-
  http_status_reply(authorise(basic,'')).
rest_exception_media_type(_, text/html, bad_request(E)) :-
  http_status_reply(bad_request(E)).
rest_exception_media_type(_, text/html, E) :-
  throw(E).
% 400 “Bad Request”
rest_exception_media_type(Req, MT, existence_error(http_parameter,Key)) :- !,
  (   MT == application/json
  ->  Headers = ['Content-Type'-media_type(application/json,[])],
      Dict = _{message: "Missing parameter", value: Key},
      with_output_to(codes(Cs), json_write_dict(current_output, Dict))
  ;   Headers = [],
      Cs = []
  ),
  reply_http_message(Req, 400, Headers, Cs).



%! rest_media_type(+Req, +MTs, :Plural_1) is det.
%! rest_media_type(+Req, +MTs, +HandleId, :Singular_2) is det.
%! rest_media_type(+Req, +MTs, :Plural_1, +HandleId, :Singular_2) is det.
%
% @tbd Add body for 405 code in multiple media types.

% Media type accepted, on to application-specific reply.
rest_media_type(_, MTs, Plural_1) :-
  member(MT, MTs),
  call(Plural_1, MT), !.
% 406 “Not Acceptable”
rest_media_type(Req, _, _) :-
  reply_http_message(Req, 406).


% Media type accepted, on to application-specific reply.
rest_media_type(Req, MTs, HandleId, Singular_2) :-
  http_relative_iri(Req, Iri),
  member(MT, MTs),
  (   http_link_to_id(HandleId, Iri)
  ->  reply_http_message(Req, 404)
  ;   iri_to_resource(Iri, Res),
      call(Singular_2, Res, MT)
  ), !.
% 406 “Not Acceptable”
rest_media_type(Req, _, _, _) :-
  reply_http_message(Req, 406).


% Media type accepted, on to application-specific reply.
rest_media_type(Req, MTs, Plural_1, HandleId, Singular_2) :-
  http_relative_iri(Req, Iri),
  member(MT, MTs),
  (   http_link_to_id(HandleId, Iri)
  ->  call(Plural_1, MT)
  ;   iri_to_resource(Iri, Res),
      call(Singular_2, Res, MT)
  ), !.
% 406 “Not Acceptable”
rest_media_type(Req, _, _, _, _) :-
  reply_http_message(Req, 406).



%! rest_method(+Req, +Methods, :Goal_3) is det.
%
% @tbd Return info for 405 status code.

rest_method(Req, Methods, Goal_3) :-
  memberchk(method(Method), Req),
  rest_method(Req, Method, Methods, Goal_3).


% “OPTIONS”
rest_method(Req, options, Methods1, _) :- !,
  sort([head,options|Methods1], Methods2),
  reply_http_message(Req, 200, ['Allow'-Methods2]).
% Method accepted, on to media types.
rest_method(Req, Method, Methods, Goal_3) :-
  memberchk(Method, Methods), !,
  (   http_location_iri(Req, Iri),
      http_iri_query(Iri, format(MT))
  ->  MTs = [MT]
  ;   http_accept(Req, MTs)
  ),
  catch(call(Goal_3, Req, Method, MTs), E, rest_exception(Req, MTs, E)).
% 405 “Method Not Allowed”
rest_method(Req, _, _, _) :-
  reply_http_message(Req, 405).
