/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2013, VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(pack,
	  [ pack/1,			% ?Pack
	    pack_version_hashes/2,	% +Pack, -VersionHashesPairs
	    pack_version_urls/2,	% +Pack, -VersionUrlPairs
	    hash_git_url/2,		% +Hash, -URL
	    pack_url_hash/2,		% +URL, -SHA1

	    current_pack/2,		% +Filter, -Pack
	    sort_packs/3,		% +By, +Packs, -Sorted
	    pack_table//2		% +Packs, +Options
	  ]).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_client)).
:- use_module(library(http/html_write)).
:- use_module(library(http/html_head)).
:- use_module(library(persistency)).
:- use_module(library(aggregate)).
:- use_module(library(memfile)).
:- use_module(library(record)).
:- use_module(library(pairs)).

:- use_module(pack_info).
:- use_module(review).
:- use_module(openid).

:- http_handler(root(pack/query),	 pack_query,	    []).
:- http_handler(root(pack/list),	 pack_list,	    []).
:- http_handler(root(pack/file_details), pack_file_details, [prefix]).

%%	pack_query(+Request)
%
%	Handle package query requests from remote installers.  Content
%	is of type text/x-prolog.   Reply is also a Prolog term.

pack_query(Request) :-
	memberchk(content_type(ContentType), Request),
	sub_atom(ContentType, 0, _, _, 'text/x-prolog'), !,
	peer(Request, Peer),
	setup_call_cleanup(
	    new_memory_file(MemFile),
	    ( setup_call_cleanup(
		  open_memory_file(MemFile, write, Stream),
		  http_read_data(Request, _, [to(stream(Stream))]),
		  close(Stream)),
	      setup_call_cleanup(
		  open_memory_file(MemFile, read, In),
		  read(In, Query),
		  close(In))
	    ),
	    free_memory_file(MemFile)),
	(   catch(pack_query(Query, Peer, Reply), E, true)
	->  format('Content-type: text/x-prolog; charset=UTF8~n~n'),
	    (   var(E)
	    ->	format('~q.~n', [true(Reply)])
	    ;	format('~q.~n', [exception(E)])
	    )
	;   format('Content-type: text/x-prolog; charset=UTF8~n~n'),
	    format('false.~n')
	).

peer(Request, Peer) :-
	memberchk(x_forwarded_for(Peer), Request), !.
peer(Request, PeerAtom) :-
	memberchk(peer(Peer), Request),
	peer_to_atom(Peer, PeerAtom).

peer_to_atom(ip(A,B,C,D), Atom) :-
	atomic_list_concat([A,B,C,D], '.', Atom).

%%	pack_query(+Query, +Peer, -Reply)
%
%	Implements  the  various  queries    from   the  pack_install/1.
%	Currently defined Query values are:
%
%	  * install(+URL, +SHA1, +Info)
%	  User tries to install from URL an object with the indicated
%	  hash and Info.
%	  * locate(+Pack)
%	  Query download locations for Pack.  Same as
%	  locate(archive, Pack).
%	  * search(+Keyword)
%	  Find packs that match Keyword.

pack_query(install(URL, SHA1, Info), Peer, Reply) :-
	with_mutex(pack, save_request(URL, SHA1, Info, Peer)),
	findall(ReplyInfo, install_info(URL, SHA1, ReplyInfo, []), Reply).
pack_query(locate(Pack), _, Reply) :-
	pack_version_urls(Pack, Reply).
pack_query(search(Word), _, Reply) :-
	search_packs(Word, Reply).


		 /*******************************
		 *	COMPUTATIONAL LOGIC	*
		 *******************************/

