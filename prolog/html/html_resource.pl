:- module(html_resource, []).
:- reexport(library(http/html_head)).

/** <module> HTML resource

Initialize locations for serving HTML resources.

@author Wouter Beek
@version 2015/08
*/

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_server_files)).

:- dynamic(user:file_search_path/2).
:- multifile(user:file_search_path/2).

user:file_search_path(css, library(resource/css)).
user:file_search_path(icon, library(resource/icon)).
user:file_search_path(img, library(resource/img)).
user:file_search_path(js, library(resource/js)).

:- dynamic(http:location/3).
:- multifile(http:location/3).

http:location(css, root(css), []).
http:location(icon, root(icon), []).
http:location(img, root(img), []).
http:location(js, root(js), []).

:- http_handler(css(.), serve_files_in_directory(css), [prefix]).
:- http_handler(icon(.), serve_files_in_directory(icon), [prefix]).
:- http_handler(img(.), serve_files_in_directory(img), [prefix]).
:- http_handler(js(.), serve_files_in_directory(js), [prefix]).
