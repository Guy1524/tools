/*- -*- tab-width: 4 -*- */
/*-
 *	SQL template for creating MySQL tables
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
#		*** MySQL: %DB_name% ***
#
###
/*- ***********************************
 *  **         **         **         **
 *  ** CAUTION ** CAUTION ** CAUTION **
 *  **         **         **         **
 *  ***********************************
 *
 * As of 2016-08, there is still a performance BUG in MySQL where
 * TRUNCATE TABLE is horribly slow (mostly noticeable on big tables).
 * A workaround has been implementaed with
 * RENAME TABLE; CREATE TABLE; DROP TABLE; instead.
 * BUT (1): TRIGGERS associated with the dropped table are also erased.
 *		They must therefore be recreated.
 * BUT (2): CREATE TRIGGER cannot be used in a PROCEDURE.
 *		The idea was to have the definition of the TRIGGER only once
 *		in a procedure and to CALL it when creating the DB and also
 *		inside PurgeAll() when "truncating" the table with the
 *		workaround.
 *		This can't be done.
 * So BEWARE: the code to create the triggers must be duplicatied
 * in Mysql.pm's purgeall().
 * Do not forget this duplication as long as the workaround is necessary!
 *
 *  ** END OF CAUTION COMMENT
-*/
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
	of a single mysql invocation. -*/
/*--*/
/*--*/

# NOTE: in LXR, users have universal access to any MySQL databases.
#       If you want to restrict access, manually configure your
#       user rights.

/*@IF	%_dbuser% */
/*@	XQT if [ ${NO_USER:-0} -eq 0 -a ${M_U_%DB_user%:-0} -eq 0 ] ; then */
/*@	XQT echo "*** MySQL - Creating global user %DB_user%"*/
/*@	XQT mysql -u root -p <<END_OF_USER*/
drop user if exists '%DB_user%'@'localhost';
/*@	XQT END_OF_USER*/
/*@	XQT mysql -u root -p <<END_OF_USER*/
create user '%DB_user%'@'localhost' identified by '%DB_password%';
grant all on *.* to '%DB_user%'@'localhost';
/*@	XQT END_OF_USER*/
/*@	XQT M_U_%DB_user%=1 */
/*@	XQT fi */
/*@ENDIF	%_dbuser% */
/*@IF	%_dbuseroverride% */
/*@	XQT if [ ${M_U_%DB_tree_user%:-0} -lt 1 ] ; then */
/*@	XQT mysql -u root -p <<END_OF_USER*/
drop user if exists '%DB_tree_user%'@'localhost';
/*@	XQT END_OF_USER*/
/*@	XQT echo "*** MySQL - Creating tree user %DB_tree_user%"*/
/*@	XQT mysql -u root -p <<END_OF_USER*/
create user '%DB_tree_user%'@'localhost' identified by '%DB_tree_password%';
grant all on *.* to '%DB_tree_user%'@'localhost';
/*@	XQT END_OF_USER*/
/*@	XQT M_U_%DB_tree_user%=1 */
/*@	XQT fi */
/*@ENDIF	%_dbuseroverride% */
/*--*/
/*--*/

