/*- -*- tab-width: 4 -*- */
/*
 *	"SQL-shell" template for launching psql under the desired user
 *	(C) 2016-2016 A. Littoz
 *
 *	This template is intended to be included in other SQL templates
 *	and further customised by Perl script initdb-config.pl.
 *	It generates a mysql command line for the required database
 *	and user (to set the appropriate privileges).
 *	It has been common factored because mysql must be launched
 *	several times to do specific jobs which can be selected or
 *	dropped according to external shell variables, making these
 *	jobs independent from each other.
 *
 *	CAUTION: sentinel at end of SQL must be END_OF_SQL.
 *			 Sorry, no way to customize it.
 *
 *	NOTA: Although this template deals with a shell command, its
 *		  extension is still .sql because it was extracted from
 *		  an SQL template and, more important, the expansion
 *		  assistant expects LCL commands to be embedded in SQL
 *		  comments /* ... * /.
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
/*--*/
/*--*/
/*-		Create tables under LXR user
-*//*- to activate place "- * /" at end of line (without spaces) -*/
/*@IF		%DB_tree_user% */
/*@	XQT mysql -u %DB_tree_user% -p%DB_tree_password% <<END_OF_SQL*/
/*@ELSE*/
/*@	XQT mysql -u %DB_user% -p%DB_password% <<END_OF_SQL*/
/*@ENDIF*/
/*- end of disable/enable comment -*/
/*--*/
/*--*/
/*-		Create tables under master user,
		may be restricted by site rules
-*//*- to activate place "- * /" at end of line (without spaces)
/*@XQT mysql -u root -p <<END_OF_SQL*/
/*- end of disable/enable comment -*/
