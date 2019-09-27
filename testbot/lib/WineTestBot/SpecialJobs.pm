# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Provides methods to create the jobs that update Wine or run the full
# WineTest suite.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2018-2019 Francois Gouget
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

package WineTestBot::SpecialJobs;

=head1 NAME

WineTestBot::SpecialJobs - Create the jobs that update Wine or run the full
WineTest suite.

=cut

use Exporter 'import';
our @EXPORT = qw(GetReconfigVMs AddReconfigJob
                 GetWindowsTestVMs AddWindowsTestJob
                 GetWineTestVMs AddWineTestJob);

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Missions;
use WineTestBot::PatchUtils; # Get*Timeout()
use WineTestBot::Users;
use WineTestBot::VMs;


sub GetReconfigVMs($$)
{
  my ($VMKey, $VMType) = @_;

  my $VMs = CreateVMs();
  $VMs->AddFilter("Name", [$VMKey]) if (defined $VMKey);
  $VMs->AddFilter("Type", [$VMType]);
  $VMs->FilterEnabledRole();

  my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
  my @SortedVMs = map { $VMs->GetItem($_) } @$SortedKeys;
  return \@SortedVMs;
}

sub AddReconfigJob($$$)
{
  my ($VMs, $VMKey, $VMType) = @_;
  return undef if (!@$VMs);

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User(GetBatchUser());
  $NewJob->Priority(3);
  my $Remarks = defined $VMKey ? "$VMKey $VMType VM" : "$VMType VMs";
  $NewJob->Remarks("Update the $Remarks");

  # Add a step to the job
  my $Steps = $NewJob->Steps;
  my $BuildStep = $Steps->Add();
  $BuildStep->Type("reconfig");
  $BuildStep->FileType("none");

  # Add a task for each VM
  foreach my $VM (@$VMs)
  {
    my $Task = $BuildStep->Tasks->Add();
    $Task->VM($VM);

    # Merge all the tasks into one so we only recreate the base snapshot once
    my $MissionStatement = $VM->Type ne "wine" ? "exe32:exe64" :
                           MergeMissionStatementTasks($VM->Missions);
    my ($ErrMessage, $Missions) = ParseMissionStatement($MissionStatement);
    if (defined $ErrMessage)
    {
      return "$VMKey has an invalid mission statement: $ErrMessage";
    }
    if (@$Missions != 1)
    {
      return "Found no mission or too many task missions for $VMKey";
    }
    $Task->Timeout(GetBuildTimeout(undef, $Missions->[0]));
    $Task->Missions($Missions->[0]->{Statement});
  }

  # Save it all
  $NewJob->Status("staging");
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    return "Failed to save the '$Remarks' job: $ErrMessage";
  }
  return undef;
}

sub GetWindowsTestVMs($$$)
{
  my ($VMKey, $Build, $BaseJob) = @_;

  my $VMs = CreateVMs();
  $VMs->AddFilter("Type", $Build eq "exe32" ? ["win32", "win64"] : ["win64"]);
  if (defined $VMKey)
  {
    $VMs->AddFilter("Name", [$VMKey]);
    $VMs->FilterEnabledRole();
  }
  elsif ($BaseJob)
  {
    $VMs->AddFilter("Role", $BaseJob eq "base" ? ["base"] :
                            $BaseJob eq "other" ? ["winetest"] :
                            ["base", "winetest"]);
  }
  else
  {
    $VMs->FilterEnabledRole();
  }

  my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
  my @SortedVMs = map { $VMs->GetItem($_) } @$SortedKeys;
  return \@SortedVMs;
}

sub AddWindowsTestJob($$$$$)
{
  my ($VMs, $VMKey, $Build, $BaseJob, $LatestBaseName) = @_;
  return undef if (!@$VMs);

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User(GetBatchUser());
  $NewJob->Priority(($BaseJob eq "base" and $Build eq "exe32") ? 8 : 9);
  my $Remarks = defined $VMKey ? "$VMKey VM" :
                $Build eq "exe64" ? "64 bit VMs" :
                "$BaseJob VMs";
  $NewJob->Remarks("WineTest: $Remarks");

  # Add a task for each VM
  my $Tasks;
  foreach my $VM (@$VMs)
  {
    my ($ErrMessage, $Missions) = ParseMissionStatement($VM->Missions);
    if (defined $ErrMessage)
    {
      return "$VMKey has an invalid mission statement: $!";
    }

    foreach my $TaskMissions (@$Missions)
    {
      next if (!$TaskMissions->{Builds}->{$Build});

      if (!$Tasks)
      {
        # Add a step to the job
        my $TestStep = $NewJob->Steps->Add();
        $TestStep->Type("suite");
        $TestStep->FileName($LatestBaseName);
        $TestStep->FileType($Build);
        $Tasks = $TestStep->Tasks;
      }

      my $Task = $Tasks->Add();
      $Task->VM($VM);
      $Task->Timeout($SuiteTimeout);
      $Task->Missions($TaskMissions->{Statement});
    }
  }

  # Save it all
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    return "Failed to save the '$Remarks' job: $ErrMessage";
  }

  # Stage the test file so it can be picked up by the job
  if (!link("$DataDir/latest/$LatestBaseName",
            "$DataDir/staging/job". $NewJob->Id ."_$LatestBaseName"))
  {
    return "Failed to stage $LatestBaseName: $!";
  }

  # Switch Status to staging to indicate we are done setting up the job
  $NewJob->Status("staging");
  ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    return "Failed to save the '$Remarks' job (staging): $ErrMessage";
  }
  return undef;
}

sub GetWineTestVMs($)
{
  my ($VMKey) = @_;

  my $VMs = CreateVMs();
  $VMs->AddFilter("Name", [$VMKey]) if (defined $VMKey);
  $VMs->AddFilter("Type", ["wine"]);
  $VMs->FilterEnabledRole();

  my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
  my @SortedVMs = map { $VMs->GetItem($_) } @$SortedKeys;
  return \@SortedVMs;
}

sub AddWineTestJob($$)
{
  my ($VMs, $VMKey) = @_;
  return undef if (!@$VMs);

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User(GetBatchUser());
  $NewJob->Priority(7);
  my $Remarks = defined $VMKey ? "$VMKey VM" : "Wine VMs";
  $NewJob->Remarks("WineTest: $Remarks");

  # Add a step for each VM
  foreach my $VM (@$VMs)
  {
    # Move all the missions into separate tasks so we don't have one very
    # long task hogging the VM forever. Note that this is also ok because
    # the WineTest tasks don't have to recompile Wine.
    my $MissionStatement = SplitMissionStatementTasks($VM->Missions);
    my ($ErrMessage, $Missions) = ParseMissionStatement($MissionStatement);
    if (defined $ErrMessage)
    {
      return "$VMKey has an invalid mission statement: $!";
    }

    my $Tasks;
    foreach my $TaskMissions (@$Missions)
    {
      if (!$Tasks)
      {
        # Add a step to the job
        my $TestStep = $NewJob->Steps->Add();
        $TestStep->Type("suite");
        $TestStep->FileType("none");
        $Tasks = $TestStep->Tasks;
      }

      my $Task = $Tasks->Add();
      $Task->VM($VM);
      $Task->Timeout(GetTestTimeout(undef, $TaskMissions));
      $Task->Missions($TaskMissions->{Statement});
    }
  }

  # Save it all
  $NewJob->Status("staging");
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    return "Failed to save the '$Remarks' job: $ErrMessage";
  }

  return undef;
}

1;
