/*- -*- tab-width: 4 -*- -*/
/*-
 *	SQL template for creating PostgreSQL tables
 *	(C) 2012-2016 A. Littoz
 *
 *	This template is intended to be customised by Perl script
 *	initdb-config.pl which creates a ready to use shell script
 *	to initialise the database with command:
 *		./custom.d/"customised result file name"
 *
 */
/* **************************************************************
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licences/>.
 * **************************************************************
-*/
###
#
#		*** PostgreSQL: %DB_name% ***
#
###
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*-						Part 1					  -*/
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*- ---===>   One-time initialisations   <===---  -*/
/*-												  -*/
/*- Do not repeat if multiple databases are       -*/
/*- created with MySQL:                           -*/
/*- - users are global, can't be duplicated       -*/
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*-	The following shell command sequence will succeed even if an
	individual command fails because the object exists or cannot
	be created. This is the reason to have many commands instead
	of a single psql invocation. -*/
/*--*/
/*--*/

# NOTE: LXR does not manage PostgreSQL groups
#       If you need them, manually configure your role properties

/*@IF		%_dbuser%*/
/*@	XQT if [ ${NO_USER:-0} -eq 0 -a ${P_U_%DB_user%:-0} -eq 0 ] ; then */
/*@	XQT echo "*** PostgreSQL - Creating global user %DB_user%"*/
/*@	XQT echo "Note: deletion of user below fails if it owns databases"*/
/*@	XQT echo "      and other objects."*/
/*@	XQT echo "      If you want to keep some databases, ignore the error"*/
/*@	XQT echo "      Otherwise, manually delete the objects"*/
/*@	XQT echo "      and relaunch this script."*/
/*@	XQT dropuser   -U postgres %DB_user%*/
/*@	XQT createuser -U postgres %DB_user% -d -P -R -S*/
/*@	XQT P_U_%DB_user%=1 */
/*@	XQT fi */
/*@ENDIF		%_dbuser%*/
/*@IF	%_dbuseroverride% */
/*@	XQT if [ ${NO_USER:-0} -eq 0 -a ${P_U_%DB_tree_user%:-0} -eq 0 ] ; then */
/*@	XQT echo "*** PostgreSQL - Creating tree user %DB_tree_user%"*/
/*@	XQT echo "Note: deletion of user below fails if it owns databases"*/
/*@	XQT echo "      and other objects."*/
/*@	XQT echo "      If you want to keep some databases, ignore the error"*/
/*@	XQT echo "      Otherwise, manually delete the objects"*/
/*@	XQT echo "      and relaunch this script."*/
/*@	XQT dropuser   -U postgres %DB_tree_user%*/
/*@	XQT createuser -U postgres %DB_tree_user% -d -P -R -S*/
/*@	XQT P_U_%DB_tree_user%=1 */
/*@	XQT fi */

/*@ENDIF	%_dbuseroverride% */
/*--*/
/*--*/
/*-	-------------------------------------------------------------
 *-		Note about createlang below
 *-	Prior to PostgreSQL release 9.0, the SQL driver is not loaded
 *-	by default. It is therefore necessary to run command createlang.
 *-	This is superfluous with releases >= 9.0 and results in an
 *-	harmless warning which can be ignored
 *-	-----------------------------------------------------------*/
/*-		Create databases under LXR user
		but it prevents from deleting user if databases exist
-*//*- to activate place "- * /" at end of line (without spaces) -*/
/*@XQT if [ ${NO_DB:-0} -eq 0 -a ${P_DB_%DB_name%:-0} -eq 0 ] ; then */
/*@IF	%_globaldb% */
/*@	XQT echo "*** PostgreSQL - Creating global database %DB_name%"*/
/*@	XQT dropdb     -U %DB_user% %DB_name%*/
/*@	XQT createdb   -U %DB_user% %DB_name%*/
/*@	XQT createlang -U %DB_user% -d %DB_name% plpgsql*/
/*@ELSE */
/*@	IF		%_dbuseroverride% */
/*@		XQT echo "*** PostgreSQL - Creating tree database %DB_name%"*/
/*@		XQT dropdb     -U %DB_tree_user% %DB_name%*/
/*@		XQT createdb   -U %DB_tree_user% %DB_name%*/
/*@		XQT createlang -U %DB_tree_user% -d %DB_name% plpgsql*/
/*@	ELSE*/
/*-	When an overriding username is already known, %_dbuseroverride% is left
 *	equal to zero to prevent generating a duplicate user. We must however
 *	test the existence of %DB_tree_user% to operate under the correct
 *	DB owner. -*/
