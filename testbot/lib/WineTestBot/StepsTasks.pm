# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
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

package WineTestBot::StepTask;

=head1 NAME

WineTestBot::StepTask - Merged Step + Task object

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use WineTestBot::Config;
use WineTestBot::Missions;


sub GetStepDir($)
{
  my ($self) = @_;
  my ($JobId, $_StepTaskId) = @{$self->GetMasterKey()};
  return "$DataDir/jobs/$JobId/". $self->StepNo;
}

# See WineTestBot::Step::GetFullFileName()
sub GetFullFileName($;$)
{
  my ($self, $FileName) = @_;

  $FileName = $self->FileName if (!defined $FileName);
  return undef if (!defined $FileName);

  my ($JobId, $_StepTaskId) = @{$self->GetMasterKey()};
  my $Path = "$DataDir/jobs/$JobId/";
  foreach my $StepNo ($self->StepNo, $self->PreviousNo)
  {
    next if (!$StepNo);
    my $Full = "$Path$StepNo/$FileName";
    return $Full if (-f $Full);
  }
  return $Path . $FileName;
}

sub GetTaskDir($)
{
  my ($self) = @_;
  return $self->GetStepDir() ."/". $self->TaskNo;
}

sub GetTitle($)
{
  my ($self) = @_;

  my @TitleParts;
  if ($self->Type eq "reconfig")
  {
    push @TitleParts, "Wine update";
  }
  elsif ($self->Type eq "build")
  {
    push @TitleParts, "build";
  }
  elsif ($self->FileType eq "exe32")
  {
    push @TitleParts, "32 bit";
  }
  elsif ($self->FileType eq "exe64")
  {
    push @TitleParts, "64 bit";
  }
  else
  {
    my ($ErrMessage, $Missions) = ParseMissionStatement($self->Missions);
    if (!defined $ErrMessage and @$Missions == 1)
    {
      my $Builds = $Missions->[0]->{Builds};
      if ($Builds->{build})
      {
        push @TitleParts, "build";
      }
      elsif ($Builds->{wow64} and ($Builds->{win32} or $Builds->{wow32}))
      {
        push @TitleParts, "32 & 64 bit";
      }
      elsif ($Builds->{win32} or $Builds->{wow32})
      {
        push @TitleParts, "32 bit";
      }
      elsif ($Builds->{wow64})
      {
        push @TitleParts, "64 bit";
      }
    }
  }
  if ($self->Type ne "suite" and $self->CmdLineArg)
  {
    push @TitleParts, $self->CmdLineArg;
  }

  my $Title = $self->VM->Name;
  $Title .= " (@TitleParts)" if (@TitleParts);
  return $Title;
}


package WineTestBot::StepsTasks;

=head1 NAME

WineTestBot::StepsTasks - A collection of StepsTasks objects

=head1 DESCRIPTION

Provides a flat collection of all the tasks in the specified Job.

Note that this is an in-memory only collection since it does not correspond to
a specific database table.

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreateStepsTasks);
}

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::VMs;

sub _initialize($$)
{
  my ($self, $Job) = @_;

  $self->SUPER::_initialize($Job);

  foreach my $Step (@{$Job->Steps->GetItems()})
  {
    foreach my $Task (@{$Step->Tasks->GetItems()})
    {
      my $StepTask = $self->CreateItem();
      $StepTask->Id(100 * $Step->No + $Task->No);
      $StepTask->StepNo($Step->No);
      $StepTask->PreviousNo($Step->PreviousNo);
      $StepTask->TaskNo($Task->No);
      $StepTask->Type($Step->Type);
      $StepTask->Status($Task->Status);
      $StepTask->VM($Task->VM);
      $StepTask->Timeout($Task->Timeout);
      $StepTask->FileName($Step->FileName);
      $StepTask->FileType($Step->FileType);
      $StepTask->Missions($Task->Missions);
      $StepTask->CmdLineArg($Task->CmdLineArg);
      $StepTask->Started($Task->Started);
      $StepTask->Ended($Task->Ended);
      $StepTask->TestFailures($Task->TestFailures);

      $self->{Items}{$StepTask->GetKey()} = $StepTask;
    }
  }

  $self->{Loaded} = 1;
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::StepTask->new($self);
}

# Note: To simplify maintenance replace enums with simple string fields.
my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("Id", "Id", 1, 1, "N", 4),
  CreateBasicPropertyDescriptor("StepNo", "Step no", !1, 1, "N", 2),
  CreateBasicPropertyDescriptor("PreviousNo", "Previous step", !1, !1, "N", 2),
  CreateBasicPropertyDescriptor("TaskNo", "Task no", !1, 1, "N", 2),
  CreateBasicPropertyDescriptor("Type", "Step type", !1, 1, "A", 32),
  CreateBasicPropertyDescriptor("Status", "Status", !1, 1, "A", 32),
  CreateItemrefPropertyDescriptor("VM", "VM", !1, 1, \&CreateVMs, ["VMName"]),
  CreateBasicPropertyDescriptor("Timeout", "Timeout", !1, 1, "N", 4),
  CreateBasicPropertyDescriptor("FileName", "File name", !1, !1, "A", 100),
  CreateBasicPropertyDescriptor("FileType", "File Type", !1, 1, "A", 32),
  CreateBasicPropertyDescriptor("Missions", "Missions", !1, 1, "A", 256),
  CreateBasicPropertyDescriptor("CmdLineArg", "Command line args", !1, !1, "A", 256),
  CreateBasicPropertyDescriptor("Started", "Execution started", !1, !1, "DT", 19),
  CreateBasicPropertyDescriptor("Ended", "Execution ended", !1, !1, "DT", 19),
  CreateBasicPropertyDescriptor("TestFailures", "Number of test failures", !1, !1, "N", 6),
);

sub CreateStepsTasks(;$$)
{
  my ($ScopeObject, $Job) = @_;

  return WineTestBot::StepsTasks->new(undef, "Tasks", undef,
                                      \@PropertyDescriptors, $ScopeObject, $Job);
}

1;
