/*  Part of ClioPatria SeRQL and SPARQL server

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2010, University of Amsterdam,
		   VU University Amsterdam

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

:- module(git,
	  [ git/2,			% +Argv, +Options
	    git_process_output/3,	% +Argv, :OnOutput, +Options
	    git_open_file/4,		% +Dir, +File, +Branch, -Stream
	    git_describe/2,		% -Version, +Options
	    git_remote_url/3,		% +Remote, -URL, +Options
	    git_default_branch/2,	% -DefaultBranch, +Options
	    git_tags_on_branch/3	% +Dir, +Branch, -Tags
	  ]).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(option)).
:- use_module(library(http/dcg_basics)).

:- meta_predicate
	git_process_output(+, 1, +).

/** <module> Run GIT commands
*/

%%	git(+Argv, +Options) is det.
%
%	Run a GIT command.  Defined options:
%
%	  * directory(+Dir)
%	  Execute in the given directory
%	  * output(-Out)
%	  Unify Out with a list of codes representing stdout of the
%	  command.  Otherwise the output is handed to print_message/2
%	  with level =informational=.
%	  * error(-Error)
%	  As output(Out), but messages are printed at level =error=.

git(Argv, Options) :-
	option(directory(Dir), Options, .),
	setup_call_cleanup(process_create(path(git), Argv,
                                          [ stdout(pipe(Out)),
                                            stderr(pipe(Error)),
                                            process(PID),
                                            cwd(Dir)
                                          ]),
                           (   read_stream_to_codes(Out, OutCodes, []),
			       read_stream_to_codes(Error, ErrorCodes, []),
                               process_wait(PID, Status)
                           ),
			   (   close(Out),
			       close(Error)
			   )),
	print_error(ErrorCodes, Options),
	print_output(OutCodes, Options),
	(   Status == exit(0)
	->  true
	;   throw(error(process_error(git(Argv), Status), _))
	).

print_output(OutCodes, Options) :-
	option(output(Codes), Options), !,
	Codes = OutCodes.
print_output(OutCodes, _) :-
	print_message(informational, git(output(OutCodes))).

print_error(OutCodes, Options) :-
	option(error(Codes), Options), !,
	Codes = OutCodes.
print_error(OutCodes, _) :-
	phrase(classify_message(Level), OutCodes, _),
	print_message(Level, git(output(OutCodes))).

classify_message(error) -->
	string(_), "fatal:", !.
classify_message(error) -->
	string(_), "error:", !.
classify_message(warning) -->
	string(_), "warning:", !.
classify_message(informational) -->
	[].


%%	git_process_output(+Argv, :OnOutput, +Options) is det.
%
%	Run a git-command and process the output with OnOutput, which is
%	called as call(OnOutput, Stream).

git_process_output(Argv, OnOutput, Options) :-
	option(directory(Dir), Options, .),
	setup_call_cleanup(process_create(path(git), Argv,
                                          [ stdout(pipe(Out)),
                                            stderr(pipe(Error)),
                                            process(PID),
                                            cwd(Dir)
                                          ]),
                           (   call(OnOutput, Out),
			       read_stream_to_codes(Error, ErrorCodes, []),
                               process_wait(PID, Status)
                           ),
			   (   close(Out),
			       close(Error)
			   )),
	print_error(ErrorCodes, Options),
	(   Status = exit(0)
	->  true
	;   throw(error(process_error(git, Status)))
	).


%%	git_open_file(+GitRepoDir, +File, +Branch, -Stream) is det.
%
%	Open the file File in the given bare GIT repository on the given
%	branch (treeisch).
%
%	@bug	We cannot tell whether opening failed for some reason.

git_open_file(Dir, File, Branch, In) :-
	atomic_list_concat([Branch, :, File], Ref),
	process_create(path(git),
		       [ show, Ref ],
		       [ stdout(pipe(In)),
			 cwd(Dir)
		       ]),
	set_stream(In, file_name(File)).


%%	git_describe(-Version, +Options) is semidet.
%
%	Describe the running version  based  on   GIT  tags  and hashes.
%	Options:
%
%	    * match(+Pattern)
%	    Only use tags that match Pattern (a Unix glob-pattern; e.g.
%	    =|V*|=)
%	    * directory(Dir)
%	    Provide the version-info for a directory that is part of
%	    a GIT-repository.
%	    * commit(+Commit)
%	    Describe Commit rather than =HEAD=
%
%	@see git describe

git_describe(Version, Options) :-
	(   option(match(Pattern), Options)
	->  true
	;   git_version_pattern(Pattern)
	),
	(   option(commit(Commit), Options)
	->  Extra = [Commit]
	;   Extra = []
	),
	option(directory(Dir), Options, .),
	setup_call_cleanup(process_create(path(git),
					  [ 'describe',
					    '--match', Pattern
					  | Extra
					  ],
					  [ stdout(pipe(Out)),
					    stderr(null),
					    process(PID),
					    cwd(Dir)
					  ]),
			   (   read_stream_to_codes(Out, V0, []),
			       process_wait(PID, Status)
			   ),
			   close(Out)),
	Status = exit(0), !,
	atom_codes(V1, V0),
	normalize_space(atom(Plain), V1),
	(   git_is_clean(Dir)
	->  Version = Plain
	;   atom_concat(Plain, '-DIRTY', Version)
	).