%%	install_info(+URL, +SHA1, -Info, +Seen) is nondet.
%
%	Info is relevant information  for  the   client  who  whishes to
%	install URL, which has the given   SHA1 hash. Currently provided
%	info is:
%
%	  - alt_hash(Downloads, URLs, Hash)
%	    Another file with the same (base) name was registered that
%	    has a different hash.  This file was downloaded Downloads
%	    times, resides on the given URLs (a list) and has the given
%	    Hash.
%	  - downloads(Downloads)
%	    This hash was downloaded Downloads times from a unique IP
%	    address
%	  - dependency(Token, Pack, Version, URLs, SubSeps)
%	    The requirement Token can be provided by Pack@Version, which
%	    may be downloaded from the given URLs (a list).  Pack has
%	    install info as specified by SubSeps (recursive
%	    dependencies)

install_info(_, SHA1, _, Seen) :-
	memberchk(SHA1, Seen), !, fail.
install_info(URL, SHA1, alt_hash(Downloads, URLs, Hash), _) :-
	file_base_name(URL, File),
	sha1_file(Hash, File),
	Hash \== SHA1,
	sha1_downloads(Hash, Downloads),
	sha1_urls(Hash, URLs).
install_info(_, SHA1, downloads(Count), _) :-
	sha1_downloads(SHA1, Count).
install_info(_, SHA1, dependency(Token, Pack, Version, URLs, SubDeps), Seen) :-
	sha1_requires(SHA1, Token),
	(   (   sha1_pack(Hash, Token),
		Pack = Token
	    ;	sha1_provides(Hash, Token),
		sha1_pack(Hash, Pack),
		Pack \== Token
	    ),
	    sha1_info(Hash, Info),
	    memberchk(version(Version), Info),
	    findall(URL, sha1_url(Hash, URL), URLs)
	*-> findall(SubDep, install_info(-, Hash, SubDep, [SHA1|Seen]), SubDeps)
	;   Pack = (-), Version = (-), URLs = []
	).

sha1_downloads(Hash, Count) :-
	aggregate_all(count, sha1_download(Hash, _), Count).

sha1_urls(Hash, URLs) :-
	findall(URL, sha1_url(Hash, URL), URLs).

sha1_version(Hash, Version) :-
	sha1_info(Hash, Info),
	memberchk(version(Atom), Info),
	prolog_pack:atom_version(Atom, Version).

sha1_title(Hash, Title) :-
	sha1_info(Hash, Info),
	(   memberchk(title(Title), Info)
	->  true
	;   Title = '<no title>'
	).

%%	pack_version_hashes(+Pack, -VersionHashesPairs) is semidet.
%
%	True when HashesByVersion is  an   ordered  list Version-Hashes,
%	latest version first.

pack_version_hashes(Pack, VersionAHashesPairs) :-
	setof(SHA1, sha1_pack(SHA1, Pack), Hashes),
	map_list_to_pairs(sha1_version, Hashes, VersionHashPairs),
	keysort(VersionHashPairs, Sorted),
	group_pairs_by_key(Sorted, VersionHashesPairs),
	reverse(VersionHashesPairs, RevPairs),
	maplist(atomic_version_hashes, RevPairs, VersionAHashesPairs).

atomic_version_hashes(Version-Hashes, VersionA-Hashes) :-
	prolog_pack:atom_version(VersionA, Version).

%%	pack_version_urls(+Pack, -Locations) is nondet.
%
%	True when Locations is a set of Version-list(URL) pairs used for
%	installing Pack.
%
%	@param	Locations is a list Version-URLs, sorted latest version
%		first.
%	@tbd	Handle versions with multiple hashes!

pack_version_urls(Pack, VersionURLs) :-
	pack_version_hashes(Pack, VersionHashes),
	maplist(version_hashes_urls, VersionHashes, VersionURLs).

version_hashes_urls(Version-Hashes, Version-URLs) :-
	maplist(sha1_url, Hashes, URLs0),
	sort(URLs0, URLs).


%%	search_packs(+Search, -Packs) is det.
%
%	Search packs by keyword, returning a list
%
%		pack(Pack, Status, Version, Title, URLs).

