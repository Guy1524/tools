# -*- tab-width: 4 perl-indent-level: 4-*-
###############################
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
###############################

package LXR::Index::Postgres;

use strict;
use DBI;
use LXR::Common;

our @ISA = ('LXR::Index');

sub new {
	my ($self, $config) = @_;

	$self = bless({}, $self);
	$self->{dbh} = DBI->connect	( $config->{'dbname'}
								, $config->{'dbuser'}
								, $config->{'dbpass'}
#	From the measurement on the medium sized test cases used to 
#	debug LXR, PostgreSQL performance is as follows:
#	- auto commit mode:		10-11 time units
#	- auto commit mode with begin_work (see below):
#							1 time unit
#	- explicit commit mode:	1 time unit
#	To change commit policy, change the following constant and
#	eventually comment out begin_work() call.
								, {'AutoCommit' => 0}
								)
	or die "Can't open connection to database: $DBI::errstr\n";

	return $self;
}

sub write_open {
	my ($self) = @_;

	my $prefix = $config->{'dbprefix'};

#	Without the following instruction (theoretically meaningless
#	in auto commit mode), indexing time is multiplied by 10
#	on the test case!
#	$self->{dbh}->begin_work() or die "begin_work failed: $DBI::errstr";

#	PostgreSQL may be run with its built-in unique record id management
#	mechanisms. There is only a big performance improvement
#	with user management.
#	Uncomment the desired management method:
#	- Variant U: common user management (in Index.pm)
#	- Variant B: built-in management with nextval() function

# CAUTION 1: must be consistent with DB table architecture
# CAUTION 2: One of built-in/user must be chosen but not both
#			Comment out the unused one.

	# Variant B
#B 	$self->{'filenum_nextval'} = 
#B 		$self->{dbh}->prepare("select nextval('${prefix}filenum')");
	# End of variants
	$self->{'files_insert'} =
		$self->{dbh}->prepare
			( "insert into ${prefix}files"
			. ' (filename, revision, fileid)'
			. ' values (?, ?, ?)'
			);

	# Variant B
#B 	$self->{'symnum_nextval'} = 
#B 		$self->{dbh}->prepare("select nextval('${prefix}symnum')");
	# End of variants
	$self->{'symbols_insert'} =
		$self->{dbh}->prepare
			( "insert into ${prefix}symbols"
			. ' (symname, symid, symcount)'
			. ' values (?, ?, 0)'
			);

	# Variant B
#B 	$self->{'typeid_nextval'} = 
#B 		$self->{dbh}->prepare("select nextval('${prefix}typenum')");
	# End of variants
	$self->{'langtypes_insert'} =
		$self->{dbh}->prepare
			( "insert into ${prefix}langtypes"
			. ' (typeid, langid, declaration)'
			. ' values (?, ?, ?)'
			);

	$self->{'delete_definitions'} =
		$self->{dbh}->prepare
			( "delete from ${prefix}definitions as d"
			. " using ${prefix}status t, ${prefix}releases r"
			. ' where r.releaseid = ?'
			. '  and  t.fileid = r.fileid'
			. '  and  t.relcount = 1'
			. '  and  d.fileid = r.fileid'
			);

	$self->{'delete_usages'} =
		$self->{dbh}->prepare
			( "delete from ${prefix}usages as u"
			. " using ${prefix}status t, ${prefix}releases r"
			. ' where r.releaseid = ?'
			. ' and t.fileid = r.fileid'
			. ' and t.relcount = 1'
			. ' and u.fileid = r.fileid'
			);

	# Variant U
# User unique record id management
	$self->uniquecountersinit($prefix);
	# The final $x_num will be saved in write_close before disconnecting
	# End of variants

	$self->SUPER::write_open();
}

#
# LXR::Index API Implementation
#

##### To activate PostgreSQL built-in record id management,
##### uncomment the following block.
##### Check also purgeall() and write_close()

# sub fileid {
# # 	my ($self, $filename, $revision) = @_;
# 	my $self = shift @_;
# 	my $fileid;
# 	$fileid = $self->fileidifexists(@_);
# 	unless ($fileid) {
# 		$self->{'filenum_nextval'}->execute();
# 		($fileid) = $self->{'filenum_nextval'}->fetchrow_array();
# 		$self->{'files_insert'}->execute(@_, $fileid);
# 		$self->{'status_insert'}->execute($fileid, 0);
# # 		$LXR::Index::files{"$filename\t$revision"} = $fileid;
# 	}
# 	return $fileid;
# }
# 
# sub symid {
# 	my ($self, $symname) = @_;
# 	my $symid;
# 	my $symcount;
# 
# 	unless (defined($symid = $LXR::Index::symcache{$symname})) {
# 		$self->{'symbols_byname'}->execute($symname);
# 		($symid, $symcount) = $self->{'symbols_byname'}->fetchrow_array();
# 		unless ($symid) {
# 			$self->{'symnum_nextval'}->execute();
# 			($symid) = $self->{'symnum_nextval'}->fetchrow_array();
# 			$self->{'symbols_insert'}->execute($symname, $symid);
# 			$symcount = 0;
# 		}
# 		$LXR::Index::symcache{$symname} = $symid;
# 		$LXR::Index::cntcache{$symname} = -$symcount;
# 	}
# 
# 	return $symid;
# }
# 
# sub decid {
# # 	my ($self, $lang, $string) = @_;
# 	my $self = shift @_;
# 	my $declid;
# 
# 	$self->{'langtypes_select'}->execute(@_);
# 	($declid) = $self->{'langtypes_select'}->fetchrow_array();
# 	unless (defined($declid)) {
# 		$self->{'typeid_nextval'}->execute();
# 		($declid) = $self->{'typeid_nextval'}->fetchrow_array();
# 		$self->{'langtypes_insert'}->execute($declid, @_);
# 	}
# 	
# 	return $declid;
# }

