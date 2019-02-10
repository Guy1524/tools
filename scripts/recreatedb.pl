#!/usr/bin/perl
# -*- tab-width: 4 -*-"
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
use lib 'lib', do { $0 =~ m{(.*)/}; "$1" };
use Fcntl;
use Getopt::Long;
use IO::Handle;
use File::Path qw(make_path);

use ContextMgr;
use LCLInterpreter;
use VTescape;

# The following use statements are written only to allow to eval
# without error the lxr.conf file is the event it contains sub
# definitions for 'range' with references to allbranches,
# allreleases, allrevisions or alltags functions defined in Files.
# These function calls may use LXR global $pathname defined in Common.
use LXR::Files;
use LXR::Common;


##############################################################
#
#				Global definitions
#
##############################################################

my $version = '2.2';

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
my $confdir = 'custom.d';
my $rootdir = `pwd`;
chomp($rootdir);
my ($scriptdir) = $0 =~ m!([^/]+)/[^/]+$!;
my $tmpldir = 'templates';
my $ovrdir  = 'custom.d/templates';
my $verbose;
my $scriptout = 'initdb.sh';
my $lxrconf = 'lxr.conf';
my $lxrctxdft = 'lxr.ctxt';
my $lxrctx;
if (!GetOptions	(\%option
				, 'conf-dir=s'	=> \$confdir
				, 'help|h|?'
				, 'lxr-ctx=s'	=> \$lxrctx
				, 'root-dir=s'	=> \$rootdir
				, 'script-out=s'=> \$scriptout
				, 'tmpl-dir=s'	=> \$tmpldir
				, 'tmpl-ovr=s'	=> \$ovrdir
				, 'verbose|v'	=> \$verbose
				, 'version'
				)
	) {
	exit 1;
}

if ($option{'help'}) {
	print <<END_HELP;
Usage:  ${cmdname} [option ...] [lxr-conf-file]

Reconstructs the DB initialisation script from 'lxr.conf' content
as it was initially created by configure-lxr.pl program.

Valid options are:
      --conf-dir=directory
                  Define user-configuration directory
                  (default: $confdir)
  -h, --help      Print this summary and quit
      --lxr-ctx=filename
                  Initial configuration context file
                  (default: $lxrctxdft, i.e. same name as
                  lxr-conf-file with extension replaced by
                  ".ctxt")
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
      --version   Print version information and quit

lxr-conf-file  LXR master configuration file from which the
               DB initialisation script will be reconstructed
               (defaults to $lxrconf if not specified)  

LXR home page: <http://lxr.sourceforge.net>
Report bugs at http://sourceforge.net/projects/lxr/.
END_HELP
	exit 0;
}