search_packs(Search, Packs) :-
	setof(Pack, matching_pack(Search, Pack), Names), !,
	maplist(pack_search_result, Names, Packs).

matching_pack(Search, Pack) :-
	sha1_pack(SHA1, Pack),
	(   '$apropos_match'(Search, Pack)
	->  true
	;   sha1_title(SHA1, Title),
	    '$apropos_match'(Search, Title)
	).

pack_search_result(Pack, pack(Pack, p, Title, VersionA, URLs)) :-
	pack_latest_version(Pack, SHA1, Version, _Older),
	sha1_title(SHA1, Title),
	prolog_pack:atom_version(VersionA, Version),
	findall(URL, sha1_url(SHA1, URL), URLs).


		 /*******************************
		 *	     DATABASE		*
		 *******************************/

:- persistent
	sha1_pack(sha1:atom, pack:atom),
	sha1_file(sha1:atom, file:atom),
	sha1_requires(sha1:atom, token:atom),
	sha1_provides(sha1:atom, token:atom),
	sha1_info(sha1:atom, info:list),
	sha1_url(sha1:atom, url:atom),
	sha1_download(sha1:atom, peer:atom).

:- initialization
	db_attach('packs.db', []).

%%	save_request(+URL, +SHA1, +Info, +Peer)
%
%	Update the database with the given   information. We only update
%	if the request is new, which means   the  same SHA1 has not been
%	downloaded from the same Peer.

save_request(URL, SHA1, Info, Peer) :-
	sha1_download(SHA1, Peer), !,		% already downloaded from here
	info_is_git(Info, IsGIT),
	register_url(SHA1, IsGIT, URL).		% but maybe from a different URL
save_request(URL, SHA1, Info, Peer) :-
	memberchk(name(Pack), Info),
	info_is_git(Info, IsGIT),
	register_url(SHA1, IsGIT, URL),
	register_pack(SHA1, Pack),
	register_info(SHA1, Info),
	assert_sha1_download(SHA1, Peer).

info_is_git(Info, IsGIT) :-
	memberchk(git(IsGIT), Info), !.
info_is_git(_, false).


register_pack(SHA1, Pack) :-
	(   sha1_pack(SHA1, Pack)
	->  true
	;   assert_sha1_pack(SHA1, Pack)
	).

register_info(SHA1, Info0) :-
	sort(Info0, Info),
	(   sha1_info(SHA1, _Info)
	->  true
	;   assert_sha1_info(SHA1, Info),
	    forall(member(requires(Token), Info),
		   register_requires(SHA1, Token)),
	    forall(member(provides(Token), Info),
		   register_provides(SHA1, Token))
	).

register_requires(SHA1, Token) :-
	(   sha1_requires(SHA1, Token)
	->  true
	;   assert_sha1_requires(SHA1, Token)
	).

register_provides(SHA1, Token) :-
	(   sha1_provides(SHA1, Token)
	->  true
	;   assert_sha1_provides(SHA1, Token)
	).

register_url(SHA1, IsGIT, URL) :-
	(   sha1_url(SHA1, URL)
	->  true
	;   sha1_url(SHA2, URL),
	    \+ ( IsGIT == true,
		 hash_git_url(SHA2, URL)
	       )
	->  throw(pack(modified_hash(SHA1-URL, SHA2-[URL])))
	;   IsGIT == true
	->  assert_sha1_url(SHA1, URL)
	;   file_base_name(URL, File),
	    register_file(SHA1, File, URL),
	    assert_sha1_url(SHA1, URL)
	).

register_file(SHA1, File, URL) :-
	(   sha1_file(SHA1, File)
	->  true
	;   sha1_file(SHA2, File),
	    sha1_urls(SHA2, URLs)
	->  throw(pack(modified_hash(SHA1-URL, SHA2-URLs)))
	;   assert_sha1_file(SHA1, File)
	).