sub purgeall {
	my ($self) = @_;

	my $dbname = $config->{'dbname'};
	$dbname =~ s/^.*dbname=//;
	$dbname =~ s/;.*$//;
	my $prefix = $config->{'dbprefix'};
	my $ttc = $self->{dbh}->prepare
			( 'select count(*) from information_schema.tables'
			. ' where table_schema = \'public\''
			);
	$ttc->execute();
	my ($tablecount) = $ttc->fetchrow_array();
	$ttc = undef;
#	If DB is fully dedicated to this tree,
#	drop DB and reconstruct it.
#	It may be faster than prunig tables.
	if ($LXR::Index::schema_table_count == $tablecount) {
		$self->write_close();
		$self->final_cleanup();
		# Database is fully unlocked, we can launch scripts against it
# 		print STDERR	# uncomment if trace of next statement needed
		`NO_USER=1 ./${LXR::Index::db_script_dir}p:${dbname}:${prefix}.sh`;
		# Recoonect
		$self->{dbh} = DBI->connect	( $config->{'dbname'}
									, $config->{'dbuser'}
									, $config->{'dbpass'}
									, {'AutoCommit' => 0}
									)
			or die "Can't open connection to database: $DBI::errstr\n";
		# Reconfigure prepared transactions
		$self->read_open();
		$self->write_open();
	} else {
# Not really necessary, but nicer for debugging
	# Variant B
#B 		$self->{dbh}->do
#B 			("select setval('${prefix}filenum', 1, false)");
#B 		$self->{dbh}->do
#B 			("select setval('${prefix}symnum',  1, false)");
#B 		$self->{dbh}->do
#B 			("select setval('${prefix}typenum', 1, false)");
	# Variant U
		$self->uniquecountersreset(-1);
		$self->uniquecounterssave();
		$self->uniquecountersreset(0);
	# End of variants
		$self->{'purge_all'}->execute;
	}
}

#	PostgreSQL is in auto commit mode; disable calls to
#	commit to suppress warning messages.
# sub commit{}

sub write_close {
	my ($self) = @_;

	# Variant U
	$self->uniquecounterssave();
	# End of variants
	$self->{dbh}->commit();		# Force a real commit
	# Variant B
#B 	$self->{'filenum_nextval'} = undef;
#B 	$self->{'symnum_nextval'} = undef;
#B 	$self->{'typeid_nextval'} = undef;
#B 	$self->{'reset_filenum'} = undef;
#B 	$self->{'reset_symnum'} = undef;
#B 	$self->{'reset_typenum'} = undef;
	# End of variants

	$self->SUPER::write_close();
}

# sub final_cleanup {
# 	my ($self) = @_;
# 
# 	$self->dropuniversalqueries();
# 	$self->{dbh}->disconnect() or die "Disconnect failed: $DBI::errstr";
# }

sub post_processing {
	my ($self) = @_;

# 	TEMPORARY COMMENT - TEMPORARY COMMENT - TEMPORARY COMMENT !
#	It looks like the PGPASSFILE, PGPASSWORD parameter passing
#	or even ~/.pgpass reference does not work. Could not
#	determine the origin of the problem: Pg library, Perl library,
#	file permissions or working directory preset.
#	Consequently, use --novacuum option when indexing unattended
#	PostgreSQL databases.
#	-- ajl - 2016-09
#	To be removed when fixed

	my $dbname = $config->{'dbname'};
	my $dbhost = $dbname;
	$dbname =~ s/^.*dbi:Pg:dbname=//;
	$dbname =~ s/;.*$//;
	if ($dbhost =~ s/^.*host=//) {
		$dbhost =~ s/;.*$//;
	} else {
		$dbhost = '';
	}
	my $dbuser = $config->{'dbuser'};
	my $dbpass = $config->{'dbpass'};
	if ($dbhost) {
		`PGPASSFILE=custom.d/db-scripts.d/pgpass psql -d $dbname -h $dbhost -U $dbuser -W -c 'vacuum analyze;'`
	} else {
		`PGPASSFILE=custom.d/db-scripts.d/pgpass psql -d $dbname -U $dbuser -W -c 'vacuum analyze;'`
	}
}

1;