/*@		XQT echo "*** PostgreSQL - Creating tree database %DB_name%"*/
/*@		IF			%DB_tree_user% */
/*@			XQT dropdb     -U %DB_tree_user% %DB_name%*/
/*@			XQT createdb   -U %DB_tree_user% %DB_name%*/
/*@			XQT createlang -U %DB_tree_user% -d %DB_name% plpgsql*/
/*@		ELSE*/
/*@			XQT dropdb     -U %DB_user% %DB_name%*/
/*@			XQT createdb   -U %DB_user% %DB_name%*/
/*@			XQT createlang -U %DB_user% -d %DB_name% plpgsql*/
/*@		ENDIF		%DB_tree_user% */
/*@	ENDIF	%_dbuseroverride% */
/*@ENDIF %_globaldb% */
/*- end of disable/enable comment -*/
/*--*/
/*--*/
/*-		Create databases under master user, usually postgres
		may be restricted by site rules
-*//*- to activate place "- * /" at end of line (without spaces)
/*@IF	%_globaldb% */
/*@	XQT echo "*** PostgreSQL - Creating global database %DB_name%"*/
/*@	XQT dropdb     -U postgres %DB_name%*/
/*@	XQT createdb   -U postgres %DB_name%*/
/*@	XQT createlang -U postgres -d %DB_name% plpgsql*/
/*@ELSE */
/*@	XQT echo "*** PostgreSQL - Creating tree database %DB_name%"*/
/*@	XQT dropdb     -U postgres %DB_name%*/
/*@	XQT createdb   -U postgres %DB_name%*/
/*@	XQT createlang -U postgres -d %DB_name% plpgsql*/
/*@ENDIF	%_globaldb% */
/*- end of disable/enable comment -*/

/*@XQT echo "*** PostgreSQL - Erasing tables %DB_tbl_prefix% in database %DB_name%"*/
/*@ADD initdb/psql-command.sql*/
/*@IF 0 */
/*- Built-in unique record id management -*/
drop sequence if exists %DB_tbl_prefix%filenum;
drop sequence if exists %DB_tbl_prefix%symnum;
drop sequence if exists %DB_tbl_prefix%typenum;
create sequence %DB_tbl_prefix%filenum;
create sequence %DB_tbl_prefix%symnum;
create sequence %DB_tbl_prefix%typenum;
/*@ELSE*/
/*- The following is a replacement (initially developed for SQLite) -*/
/*@ADD initdb/unique-user-sequences.sql*/
/*@ENDIF*/

drop table if exists %DB_tbl_prefix%files cascade;
drop index if exists %DB_tbl_prefix%filelookup;
drop table if exists %DB_tbl_prefix%symbols cascade;
drop table if exists %DB_tbl_prefix%definitions cascade;
drop index if exists %DB_tbl_prefix%i_definitions;
drop table if exists %DB_tbl_prefix%releases cascade;
drop table if exists %DB_tbl_prefix%usages cascade;
drop index if exists %DB_tbl_prefix%i_usages;
drop table if exists %DB_tbl_prefix%status cascade;
drop table if exists %DB_tbl_prefix%langtypes cascade;
drop table if exists %DB_tbl_prefix%times cascade;
/*@XQT END_OF_SQL*/
/*@XQT P_DB_%DB_name%=1 */
/*@XQT fi */
/*--*/
/*-If we don't erase the database, we must erase the triggers
 *- so that they can be recreated/replaced by the new version.
 *- However, PostgreSQL requires the associated tables to exist
 *- otherwise it issues an error.
 *- Therefore we add an intermediaite step before dropping the
 *- tables.
-*/
/*@XQT if [ ${NO_DB:-0} -ne 0 ] ; then */
/*@XQT echo "*** PostgreSQL - Erasing triggers in database %DB_name%"*/
/*@ADD initdb/psql-command.sql*/
drop trigger if exists %DB_tbl_prefix%remove_definition
	on %DB_tbl_prefix%definitions;
drop trigger if exists %DB_tbl_prefix%add_release
	on %DB_tbl_prefix%releases;
drop trigger if exists %DB_tbl_prefix%remove_usage
	on %DB_tbl_prefix%usages;
