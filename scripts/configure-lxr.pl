#!/usr/bin/perl
# -*- tab-width: 4 -*-
###############################################
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
###############################################

use strict;
use Getopt::Long qw(:config gnu_getopt);
use File::Path qw(make_path);
use lib do { $0 =~ m{(.*)/}; "$1" };

use ContextMgr;
use LCLInterpreter;
use QuestionAnswer;
use VTescape;


##############################################################
#
#				Global definitions
#
##############################################################

my $version = '2.3';

#	Who am I? Strip directory path.
my $cmdname = $0;
$cmdname =~ s:.*/([^/]+)$:$1:;

#	Default record separator
#	changed to read full file content at once and restored afterwards
my $oldsep = $/;


##############################################################
#
#			Parse options and check environment
#
##############################################################

# Define default values for options and process command line
my %option;
my $addtree = 0;
my $confdir = 'custom.d';
my $rootdir = `pwd`;
chomp($rootdir);
my ($scriptdir) = $0 =~ m!([^/]+)/[^/]+$!;
my $tmpldir = 'templates';
my $ovrdir  = 'custom.d/templates';
my $verbose;
my $confout;
my $scriptout = 'initdb.sh';
my $lxrtmplconf = 'lxr.conf';
if (!GetOptions	(\%option
				, 'add|a'		=> \$addtree
				, 'conf-dir=s'	=> \$confdir
				, 'conf-out=s'	=> \$confout
				, 'help|h|?'
				, 'root-dir=s'	=> \$rootdir
				, 'script-out=s'=> \$scriptout
				, 'tmpl-dir=s'	=> \$tmpldir
				, 'tmpl-ovr=s'	=> \$ovrdir
				, 'verbose:2'	=> \$verbose
				, 'v+'			=> \$verbose
				, 'version'
				)
	) {
	exit 1;
}

if ($option{'help'}) {
	print <<END_HELP;
Usage: ${cmdname} [option ...] [lxr-conf-template]

Creates in confdir all configuration files and scripts needed to run LXR.

Valid options are:
  -a, --add       Add a new tree to an existing configuration
      --conf-dir=directory
                  Define user-configuration directory
                  (default: $confdir)
      --conf-out=filename (without directory component)
                  Define custom configuration output filename
                  (default: same name as lxr-conf-template)
  -h, --help      Print this summary and quit
      --root-dir=directory
                  LXR root directory name
                  (default: $rootdir, i.e. the directory
                  from which you run this script)
      --script-out=filename (without directory component)
                  Define custom DB initialisation script name
                  (default: $scriptout)
      --tmpl-dir=directory
                  Define template directory
                  (default: $tmpldir)
      --tmpl-ovr=directory
                  Define template user-override directory
                  (default: $ovrdir)
  -v, --verbose   Explain what is being done
                  full verbosity:   -vv or --verbose,
                  medium verbosity: -v
                  minimal verbosity: none
      --version   Print version information and quit

lxr-conf-template  LXR master configuration template name in templates/
                   sub-directory (defaults to $lxrtmplconf if not specified)  

LXR home page: <http://lxr.sourceforge.net>
Report bugs at http://sourceforge.net/projects/lxr/.
END_HELP
	exit 0;
}

if ($option{'version'}) {
	print <<END_VERSION;
${cmdname} version $version
(C) 2012-2018 A. J. Littoz
This is free software under GPL v3 (or higher) licence.
There is NO warranty, not even for MERCHANTABILITY nor
FITNESS FOR A PARICULAR PURPOSE to the extent permitted by law.

LXR home page: <http://lxr.sourceforge.net>
See home page for bug reports.
END_VERSION
	exit 0;
}

