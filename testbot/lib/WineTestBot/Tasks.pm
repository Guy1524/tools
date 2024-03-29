# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014 Francois Gouget
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

package WineTestBot::Task;

=head1 NAME

WineTestBot::Task - A task associated with a given WineTestBot::Step object

=head1 DESCRIPTION

A WineTestBot::Step is composed of one or more Tasks, each responsible for
performing that Step in a WineTestBot::VM virtual machine. For instance a Step
responsible for running a given test would have one Task object for each
virtual machine that the test must be performed in.

A Task's lifecyle is as follows:
=over

=item *
A Task is created with Status set to queued which means it is ready to be run
as soon as long as the Step itself is runnable (see the WineTestBot::Step
documentation).

=item *
Once the Task is running on the corresponding VM the Status field is set to
running.

=item *
If running the Task fails due to a transient error the TestFailure field
is checked. If it is lower than a configurable threshold the Status is
reset to queued and the TestFailure field is incremented. Otherwise the
Status is set to boterror and the Task is considered to have completed.

=item *
If the Task completes normally the Status field is set to the appropriate
value based on the result: completed, badpatch, etc.

=item *
If the Task is canceled by the user its Status is set to canceled.

=item *
If the Task's Step cannot be run because the Step it depends on failed, then
Status is set to skipped.

=back

=cut

use WineTestBot::WineTestBotObjects;
our @ISA = qw(WineTestBot::WineTestBotItem);

use File::Path;
use ObjectModel::BackEnd;
use WineTestBot::Config;


sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  # Make up an initial, likely unique, key so the Task can be added to the
  # Collection
  my $Keys = $Collection->GetKeys();
  $self->No(scalar @$Keys + 1);

  $self->Status("queued");

  $self->SUPER::InitializeNew($Collection);
}

sub GetDir($)
{
  my ($self) = @_;
  my ($JobId, $StepNo, $TaskNo) = @{$self->GetMasterKey()};
  return "$DataDir/jobs/$JobId/$StepNo/$TaskNo";
}

sub CreateDir($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  mkpath($Dir, 0, 0775);
  return $Dir;
}

sub RmTree($)
{
  my ($self) = @_;
  my $Dir = $self->GetDir();
  rmtree($Dir);
}

sub _SetupTask($$)
{
  my ($VM, $self) = @_;

  # Remove the previous run's files if any
  my $Dir = $self->GetDir();
  if (-d $Dir)
  {
    mkpath("$Dir.new", 0, 0775);
    foreach my $Filename ("log", "log.err")
    {
      if (-f "$Dir/old_$Filename")
      {
        rename "$Dir/old_$Filename", "$Dir.new/old_$Filename";
      }
      if (open(my $Src, "<", "$Dir/$Filename"))
      {
        if (open(my $Dst, ">>", "$Dir.new/old_$Filename"))
        {
          print $Dst "----- Run ", ($self->TestFailures || 0), " $Filename\n";
          while (my $Line = <$Src>)
          {
            print $Dst $Line;
          }
          close($Dst);
        }
        close($Src);
      }
    }

    $self->RmTree();
    rename("$Dir.new", $Dir);
  }

  # Capture Perl errors in the task's generic error log
  my $TaskDir = $self->CreateDir();
  if (open(STDERR, ">>", "$TaskDir/log.err"))
  {
    # Make sure stderr still flushes after each print
    my $tmp=select(STDERR);
    $| = 1;
    select($tmp);
  }
  else
  {
    require WineTestBot::Log;
    WineTestBot::Log::LogMsg("unable to redirect stderr to '$TaskDir/log.err': $!\n");
  }
}

=pod
=over 12

=item C<Run()>

Starts a script in the background to execute the specified task. The command is
of the form:

    ${ProjectName}Run${Type}.pl ${JobId} ${StepNo} ${TaskNo}

Where $Type corresponds to the Task's type.

=back
=cut

sub Run($$)
{
  my ($self, $Step) = @_;

  my ($JobId, $StepNo, $TaskNo) = @{$self->GetMasterKey()};
  my $Script = $Step->Type eq "reconfig" ? "Reconfig" :
               $self->VM->Type eq "wine" ? "WineTest" :
               $Step->Type eq "build" ? "Build" :
               "Task";
  my $Args = ["$BinDir/${ProjectName}Run$Script.pl", "--log-only",
              $JobId, $StepNo, $TaskNo];

  my $ErrMessage = $self->VM->Run("running", $Args,
                                  $self->Timeout + $TimeoutMargin,
                                  \&_SetupTask, $self);
  if (!$ErrMessage)
  {
    $self->Status("running");
    $self->Started(time());
    my $_ErrProperty;
    ($_ErrProperty, $ErrMessage) = $self->Save();
  }
  return $ErrMessage;
}