drop trigger if exists %DB_tbl_prefix%remove_release
	on %DB_tbl_prefix%releases;
drop trigger if exists %DB_tbl_prefix%remove_file
	on %DB_tbl_prefix%status;
/*@XQT END_OF_SQL*/
/*@XQT fi */
/*--*/
/*--*/

/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*-						Part 2					  -*/
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*- ---===>    Tree database creation    <===---  -*/
/*-												  -*/
/*- Always to be done, this (re)creates the tables-*/
/*- for the specific database.                    -*/
/*- SQL is "safe".                                -*/
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*- - - - - - - - - - - - - - - - - - - - - - - - -*/
/*@XQT echo "*** PostgreSQL - Configuring tables %DB_tbl_prefix% in database %DB_name%"*/
/*-
-*-	Special initialisation mandatory for PostgreSQL < 9.5
-*- For higher versions, enable the "create index if not exists" statements.
-*/
/*@XQT if [ ${NO_DB:-0} -ne 0 -o ${P_DB_%DB_name%:-0} -ne 0 ] ; then */
/*@ADD initdb/psql-command.sql*/
drop index if exists %DB_tbl_prefix%filelookup;
drop index if exists %DB_tbl_prefix%i_definitions;
drop index if exists %DB_tbl_prefix%i_usages;
/*@XQT END_OF_SQL*/
/*@XQT fi*/
/*- End of special initialisation -*/

/*@ADD initdb/psql-command.sql*/
/* Base version of files */
/*	revision:	a VCS generated unique id for this version
				of the file
 */
create table if not exists %DB_tbl_prefix%files
	( fileid		int   not null primary key -- given by filenum
	, filename		bytea not null
	, revision		bytea not null
	, constraint %DB_tbl_prefix%uk_files
		unique		(filename, revision)
	);
/*- CAUTION! CAUTION! -*/
/*- "if not exists" is valid only from PostgreSQL version 9.5 onwards.
-*/
create index
/*@	IF 0 */
	if not exists
/*@	ENDIF */
	%DB_tbl_prefix%filelookup
	on %DB_tbl_prefix%files
	using btree (filename);

/* Status of files in the DB */
/*	fileid:		refers to base version
	relcount:	number of releases associated with base version
	indextime:	time when file was parsed for references
	status:		set of bits with the following meaning
		1	declaration have been parsed
		2	references have been processed
	Though this table could be merged with 'files',
	performance is improved with access to a very small item.
 */
create table if not exists %DB_tbl_prefix%status
	( fileid	int      not null primary key
	, relcount  int
	, indextime int
	, status	smallint not null
	, constraint %DB_tbl_prefix%fk_sts_file
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
-- 		on delete cascade
	);

/* The following trigger deletes no longer referenced files
 * (from releases), once status has been deleted so that
 * foreign key constrained has been cleared.
 */
drop function if exists %DB_tbl_prefix%erasefile();
create function %DB_tbl_prefix%erasefile()
	returns trigger
	language PLpgSQL
/*@IF	%_shell% */
	as \$\$
/*@ELSE*/
	as $$
/*@ENDIF	%_shell% */
		begin
			delete from %DB_tbl_prefix%files
				where fileid = old.fileid;
			return old;
		end;
/*@IF	%_shell% */
	\$\$;
/*@ELSE*/
	$$;
/*@ENDIF	%_shell% */

create trigger %DB_tbl_prefix%remove_file
	after delete on %DB_tbl_prefix%status
	for each row
	execute procedure %DB_tbl_prefix%erasefile();

/* Aliases for files */
/*	A base version may be known under several releaseids
	if it did not change in-between.
	fileid:		refers to base version
	releaseid:	"public" release tag
 */
create table if not exists %DB_tbl_prefix%releases
	( fileid    int   not null
	, releaseid bytea not null
	, constraint %DB_tbl_prefix%pk_releases
		primary key	(fileid, releaseid)
	, constraint %DB_tbl_prefix%fk_rls_fileid
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
	);

/* The following triggers maintain relcount integrity
 * in status table after insertion/deletion of releases
 */
drop function if exists %DB_tbl_prefix%increl();
create function %DB_tbl_prefix%increl()
	returns trigger
	language PLpgSQL
/*- $$ is causing trouble with sh because it is replaced
 *  by the process PID. It must then be quoted if the
 *  resulting file is intended to be executed as a script.
-*/
/*@IF	%_shell% */
	as \$\$
/*@ELSE*/
	as $$