/*@XQT if [ ${NO_DB:-0} -eq 0 -a ${M_DB_%DB_name%:-0} -eq 0 ] ; then */
/*-		Create databases under LXR user
-*//*- to activate place "- * /" at end of line (without spaces) -*/
/*@IF	%_globaldb% */
/*@	XQT echo "*** MySQL - Creating global database %DB_name%"*/
/*@	XQT mysql -u %DB_user% -p%DB_password% <<END_OF_CREATE*/
drop database if exists %DB_name%;
create database %DB_name%;
/*@	XQT END_OF_CREATE*/
/*@ELSE */
/*@	XQT echo "*** MySQL - Creating tree database %DB_name%"*/
/*@	IF		%_dbuseroverride% */
/*@		XQT mysql -u %DB_tree_user% -p%DB_tree_password% <<END_OF_CREATE*/
/*@	ELSE*/
/*@		XQT mysql -u %DB_user% -p%DB_password% <<END_OF_CREATE*/
/*@	ENDIF*/
drop database if exists %DB_name%;
create database %DB_name%;
/*@	XQT END_OF_CREATE*/
/*@ENDIF	%_globaldb% */
/*- end of disable/enable comment -*/
/*--*/
/*--*/
/*-		Create databases under master user,
		may be restricted by site rules
-*//*- to activate place "- * /" at end of line (without spaces)
/*@IF	%_globaldb% */
/*@	XQT echo "*** MySQL - Creating global database %DB_name%"*/
/*@	XQT mysql -u root -p <<END_OF_CREATE*/
drop database if exists %DB_name%;
create database %DB_name%;
/*@	XQT END_OF_CREATE*/
/*@ELSE */
/*@	XQT echo "*** MySQL - Creating tree database %DB_name%"*/
/*@	XQT mysql -u root -p <<END_OF_CREATE*/
drop database if exists %DB_name%;
create database %DB_name%;
/*@	XQT END_OF_CREATE*/
/*@ENDIF	%_globaldb% */
/*- end of disable/enable comment -*/
/*@ADD initdb/mysql-command.sql*/
use %DB_name%;
/*@IF 0 */
/*@	DEFINE autoinc='auto_increment'*/
/*@ELSE*/
/*- Unique record id user management (initially developed for SQLite) -*/
/*@	DEFINE autoinc='              '*/
/*@	ADD initdb/unique-user-sequences.sql*/
alter table %DB_tbl_prefix%filenum
	engine = MyISAM;
alter table %DB_tbl_prefix%symnum
	engine = MyISAM;
alter table %DB_tbl_prefix%typenum
	engine = MyISAM;
/*@ENDIF*/
/*@XQT END_OF_SQL*/
/*@XQT M_DB_%DB_name%=1 */
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
/*@XQT echo "*** MySQL - Configuring tables %DB_tbl_prefix% in database %DB_name%"*/
/*@ADD initdb/mysql-command.sql*/
use %DB_name%;

/* Base version of files */
/*	revision:	a VCS generated unique id for this version
				of the file
 */
create table if not exists %DB_tbl_prefix%files
	( fileid    int %autoinc% not null primary key
	, filename  varbinary(255)     not null
	, revision  varbinary(255)     not null
	, constraint %DB_tbl_prefix%uk_files
		unique (filename, revision)
	, index %DB_tbl_prefix%filelookup (filename)
	)
	engine = MyISAM;

/* Status of files in the DB */
/*	fileid:		refers to base version
 *	relcount:	number of releases associated with base version
 *	indextime:	time when file was parsed for references
 *	status:		set of bits with the following meaning
 *		1	declaration have been parsed
 *		2	references have been processed
 *	Though this table could be merged with 'files',
 *	performance is improved with access to a very small item.
 */
/* Deletion of a record automatically removes the associated
 * base version files record.
 */
create table if not exists %DB_tbl_prefix%status
	( fileid    int     not null primary key
	, relcount  int
	, indextime int
	, status    tinyint not null
	, constraint %DB_tbl_prefix%fk_sts_file
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
	)
	engine = MyISAM;

/* The following trigger deletes no longer referenced files
 * (from releases), once status has been deleted so that
 * foreign key constrained has been cleared.
 */
/*-
 *  ==> See CAUTION comment at beginning of file
-*/
drop trigger if exists %DB_tbl_prefix%remove_file;
create trigger %DB_tbl_prefix%remove_file
	after delete on %DB_tbl_prefix%status
	for each row
		delete from %DB_tbl_prefix%files
			where fileid = old.fileid;

/* Aliases for files */
/*	A base version may be known under several releaseids
 *	if it did not change in-between.
 *	fileid:		refers to base version
 *	releaseid:	"public" release tag
 */
create table if not exists %DB_tbl_prefix%releases 
	( fileid    int            not null
	, releaseid varbinary(255) not null
	, constraint %DB_tbl_prefix%pk_releases
		primary key (fileid, releaseid)
	, constraint %DB_tbl_prefix%fk_rls_fileid
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
	)
	engine = MyISAM;

