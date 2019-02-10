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

package LXR::Index::Oracle;

# ***
# *** CAUTION -CAUTION - CAUTION ***
# ***
# *** This update has not been tested because
# *** Oracle has a proprietary licence.
# ***
# *** (It was written with SQL syntax description only
# *** without live checks.)
# ***
# *** If something goes wrong, report to the maintainer.
# ***

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
								, { RaiseError => 1
								  , AutoCommit => 1
								  }
								)
		or die "Can't open connection to database: $DBI::errstr\n";

	return $self;
}

sub write_open {
	my ($self) = @_;

	my $prefix = $config->{'dbprefix'};

	$self->{'files_insert'} =
		$self->{dbh}->prepare
			( "insert into ${prefix}files"
			. ' (filename, revision, fileid)'
			. " values (?, ?, ${prefix}filenum.nextval)"
			);

	$self->{'symbols_insert'} =
		$self->{dbh}->prepare
			( "insert into ${prefix}symbols"
			. ' (symname, symid) values'
			. " ( ?, ${prefix}symnum.nextval)"
			);

	$self->{'langtypes_insert'} =
		$self->{dbh}->prepare
			( "insert into ${prefix}langtypes"
			. ' (typeid, langid, declaration)'
			. " values (${prefix}typenum.nextval, ?, ?)"
			);

	$self->{'purge_all'} = $self->{dbh}->prepare
		("${prefix}PurgeAll");

	$self->SUPER::write_open();
}

1;