/*@ENDIF	%_shell% */
		begin
			update %DB_tbl_prefix%status
				set relcount = relcount + 1
				where fileid = new.fileid;
			return new;
		end;
/*@IF	%_shell% */
	\$\$;
/*@ELSE*/
	$$;
/*@ENDIF	%_shell% */

create trigger %DB_tbl_prefix%add_release
	after insert on %DB_tbl_prefix%releases
	for each row
	execute procedure %DB_tbl_prefix%increl();

/* Note: a release is erased only when option --reindexall
 * is given to genxref; it is thus necessary to reset status
 * to cause reindexing, especially if the file is shared by
 * several releases
 */
drop function if exists %DB_tbl_prefix%decrel();
create function %DB_tbl_prefix%decrel()
	returns trigger
	language PLpgSQL
/*@IF	%_shell% */
	as \$\$
/*@ELSE*/
	as $$
/*@ENDIF	%_shell% */
		begin
			update %DB_tbl_prefix%status
				set	relcount = relcount - 1
/*-	Uncomment next line if you want to rescan a common file
	on next indexation by genxref -*/
-- 				,	status = 0
				where fileid = old.fileid
				and relcount > 0;
			return old;
		end;
/*@IF	%_shell%*/
	\$\$;
/*@ELSE*/
	$$;
/*@ENDIF	%_shell% */

create trigger %DB_tbl_prefix%remove_release
	after delete on %DB_tbl_prefix%releases
	for each row
	execute procedure %DB_tbl_prefix%decrel();

/* Types for a language*/
/*	declaration:	provided by generic.conf
 */
create table if not exists %DB_tbl_prefix%langtypes
	( typeid		smallint     not null -- given by typenum
	, langid		smallint     not null
	, declaration	varchar(255) not null
	, constraint %DB_tbl_prefix%pk_langtypes
		primary key	(typeid, langid)
	);

/* Symbol name dictionary */
/*	symid:		unique symbol id for name
	symcount:	number of definitions and usages for this name
	symname:	symbol name
 */
create table if not exists %DB_tbl_prefix%symbols
	( symid		int   not null primary key -- given by symnum
	, symcount  int
	, symname	bytea not null
	, constraint %DB_tbl_prefix%uk_symbols
		unique (symname)
	);
-- create index %DB_tbl_prefix%symlookup
-- 	on %DB_tbl_prefix%symbols
-- 	using btree (symname);

/* The following function decrements the symbol reference count
 * for a definition
 * (to be used in triggers).
 */
drop function if exists %DB_tbl_prefix%decdecl();
create function %DB_tbl_prefix%decdecl()
	returns trigger
	language PLpgSQL
/*@IF	%_shell% */
	as \$\$
/*@ELSE*/
	as $$
/*@ENDIF	%_shell% */
		begin
			update %DB_tbl_prefix%symbols
				set	symcount = symcount - 1
				where symid = old.symid
				and symcount > 0;
			if old.relid is not null
			then update %DB_tbl_prefix%symbols
				set	symcount = symcount - 1
				where symid = old.relid
				and symcount > 0;
			end if;
			return new;
		end;
/*@IF	%_shell% */
	\$\$;
/*@ELSE*/
	$$;
/*@ENDIF	%_shell% */

/* The following function decrements the symbol reference count
 * for a usage
 * (to be used in triggers).
 */
drop function if exists %DB_tbl_prefix%decusage();
create function %DB_tbl_prefix%decusage()
	returns trigger
	language PLpgSQL
/*@IF	%_shell% */
	as \$\$
/*@ELSE*/
	as $$
/*@ENDIF	%_shell% */
		begin
			update %DB_tbl_prefix%symbols
				set	symcount = symcount - 1
				where symid = old.symid
				and symcount > 0;
			return new;
		end;
/*@IF	%_shell% */
	\$\$;
/*@ELSE*/
	$$;
/*@ENDIF	%_shell% */

/* Definitions */
/*	symid:	refers to symbol name
	fileid and line define the location of the declaration
	langid:	language id
	typeid:	language type id
	relid:	optional id of the englobing declaration
			(refers to another symbol, not a definition)
 */
