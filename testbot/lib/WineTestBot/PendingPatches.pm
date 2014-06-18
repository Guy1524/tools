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

package WineTestBot::PendingPatch;

=head1 NAME

WineTestBot::PendingPatch - Tracks the patches of an incomplete series

=head1 DESCRIPTION

Ties a WineTestBot::Patch object to the WineTestBot::PendingPatchSet object
identifying the patch series it belongs to.

=cut

use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

package WineTestBot::PendingPatches;

=head1 NAME

WineTestBot::PendingPatches - A collection of WineTestBot::PendingPatch objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::Patches;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreatePendingPatches);

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("No", "Part no", 1, 1, "N", 2),
    CreateItemrefPropertyDescriptor("Patch", "Submitted via patch", !1, 1, \&WineTestBot::Patches::CreatePatches, ["PatchId"]),
  );
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::PendingPatch->new($self);
}

sub CreatePendingPatches(;$$)
{
  my ($ScopeObject, $PendingPatchSet) = @_;

  return WineTestBot::PendingPatches->new("PendingPatches", "PendingPatches", "PendingPatch", \@PropertyDescriptors, $ScopeObject, $PendingPatchSet);
}

1;
