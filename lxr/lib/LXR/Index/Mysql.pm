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

package LXR::Index::Mysql;

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
								, {'AutoCommit' => 0}
								)
#	MySQL seems to be neutral vis-à-vis auto commit mode, though
#	a tiny improvement may show up with explicit commit (the
#	difference on the medium-sized test cases is difficult to
#	appreciate since it is within the measurement error).
		or die "Can't open connection to database: $DBI::errstr\n";

	return $self;
}

sub write_open {
	my ($self) = @_;

	my $prefix = $config->{'dbprefix'};

#	MySQL may be run with its built-in unique record id management
#	mechanisms. There is only a small performance improvement
#	between the most efficient variant and user management.
#	Uncomment the desired management method:
#	- Variant U: common user management (in Index.pm)
#	- Variant A enabled: built-in with id retrieval through
#	-			record re-read
#	- Variant B enabled: built-in with id retrieval through 
#				last_insert_id() function (faster than variant A)
#	Variant B is recommended over variant A.

# CAUTION 1: must be consistent with DB table architecture
#	extra tables with variant U
#	autoincrement fields with variants A/B
# CAUTION 2: Only one of built-in A or B/user must be chosen
#			Comment out the unused ones.

	# Variant B
#B	$self->{'last_auto_val'} = 
#B		$self->{dbh}->prepare('select last_insert_id()');
	# End of prefix for variant B

	# Variants A & B
#AB	$self->{'files_insert'} =
#AB		$self->{dbh}->prepare
#AB			( "insert into ${prefix}files"
#AB			. ' (filename, revision, fileid)'
#AB			. ' values (?, ?, NULL)'
#AB			);
#AB
#AB	$self->{'symbols_insert'} =
#AB		$self->{dbh}->prepare
#AB			( "insert into ${prefix}symbols"
#AB			. ' (symname, symid, symcount)'
#AB			. ' values ( ?, NULL, 0)'
#AB			);
#AB
#AB	$self->{'langtypes_insert'} =
#AB		$self->{dbh}->prepare
#AB		( "insert into ${prefix}langtypes"
#AB			. ' (typeid, langid, declaration)'
#AB			. ' values (NULL, ?, ?)'
#AB			);
	# End of variants A & B

	$self->{'purge_all'} = $self->{dbh}->prepare
		( "call ${prefix}PurgeAll()"
		);

	# Variant U
	$self->uniquecountersinit($prefix);
	# The final $x_num will be saved in final_cleanup before disconnecting
	# End of variants

	$self->SUPER::write_open();
}

sub write_close {
	my ($self) = @_;

	# Variant U
	$self->uniquecounterssave();
	# End of variants
	# Variant B
#B 	$self->{'last_auto_val'} = undef;
	# End of variants

	$self->SUPER::write_close();
}

##### To activate MySQL built-in record id management,
##### uncomment the following block and choose one of
##### the A/B variants.
##### Check also final_cleanup()

# sub fileid {
# # 	my ($self, $filename, $revision) = @_;
# 	my $self = shift @_;
# 	my $fileid;
# 
# 	$fileid = $self->fileidifexists(@_);
# 	unless ($fileid) {
# 		$self->{'files_insert'}->execute(@_);
# 	# Variant B
# 		$self->{'last_auto_val'}->execute();
# 		($fileid) = $self->{'last_auto_val'}->fetchrow_array();
# 		$self->{'status_insert'}->execute($fileid, 0);
# 	# Variant A
# #A		$self->{'files_select'}->execute(@_);
# #A		($fileid) = $self->{'files_select'}->fetchrow_array();
# #A		$self->{'status_insert'}->execute(0);
# 	# End of variants
# # opt	$self->{'last_auto_val'}->finish();
# # 		$files{"$filename\t$revision"} = $fileid;
# 	}
# 	return $fileid;
# }
# 
# sub symid {
# 	my ($self, $symname) = @_;
# 	my $symid;
# 	my $symcount;
# 
# 	$symid = $LXR::Index::symcache{$symname};
# 	unless (defined($symid)) {
# 		$self->{'symbols_byname'}->execute($symname);
# 		($symid, $symcount) = $self->{'symbols_byname'}->fetchrow_array();
# 		unless ($symid) {
# 			$self->{'symbols_insert'}->execute($symname);
# #             # Get the id of the new symbol
# 	# Variant B
# 			$self->{'last_auto_val'}->execute();
# 			($symid) = $self->{'last_auto_val'}->fetchrow_array();
# 			$symcount = 0;
# 	# Variant A
# #A 			$self->{'symbols_byname'}->execute($symname);
# #A 			($symid, $symcount) = $self->{'symbols_byname'}->fetchrow_array();
# 	# End of variants
# 		}
# 		$LXR::Index::symcache{$symname} = $symid;
# 		$LXR::Index::cntcache{$symname} = -$symcount;
# 	}
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
# 		$self->{'langtypes_insert'}->execute(@_);
# 	# Variant B
# 		$self->{'last_auto_val'}->execute();
# 		($declid) = $self->{'last_auto_val'}->fetchrow_array();
# 	# Variant A
# #A 		$self->{'langtypes_select'}->execute(@_);
# #A 		($declid) = $self->{'langtypes_select'}->fetchrow_array();
# 	# End of variants
# 	}
# # opt	$self->{'last_auto_val'}->finish();
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
			. ' where table_schema = \''
			. $dbname
			. '\''
			);
	$ttc->execute();
	my ($tablecount) = $ttc->fetchrow_array();
	$ttc = undef;
