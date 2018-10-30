# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# VM details page
#
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

package VMDetailsPage;

use ObjectModel::CGI::ItemPage;
our @ISA = qw(ObjectModel::CGI::ItemPage);

use WineTestBot::VMs;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateVMs());
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  return "" if ($PropertyName =~ /^(?:ChildPid|ChildDeadline|Errors)$/);
  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub Save($)
{
  my ($self) = @_;

  my $OldStatus = $self->{Item}->Status || "";
  return !1 if (!$self->SaveProperties());

  if ($OldStatus ne $self->{Item}->Status)
  {
    # The administrator action resets the consecutive error count
    $self->{Item}->Errors(undef);
    my ($ErrProperty, $ErrMessage) = $self->{Item}->Validate();
    if (!defined $ErrMessage)
    {
      $self->{Item}->RecordStatus(undef, $self->{Item}->Status ." administrator");
    }
  }

  my $ErrKey;
  ($ErrKey, $self->{ErrField}, $self->{ErrMessage}) = $self->{Collection}->Save();
  return ! defined($self->{ErrMessage});
}

sub GenerateFooter($)
{
  my ($self) = @_;
  print "<p></p><div class='CollectionBlock'><table>\n";
  print "<thead><tr><th class='Record'>Legend</th></tr></thead>\n";
  print "<tbody><tr><td class='Record'>\n";

  print "<p>The Missions syntax is <i>mission1:mission2:...|mission3|...</i> where <i>mission1</i> and <i>mission2</i> will be run in the same task, and <i>mission3</i> in a separate task.<br>\n";
  print "Each mission is composed of a build and options separated by commas: <i>build,option1=value,option2,...</i>. The value can be omitted for boolean options and defaults to true.<br>\n";
  print "The supported builds are <i>build</i> for build VMs; <i>exe32</i> and <i>exe64</i> for Windows VMs;<i> win32</i>, <i>wow32</i> and <i>wow64</i> for Wine VMs.</p>\n";
  print "<p>On Wine VMs:<br>\n";
  print "The <i>test</i> option can be set to <i>build</i> to only test building, <i>test</i> to only rerun patched tests, <i>module</i> to rerun all of a patched dll or program's tests, or <i>all</i> to always rerun all the tests.<br>\n";
  print "If set, the <i>nosubmit</i> option specifies that the WineTest results should not be published online.</p>\n";
  print "</td></tr></tbody>\n";
  print "</table></div>\n";
  $self->SUPER::GenerateFooter();
}

package main;

my $Request = shift;

my $VMDetailsPage = VMDetailsPage->new($Request, "admin");
$VMDetailsPage->GeneratePage();
