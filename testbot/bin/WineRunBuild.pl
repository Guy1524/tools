#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Communicates with the build machine to have it perform the 'build' task.
# See the bin/build/Build.pl script.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2013-2019 Francois Gouget
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

sub BEGIN
{
  if ($0 !~ m=^/=)
  {
    # Turn $0 into an absolute path so it can safely be used in @INC
    require Cwd;
    $0 = Cwd::cwd() . "/$0";
  }
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
}
my $Name0 = $0;
$Name0 =~ s+^.*/++;


use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::PatchUtils;
use WineTestBot::VMs;
use WineTestBot::Log;
use WineTestBot::LogUtils;
use WineTestBot::Utils;
use WineTestBot::Engine::Notify;


#
# Logging and error handling helpers
#

my $Debug;
sub Debug(@)
{
  print STDERR @_ if ($Debug);
}

my $LogOnly;
sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}


#
# Setup and command line processing
#

my $Usage;
sub ValidateNumber($$)
{
  my ($Name, $Value) = @_;

  # Validate and untaint the value
  return $1 if ($Value =~ /^(\d+)$/);
  Error "$Value is not a valid $Name\n";
  $Usage = 2;
  return undef;
}

my ($JobId, $StepNo, $TaskNo);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--debug")
  {
    $Debug = 1;
  }
  elsif ($Arg eq "--log-only")
  {
    $LogOnly = 1;
  }
  elsif ($Arg =~ /^(?:-\?|-h|--help)$/)
  {
    $Usage = 0;
    last;
  }
  elsif ($Arg =~ /^-/)
  {
    Error "unknown option '$Arg'\n";
    $Usage = 2;
    last;
  }
  elsif (!defined $JobId)
  {
    $JobId = ValidateNumber('job id', $Arg);
  }
  elsif (!defined $StepNo)
  {
    $StepNo = ValidateNumber('step number', $Arg);
  }
  elsif (!defined $TaskNo)
  {
    $TaskNo = ValidateNumber('task number', $Arg);
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check parameters
if (!defined $Usage)
{
  if (!defined $JobId || !defined $StepNo || !defined $TaskNo)
  {
    Error "you must specify the job id, step number and task number\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
    print "Usage: $Name0 [--debug] [--log-only] [--help] JobId StepNo TaskNo\n";
    exit $Usage;
}

my $Job = CreateJobs()->GetItem($JobId);
if (!defined $Job)
{
  Error "Job $JobId does not exist\n";
  exit 1;
}
my $Step = $Job->Steps->GetItem($StepNo);
if (!defined $Step)
{
  Error "Step $StepNo of job $JobId does not exist\n";
  exit 1;
}
my $Task = $Step->Tasks->GetItem($TaskNo);
if (!defined $Task)
{
  Error "Step $StepNo task $TaskNo of job $JobId does not exist\n";
  exit 1;
}
my $OldUMask = umask(002);
my $TaskDir = $Task->CreateDir();
umask($OldUMask);
my $VM = $Task->VM;


my $Start = Time();
LogMsg "Task $JobId/$StepNo/$TaskNo started\n";


#
# Error handling helpers
#

sub LogTaskError($)
{
  my ($ErrMessage) = @_;
  Debug("$Name0:error: ", $ErrMessage);

  my $OldUMask = umask(002);
  if (open(my $ErrFile, ">>", "$TaskDir/log.err"))
  {
    print $ErrFile $ErrMessage;
    close($ErrFile);
  }
  else
  {
    Error "Unable to open 'log.err' for writing: $!\n";
  }
  umask($OldUMask);
}

sub WrapUpAndExit($;$$$)
{
  my ($Status, $Retry, $TimedOut, $Reason) = @_;
  my $NewVMStatus = $Status eq 'queued' ? 'offline' : 'dirty';
  my $VMResult = defined $Reason ? $Reason :
                 $Status eq "boterror" ? "boterror" :
                 $Status eq "queued" ? "error" :
                 $TimedOut ? "timeout" : "";

  my $TestFailures;
  my $Tries = $Task->TestFailures || 0;
  if ($Retry)
  {
    # This may be a transient error (e.g. a network glitch)
    # so retry a few times to improve robustness
    $Tries++;
    if ($Task->CanRetry())
    {
      $Status = 'queued';
      $TestFailures = $Tries;
    }
    else
    {
      LogTaskError("Giving up after $Tries run(s)\n");
    }
  }
  elsif ($Tries >= 1)
  {
    LogTaskError("The previous $Tries run(s) terminated abnormally\n");
  }

  # Record result details that may be lost or overwritten by a later run
  if ($VMResult)
  {
    $VMResult .= " $Tries $MaxTaskTries" if ($Retry);
    $VM->RecordResult(undef, $VMResult);
  }

  # Update the Task and Job
  $Task->Status($Status);
  $Task->TestFailures($TestFailures);
  if ($Status eq 'queued')
  {
    $Task->Started(undef);
    $Task->Ended(undef);
    # Leave the Task files around so they can be seen until the next run
  }
  else
  {
    $Task->Ended(time());
  }
  $Task->Save();
  $Job->UpdateStatus();

  # Get the up-to-date VM status and update it if nobody else changed it
  $VM = CreateVMs()->GetItem($VM->GetKey());
  if ($VM->Status eq 'running')
  {
    $VM->Status($NewVMStatus);
    if ($NewVMStatus eq 'offline')
    {
      my $Errors = ($VM->Errors || 0) + 1;
      $VM->Errors($Errors);
    }
    else
    {
      $VM->Errors(undef);
    }
    $VM->ChildDeadline(undef);
    $VM->ChildPid(undef);
    $VM->Save();
  }

  my $Result = $VM->Name .": ". $VM->Status ." Status: $Status Failures: ". (defined $TestFailures ? $TestFailures : "unset");
  LogMsg "Task $JobId/$StepNo/$TaskNo done ($Result)\n";
  Debug(Elapsed($Start), " Done. $Result\n");
  exit($Status eq 'completed' ? 0 : 1);
}

# Only to be used if the error cannot be fixed by re-running the task.
# The TestBot will be indicated as having caused the failure.
sub FatalError($;$)
{
  my ($ErrMessage, $Retry) = @_;

  LogMsg "$JobId/$StepNo/$TaskNo $ErrMessage";
  LogTaskError("BotError: $ErrMessage");

  WrapUpAndExit('boterror', $Retry);
}

sub FatalTAError($$)
{
  my ($TA, $ErrMessage) = @_;
  $ErrMessage .= ": ". $TA->GetLastError() if (defined $TA);

  # A TestAgent operation failed, see if the VM is still accessible
  my $IsPoweredOn = $VM->GetDomain()->IsPoweredOn();
  if (!defined $IsPoweredOn)
  {
    # The VM host is not accessible anymore so put the VM offline and
    # requeue the task. This does not count towards the task's tries limit
    # since neither the VM nor the task are at fault.
    Error("$ErrMessage\n");
    NotifyAdministrator("Putting the ". $VM->Name ." VM offline",
                        "A TestAgent operation to the ". $VM->Name ." VM failed:\n".
                        "\n$ErrMessage\n".
                        "So the VM has been put offline and the TestBot will try to regain access to it.");
    WrapUpAndExit('queued');
  }

  my $Retry;
  if ($IsPoweredOn)
  {
    LogMsg("$ErrMessage\n");
    LogTaskError("$ErrMessage\n");
    $ErrMessage = "The test VM has crashed, rebooted or lost connectivity (or the TestAgent server died)\n";
    # Retry in case it was a temporary network glitch
    $Retry = 1;
  }
  else
  {
    # Ignore the TestAgent error, it's irrelevant
    $ErrMessage = "The test VM is powered off!\n";
  }
  FatalError($ErrMessage, $Retry);
}


#
# Check the VM and Step
#

if ($VM->Type ne "build")
{
  FatalError("This is not a build VM! (" . $VM->Type . ")\n");
}
if (!$Debug and $VM->Status ne "running")
{
  # Maybe the administrator tinkered with the VM state? In any case the VM
  # is not ours to use so requeue the task and abort. Note that the VM will
  # not be put offline (again, not ours).
  Error("The VM is not ready for use (" . $VM->Status . ")\n");
  WrapUpAndExit('queued');
}
my $Domain = $VM->GetDomain();
if (!$Domain->IsPoweredOn())
{
  # Maybe the VM was prepared in advance and got taken down by a power outage?
  # Requeue the task and treat this event as a failed revert to avoid infinite
  # loops.
  Error("The VM is not powered on\n");
  NotifyAdministrator("Putting the ". $VM->Name ." VM offline",
    "The ". $VM->Name ." VM should have been powered on to run the task\n".
    "below but its state was ". $Domain->GetStateDescription() ." instead.\n".
    MakeSecureURL(GetTaskURL($JobId, $StepNo, $TaskNo)) ."\n\n".
    "So the VM has been put offline and the TestBot will try to regain\n".
    "access to it.");
  WrapUpAndExit('queued', undef, undef, 'boterror vm off');
}

if ($Step->Type ne "build")
{
  FatalError("Unexpected step type '". $Step->Type ."' found\n");
}
if ($Step->FileType ne "patch")
{
  FatalError("Unexpected file type '". $Step->FileType ."' found for ". $Step->Type ." step\n");
}


#
# Run the build
#

my $FileName = $Step->GetFullFileName();
my $TA = $VM->GetAgent();
Debug(Elapsed($Start), " Sending '$FileName'\n");
if (!$TA->SendFile($FileName, "staging/patch.diff", 0))
{
  FatalTAError($TA, "Could not copy the patch to the VM");
}
my $Script = "#!/bin/sh\n".
             "( set -x\n".
             "  ../bin/build/Build.pl patch.diff ". $Task->Missions ."\n".
             ") >Build.log 2>&1\n";
Debug(Elapsed($Start), " Sending the script: [$Script]\n");
if (!$TA->SendFileFromString($Script, "task", $TestAgent::SENDFILE_EXE))
{
  FatalTAError($TA, "Could not send the build script to the VM");
}

Debug(Elapsed($Start), " Starting the script\n");
my $Pid = $TA->Run(["./task"], 0);
if (!$Pid)
{
  FatalTAError($TA, "Failed to start the build");
}


#
# From that point on we want to at least try to grab the build
# log before giving up
#

my ($NewStatus, $ErrMessage, $TAError, $TaskTimedOut);
Debug(Elapsed($Start), " Waiting for the script (", $Task->Timeout, "s timeout)\n");
if (!defined $TA->Wait($Pid, $Task->Timeout, 60))
{
  $ErrMessage = $TA->GetLastError();
  if ($ErrMessage =~ /timed out waiting for the child process/)
  {
    $ErrMessage = "The build timed out\n";
    $NewStatus = "badbuild";
    $TaskTimedOut = 1;
  }
  else
  {
    $TAError = "An error occurred while waiting for the build to complete: $ErrMessage";
    $ErrMessage = undef;
  }
}

Debug(Elapsed($Start), " Retrieving 'Build.log'\n");
if ($TA->GetFile("Build.log", "$TaskDir/log"))
{
  my $Summary = ParseTaskLog("$TaskDir/log");
  if ($Summary->{Task} eq "ok")
  {
    # We must have gotten the full log and the build did succeed.
    # So forget any prior error.
    $NewStatus = "completed";
    $TAError = $ErrMessage = undef;
  }
  elsif ($Summary->{Task} eq "badpatch")
  {
    # This too is conclusive enough to ignore other errors.
    $NewStatus = "badpatch";
    $TAError = $ErrMessage = undef;
  }
  elsif ($Summary->{NoLog})
  {
    FatalError("$Summary->{NoLog}\n", "retry");
  }
  else
  {
    # If the result line is missing we probably already have an error message
    # that explains why.
    $NewStatus = "badbuild";
  }
}
elsif (!defined $TAError)
{
  $TAError = "An error occurred while retrieving the build log: ". $TA->GetLastError();
}

# Report the build errors even though they may have been caused by
# TestAgent trouble.
LogTaskError($ErrMessage) if (defined $ErrMessage);
FatalTAError(undef, $TAError) if (defined $TAError);


#
# Grab the executables for the next steps
#

my %TestExes;
foreach my $TestStep (@{$Job->Steps->GetItems()})
{
  if (($TestStep->PreviousNo || 0) == $Step->No and
      $TestStep->FileType =~ /^exe/)
  {
    $TestExes{$TestStep->FileName} = $TestStep->FileType;
  }
}

my $Impacts = GetPatchImpacts($FileName);
my $StepDir = $Step->CreateDir();
foreach my $TestInfo (values %{$Impacts->{Tests}})
{
  foreach my $Bits ("", "64")
  {
    my $Local = "$TestInfo->{ExeBase}$Bits.exe";
    next if (!$TestExes{$Local});

    Debug(Elapsed($Start), " Retrieving '$Local'\n");
    my $BuildDir = "wine-$TestExes{$Local}";
    if ($TA->GetFile("$BuildDir/$TestInfo->{Path}/$TestInfo->{ExeBase}.exe",
                     "$StepDir/$Local"))
    {
      chmod 0664, "$StepDir/$Local";
    }
    elsif ($TA->GetLastError() !~ /: No such file or directory/)
    {
      FatalTAError($TA, "An error occurred while retrieving '$Local'");
    }
  }
}
$TA->Disconnect();


#
# Grab a copy of the reference logs
#

# Note that this may be a bit inaccurate right after a Wine commit.
# See WineSendLog.pl for more details.
my $LatestDir = "$DataDir/latest";
foreach my $TestStep (@{$Job->Steps->GetItems()})
{
  if (($TestStep->PreviousNo || 0) == $Step->No and
      $TestStep->FileType =~ /^exe/)
  {
    foreach my $TestTask (@{$TestStep->Tasks->GetItems()})
    {
      my $RefReport = $TestTask->VM->Name ."_". $TestStep->FileType .".report";
      for my $Suffix ("", ".err")
      {
        if (-f "$LatestDir/$RefReport$Suffix")
        {
          unlink "$StepDir/$RefReport$Suffix";
          if (!link "$LatestDir/$RefReport$Suffix", "$StepDir/$RefReport$Suffix")
          {
            Error "Could not link '$RefReport$Suffix': $!\n";
          }
        }
      }
    }
  }
}


#
# Wrap up
#

WrapUpAndExit($NewStatus, undef, $TaskTimedOut);
