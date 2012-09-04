# Copyright 2009 Ge van Geldorp
# Copyright 2012 Francois Gouget
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;

package ObjectModel::PropertyDescriptor;

=head1 NAME

ObjectModel::PropertyDescriptor - Base class for item property descriptions

=head1 DESCRIPTION

This includes the basic information for retrieving and storing the property
in the database, whether it is part of the primary key and whether it is
required or not.

=cut

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);

sub new
{
  my $class = shift;
  my $Name = shift;
  my $DisplayName = shift;
  my $IsKey = shift;
  my $IsRequired = shift;

  my $self = {Name        => $Name,
              DisplayName => $DisplayName,
              IsKey       => $IsKey,
              IsRequired  => $IsRequired,
              Class       => undef};
  $self = bless $self, $class;
  $self->_initialize(@_);
  return $self;
}

sub _initialize
{
}

sub GetName
{
  my $self = shift;

  return $self->{Name};
}

sub GetDisplayName
{
  my $self = shift;

  return $self->{DisplayName};
}

sub GetIsKey
{
  my $self = shift;

  return $self->{IsKey};
}

sub GetIsRequired
{
  my $self = shift;

  return $self->{IsRequired};
}

sub GetClass
{
  my $self = shift;

  return $self->{Class};
}

1;