/* The following triggers maintain relcount integrity
 * in status table after insertion/deletion of releases
 */
/*-
 *  ==> See CAUTION comment at beginning of file
-*/
drop trigger if exists %DB_tbl_prefix%add_release;
create trigger %DB_tbl_prefix%add_release
	after insert on %DB_tbl_prefix%releases
	for each row
		update %DB_tbl_prefix%status
			set relcount = relcount + 1
			where fileid = new.fileid;
/* Note: a release is erased only when option --reindexall
 * is given to genxref; it is thus necessary to reset status
 * to cause reindexing, especially if the file is shared by
 * several releases
 */
/*-
 *  ==> See CAUTION comment at beginning of file
-*/
drop trigger if exists %DB_tbl_prefix%remove_release;
create trigger %DB_tbl_prefix%remove_release
	after delete on %DB_tbl_prefix%releases
	for each row
		update %DB_tbl_prefix%status
			set	relcount = relcount - 1
/*-	Uncomment next line if you want to rescan a common file
	on next indexation by genxref -*/
-- 			,	status = 0
			where fileid = old.fileid
			and relcount > 0;

/* Types for a language */
/*	declaration:	provided by generic.conf
 */
create table if not exists %DB_tbl_prefix%langtypes
	( typeid       smallint         not null %autoinc%
	, langid       tinyint unsigned not null
	, declaration  varchar(255)     not null
	, constraint %DB_tbl_prefix%pk_langtypes
		primary key  (typeid, langid)
	)
	engine = MyISAM;

/* Symbol name dictionary */
/*	symid:		unique symbol id for name
 * 	symcount:	number of definitions and usages for this name
 *	symname:	symbol name
 */
create table if not exists %DB_tbl_prefix%symbols
	( symid    int            not null %autoinc% primary key
	, symcount int
	, symname  varbinary(255) not null unique
	)
	engine = MyISAM;

/* The following function decrements the symbol reference count
 * (to be used in triggers).
 */
drop procedure if exists %DB_tbl_prefix%decsym;
delimiter //
create procedure %DB_tbl_prefix%decsym(in whichsym int)
begin
	update %DB_tbl_prefix%symbols
		set	symcount = symcount - 1
		where symid = whichsym
		and symcount > 0;
end//
delimiter ;

/* Definitions */
/*	symid:	refers to symbol name
 *  fileid and line define the location of the declaration
 *	langid:	language id
 *	typeid:	language type id
 *	relid:	optional id of the englobing declaration
 *			(refers to another symbol, not a definition)
 */
create table if not exists %DB_tbl_prefix%definitions
	( symid   int              not null
	, fileid  int              not null
	, line    int              not null
	, typeid  smallint         not null
	, langid  tinyint unsigned not null
	, relid   int
	, index %DB_tbl_prefix%i_definitions (symid, fileid)
	, constraint %DB_tbl_prefix%fk_defn_symid
		foreign key (symid)
		references %DB_tbl_prefix%symbols(symid)
	, constraint %DB_tbl_prefix%fk_defn_fileid
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
	, constraint %DB_tbl_prefix%fk_defn_type
		foreign key (typeid, langid)
		references %DB_tbl_prefix%langtypes(typeid, langid)
	, constraint %DB_tbl_prefix%fk_defn_relid
		foreign key (relid)
		references %DB_tbl_prefix%symbols(symid)
	)
	engine = MyISAM;

/* The following trigger maintains correct symbol reference count
 * after definition deletion.
 */
/*-
 *  ==> See CAUTION comment at beginning of file
-*/
drop trigger if exists %DB_tbl_prefix%remove_definition;
delimiter //
create trigger %DB_tbl_prefix%remove_definition
	after delete on %DB_tbl_prefix%definitions
	for each row
	begin
		call %DB_tbl_prefix%decsym(old.symid);
		if old.relid is not null
		then call %DB_tbl_prefix%decsym(old.relid);
		end if;
	end//
delimiter ;