%%	hash_git_url(+SHA1, -GitURL) is semidet.
%
%	True when SHA1 was installed using GIT from GitURL.

hash_git_url(SHA1, GitURL) :-
	sha1_info(SHA1, Info),
	memberchk(git(true), Info), !,
	sha1_url(SHA1, GitURL).


%%	pack_url_hash(?URL, ?Hash) is nondet.
%
%	True when Hash is the registered hash for URL.

pack_url_hash(URL, Hash) :-
	sha1_url(Hash, URL).

%%	pack(?Pack) is nondet.
%
%	True when Pack is a currently known pack.

pack(Pack) :-
	findall(Pack, sha1_pack(_,Pack), Packs),
	sort(Packs, Sorted),
	member(Pack, Sorted).


		 /*******************************
		 *	     USER API		*
		 *******************************/

%%	pack_list(+Request)
%
%	List available packages.

pack_list(Request) :-
	http_parameters(Request,
			[ p(Pack, [optional(true)]),
			  author(Author, [optional(true)]),
			  sort(Sort, [ oneof([name,downloads,rating]),
				       optional(true),
				       default(name)
				     ])
			]),
	reply_html_page(wiki,
			title('SWI-Prolog packages'),
			[ \pack_listing(Pack, Author, Sort)
			]).

pack_listing(Pack, _Author, _Sort) -->
	{ ground(Pack) }, !,
	html([ h1(class(wiki), 'Package "~w"'-[Pack]),
	       \html_requires(css('pack.css')),
	       \pack_info(Pack)
	     ]).
pack_listing(_Pack, Author, SortBy) -->
	{ (   nonvar(Author)
	  ->  Filter = [author(Author)]
	  ;   Filter = []
	  ),
	  (   setof(Pack, current_pack(Filter, Pack), Packs)
	  ->  true
	  ;   Packs = []
	  ),
	  sort_packs(SortBy, Packs, Sorted)
	},
	html([ h1(class(wiki), 'Available packages'),
	       p([ 'Below is a list of known packages.  Please be aware that ',
		   'packages are ', b('not moderated'), '. Installing a pack ',
		   ' does not execute code in the pack, but simply loading a ',
		   'library from the pack may execute arbitrary code. ',
		   'More information about packages is available ',
		   a(href('http://www.swi-prolog.org/howto/Pack.html'), here),
		   '.'
		 ]),
	       p([ 'Clicking the package shows details and allows you to ',
		   'rate and comment the pack.'
		 ])
	     ]),
	pack_table(Sorted, [sort_by(SortBy)]),
	html_receive(rating_scripts).

%%	pack_table(+Packs, +Options)// is det.
%
%	Show a table of packs.

pack_table(Packs, Options) -->
	{ option(sort_by(SortBy), Options, -)
	},
	html_requires(css('pack.css')),
	html(table(class(packlist),
		   [ tr([ \pack_header(name,  SortBy,
				       'Pack', []),
			  \pack_header(version, SortBy,
				       'Version', '(#older)'),
			  \pack_header(downloads, SortBy,
				       'Downloads', '(#latest)'),
			  \pack_header(rating, SortBy,
				       'Rating', ['(#votes/', br([]),
						  '#comments)']),
			  \pack_header(title, SortBy,
				       'Title', [])
			])
		   | \pack_rows(Packs)
		   ])).


pack_rows([]) --> [].
pack_rows([H|T]) --> pack_row(H), pack_rows(T).

pack_row(Pack) -->
	{ pack_name(Pack, Name),
	  http_link_to_id(pack_list, [p(Name)], HREF)
	},
	html(tr([ td(a(href(HREF),Name)),
		  td(\pack_version(Pack)),
		  td(\pack_downloads(Pack)),
		  td(\pack_rating(Pack)),
		  td(\pack_title(Pack))
		])).