#	If DB is fully dedicated to this tree,
#	drop DB and reconstruct it.
#	It is faster than prunig tables because of a performance
#	bug xith TRUNCATE TABLES in MySQL.
	if ($LXR::Index::schema_table_count == $tablecount) {
		$self->write_close();
		$self->final_cleanup();
		# Database is fully unlocked, we can launch scripts against it
# 		print STDERR	# uncomment if trace of next statement needed
		`NO_USER=1 ./${LXR::Index::db_script_dir}m:${dbname}:${prefix}.sh`;
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
#	DB hosts several trees. Since we do not know if the other trees
#	should be purged, purge only the tables related to this tree.
		$self->{'purge_all'}->execute();
		# Variant U
		$self->uniquecountersreset(0);
		# End of variants
		# Fix a collateral effect of TRUNCATE TABLES performance bug workaround
		$self->{dbh}->do
				("drop trigger if exists ${prefix}remove_file");
		$self->{dbh}->do
				( "create trigger ${prefix}remove_file"
				. " after delete on ${prefix}status"
				. ' for each row'
				. "  delete from ${prefix}files"
				. '   where fileid = old.fileid'
				);
		$self->{dbh}->do
				("drop trigger if exists ${prefix}add_release");
		$self->{dbh}->do
				( "create trigger ${prefix}add_release"
				. " after insert on ${prefix}releases"
				. ' for each row'
				. "  update ${prefix}status"
				. '   set relcount = relcount + 1'
				. '   where fileid = new.fileid'
				);
		$self->{dbh}->do
				("drop trigger if exists ${prefix}remove_release");
		$self->{dbh}->do
				( "create trigger ${prefix}remove_release"
				. " after delete on ${prefix}releases"
				. ' for each row'
				. "  update ${prefix}status"
				. '   set relcount = relcount - 1'
				. '   where fileid = old.fileid'
				. '     and relcount > 0'
				);
		$self->{dbh}->do
				("drop trigger if exists ${prefix}remove_definition");
		$self->{dbh}->do
				( "create trigger ${prefix}remove_definition"
				. " after delete on ${prefix}definitions"
				. ' for each row'
				. '  begin'
				. "   call ${prefix}decsym(old.symid);"
				. '   if old.relid is not null'
				. "   then call ${prefix}decsym(old.relid);"
				. '   end if;'
				. '  end'
				);
		$self->{dbh}->do
				( "drop trigger if exists ${prefix}remove_usage");
		$self->{dbh}->do
				( "create trigger ${prefix}remove_usage"
				. " after delete on ${prefix}usages"
				. ' for each row'
				. "  call ${prefix}decsym(old.symid)"
				);
	}
}

sub post_processing {
	my ($self) = @_;

	my $dbfile = $config->{'dbname'};
	my $dbhost = $dbfile;
	$dbfile =~ s/^.*dbi:mysql:dbname=//;
	$dbfile =~ s/;.*$//;
	$dbhost =~ s/^.*host=//;
	$dbhost =~ s/;.*$//;
	my $dbuser = $config->{'dbuser'};
	my $dbpass = $config->{'dbpass'};
	my $prefix = $config->{'dbprefix'};
	my $statement = 'optimize local table'
				. " ${prefix}files"
				. " ${prefix}status"
				. " ${prefix}releases"
				. " ${prefix}langtypes"
				. " ${prefix}symbols"
				. " ${prefix}definitions"
				. " ${prefix}usages";
	`mysql $dbfile -u $dbuser -p$dbpass -e $statement`;
	$statement = 'analyze local table'
				. " ${prefix}files"
				. " ${prefix}status"
				. " ${prefix}releases"
				. " ${prefix}langtypes"
				. " ${prefix}symbols"
				. " ${prefix}definitions"
				. " ${prefix}usages";
	`mysql $dbfile -u $dbuser -p$dbpass -e $statement`;
}

1;