create table if not exists %DB_tbl_prefix%definitions
	( symid		int      not null
	, fileid	int      not null
	, line		int      not null
	, typeid	smallint not null
	, langid	smallint not null
	, relid		int
	, constraint %DB_tbl_prefix%fk_defn_symid
		foreign key (symid)
		references %DB_tbl_prefix%symbols(symid)
	, constraint %DB_tbl_prefix%fk_defn_fileid
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
-- 	, index (typeid, langid)
	, constraint %DB_tbl_prefix%fk_defn_type
		foreign key (typeid, langid)
		references %DB_tbl_prefix%langtypes (typeid, langid)
	, constraint %DB_tbl_prefix%fk_defn_relid
		foreign key (relid)
		references %DB_tbl_prefix%symbols(symid)
	);
/*- CAUTION! CAUTION! -*/
/*- "if not exists" is valid only from PostgreSQL version 9.5 onwards.
-*/
create index
/*@	IF 0 */
	if not exists
/*@	ENDIF */
	%DB_tbl_prefix%i_definitions
	on %DB_tbl_prefix%definitions
	using btree (symid, fileid);

/* The following trigger maintains correct symbol reference count
 * after definition deletion.
 */
-- drop function if exists %DB_tbl_prefix%proxy_rem_def();
-- create function %DB_tbl_prefix%proxy_rem_def()
-- 	returns trigger
-- 	language PLpgSQL
-- /*@IF	%_shell% */
-- 	as \$\$
-- /*@ELSE*/
-- 	as $$
-- /*@ENDIF	%_shell% */
-- 		begin
-- 			perform %DB_tbl_prefix%decsym(old.symid);
-- 			if old.relid is not null
-- 			then perform %DB_tbl_prefix%decsym(old.relid);
-- 			end if;
-- 		end;
-- /*@IF	%_shell% */
-- 	\$\$;
-- /*@ELSE*/
-- 	$$;
-- /*@ENDIF	%_shell% */
create trigger %DB_tbl_prefix%remove_definition
	after delete on %DB_tbl_prefix%definitions
	for each row
	execute procedure %DB_tbl_prefix%decdecl();

/* Usages */
create table if not exists %DB_tbl_prefix%usages
	( symid		int not null
	, fileid	int not null
	, line		int not null
	, constraint %DB_tbl_prefix%fk_use_symid
		foreign key (symid)
		references %DB_tbl_prefix%symbols(symid)
	, constraint %DB_tbl_prefix%fk_use_fileid
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
	);
/*- CAUTION! CAUTION! -*/
/*- "if not exists" is valid only from PostgreSQL version 9.5 onwards.
-*/
create index
/*@	IF 0 */
	if not exists
/*@	ENDIF */
	%DB_tbl_prefix%i_usages
	on %DB_tbl_prefix%usages
	using btree (symid, fileid);

/* The following trigger maintains correct symbol reference count
 * after usage deletion.
 */
-- drop function if exists %DB_tbl_prefix%proxy_rem_usg();
-- create function %DB_tbl_prefix%proxy_rem_usg()
-- 	returns trigger
-- 	language PLpgSQL
-- /*@IF	%_shell% */
-- 	as \$\$
-- /*@ELSE*/
-- 	as $$
-- /*@ENDIF	%_shell% */
-- 		begin
-- 			perform %DB_tbl_prefix%decsym(old.symid);
-- 		end;
-- /*@IF	%_shell% */
-- 	\$\$;
-- /*@ELSE*/
-- 	$$;
-- /*@ENDIF	%_shell% */
create trigger %DB_tbl_prefix%remove_usage
	after delete on %DB_tbl_prefix%usages
	for each row
	execute procedure %DB_tbl_prefix%decusage();

/* Statistics */
/*	releaseid:	"public" release tag
 *	reindex  :	reindex-all flag
 *	stepname :	step name
 *	starttime:	step start time
 *	endtime  :	step end time
 */
drop table if exists %DB_tbl_prefix%times;
create table %DB_tbl_prefix%times
	( releaseid bytea
	, reindex   int
	, stepname  char(1)
	, starttime int
	, endtime   int
	);

/*
 *
 */
grant select on %DB_tbl_prefix%files       to public;
grant select on %DB_tbl_prefix%symbols     to public;
grant select on %DB_tbl_prefix%definitions to public;
grant select on %DB_tbl_prefix%releases    to public;
grant select on %DB_tbl_prefix%usages      to public;
grant select on %DB_tbl_prefix%status      to public;
grant select on %DB_tbl_prefix%langtypes   to public;
grant select on %DB_tbl_prefix%times       to public;
/*@XQT END_OF_SQL*/