pack_header(Name, -, Title, Subtitle) --> !,
	html(th(id(Name), [Title, \subtitle(Subtitle)])).
pack_header(Name, SortBy, Title, Subtitle) -->
	{ Name \== SortBy,
	  sortable(Name), !,
	  http_link_to_id(pack_list, [sort(Name)], HREF)
	},
	html(th(id(Name), [a(href(HREF), Title), \subtitle(Subtitle)])).
pack_header(Name, Name, Title, Subtitle) -->
	html(th(id(Name), [i(Title), \subtitle(Subtitle)])).
pack_header(Name, _, Title, Subtitle) -->
	html(th(id(Name), [Title, \subtitle(Subtitle)])).

subtitle([]) --> [].
subtitle(Subtitle) --> html(div(class(sth), Subtitle)).


sortable(name).
sortable(downloads).
sortable(rating).

pack_version(Pack) -->
	{ pack_version(Pack, Version),
	  pack_older_versions(Pack, Older),
	  prolog_pack:atom_version(Atom, Version)
	},
	(   { Older =\= 0 }
	->  html([Atom, span(class(annot), '~D'-[Older])])
	;   html(Atom)
	).

pack_downloads(Pack) -->
	{ pack_downloads(Pack, Total),
	  pack_download_latest(Pack, DownLoadLatest)
	},
	(   { Total =:= DownLoadLatest }
	->  html('~D'-[Total])
	;   html(['~D'-[Total], span(class(annot), '~D'-[DownLoadLatest])])
	).

pack_rating(Pack) -->
	{ pack_rating(Pack, Rating),
	  pack_votes(Pack, Votes),
	  pack_comments(Pack, CommentCount),
	  pack_name(Pack, Name),
	  http_link_to_id(pack_rating, [], OnRating)
	},
	show_pack_rating(Name, Rating, Votes, CommentCount,
			 [ on_rating(OnRating)
			 ]).

pack_title(Pack) -->
	{ pack_hash(Pack, SHA1),
	  sha1_title(SHA1, Title)
	},
	html(Title).

:- record
	pack(name:atom,				% Name of the pack
	     hash:atom,				% SHA1 of latest version
	     version:list(integer),		% Latest Version
	     older_versions:integer,		% # older versions
	     downloads:integer,			% Total downloads
	     download_latest:integer,		% # downloads latest version
	     rating:number,			% Average rating
	     votes:integer,			% Vote count
	     comments:integer).			% Comment count

%%	current_pack(+Filter:list, -Pack) is nondet.
%
%	True when Pack is a pack that satisfies Filter. Filter is a list
%	of filter expressions. Currently defined filters are:
%
%	  * author(+Author)
%	  Pack is claimed by this author.

current_pack(Filters,
	     pack(Pack, SHA1,
		  Version, OlderVersionCount,
		  Downloads, DLLatest,
		  Rating, Votes, CommentCount)) :-
	setof(Pack, H^sha1_pack(H,Pack), Packs),
	member(Pack, Packs),
	pack_latest_version(Pack, SHA1, Version, OlderVersionCount),
	maplist(pack_filter(SHA1), Filters),
	pack_downloads(Pack, SHA1, Downloads, DLLatest),
	pack_rating_votes(Pack, Rating, Votes),
	pack_comment_count(Pack, CommentCount).

pack_filter(SHA1, author(Author)) :-
	sha1_info(SHA1, Info),
	member(author(Name, Contact), Info),
	author_match(Author, Name, Contact).

author_match(Author, Author, _).
author_match(Author, _, Author).
author_match(UUID, Name, Contact) :-
	site_user_property(UUID, name(Name)),
	site_user_property(UUID, email(Contact)).


%%	sort_packs(+Field, +Packs, -Sorted)

sort_packs(By, Packs, Sorted) :-
	map_list_to_pairs(pack_data(By), Packs, Keyed),
	keysort(Keyed, KeySorted),
	pairs_values(KeySorted, Sorted0),
	reverse_sort(By, Sorted0, Sorted).

