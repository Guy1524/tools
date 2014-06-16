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

package ObjectModel::EnumPropertyDescriptor;

=head1 NAME

ObjectModel::EnumPropertyDescriptor - Defines an enumeration property

=head1 DESCRIPTION

This handles the ENUM columns. In particular ValidateValue() checks that the
new value is allowed.

=cut

use ObjectModel::PropertyDescriptor;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::PropertyDescriptor Exporter);
@EXPORT = qw(&CreateEnumPropertyDescriptor);

sub _initialize($$)
{
  my ($self, $Values) = @_;

  $self->{Class} = "Enum";
  $self->{Values} = $Values;

  $self->SUPER::_initialize();
}

sub GetValues($)
{
  my ($self) = @_;

  return $self->{Values};
}

sub GetColNames($)
{
  my ($self) = @_;

  return [$self->{Name}];
}

sub ValidateValue($$$)
{
  my ($self, $Value, $IsNew) = @_;

  if ($self->GetIsRequired())
  {
    if (!$IsNew && (!defined($Value) || $Value eq ""))
    {
      return $self->GetDisplayName() .  ": Must be entered";
    }
  }

  foreach my $V (@{$self->{Values}})
  {
      return undef if ($V eq $Value);
  }
  return $self->GetDisplayName() . ": Is not valid";
}

sub CreateEnumPropertyDescriptor($$$$$)
{
  my ($Name, $DisplayName, $IsKey, $IsRequired, $Values) = @_;
  return ObjectModel::EnumPropertyDescriptor->new($Name, $DisplayName, $IsKey, $IsRequired, $Values);
}

1;
