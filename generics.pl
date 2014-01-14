:- module(
  generics,
  [
    clean_dom/2, % +DOM:list
                 % -CleanedDOM:list
    ensure_number/2, % +Something:term
                     % -Number:number
    is_empty/1, % +Content:atom
    login_link//0,
    md5/2, % +Unencrypted:or([atom,list(code),string])
           % -Encrypted:or([atom,list(code),string])
    request_to_id/3, % +Request:list
                     % +Kind:oneof([annotation,news,post])
                     % -Id:atom
    request_to_resource/3, % +Request:list
                           % +Kind:oneof([annotation,news,post])
                           % -URL:atom
    sep//0,
    true/1, % +Term
    uri_path/2, % +PathComponents:list(term)
                % -Path:atom
    uri_query_add/4, % +FromURI:uri
                     % +Name:atom
                     % +Value:atom
                     % -ToURI:atom
    wiki_file_codes_to_dom/3 % +Codes:list(code)
                             % +File:atom
                             % -DOM:list
  ]
).

/** <module> Generics

Generic predicates in plweb.
Candidates for placement in some library.

@author Wouter Beek
@version 2013/12-2014/01
*/

:- use_module(library(apply)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_path)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(option)).
:- use_module(library(pldoc/doc_wiki)).
:- use_module(library(semweb/rdf_db)).
:- use_module(library(uri)).
:- use_module(openid).

%! add_option(
%!   +FromOptions:list(nvpair),
%!   +Name:atom,
%!   +Value:atom,
%!   +ToOptions:list(nvpair)
%! ) is det.
% Adds an option with the given name and value (i.e. `Name(Value)`),
%   and ensures that old options are overwritten and
%   that the resultant options list is sorted.

add_option(Os1, N, V, Os2):-
  O =.. [N,V],
  merge_options([O], Os1, Os2).

clean_dom([p(X)], X) :- !.
clean_dom(X, X).

ensure_number(X, X):-
  number(X), !.
ensure_number(X, Y):-
  atom(X), !,
  atom_number(X, Y).

%! is_empty(+Content:atom) is semidet.

is_empty(Content):-
  var(Content), !.
is_empty(Content):-
  normalize_space(atom(''), Content).

login_link -->
  {http_current_request(Request)},
  login_link(Request).

md5(Unencrypted, Encrypted):-
  rdf_atom_md5(Unencrypted, 1, Encrypted).

request_to_id(Request, Kind, Id):-
  memberchk(path(Path), Request),
  atomic_list_concat(['',Kind,Id], '/', Path).

request_to_resource(Request, Kind, URL):-
  request_to_id(Request, Kind, Id),
  Id \== '',
  http_link_to_id(post_process, path_postfix(Id), Link),
  http_absolute_uri(Link, URL).
  %http_absolute_uri(post(Id), URL).

sep -->
  html(span(class(separator), '|')).

true(_).

uri_path(T1, Path):-
  exclude(var, T1, T2),
  atomic_list_concat([''|T2], '/', Path).

%! uri_query_add(+FromURI:uri, +Name:atom, +Value:atom, -ToURI:atom) is det.
% Inserts the given name-value pair as a query component into the given URI.

uri_query_add(URI1, Name, Value, URI2):-
  uri_components(
    URI1,
    uri_components(Scheme, Authority, Path, Search1_, Fragment)
  ),
  (var(Search1_) -> Search1 = '' ; Search1 = Search1_),
  uri_query_components(Search1, SearchPairs1),
  add_option(SearchPairs1, Name, Value, SearchPairs2),
  uri_query_components(Search2, SearchPairs2),
  uri_components(
    URI2,
    uri_components(Scheme, Authority, Path, Search2, Fragment)
  ).

%%	wiki_file_codes_to_dom(+Codes, +File, -DOM)
%
%	DOM is the HTML dom representation for Codes that originate from
%	File.

wiki_file_codes_to_dom(String, File, DOM):-
  nb_current(pldoc_file, OrgFile), !,
  setup_call_cleanup(
    b_setval(pldoc_file, File),
    wiki_codes_to_dom(String, [], DOM),
    b_setval(pldoc_file, OrgFile)
  ).
wiki_file_codes_to_dom(String, File, DOM):-
  setup_call_cleanup(
    b_setval(pldoc_file, File),
    wiki_codes_to_dom(String, [], DOM),
    nb_delete(pldoc_file)
  ).