/* Usages */
create table if not exists %DB_tbl_prefix%usages
	( symid   int not null
	, fileid  int not null
	, line    int not null
	, index %DB_tbl_prefix%i_usages (symid, fileid)
	, constraint %DB_tbl_prefix%fk_use_symid
		foreign key (symid)
		references %DB_tbl_prefix%symbols(symid)
	, constraint %DB_tbl_prefix%fk_use_fileid
		foreign key (fileid)
		references %DB_tbl_prefix%files(fileid)
	)
	engine = MyISAM;

/* The following trigger maintains correct symbol reference count
 * after usage deletion.
 */
/*-
 *  ==> See CAUTION comment at beginning of file
-*/
drop trigger if exists %DB_tbl_prefix%remove_usage;
create trigger %DB_tbl_prefix%remove_usage
	after delete on %DB_tbl_prefix%usages
	for each row
	call %DB_tbl_prefix%decsym(old.symid);

/* Statistics */
/*	releaseid:	"public" release tag
 *	reindex  :	reindex-all flag
 *	stepname :	step name
 *	starttime:	step start time
 *	endtime  :	step end time
 */
drop table if exists %DB_tbl_prefix%times;
create table %DB_tbl_prefix%times
	( releaseid varbinary(255)
	, reindex   int
	, stepname  char(1)
	, starttime int
	, endtime   int
	)
	engine = MyISAM;

drop procedure if exists %DB_tbl_prefix%PurgeAll;
delimiter //
create procedure %DB_tbl_prefix%PurgeAll ()
begin
	set @old_check = @@session.foreign_key_checks;
	set session foreign_key_checks = OFF;
/*@IF 0 */
/*@ELSE*/
/*- Unique record id user management -*/
	truncate table %DB_tbl_prefix%filenum;
	truncate table %DB_tbl_prefix%symnum;
	truncate table %DB_tbl_prefix%typenum;
	insert into %DB_tbl_prefix%filenum
		(rcd, fid) VALUES (0, 0);
	insert into %DB_tbl_prefix%symnum
		(rcd, sid) VALUES (0, 0);
	insert into %DB_tbl_prefix%typenum
		(rcd, tid) VALUES (0, 0);
/*@ENDIF*/
/* *** *** ajl 160815 *** *** */
/* A bug in TRUNCATE TABLE management causes it to become
 * unacceptably slow on huge tables. To avoid the performance
 * penalty, an alternate strategy is used.
 * The tables which are deemed to have small to "acceptable"
 * sizes are processed as usual.
 */
--	truncate table %DB_tbl_prefix%definitions;
--	truncate table %DB_tbl_prefix%usages;
--	truncate table %DB_tbl_prefix%langtypes;
--	truncate table %DB_tbl_prefix%symbols;
--	truncate table %DB_tbl_prefix%releases;
--	truncate table %DB_tbl_prefix%status;
--	truncate table %DB_tbl_prefix%files;
/* This is the workaround: */
/*-
 *  ==> See CAUTION comment at beginning of file
-*/
	rename table %DB_tbl_prefix%definitions to trash;
	create table %DB_tbl_prefix%definitions like trash;
	drop table trash;
	rename table %DB_tbl_prefix%usages to trash;
	create table %DB_tbl_prefix%usages like trash;
	drop table trash;
	rename table %DB_tbl_prefix%langtypes to trash;
	create table %DB_tbl_prefix%langtypes like trash;
	drop table trash;
	rename table %DB_tbl_prefix%symbols to trash;
	create table %DB_tbl_prefix%symbols like trash;
	drop table trash;
	rename table %DB_tbl_prefix%releases to trash;
	create table %DB_tbl_prefix%releases like trash;
	drop table trash;
	rename table %DB_tbl_prefix%status to trash;
	create table %DB_tbl_prefix%status like trash;
	drop table trash;
	rename table %DB_tbl_prefix%files to trash;
	create table %DB_tbl_prefix%files like trash;
	drop table trash;
/* End of work around */
	truncate table %DB_tbl_prefix%times;
	set session foreign_key_checks = @old_check;
end//
delimiter ;
/*@XQT END_OF_SQL*/