#	"Canonise" directory names
$confdir =~ s:/*$::;
$tmpldir =~ s:/*$::;
$ovrdir  =~ s:/*$::;
$rootdir =~ s:/*$::;

#	Check LXR environment
my $error = 0;
if (! -d $rootdir) {
	print "${VTred}ERROR:${VTnorm} directory"
		. " ${VTred}$rootdir${VTnorm} does not exist!\n";
	$error = 1;
}
if (! -d $rootdir.'/'.$scriptdir) {
	print "${VTred}ERROR:${VTnorm} ${VTred}$rootdir${VTnorm} does not look "
		. "like an LXR root directory (scripts directory not found)!\n";
	$error = 1;
}
if (! -d $tmpldir) {
	print "${VTred}ERROR:${VTnorm} directory"
		. " ${VTred}$tmpldir${VTnorm} does not exist!\n";
	$error = 1;
}

if (0 <= index($scriptout, '/')) {
	print "${VTred}ERROR:${VTnorm} output script ${VTred}$scriptout${VTnorm} should not contain directory name!\n";
	$error = 1;
}

if (@ARGV > 1) {
	print "${VTred}ERROR:${VTnorm} only one template can be given!\n";
	$error = 1;
}
if (@ARGV == 1) {
	$lxrtmplconf = $ARGV[0];
	if (0 <= index($lxrtmplconf, '/')) {
		print "${VTred}ERROR:${VTnorm} template ${VTred}$lxrtmplconf${VTnorm} should not contain directory name!\n";
	$error = 1;
	}
}
if	(	! -e "$ovrdir/$lxrtmplconf"
	&&	! -e "$tmpldir/$lxrtmplconf"
	) {
	print "${VTred}ERROR:${VTnorm} template file ${VTred}$lxrtmplconf${VTnorm}"
		. " exists neither in override nor in templates directory!\n";
	$error = 1;
}

$confout =  $lxrtmplconf unless defined($confout);
if (0 <= index($confout, '/')) {
	print "${VTred}ERROR:${VTnorm} output configuration ${VTred}$confout${VTnorm} should not contain directory name!\n";
	$error = 1;
}
if (substr($confout, -5) eq '.ctxt') {
	print "${VTred}ERROR:${VTnorm} output configuration file ${VTred}$confout${VTnorm} has a forbidden extension!\n";
	$error = 1;
}
if (substr($confout, -5) ne '.conf') {
	print "${VTyellow}WARNING:${VTnorm} output configuration file ${VTbold}$confout${VTnorm} has an unusual extension!\n";
}

exit $error if $error;

my $contextfile = $confout // $lxrtmplconf;
$contextfile =~ s!(?:\.[^/]*|)$!.ctxt!;


##############################################################
#
#				Start configuration
#
##############################################################

if ($verbose) {
	print <<END_INTRO;
${VTyellow}***${VTnorm} ${VTred}L${VTblue}X${VTgreen}R${VTnorm} configurator (version: $version) ${VTyellow}***${VTnorm}

LXR root directory is ${VTbold}$rootdir${VTnorm}
Configuration will be stored in ${VTbold}$confdir/${VTnorm}
END_INTRO
}

if (! -d $confdir) {
	make_path($confdir);	# equivalent to mkdir -p
	if ($verbose) {
		print "directory ${VTbold}$confdir${VTnorm} created\n";
	}
}

if (! -d $confdir.'/db-scripts.d') {
	make_path($confdir.'/db-scripts.d');	# equivalent to mkdir -p
	if ($verbose) {
		print "directory ${VTbold}$confdir/db-scripts.d${VTnorm} created\n";
	}
}

##############################################################
#
#				Define global parameters
#
##############################################################
my @config;				# configuration file tree sections
my $treesinconfig = 0;	# count of trees in configuration file
my $tdbengine;			# tree-local database properties
my $tdbname;
my $tdbuser;
my $tdbpass;
my $tdbprefix;
my %deferred_markers;	# in case we precompute markers

if ($verbose) {
	print "\n";
}
#	The hashes below guarantee unicity of databases and users across
#	all trees and configuration sessions.
#	Key is engine:dbname:prefix with indifferent value (only existence is
#	relevant or engine:user with password value.
my %dbdict;			# dictionary of all databases (as a set of tables)
my %dbusersdict;	# dictionary of all user/password

if ($addtree) {
	$addtree += contextReload ($verbose, "$confdir/$contextfile");
	sub readfile {}		# dummy sub to disable 'range' file reads
	sub dummyfiles {	# dummy "files" object constructor to disable 'range' functions
		my $self = {};
		bless $self;
		return $self;
	};
	sub AUTOLOAD {		# silence all 'files' methods
		return undef;
	}
	my $files = dummyfiles();
	unless (open(CONFIG, "$confdir/$confout")) {
		print "${VTred}ERROR:${VTnorm} could not load configuration file ${VTbold}$confdir/$confout${VTnorm}\n";
		if (1 < $addtree) {
			print <<END_NOCONF;
   You have neither a configuration file nor its associated context file.
   Option ${VTred}--addtree${VTnorm} may be specified by mistake. If so, retry without it.
   Otherwise, use options ${VTbold}--conf-dir${VTnorm} and ${VTbold}--conf-out${VTnorm} to point the wizard
   onto the adequate directory
END_NOCONF
		}
		exit(1);
	}
	$/ = undef;
	my $config_contents = <CONFIG>;
	$/ = $oldsep;
	close(CONFIG);
	$config_contents =~ /(.*)/s;
	$config_contents = $1;    #untaint it
	@config = eval("\n#line 1 \"configuration file\"\n" . $config_contents);
	die($@) if $@;
	$treesinconfig = $#config - 1;	# count of trees previously described
	if ('single' eq $config[0]->{'routing'}) {
		print "${VTred}ERROR:${VTnorm} your initial context was ${VTbold}single-tree${VTnorm}.\n";
		print "       It does not make sense to add a tree in this mode.\n";
		exit 1;
	}
	$deferred_markers{'%_no_freesearch%'} = 
		(	defined $config[0]->{'glimpsebin'}
			&& $config[0]->{'glimpsebin'} eq '/usr/bin/true'
		||	defined $config[0]->{'swishbin'}
			&& $config[0]->{'swishbin'} eq '/usr/bin/true'
		||	defined $config[0]->{'glimpsebin'} && defined $config[0]->{'swishbin'}
		);
}

if ($addtree != 1) {

		#	Single or multiple trees mode of operation
		#	------------------------------------------

	if (1 < $treesinconfig) {
		$cardinality = 'm';
	} else {
		contextTrees ($verbose, $addtree);
	}
	if	(	1 < $addtree
		&&	's' eq $cardinality
		) {
		print "${VTred}ERROR:${VTnorm} ${VTbold}single${VTnorm} mode conflicts with option ${VTbold}--addtree${VTnorm}\n";
		if ($verbose) {
			print <<END_S_CFLCT;
   Context file is not really necessary in ${VTbold}single${VTnorm} mode.
   * DB recreation script can proceed without it. It is not necessary to
     run the present script to rebuild context.
   * You arrived here because option ${VTbold}--addtree${VTnorm} was specified
     on the command line. If this is an error, retry without it.
END_S_CFLCT
		}
		exit 1;
	}

		#	Web server definition
		#	---------------------

	if ($verbose) {
		print "\n";
		print "${VTyellow}***${VTnorm} ${VTred}L${VTblue}X${VTgreen}R${VTnorm} web server configuration ${VTyellow}***${VTnorm}\n";
		print "\n";
	}
	contextServer ($verbose);
	if (1 < $addtree) {
		my $oldrouting = uc($config[0]->{'routing'});
		$oldrouting = 'N' if 'single' eq $oldrouting;
		$oldrouting = substr($oldrouting, 0, 1);
		if ($oldrouting ne $treematch) {
			print "${VTred}ERROR:${VTnorm} tree designation method was ${VTbold}";
			if ('N' eq $oldrouting) {
				print 'implicit (single tree)';
			} elsif ('H' eq $oldrouting) {
				print 'hostname';
			} elsif ('P' eq $oldrouting) {
				print 'prefix in hostname';
			} elsif ('S' eq $oldrouting) {
				print 'section name';
			} elsif ('E' eq $oldrouting) {
				print 'embedded in section';
			} elsif ('A' eq $oldrouting) {
				print 'argument';
			}
			print "${VTnorm}.\n";
			print "       You requested ${VTbold}";
			if ('N' eq $treematch) {
				print 'implicit (single tree)';
			} elsif ('H' eq $treematch) {
				print 'hostname';
			} elsif ('P' eq $treematch) {
				print 'prefix in hostname';
			} elsif ('S' eq $treematch) {
				print 'section name';
			} elsif ('E' eq $treematch) {
				print 'embedded in section';
			} elsif ('A' eq $treematch) {
				print 'argument';
			}
			print "${VTnorm}.\n";
			exit 1;
		}
		if	(	@hostaliases <= 0
			&&	1 < scalar($config[0]->{'host_names'})
			) {
# 			if (1 < $verbose) {
				print "${VTyellow}***${VTnorm} Host aliases recovered from configuration file\n";
# 			}
			my @hn = @{$config[0]->{'host_names'}};
			shift @hn;	# remove primary host name
			foreach my $alias (@hn) {
				# copied from contextServer
				$alias =~ m!^([^/]+)?//([^:]+)(?::(\d+))?/?!;
				my $aliasscheme = $1;
				my $aliasname   = $2;
				my $aliasport   = $3;
				$aliasscheme = 'http:' if !defined($1);
				$aliasport   = 80  if 'http:' eq $aliasscheme && !defined($3);
				$aliasport   = 443 if 'https:' eq $1 && !defined($3);
				push (@schemealiases, $aliasscheme);
				push (@hostaliases,   $aliasname);
				push (@portaliases,   $aliasport);
			}
		}
		if	(	$commonvirtroot
			&&	$virtrootbase ne $config[0]->{'virtroot'}
			) {
			print <<END_CVR;
${VTyellow}WARNING:${VTnorm} the virtual root '${VTbold}$virtrootbase${VTnorm}' you provided is not the same
         the one retrieved from the configuration file ('${VTbold}$config[0]->{'virtroot'}${VTnorm}').
         Configuration is allowed to continue but you may get weird results.
END_CVR
		}
	}
	if	(	'c' eq $virtrootpolicy
		&&	!$addtree
		) {
		print <<END_C_VIRT;
${VTyellow}Reminder:${VTnorm} do not forget to implement your management in the following files:
- ${confdir}/${VTbold}apache-lxrserver.conf${VTnorm} if using Apache,
- ${confdir}/${VTbold}lighttpd-lxrserver.conf${VTnorm} if using lighttpd,
- ${confdir}/${VTbold}${confout}${VTnorm} for parameter 'treeextract'.
It is wise to thoroughly read the Web server chapter in the User's Manual.
END_C_VIRT
		if	('s' eq get_user_choice
						( 'Continue or stop?'
						, 1
						, [ 'continue', 'stop' ]
						, [ 'c', 's' ]
						)
			) {
			exit 0;
		}
	}
}

		#	Choice of database (addition or initial config)
		#	-----------------------------------------------

if ($addtree) {

	if ($verbose) {
		print "== ${VTyellow}ADD MODE${VTnorm} ==\n";
		print "\n";
	}
	if ($cardinality eq 's') {
		print "${VTred}ERROR:${VTnorm} initial configuration was done for a single tree!\n";
		print "This is not compatible with the present web server configuration.\n";
		print "To add more trees, you must reconfigure for multiple trees.\n";
		exit 1;
	}
	$cardinality = 'm';	# make sure context is correct even if context not reloaded
	if ($dbpolicy eq 't') {
		print "${VTnorm}\n";
		print "Advanced users can configure different DB engines for different trees.\n";
		print "This is not recommended for average users.\n";
		if ('n' eq get_user_choice
				( 'Use previous DB engine?'
				, 1
				, [ 'yes', 'no' ]
				, [ 'y', 'n' ]
				) ) {
			$dbengine =  get_user_choice
					( 'New database engine?'
					, 3
					, [ 'mysql', 'oracle', 'postgres', 'sqlite' ]
					, [ 'm', 'o', 'p', 's' ]
					);
			$dbenginechanged = 1;
		}
	}
}

if ($addtree != 1) {
	if ($verbose) {
		print <<END_DB;

${VTyellow}***${VTnorm} ${VTred}L${VTblue}X${VTgreen}R${VTnorm} database configuration ${VTyellow}***${VTnorm}

END_DB
	}
	if ($verbose > 1) {
		print <<END_DB;

The choice of the database engine can make a difference in indexing performance,
but resource consumption is also an important factor.
  * For a small personal project, try ${VTbold}SQLite${VTnorm} which do not
    need a server and is free from configuration burden.
  * For medium to large projects, choice is between ${VTbold}MySQL${VTnorm},
    ${VTbold}PostgreSQL${VTnorm} and Oracle.
    Oracle is not a free software, its interface has not been
    tested for a long time.
  * ${VTbold}PostgreSQL${VTnorm} databases are smaller than MySQL's
    and performance is roughly equivalent.
  * ${VTbold}MySQL${VTnorm} is at its best with large-sized projects
    (such as kernel cross-referencing) where it is fastest at the cost
    of bigger databases.
  * Take also in consideration the number of connected users.
END_DB
	}
	contextDB ($verbose);

	if (1 < $addtree) {
		if	(	!$nodbuser
			&&	(	$dbuser ne $config[0]->{'dbuser'}
				||	$dbpass ne $config[0]->{'dbpass'}
				)
			) {
				print <<END_CDU;
${VTred}ERROR:${VTnorm} the common database user $VTbold$dbuser$VTnorm/$VTbold$dbpass$VTnorm you provided is not the same
       as the one retrieved from the configuration file ($VTbold$config[0]->{'dbuser'}$VTnorm/$VTbold$config[0]->{'dbpass'}$VTnorm).
       This may cause problems if you continue.
END_CDU
		}
		if	(	!$nodbprefix
			&&	$dbprefix ne $config[0]->{'dbprefix'}
			) {
			print <<END_CDP;
${VTred}ERROR:${VTnorm} the common database table prefix '$VTbold$dbprefix$VTnorm$VTnorm' you provided is not the same
       as the one retrieved from the configuration file ('$VTbold$config[0]->{'dbprefix'}$VTnorm$VTnorm').
       This may cause problems if you continue.
END_CDP
		}
	}
}

		#	Scan lxr.conf to gather tree properties 
		#	---------------------------------------
		#	in order to detect inconsistencies and duplicates
		#	in databases descriptions

if ($addtree) {
	shift @config;	# remove global section
	foreach my $confblock (@config) {
		my ($tdbengine, $tdbname, $tdbuser, $tdbpass, $tdbprefix);
		$confblock->{'dbname'} =~ m/dbi:(\w+):dbname=(.+)(?:;|$)/;
		$tdbname = $2;
		$tdbengine = lc(substr($1, 0, 1));
		if (exists($confblock->{'dbuser'})) {
			$tdbuser = $confblock->{'dbuser'};
		} else {
			$tdbuser = $dbuser;
		}
		if (exists($confblock->{'dbpass'})) {
			$tdbpass = $confblock->{'dbpass'};
		} else {
			$tdbpass = $dbpass;
		}
		if (exists($confblock->{'dbprefix'})) {
			$tdbprefix = $confblock->{'dbprefix'};
		} else {
			$tdbprefix = $dbprefix;
		}
		$dbdict{"$tdbengine:$tdbname:$tdbprefix"} = 1;	# note definition
		$dbusersdict{$tdbengine.$tdbuser} = $tdbpass;	# remember password
	}
	print "Initial configuration file $confout scanned\n" if $verbose;
}

		#	Remember eventual global user/password
		#	--------------------------------------


if ($dbuser) {
	$dbusersdict{$dbengine.$dbuser} = $dbpass;
}

##############################################################
#
#			Save context for future additions
#
##############################################################

if (1 < $addtree) {
	if (1 < $verbose) {
		print <<END_CTX;

${VTyellow}***${VTnorm} A reconstructed context is now available.
  * If errors were notified, the safest option is to ${VTbold}quit without saving${VTnorm}
    to take time to think about the errors and their fixes.
  * You can also ${VTbold}save and quit${VTnorm} so that you can manually check and compare
    the context file and the configuration file.
  = = = If you are confident in context reconstruction, you can try to continue.
  * You can ${VTbold}continue without saving${VTnorm} to see what happens and you'll have
    to restore again a context next time you add a tree.
  * You can also ${VTbold}save and continue{VTnorm} on the ground you can delete the context
    file if you are not satisfied with the results.

END_CTX
	}
	my $ctxaction = get_user_choice
			( "${VTyellow}***${VTnorm} What do you want to do with the restored context?\n"
			, 2
			,	[ '1. quit no save'
				, '2. save and quit'
				, '3. continue no save'
				, '4. save and continue'
				]
			, [ '1', '2', '3', '4' ]
			);
	if	(	'2' eq $ctxaction
		||	'4' eq $ctxaction
		) {
		contextSave ("$confdir/$contextfile", $confout);
	}
	if	(	'1' eq $ctxaction
		||	'2' eq $ctxaction
		) {
		exit 0;
	}
	print "${VTyellow}***${VTnorm} End of context restoration, back to new tree description\n";
	print "\n";
}
if (!$addtree) {
	contextSave ("$confdir/$contextfile", $confout);
}

##############################################################
#
#			Set variables needed by the expanders
#
##############################################################

#	%markers contains value for "options" (or their equivalent)
#	which are not meant for substitution in the templates (this
#	is indicated by the _ prefix, but not checked),
#	and "substitution markers".
# From release 1.1 on, both are stuffed in the same hash since
# it simplifies processing in the macro interpreter.
my %markers =
	# Read-only options and parameters
	# (mainly from context)
		( '%_add%'		=> $addtree
		, '%_shell%'	=> 0
		, '%_singlecontext%' => $cardinality eq 's'
		, '%_dbengine%'	=> $dbengine
		, '%_dbpass%'	=> $dbpass
		, '%_dbprefix%'	=> $dbprefix
		, '%_dbuser%'	=> $dbuser
		, '%_dbuseroverride%' => 0
		, '%_globaldb%'	=> $dbpolicy eq 'g'
		, '%_nodbuser%'	=> $nodbuser
		, '%_nodbprefix%' => $nodbprefix
		, '%_virtrootpolicy%' => $virtrootpolicy
		, '%_routing%'	=> $treematch
		, '%_shared%'	=> 'S' eq $servertype
		, '%_commonvirtroot%' => $commonvirtroot

	# Global parameters: directories, server URL
	# (may be overwritten, but not recommended!)
		, '%LXRconfUser%'	=> getlogin	# OS-user running configuration
		, '%LXRroot%'		=> $rootdir
		, '%LXRtmpldir%'	=> $tmpldir
		, '%LXRovrdir%'		=> $ovrdir
		, '%LXRconfdir%'	=> $confdir
		, '%scheme%'		=> $scheme
		, '%hostname%'		=> $hostname
		, '%schemealiases%'	=> \@schemealiases
		, '%hostaliases%'	=> \@hostaliases
		, '%portaliases%'	=> \@portaliases
		, '%port%'			=> $port
		, '%virtrootbase%'	=> $virtrootbase
		, '%SQLiteDBdir%'	=> $sqlitedir
		);

my $sample;
$sample = `command -v glimpse 2>/dev/null`;
chomp($sample);
$markers{'%glimpse%'} = $sample if $sample;
$sample = `command -v glimpseindex 2>/dev/null`;
chomp($sample);
$markers{'%glimpseindex%'} = $sample if $sample;
$sample = `command -v swish-e 2>/dev/null`;
chomp($sample);
$markers{'%swish%'} = $sample if $sample;
$sample = `command -v ctags 2>/dev/null`;
chomp($sample);
$markers{'%ctags%'} = $sample if $sample;

$markers{'%DB_name%'} = $dbname if $dbname;
$markers{'%DB_user%'} = $dbuser if $dbuser;
$markers{'%DB_password%'} = $dbpass if $dbpass;
$markers{'%DB_global_prefix%'} = $dbprefix if $dbprefix;

$markers{'%search_engine%'} = 'glimpse';	# glimpse will have priority
$markers{'%_no_freesearch%'} = 0;
if (!$addtree) {
	if	(  !defined($markers{'%glimpse%'})
		&& !defined($markers{'%swish%'})
		) {
		print "${VTred}ERROR:${VTnorm} neither glimpse nor swish-e found in \$PATH!\n";
		if ('y' eq get_user_choice
				( 'Does one of them exist in a non standard directory?'
				, 1
				, [ 'yes', 'no' ]
				, [ 'y', 'n']
				)
			) {
			my $search = get_user_choice
					( '--- Which tool?'
					, 1
					, [ 'glimpse',   'swish-e' ]
					, [ '%glimpse%', '%swish%' ]
					);
			if ($search eq '%glimpse%') {
				$markers{'%glimpse%'} = get_user_choice
					( '--- Location? (e.g. /usr/share/glimpse-dir/glimpse)'
					, -2
					, [ '^/', 'absolute file path required' ]
					, []
					);
				$markers{'%glimpseindex%'} = get_user_choice
					( '--- Location of indexer? (e.g. /usr/share/glimpse-dir/glimpseindex)'
					, -2
					, [ '^/', 'absolute file path required' ]
					, []
					);
			} else {
				$markers{'%swish%'} = get_user_choice
					( '--- Location? (e.g. /usr/share/swish-dir/swish-e)'
					, -2
					, [ '^/', 'absolute file path required' ]
					, []
					);
			}
		} else {
			print "${VTyellow}Sorry:${VTnorm} free-text search disabled\n";
			$markers{'%glimpse%'} = '/bin/true';	# disable free-text search
			$markers{'%glimpsedirbase%'} = '/tmp';	# only to silence config check
			$markers{'%_no_freesearch%'} = 1;
		}
	}

	if	(  defined($markers{'%glimpse%'})
		&& $markers{'%glimpse%'} ne '/bin/true'
		) {
		$markers{'%glimpsedirbase%'} = get_user_choice
					( '--- Directory for glimpse databases?'
					, -2
					, [ '^/', 'absolute file path required' ]
					, []
					);
	}
	if (defined($markers{'%swish%'})) {
		$markers{'%swishdirbase%'} = get_user_choice
					( '--- Directory for swish-e databases?'
					, -2
					, [ '^/', 'absolute file path required' ]
					, []
					);
		if	(  !defined($markers{'%glimpse%'})
			|| $markers{'%glimpse%'} eq '/bin/true'
			) {
			$markers{'%search_engine%'} = 'swish';
		}
	}
	if	(  defined($markers{'%glimpse%'})
		&& $markers{'%glimpse%'} ne '/bin/true'
		&& defined($markers{'%swish%'})
		) {
		print "${VTred}REMINDER:${VTyellow} after this configuration step, open ${VTnorm}${VTbold}$confout${VTnorm}${VTyellow}\n";
		print "and comment out one of 'glimpsebin' or 'swishbin'.${VTnorm}\n";
	}
} else {
		# retrieve present freetext search status
	$markers{'%_no_freesearch%'} = $deferred_markers{'%_no_freesearch%'};
}

##############################################################
#
#			Copy basic files from templates directory
#
##############################################################

sub copy_and_configure_template {
	my ($fin, $fout, $target) = @_;

	my $input = $ovrdir . '/' . $fin;
	if (! -e $input) {
		$input = $tmpldir. '/' . $fin;
	}
	unless (open(SOURCE, '<', $input)) {
		die("${VTred}ERROR:${VTnorm} couldn't open template file \"$input\"\n");
	}
	unless (open(DEST, '>', $fout)) {
		die("${VTred}ERROR:${VTnorm} couldn't open output file \"$fout\n");
	}
	expand_hash	( sub{ <SOURCE> }
				, \*DEST
				, \%markers
				, $verbose
				);
	close(DEST);
	close(SOURCE);
	if ($target && $verbose) {
		print "file ${VTbold}$target${VTnorm} written into ";
		if ($fout eq $target) {
			print 'LXR root';
		} else {
			print 'configuration';
		}
		print " directory\n";
	}
}

if (!$addtree) {
	print "\n" if $verbose;

	chmod(0555, "$tmpldir/Apache/apache2-require.pl");	# Make sure it is executable
# 	chmod(0555, $tmpldir);
# 	if ($verbose) {
# 		print "templates directory ${VTbold}$tmpldir/${VTnorm} now protected read-only\n"
# 	}

	my $target;

	#	Apache: per-directory access control file
	$target = '.htaccess';
	copy_and_configure_template	( 'Apache/htaccess-generic'
								, ${target}
								, $target
								);

	#	Apache: mod_perl startup file
	$target = 'apache2-require.pl';
	copy_and_configure_template	( "Apache/$target"
								, "${confdir}/${target}"
								, ${target}
								);

	#	Apache: LXR server configuration file
	$target = 'apache-lxrserver.conf';
	copy_and_configure_template	( "Apache/$target"
								, "${confdir}/${target}"
								, ${target}
								);

	#	lighttpd: LXR server configuration file
	$target = 'lighttpd-lxrserver.conf';
	copy_and_configure_template	( "lighttpd/$target"
								, "${confdir}/${target}"
								, ${target}
								);

	#	nginx: LXR server configuration file
	$target = 'nginx-lxrserver.conf';
	copy_and_configure_template	( "Nginx/${target}"
								, "${confdir}/${target}"
								, ${target}
								);

	#	thttpd: LXR server configuration file
	$target = 'thttpd-lxrserver.conf';
	copy_and_configure_template	( ${target}
								, "${confdir}/${target}"
								, ${target}
								);

	#	Mercurial: extension and configuration file
	$target = 'hg-lxr-ext.py';
	copy_and_configure_template	( "Mercurial/$target"
								, "${confdir}/${target}"
								);
	$target = 'hg.rc';
	copy_and_configure_template	( "Mercurial/$target"
								, "${confdir}/${target}"
								);
	if ($verbose) {
		print "${VTbold}Mercurial${VTnorm} support files written into configuration directory\n"
	}
}
##############################################################
#
#			Configure lxr.conf's global part
#
##############################################################

if (!$addtree) {
	if ($verbose) {
		print <<END_GLOBAL;

${VTyellow}***${VTnorm} ${VTred}L${VTblue}X${VTgreen}R${VTnorm} master configuration file setup ${VTyellow}***${VTnorm}
    Global section part

END_GLOBAL
	}
	copy_and_configure_template	( $lxrtmplconf
								, "${confdir}/${confout}"
								);
}

##############################################################
#
#			Configure lxr.conf's tree-specific part
#		and build shell script for database initialisation
#
##############################################################

if ($verbose) {
	print <<END_TREE;

${VTyellow}***${VTnorm} ${VTred}L${VTblue}X${VTgreen}R${VTnorm} master configuration file setup ${VTyellow}***${VTnorm}
    Tree section part
    SQL script for database initialisation

END_TREE
}

if (!$addtree) {
	open(GLOBAL, '>', "${confdir}/${scriptout}");
	print GLOBAL "#!/bin/sh\n";
} else {
	open(GLOBAL, '>>', "${confdir}/${scriptout}")
}
while (1) {
	#	Start each iteration in default configuration
	$markers{'%_add%'} = $addtree;
	$markers{'%_dbuseroverride%'} = 0;
	delete $markers{'%DB_tree_user%'};
	delete $markers{'%DB_tree_password%'};
	delete $markers{'%DB_tbl_prefix%'};

	my $input = $ovrdir . '/' . $lxrtmplconf;
	if (! -e $input) {
		$input = ${tmpldir} . '/' . $lxrtmplconf;
	}
	unless (open(SOURCE, '<', $input)) {
		die("${VTred}ERROR:${VTnorm} couldn't open template file \"${input}\"\n");
	}

	pass2_hash	( \*SOURCE
				, "${confdir}/${confout}"
				, \%markers
				, $verbose
				);

	close(SOURCE);

	#	Update Apache configuration with the new 'virtroot'
	$input = $ovrdir . '/Apache/apache-lxrserver.conf';
	if (! -e $input) {
		$input = ${tmpldir} . '/Apache/apache-lxrserver.conf';
	}
	open(SOURCE, '<', ${input})
	or die("${VTred}ERROR:${VTnorm} couldn't open template file \"${input}\"\n");
	pass2_hash	( \*SOURCE
				, "${confdir}/apache-lxrserver.conf"
				, \%markers
				, $verbose
				);
	close(SOURCE);

	#	Update lighttpd configuration with the new 'virtroot'
	$input = $ovrdir . '/lighttpd/lighttpd-lxrserver.conf';
	if (! -e $input) {
		$input = ${tmpldir} . '/lighttpd/lighttpd-lxrserver.conf';
	}
	open(SOURCE, '<', ${input})
	or die("${VTred}ERROR:${VTnorm} couldn't open template file \"${input}\"\n");
	pass2_hash	( \*SOURCE
				, "${confdir}/lighttpd-lxrserver.conf"
				, \%markers
				, $verbose
				);
	close(SOURCE);

	#	Update Nginx configuration with the new 'virtroot'
	$input = $ovrdir . '/Nginx/nginx-lxrserver.conf';
	if (! -e $input) {
		$input = ${tmpldir} . '/Nginx/nginx-lxrserver.conf';
	}
	open(SOURCE, '<', ${input})
	or die("${VTred}ERROR:${VTnorm} couldn't open template file \"${input}\"\n");
	pass2_hash	( \*SOURCE
				, "${confdir}/nginx-lxrserver.conf"
				, \%markers
				, $verbose
				);
	close(SOURCE);

	#	Have new DB user and password been defined?
	if (exists($markers{'%DB_tree_user%'})) {
		if (exists($dbusersdict{$dbengine.$markers{'%DB_tree_user%'}})) {
			if ($dbusersdict{$dbengine.$markers{'%DB_tree_user%'}} ne
					$markers{'%DB_tree_password%'}) {
				print "${VTred}ERROR:${VTnorm} user ${VTbold}$markers{'%DB_tree_user%'}${VTnorm} already exists with a different password!\n";
				print "Configuration continues but it won't work.\n";
			}
		} else {
			#	Tell other templates something changed
			$markers{'%_dbuseroverride%'} = 1;
			$dbusersdict{$dbengine.$markers{'%DB_tree_user%'}} = $markers{'%DB_tree_password%'};
		}
	}
	#	New DB table prefix?
	if (!exists($markers{'%DB_tbl_prefix%'})) {
		$markers{'%DB_tbl_prefix%'} = $dbprefix;
	}
	#	Check DB unicity
	$tdbname = $dbengine
				. ':' . $markers{'%DB_name%'}
				. ':' . $markers{'%DB_tbl_prefix%'}
				;
	if (exists($dbdict{$tdbname})) {
			print "${VTred}ERROR:${VTnorm} database ${VTbold}$markers{'%DB_name%'}${VTnorm}"
				. " with table prefix ${VTbold}$markers{'%DB_tbl_prefix%'}${VTnorm} already exists!\n";
			print "Configuration continues but the previous DB will be erased if you try running the\n";
			print "initialisation script.\n";
	} else {
		$dbdict{$tdbname} = 1;
	}
	$input = $ovrdir . "/initdb/initdb-${dbengine}-template.sql";
	if (! -e $input) {
		$input = ${tmpldir} . "/initdb/initdb-${dbengine}-template.sql";
	}
	open(SOURCE, '<', ${input})
	or die("${VTred}ERROR:${VTnorm} couldn't open script template file \"${input}\"\n");
	my $dbscript = $markers{'%DB_name%'};
	if ('s' eq $dbengine) {	# SQLite DB name is a file path
		$dbscript = substr($dbscript, 1);
		$dbscript =~ s!/!@!g;
	}
	$dbscript = ${confdir}.'/db-scripts.d/'
					. $dbengine . ':'
					. $dbscript . ':'
					. $markers{'%DB_tbl_prefix%'}
					. '.sh';
	open( DEST
		, '>'
		, $dbscript
		)
	or die("${VTred}ERROR:${VTnorm} couldn't open output file \"${dbscript}\"\n");
	print DEST "#!/bin/sh\n";

	# NOTE:
	#	The design of the configuration process left the possibility
	#	to expand the SQL templates without interspersing the results
	#	with shell commands (so that the result would be a sequence
	#	of SQL commands only).
	#	Initially, the sub expand_slash_star was intended to be a script
	#	to which others would connect through a pipe.
	#	A shell expander would pass --shell to expand_slash_star to enable
	#	shell commands, while an SQL expander script would not pass
	#	this option.
	#	This is why the 'shell' pseudo-option is created.
	#	Of course, this statement would be better outside the loop,
	#	but this comment would be far from expand_slash_star invocation.
	$markers{'%_shell%'} = 1;
	#	Expand script model
	expand_slash_star	( sub{ <SOURCE> }
						, \*DEST
						, \%markers
						, $verbose
						);
	$markers{'%_shell%'} = 0;

	close(SOURCE);
	close(DEST);
	chmod 0775, $dbscript;	# Make sure script has x permission
	#	Stuff the individual DB script into the global script
	print GLOBAL ". ${dbscript}\n";

	print "\n";
	if	(  $cardinality eq 's'
		|| 'n' eq get_user_choice
			( "${VTblue}***${VTnorm} Configure another tree?"
			, 1
			, [ 'yes', 'no' ]
			, [ 'y', 'n']
			)
		) {
		last;
	}
	#	Prevent doing one-time actions more than once
	$addtree = 1;	# Same as adding a new tree
}

close(GLOBAL);
chmod 0775, "${confdir}/${scriptout}";	# Make sure script has x permission

##############################################################
#
#				Manage PostgreSQL passwords
#
##############################################################

my $pwdf = "${confdir}/db-scripts.d/pgpass";
if (!$addtree) {
	unlink($pwdf);
}
my @pguser = map {substr($_, 1)} grep (m/^p/, keys %dbusersdict);
if (0 < scalar(@pguser)) {
	my %olduserdict;
	if (-f $pwdf) {
		open (PWD, '<', $pwdf)
		or die("${VTred}ERROR:${VTnorm} couldn't open password file \"${pwdf}\"\n");
		while (<PWD>) {
			m/(\w+)=(.+)\n/;
			$olduserdict{$1} = $2;
		}
		close(PWD);
	}
	my @pgnew = map {
		if (exists $olduserdict{$_}) {
			if ($olduserdict{$_} ne $dbusersdict{'p'.$_}) {
				print "${VTred}ERROR:${VTnorm} PostgreSQL role ${VTbold}$_${VTnorm} redefined"
					, ' with password ', ${VTbold}, $dbusersdict{'p'.$_}, ${VTnorm}
					, 'different from stored ', ${VTbold}, $olduserdict{$_}, ${VTnorm}
					, "\n"
			}
			()
		} else {
			$_;
		}
	} @pguser;
	if (0 < scalar(@pgnew)) {
		open (PWD, '>>', $pwdf)
		or die("${VTred}ERROR:${VTnorm} couldn't create password file \"${pwdf}\"\n");
		print PWD <<END_PWD_PROLOG;
#
#	Automatically generated file
#	Manual changes will be lost on next update
#
END_PWD_PROLOG
		foreach (@pgnew) {
			print PWD '*:*:*:', $_, ':', $dbusersdict{'p'.$_}, "\n"
		}
		close(PWD)
	}
	chmod 0600, $pwdf;	# permissions as per PostgreSQL manual
}

##############################################################
#
#					End of configuration
#
##############################################################

#	Since storing files in a VCS does not guarantee adequate permissions
#	are kept, set them explicitly on scripts.
#	We suppose configure-lxr.pl has correct permissions, otherwise we
#	can't bootstrap.
chmod 0775, 'diff', 'genxref', 'ident', 'perf', 'search', 'showconfig', 'source';
chmod 0775, "${scriptdir}/kernel-vars-grab.sh";
chmod 0775, "${scriptdir}/set-lxr-version.sh";
chmod 0775, "${scriptdir}/recreatedb.pl";
chmod 0775, "${scriptdir}/lighttpd-init";

if ($verbose) {
		print "configuration saved in ${VTbold}$confdir/$confout${VTnorm}\n";
		print "DB initialisation script is ${VTbold}$confdir/$scriptout${VTnorm}\n";
}
