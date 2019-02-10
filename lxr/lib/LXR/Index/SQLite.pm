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

package LXR::Index::SQLite;

use strict;
use DBI;
use LXR::Common;

our @ISA = ('LXR::Index');

# NOTE:
#	Some Perl statements below are commented out as '# opt'.
#	This is meant to decrease the number of calls to DBI methods,
#	in this case finish() since we know the previous fetch_array()
#	did retrieve all selected rows.
#	The warning message is removed through undef'ing the DBI
#	prepares in final_cleanup before disconnecting.
#	The time advantage is negligible, if any, on the test cases. It
#	is not known if it grows to an appreciable difference on huge
#	trees, such as the Linux kernel.
#
#	If strict rule observance is preferred, uncomment the '# opt'.
#	You can leave the undef'ing in final_cleanup, they are executed
#	only once and do not contribute to the running time behaviour.

sub new {
	my ($self, $config) = @_;

	$self = bless({}, $self);
	$self->{dbh} = DBI->connect($config->{'dbname'})
	or die "Can't open connection to database: $DBI::errstr\n";

#	To really remove all writes from SQLite operation, auto commit
#	mode must be activated. Otherwise, even with read transactions
#	such as SELECT, SQLite tries to write into its cache. Auto
#	commit does not matter when browsing as Perl interpretation
#	dominates execution time.
	$self->{dbh}{'AutoCommit'} = 1;

	return $self;
}

#
# LXR::Index API Implementation
#

sub write_open {
	my ($self) = @_;

	my $prefix = $config->{'dbprefix'};

#	SQLite is forced into explicit commit mode as the medium-sized
#	test cases have shown a 40-times (!) performance improvement
#	over auto commit.
	$self->{dbh}{'AutoCommit'} = 0;

#	Since SQLite has no auto-incrementing counter,
#	we simulate them in specific one-record tables.
#	These counters provide unique record ids for
#	files, symbols and language types.
	$self->uniquecountersinit($prefix);
	# The final $x_num will be saved in write_close before disconnecting

#	'purge_all' is not used but must not be prepare'd in the parent object,
#	otherwise TRUNCATE TABLE statement will cause an error because SQLite
#	has no such statement.
#	The generic transaction must be replaced by individual DELETE on each table.
	$index->{'purge_all'} = 1;
	$self->SUPER::write_open();
}

sub write_close {
	my ($self) = @_;

	$self->uniquecounterssave();
	$self->SUPER::write_close();
}

sub purgeall {
	my ($self) = @_;

	my $dbname = $config->{'dbname'};
	$dbname =~ s/^.*dbname=//;
	$dbname =~ s/;.*$//;
	my $prefix = $config->{'dbprefix'};
	my $ttc = $self->{dbh}->prepare
			( 'select count(*)  from sqlite_master'
			. ' where type=\'table\''
			. ' and not name like \'sqlite_%\''
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
		unlink $dbname;
		# Database is fully unlocked, we can launch scripts against it
		$dbname = substr($dbname, 1);
		$dbname =~ s!/!@!g;
# 		print STDERR	# uncomment if trace of next statement needed
		`NO_USER=1 ./${LXR::Index::db_script_dir}s:${dbname}:${prefix}.sh`;
		# Recoonect
		$self->{dbh} = DBI->connect	( $config->{'dbname'}
									, {'AutoCommit' => 0}
									)
			or die "Can't open connection to database: $DBI::errstr\n";
		# Reconfigure prepared transactions
		$self->read_open();
		$self->write_open();
	} else {
#	DB hosts several trees. Since we do not know if the other trees
#	should be purged, purge only the tables related to this tree.

# Not really necessary, but nicer for debugging
		$self->uniquecountersreset(-1);
		$self->uniquecounterssave();
		$self->uniquecountersreset(0);

		my $prefix = $config->{'dbprefix'};
		$self->{dbh}->do("delete from ${prefix}definitions");
		$self->{dbh}->do("delete from ${prefix}usages");
		$self->{dbh}->do("delete from ${prefix}langtypes");
		$self->{dbh}->do("delete from ${prefix}symbols");
		$self->{dbh}->do("delete from ${prefix}releases");
		$self->{dbh}->do("delete from ${prefix}status");
		$self->{dbh}->do("delete from ${prefix}files");
		$self->{dbh}->do("delete from ${prefix}times");
		$self->{dbh}->commit;
	}
}

# sub final_cleanup {
# 	my ($self) = @_;
# 
# 	$self->dropuniversalqueries();
# 	$self->{dbh}->disconnect() or die "Disconnect failed: $DBI::errstr";
# }

sub post_processing {
	my ($self) = @_;

	my $dbfile = $config->{'dbname'};
	$dbfile =~ s/^.*dbi:SQLite:dbname=//;
	$dbfile =~ s/;.*$//;
	`sqlite3 $dbfile 'vacuum'`
}

1;