reverse_sort(name, Packs, Packs) :- !.
reverse_sort(_, Packs, RevPacks) :-
	reverse(Packs, RevPacks).


pack_downloads(Pack, SHA1, Total, DownLoadLatest) :-
	setof(Hash, sha1_pack(Hash, Pack), Hashes),
	map_list_to_pairs(sha1_downloads, Hashes, Pairs),
	memberchk(DownLoadLatest-SHA1, Pairs),
	pairs_keys(Pairs, Counts),
	sum_list(Counts, Total).

%%	pack_latest_version(+Pack, -SHA1, -Version, -OlderCount)
%
%	True when SHA1 is the  latest  version   of  Pack  at  the given
%	Version and there are OlderCount older versions.

pack_latest_version(Pack, SHA1, Version, Older) :-
	setof(SHA1, sha1_pack(SHA1, Pack), Hashes),
	map_list_to_pairs(sha1_version, Hashes, Versions),
	keysort(Versions, Sorted),
	length(Sorted, Count),
	Older is Count - 1,
	last(Sorted, Version-SHA1).


		 /*******************************
		 *	  DETAILED INFO		*
		 *******************************/

%%	pack_info(+Pack)//
%
%	Provided detailed information about a package.
%
%	@tbd	provide many more details
%	@tbd	Show dependency for requirements/provides

pack_info(Pack) -->
	{ \+ pack(Pack) }, !,
	html(p(class(warning),
	       'Sorry, I know nothing about a pack named "~w"'-[Pack])).
pack_info(Pack) -->
	pack_info_table(Pack),
	pack_reviews(Pack),
	pack_file_table(Pack),
	( pack_readme(Pack) -> [] ; [] ),
	(   pack_file_hierarchy(Pack)
	->  []
	;   html(p(class(warning), 'Failed to process pack'))
	).

%%	pack_info_table(+Pack)// is det.
%
%	Provide basic information on the package

pack_info_table(Pack) -->
	{ pack_latest_version(Pack, SHA1, Version, _Older),
	  prolog_pack:atom_version(VersionA, Version),
	  sha1_title(SHA1, Title),
	  sha1_info(SHA1, Info)
	},
	html(table(class(pack),
		   [ \property('Title', span(class(title), Title)),
		     \property('Rating', \show_pack_rating(Pack)),
		     \property('Latest version', VersionA),
		     \property('SHA1 sum', \hash(SHA1)),
		     \info(author(_,_), Info),
		     \info(maintainer(_,_), Info),
		     \info(packager(_,_), Info),
		     \info(home(_), Info),
		     \info(download(_), Info),
		     \info(requires(_), Info),
		     \info(provides(_), Info),
		     \info(conflicts(_), Info)
		   ])).

property(Label, Value) -->
	html(tr([th([Label, :]), td(Value)])).

info(Term, Info) -->
	{ findall(Term, member(Term, Info), [T0|More]), !
	},
	html(tr([th([\label(T0), :]), td(\value(T0))])),
	extra_values(More).
info(_, _) --> [].

extra_values([]) --> [].
extra_values([H|T]) -->
	html(tr([th([]), td(\value(H))])),
	extra_values(T).

label(Term) -->
	{ prolog_pack:pack_level_info(_, Term, LabelFmt, _),
	  (   LabelFmt = Label-_
	  ->  true
	  ;   Label = LabelFmt
	  )
	},
	html(Label).

value(Term) -->
	{ name_address(Term, Name, Address) }, !,
	html([span(class(name), Name), ' ']),
	address(Address).
value(Term) -->
	{ url(Term, Label, URL) },
	html(a(href(URL), Label)).
value(Term) -->
	{ prolog_pack:pack_level_info(_, Term, LabelFmt, _),
	  (   LabelFmt = _-Fmt
	  ->  true
	  ;   Fmt = '~w'
	  ),
	  Term =.. [_|Values]
	},
	html(Fmt-Values).