git_describe(Version, Options) :-
	option(directory(Dir), Options, .),
	option(commit(Commit), Options, 'HEAD'),
	setup_call_cleanup(process_create(path(git),
					  [ 'rev-parse', '--short',
					    Commit
					  ],
					  [ stdout(pipe(Out)),
					    stderr(null),
					    process(PID),
					    cwd(Dir)
					  ]),
			   (   read_stream_to_codes(Out, V0, []),
			       process_wait(PID, Status)
			   ),
			   close(Out)),
	Status = exit(0),
	atom_codes(V1, V0),
	normalize_space(atom(Plain), V1),
	(   git_is_clean(Dir)
	->  Version = Plain
	;   atom_concat(Plain, '-DIRTY', Version)
	).


:- multifile
	git_version_pattern/1.

git_version_pattern('V*').
git_version_pattern('*').


%%	git_is_clean(+Dir) is semidet.
%
%	True if the given directory is in   a git module and this module
%	is clean. To us, clean only   implies that =|git diff|= produces
%	no output.

git_is_clean(Dir) :-
	setup_call_cleanup(process_create(path(git), ['diff'],
					  [ stdout(pipe(Out)),
					    stderr(null),
					    cwd(Dir)
					  ]),
			   stream_char_count(Out, Count),
			   close(Out)),
	Count == 0.

stream_char_count(Out, Count) :-
	setup_call_cleanup(open_null_stream(Null),
			   (   copy_stream_data(Out, Null),
			       character_count(Null, Count)
			   ),
			   close(Null)).


%%	git_remote_url(+Remote, -URL, +Options) is det.
%
%	URL is the remote (fetch) URL for the given Remote.

git_remote_url(Remote, URL, Options) :-
	git_process_output([remote, show, Remote],
			   read_url("Fetch URL:", URL),
			   Options).

read_url(Tag, URL, In) :-
	repeat,
	    read_line_to_codes(In, Line),
	    (	Line == end_of_file
	    ->	!, fail
	    ;	phrase(url_codes(Tag, Codes), Line)
	    ->	!, atom_codes(URL, Codes)
	    ).

url_codes(Tag, Rest) -->
	whites, string(Tag), whites, string(Rest).


%%	git_default_branch(-BranchName, +Options) is det.
%
%	True if BranchName is the default branch of a repository.

git_default_branch(BranchName, Options) :-
	git_process_output([branch],
			   read_default_branch(BranchName),
			   Options).

read_default_branch(BranchName, In) :-
	repeat,
	    read_line_to_codes(In, Line),
	    (	Line == end_of_file
	    ->	!, fail
	    ;	phrase(default_branch(Codes), Line)
	    ->	!, atom_codes(BranchName, Codes)
	    ).

default_branch(Rest) -->
	"*", whites, string(Rest).


%%	git_tags_on_branch(+Dir, +Branch, -Tags) is det.
%
%	Tags is a list of tags in Branch on the GIT repository Dir, most
%	recent tag first.
%
%	@see Git tricks at http://mislav.uniqpath.com/2010/07/git-tips/

git_tags_on_branch(Dir, Branch, Tags) :-
	git_process_output([ log, '--oneline', '--decorate', Branch ],
			   log_to_tags(Tags),
			   [ directory(Dir) ]).

log_to_tags(Out, Tags) :-
	read_line_to_codes(Out, Line0),
	log_to_tags(Line0, Out, Tags, []).

log_to_tags(end_of_file, _, Tags, Tags) :- !.
log_to_tags(Line, Out, Tags, Tail) :-
	phrase(tags_on_line(Tags, Tail1), Line),
	read_line_to_codes(Out, Line1),
	log_to_tags(Line1, Out, Tail1, Tail).

tags_on_line(Tags, Tail) -->
	string_without(" ", _Hash),
	tags(Tags, Tail),
	skip_rest.

tags(Tags, Tail) -->
	whites,
	"(tag: ",
	string(Codes),
	")", !,
	{ atom_codes(Tag, Codes),
	  Tags = [Tag|Rest]
	},
	tags(Rest, Tail).
tags(Tags, Tags) -->
	skip_rest.

skip_rest(_,_).


		 /*******************************
		 *	      MESSAGES		*
		 *******************************/

:- multifile
	prolog:message//1.

prolog:message(git(output(Codes))) -->
	{ split_lines(Codes, Lines) },
	git_lines(Lines).

git_lines([]) --> [].
git_lines([H|T]) -->
	[ '~s'-[H] ],
	(   {T==[]}
	->  []
	;   [nl], git_lines(T)
	).

split_lines([], []) :- !.
split_lines(All, [Line1|More]) :-
	append(Line1, [0'\n|Rest], All), !,
	split_lines(Rest, More).
split_lines(Line, [Line]).