sub CanRetry($)
{
  my ($self) = @_;
  return ($self->TestFailures || 0) + 1 < $MaxTaskTries;
}

sub UpdateStatus($$)
{
  my ($self, $Skip) = @_;

  my $Status = $self->Status;
  my $VM = $self->VM;

  if ($Status eq "running" and
      ($VM->Status ne "running" or !$VM->HasRunningChild()))
  {
    my ($JobId, $StepNo, $TaskNo) = @{$self->GetMasterKey()};
    my $OldUMask = umask(002);
    my $TaskDir = $self->CreateDir();
    if (open TASKLOG, ">>$TaskDir/log.err")
    {
      print TASKLOG "TestBot process got stuck or died unexpectedly\n";
      close TASKLOG;
    }
    umask($OldUMask);

    require WineTestBot::Log;
    WineTestBot::Log::LogMsg("Child process for task $JobId/$StepNo/$TaskNo died unexpectedly\n");

    # A crash probably indicates a bug in the task script but getting stuck
    # could happen due to network issues. So requeue the task like its script
    # would and count attempts to avoid getting into an infinite loop.
    if ($self->CanRetry())
    {
      $Status = "queued";
      $self->TestFailures(($self->TestFailures || 0) + 1);
      $self->Started(undef);
      $self->Ended(undef);
    }
    else
    {
      $Status = "boterror";
    }
    $self->Status($Status);
    $self->Save();

    if ($VM->Status eq "running")
    {
      $VM->Status('dirty');
      $VM->ChildDeadline(undef);
      $VM->ChildPid(undef);
      $VM->Save();
      $VM->RecordResult(undef, "boterror process died");
    }
    # else it looks like this is not our VM anymore
  }
  elsif ($Skip && $Status eq "queued")
  {
    $Status = "skipped";
    $self->Status("skipped");
    $self->Save();
  }
  return $Status;
}


package WineTestBot::Tasks;

=head1 NAME

WineTestBot::Tasks - A collection of WineTestBot::Task objects

=cut

use Exporter 'import';
use WineTestBot::WineTestBotObjects;
BEGIN
{
  our @ISA = qw(WineTestBot::WineTestBotCollection);
  our @EXPORT = qw(CreateTasks);
}

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::ItemrefPropertyDescriptor;
use WineTestBot::VMs;


sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Task->new($self);
}

my @PropertyDescriptors = (
  CreateBasicPropertyDescriptor("No", "Task no",  1,  1, "N", 2),
  CreateEnumPropertyDescriptor("Status", "Status",  !1,  1, ['queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled', 'skipped']),
  CreateItemrefPropertyDescriptor("VM", "VM", !1,  1, \&CreateVMs, ["VMName"]),
  CreateBasicPropertyDescriptor("Timeout", "Timeout", !1, 1, "N", 4),
  CreateBasicPropertyDescriptor("Missions", "Missions", !1, 1, "A", 256),
  CreateBasicPropertyDescriptor("CmdLineArg", "Command line args", !1, !1, "A", 256),
  CreateBasicPropertyDescriptor("Started", "Execution started", !1, !1, "DT", 19),
  CreateBasicPropertyDescriptor("Ended", "Execution ended", !1, !1, "DT", 19),
  CreateBasicPropertyDescriptor("TestFailures", "Number of test failures", !1, !1, "N", 6),
);
my @FlatPropertyDescriptors = (
  CreateBasicPropertyDescriptor("JobId", "Job id", 1, 1, "S", 5),
  CreateBasicPropertyDescriptor("StepNo", "Step no",  1,  1, "N", 2),
  @PropertyDescriptors
);

=pod
=over 12

=item C<CreateTasks()>

When given a Step object returns a collection containing the corresponding
tasks. In this case the Task objects don't store the key of their parent.

If no Step object is specified all the table rows are returned and the Task
objects have JobId and StepNo properties.

=back
=cut

sub CreateTasks(;$$)
{
  my ($ScopeObject, $Step) = @_;
  return WineTestBot::Tasks->new("Tasks", "Tasks", "Task",
      $Step ? \@PropertyDescriptors : \@FlatPropertyDescriptors,
      $ScopeObject, $Step);
}

1;