address(Address) -->
	{ sub_atom(Address, _, _, _, @) }, !,
	html(['<', Address, '>']).
address(URL) -->
	html(a(href(URL), URL)).

name_address(author(    Name, Address), Name, Address).
name_address(maintainer(Name, Address), Name, Address).
name_address(packager(  Name, Address), Name, Address).

url(home(URL), URL, URL).
url(download(Pattern), Pattern, URL) :-
	(   wildcard_pattern(Pattern)
	->  file_directory_name(Pattern, Dir),
	    ensure_slash(Dir, URL)
	;   URL = Pattern
	).

wildcard_pattern(URL) :- sub_atom(URL, _, _, _, *).
wildcard_pattern(URL) :- sub_atom(URL, _, _, _, ?).

ensure_slash(Dir, DirS) :-
	(   sub_atom(Dir, _, _, 0, /)
	->  DirS = Dir
	;   atom_concat(Dir, /, DirS)
	).

%%	pack_file_table(+Pack)// is det.
%
%	Provide a table with the files, sorted by version, providing
%	statistics on downloads.

pack_file_table(Pack) -->
	{ setof(Version-Hash, pack_version_hash(Pack, Hash, Version), Pairs),
	  group_pairs_by_key(Pairs, Grouped)
	},
	html(h2(class(wiki), 'Details by download location')),
	html(table(class(pack_file_table),
		   [ tr([th('Version'), th('SHA1'), th('#Downloads'), th('URL')])
		   | \pack_file_rows(Grouped)
		   ])).

pack_file_rows([]) --> [].
pack_file_rows([H|T]) --> pack_file_row(H), pack_file_rows(T).

pack_file_row(Version-[H0|Hashes]) -->
	{ sha1_downloads(H0, Count),
	  sha1_urls(H0, [URL|URLs])
	},
	html(tr([ td(\version(Version)),
		  td(\hash(H0)),
		  \count(Count),
		  td(\download_url(URL))
		])),
	alt_urls(URLs),
	alt_hashes(Hashes).

alt_urls([]) --> [].
alt_urls([H|T]) --> alt_url(H), alt_urls(T).

alt_url(H) -->
	html(td([td(''), td(''), td(''), td(\download_url(H))])).

alt_hashes([]) --> [].
alt_hashes([H|T]) --> alt_hash(H), alt_hashes(T).

alt_hash(H) -->
	{ sha1_downloads(H, Count),
	  sha1_urls(H, [URL|URLs])
	},
	html([td(''), td(\hash(H)), \count(Count), td(\download_url(URL))]),
	alt_urls(URLs).

hash(H)		  --> html(span(class(hash), H)).
download_url(URL) --> html(a(href(URL), URL)).
count(N)          --> html(td(class(count), N)).
version(V)        --> { prolog_pack:atom_version(Atom, V) },
		      html(Atom).

pack_version_hash(Pack, Hash, Version) :-
	sha1_pack(Hash, Pack),
	sha1_version(Hash, Version).


%%	pack_file_details(+Request)
%
%	HTTP handler to provide details on a file in a pack

pack_file_details(Request) :-
	memberchk(path_info(SlashPackAndFile), Request),
	\+ sub_atom(SlashPackAndFile, _, _, _, '/../'), !,
	http_parameters(Request,
			[ public_only(Public),
			  show(Show)
			],
			[ attribute_declarations(pldoc_http:param)
			]),
	atom_concat(/, PackAndFile, SlashPackAndFile),
	sub_atom(PackAndFile, B, _, A, /), !,
	sub_atom(PackAndFile, 0, B, _, Pack),
	sub_atom(PackAndFile, _, A, 0, File),
	pack_file_details(Pack, File,
			  [ public_only(Public),
			    show(Show)
			  ]).
