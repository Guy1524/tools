# Web session handling
#
# Copyright 2009 Ge van Geldorp
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

=head1 NAME

WineTestBot::CGI::Sessions - Session collection

=cut


package WineTestBot::CGI::Session;

use WineTestBot::Utils;
use WineTestBot::WineTestBotObjects;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub InitializeNew
{
  my $self = shift;

  $self->SUPER::InitializeNew(@_);

  $self->Permanent(!1);
}

package WineTestBot::CGI::Sessions;

use CGI::Cookie;
use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::Config;
use WineTestBot::Users;
use WineTestBot::Utils;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateSessions &NewSession);

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Id",        "Session id",         1,  1, "A", 32),
    CreateItemrefPropertyDescriptor("User",    "User",              !1,  1, \&CreateUsers, ["UserName"]),
    CreateBasicPropertyDescriptor("Permanent", "Permanent session", !1,  1, "B",  1),
  );
}

sub CreateItem
{
  my $self = shift;

  return WineTestBot::CGI::Session->new($self);
}

sub DeleteNonPermanentSessions
{
  my $self = shift;
  my $User = $_[0];

  $self->AddFilter("User", [$User]);
  $self->AddFilter("Permanent", [!1]);
  map { $self->DeleteItem($_); } @{$self->GetItems()};
}

sub NewSession
{
  my $self = shift;
  my ($User, $Permanent) = @_;

  CreateSessions()->DeleteNonPermanentSessions($User);

  my $Session = $self->Add();
  my $Existing = $Session;
  my $Id;
  while (defined($Existing))
  {
    $Id = "";
    foreach my $i (1..8)
    {
      $Id .= sprintf("%lx", int(rand(2 ** 16)));
    }
    $Existing = $self->GetItem($Id);
  }
  $Session->Id($Id);
  $Session->User($User);
  $Session->Permanent($Permanent);

  my ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();

  return ($ErrMessage, $Session);
}

sub CreateSessions
{
  return WineTestBot::CGI::Sessions->new("Sessions", "Sessions", "Session",
                                         \@PropertyDescriptors);
}

1;