if ($option{'version'}) {
	print <<END_VERSION;
${cmdname} version $version
(C) 2012-2016 A. J. Littoz
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
if (! -d "$rootdir/$scriptdir") {
	print "${VTred}ERROR:${VTnorm} ${VTred}$rootdir${VTnorm} does not look "
		. "like an LXR root directory (scripts directory not found)!\n";
	$error = 1;
}
if (! -d $tmpldir) {
	print "${VTred}ERROR:${VTnorm} directory"
		. " ${VTred}$tmpldir${VTnorm} does not exist!\n";
	$error = 1;
}

if ($scriptout =~ m:/:) {
	print "${VTred}ERROR:${VTnorm} output script ${VTred}$scriptout${VTnorm} should not contain directory name!\n";
	$error = 1;
}

if (@ARGV > 1) {
	print "${VTred}ERROR:${VTnorm} only one configuration file can be given!\n";
	$error = 1;
}
if (@ARGV == 1) {
	$lxrconf = $ARGV[0];
}

# If lxr-ctx not given, use default companion filename
if (! $lxrctx) {
	$lxrctx		= $lxrconf;
	my $extpos  = rindex($lxrctx, '.');
	if (0 <= $extpos) {		# Remove the extension
		$lxrctx = substr($lxrctx, 0, $extpos);
	}
	$extpos  = rindex($lxrctxdft, '.');		# Default extension
	$lxrctx	.= substr($lxrctxdft, $extpos);	# Insert correct extension
	if (0 >= index($lxrctx, '/')) {
		$lxrctx = $confdir . '/' . $lxrctx;
	}
}
if (! -e $lxrctx) {
	print "${VTred}ERROR:${VTnorm} configuration context file"
		. " ${VTred}$lxrctx${VTnorm} does not exist!\n";
}

if	(	! -e $tmpldir.'/initdb/initdb-m-template.sql'
	&&	! -e $ovrdir .'/initdb/initdb-m-template.sql'
	) {
	print "${VTred}ERROR:${VTnorm} template file"
		. " ${VTred}initdb/initdb-m-template.sql{VTnorm}"
		. " exists neither in override nor in templates directory!\n";
	$error = 1;
}
if	(	! -e $tmpldir.'/initdb/initdb-o-template.sql'
	&&	! -e $ovrdir .'/initdb/initdb-o-template.sql'
	) {
	print "${VTred}ERROR:${VTnorm} template file"
		. " ${VTred}initdb/initdb-o-template.sql{VTnorm}"
		. " exists neither in override nor in templates directory!\n";
	$error = 1;
}
if	(	! -e $tmpldir.'/initdb/initdb-p-template.sql'
	&&	! -e $ovrdir .'/initdb/initdb-p-template.sql'
	) {
	print "${VTred}ERROR:${VTnorm} template file"
		. " ${VTred}initdb/initdb-p-template.sql{VTnorm}"
		. " exists neither in override nor in templates directory!\n";
	$error = 1;
}
if	(	! -e $tmpldir.'/initdb/initdb-s-template.sql'
	&&	! -e $ovrdir .'/initdb/initdb-s-template.sql'
	) {
	print "${VTred}ERROR:${VTnorm} template file"
		. " ${VTred}initdb/initdb-s-template.sql{VTnorm}"
		. " exists neither in override nor in templates directory!\n";
	$error = 1;
}

exit $error if $error;


##############################################################
#
#				Start reconstruction
#
##############################################################

if ($verbose) {
	$verbose = 2;		# Force max verbosity in support routines
	print "${VTyellow}***${VTnorm} ${VTred}L${VTblue}X${VTgreen}R${VTnorm}";
	print ' DB initialisation reconstruction ';
	print "(version: $version) ${VTyellow}***${VTnorm}\n";
	print "\n";
	print "LXR root directory is ${VTbold}$rootdir${VTnorm}\n";
	print "Configuration read from ${VTbold}$lxrconf${VTnorm}\n";
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

if ($verbose) {
	print "\n";
}
my %users;			# Cumulative list of all user/password
# Flags for first use of DB engine
my %dbengine_seen =
	( 'm' => 0
	, 'o' => 0
	, 'p' => 0
	, 's' => 0	# Silly, but does not break scheme
	);


##############################################################
#
#			Reload context from initial configuration
#
##############################################################

my $manualreload = contextReload ($verbose, $lxrctx);

if ($manualreload) {
	print "\n";
	if ($verbose) {
		print <<END_CTX_INTRO;
The following questions are intended to rebuild the global
databases options (which may be overridden in individual
trees. Answer with the choices you made previously,
otherwise your DB will not be what LXR expects.

END_CTX_INTRO
	}
	print <<END_CTX_NOTE;
${VTyellow}NOTE:${VTnorm} This is a simplified context recovery procedure,
      only for the purpose of reconstructing the DB creation scripts.
      To recover the context in a more reliable and exhaustive way,
      launch the configuration wizard with ${VTbold}--add${VTnorm} option and
      stop it after context backup.
${VTyellow}WARNING:${VTnorm} Single-tree context recovery is only possible here
         but it cannot be saved.

END_CTX_NOTE
	contextTrees ($verbose);
	contextDB ($verbose);
	if ($dbuser) {
		$users{$dbengine.$dbuser} = $dbpass;	# Record global user/password
	}
}

##############################################################
#
#					Read lxr.conf
#
##############################################################

# Dummy sub to disable 'range' file reads
sub readfile {}
sub dummyfiles {	# dummy "files" object constructor to disable 'range' functions
	my $self = {};
	bless $self;
	return $self;
};
sub AUTOLOAD {		# silence all 'files' methods
	return undef;
}
my $files = dummyfiles();

unless (open(CONFIG, $lxrconf)) {
	print "${VTred}ERROR:${VTnorm} could not open configuration file ${VTred}$lxrconf${VTnorm}\n";
	exit(1);
}
$/ = undef;
my $config_contents = <CONFIG>;
$/ = $oldsep;
close(CONFIG);
$config_contents =~ /(.*)/s;
$config_contents = $1;    #untaint it
my @config = eval("\n#line 1 \"configuration file\"\n" . $config_contents);
die($@) if $@;

print "Configuration file $lxrconf loaded\n" if $verbose;


##############################################################
#
#			Scan lxr.conf's global part
#			and build database description
#
##############################################################

if ($verbose) {
	print "\n";
	print "${VTyellow}***${VTnorm} scanning global configuration section ${VTyellow}***${VTnorm}\n";
}
if (exists($config[0]{'dbuser'})) {
	$dbuser = $config[0]{'dbuser'};
	$dbpass = $config[0]{'dbpass'};
}
if (exists($config[0]{'dbprefix'})) {
	$dbprefix = $config[0]{'dbprefix'};
}
if (exists($config[0]{'dbname'})) {
	$config[0]{'dbname'} =~ m/dbi:(.)/;
	$dbengine = lc($1);
	if ($config[0]{'dbname'} =~ m/dbname=([^;]+)/) {
		$dbname = $1;
	}
}
shift @config;	# Remove global part

##############################################################
#
#			Set variables needed by the expanders
#
##############################################################

my %markers =
		( '%_singlecontext%' => $cardinality eq 's'
		, '%_dbengine%'	=> $dbengine
		, '%_dbpass%'	=> $dbpass
		, '%_dbprefix%'	=> $dbprefix
		, '%_dbuser%'	=> $dbuser
		, '%_dbuseroverride%' => 0
		, '%_globaldb%'	=> $dbpolicy eq 'g'
		, '%_nodbuser%'	=> $nodbuser
		, '%_nodbprefix%' => $nodbprefix
		, '%_shell%'	=> 1

	# Global parameters: directories, server URL
	# (may be overwritten, but not recommended!)
		, '%LXRconfUser%'	=> getlogin	# OS-user running configuration
		, '%LXRroot%'		=> $rootdir
		, '%LXRtmpldir%'	=> $tmpldir
		, '%LXRovrdir%'		=> $ovrdir
		, '%LXRconfdir%'	=> $confdir
		);

$markers{'%DB_name%'} = $dbname if $dbname;
$markers{'%DB_user%'} = $dbuser if $dbuser;
$markers{'%DB_password%'} = $dbpass if $dbpass;
$markers{'%DB_global_prefix%'} = $dbprefix if $dbprefix;


##############################################################
#
#			Scan lxr.conf's tree-specific parts
#			and build database description
#
##############################################################

unlink "${confdir}/${scriptout}";
open(GLOBAL, '>', "${confdir}/${scriptout}")
or die("${VTred}ERROR:${VTnorm} couldn't open output file \"${confdir}/${scriptout}\"\n");
print GLOBAL "#!/bin/sh\n";

if ($verbose) {
	print "\n";
}
foreach my $config (@config) {

	if ($verbose) {
		print "${VTyellow}***${VTnorm} scanning ${VTbold}$$config{'treename'}${VTnorm} tree configuration section ${VTyellow}***${VTnorm}\n";
# NOTE:	the treename is displayed ONLY when 'routing' is 'argument', which is the now
#		recommended method. Managing all the variants would require too much effort.
#		In single tree context, not displaying a tree name really does not matter
#		since there is a single tree after all.
	}
	#	Start each iteration in default configuration
	$markers{'%_dbuseroverride%'} = 0;
	delete $markers{'%DB_tree_user%'};
	delete $markers{'%DB_tree_password'};
	delete $markers{'%DB_tbl_prefix%'};

	my $treedbengine = $dbengine;
	if (exists($config->{'dbname'})) {
		$config->{'dbname'} =~ m/dbi:(.)/;
		$treedbengine = lc($1);
		if ($config->{'dbname'} =~ m/dbname=([^;]+)/) {
			$markers{'%DB_name%'} = $1;
		}
	}
	if (!defined($markers{'%DB_name%'})) {
		$markers{'%DB_name%'} = $dbname;
	}
	if (!defined($markers{'%DB_name%'})) {
		print "${VTred}ERROR:${VTnorm} no data base name (either tree-specific or global)\n";
		print "for tree ${VTred}$$config{'treename'}${VTnorm}!\n";
# See NOTE above about 'treename'
	}

	if	(	$dbenginechanged
		||	$treedbengine ne $dbengine && !$dbengine_seen{$treedbengine}
		) {
		$dbengine_seen{$treedbengine} = 1;
	}

	#	Have new DB user and password been defined?
	if (exists($config->{'dbuser'})) {
		$markers{'%_dbuseroverride%'} = 1;
		$markers{'%DB_tree_user%'} = $config->{'dbuser'};
		$markers{'%DB_tree_password%'} = $config->{'dbpass'};
		$users{$treedbengine.$config->{'dbuser'}} = $config->{'dbpass'};
	} else {
		$users{$treedbengine.$dbuser} = $dbpass;
	}
	#	New DB table prefix?
	if (exists($config->{'dbprefix'})) {
		$markers{'%DB_tbl_prefix%'} = $config->{'dbprefix'};
	} else {
		$markers{'%DB_tbl_prefix%'} = $dbprefix;
	}

	my $input = $ovrdir . "/initdb/initdb-${treedbengine}-template.sql";
	if (! -e $input) {
		$input = $tmpldir . "/initdb/initdb-${treedbengine}-template.sql";
	}
	open(SOURCE, '<', $input)
	or die("${VTred}ERROR:${VTnorm} couldn't open  script template file \"${input}\"\n");

	my $dbscript = $markers{'%DB_name%'};
	if ('s' eq $treedbengine) {	# SQLite DB name is a file path
		$dbscript = substr($dbscript, 1);
		$dbscript =~ s!/!@!g;
	}
	$dbscript = ${confdir}.'/db-scripts.d/'
					. $treedbengine . ':'
					. $dbscript . ':'
					. $markers{'%DB_tbl_prefix%'}
					. '.sh';
	open( DEST, '>', $dbscript)
	or die("${VTred}ERROR:${VTnorm} couldn't open output file \"${dbscript}\"\n");
	print DEST "#!/bin/sh\n";

	#	Expand script model
	expand_slash_star	( sub{ <SOURCE> }
						, \*DEST
						, \%markers
						, $verbose
						);

	close(SOURCE);
	close(DEST);
	chmod 0775, $dbscript;	# Make sure script has x permission
	#	Stuff the individual DB script into the global script
	print GLOBAL ". ${dbscript}\n";

	#	Prevent doing one-time actions more than once
	$dbenginechanged = 0;
}

close(GLOBAL);
chmod 0775,"${confdir}/${scriptout}";	# Make sure script has x permission

##############################################################
#
#				Manage PostgreSQL passwords
#
##############################################################

my $pwdf = "${confdir}/db-scripts.d/pgpass";
unlink($pwdf);
my @pguser = map {substr($_, 1)} grep (m/^p/, keys %users);
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
			if ($olduserdict{$_} ne $users{'p'.$_}) {
				print "${VTred}ERROR:${VTnorm} PostgreSQL role ${VTbold}$_${VTnorm} redefined"
					, ' with password ', ${VTbold}, $users{'p'.$_}, ${VTnorm}
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
			print PWD '*:*:*:', $_, ':', $users{'p'.$_}, "\n"
		}
		close(PWD)
	}
	chmod 0600, $pwdf;	# permissions as per PostgreSQL manual
}
