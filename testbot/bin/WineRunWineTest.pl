#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Makes sure the Wine patches compile or run WineTest.
# See the bin/build/WineTest.pl script.
#
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
use WineTestBot::Engine::Notify;
use WineTestBot::Jobs;
use WineTestBot::Missions;
use WineTestBot::PatchUtils;
use WineTestBot::Log;
use WineTestBot::LogUtils;
use WineTestBot::Utils;
use WineTestBot::VMs;


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
# Task helpers
#

sub TakeScreenshot($$)
{
  my ($VM, $FileName) = @_;

  my $Domain = $VM->GetDomain();
  my ($ErrMessage, $ImageSize, $ImageBytes) = $Domain->CaptureScreenImage();
  if (!defined $ErrMessage)
  {
    if (open(my $Screenshot, ">", $FileName))
    {
      print $Screenshot $ImageBytes;
      close($Screenshot);
    }
    else
    {
      Error "Could not open the screenshot file for writing: $!\n";
    }
  }
  elsif ($Domain->IsPoweredOn())
  {
    Error "Could not capture a screenshot: $ErrMessage\n";
  }
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
my $TaskDir = $Task->CreateDir();
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

  if (open(my $ErrFile, ">>", "$TaskDir/log.err"))
  {
    print $ErrFile $ErrMessage;
    close($ErrFile);
  }
  else
  {
    Error "Unable to open 'log.err' for writing: $!\n";
  }
}

my $TaskMissions;

sub WrapUpAndExit($;$$$$)
{
  my ($Status, $TestFailures, $Retry, $TimedOut, $Reason) = @_;
  my $NewVMStatus = $Status eq 'queued' ? 'offline' : 'dirty';
  my $VMResult = defined $Reason ? $Reason :
                 $Status eq "boterror" ? "boterror" :
                 $Status eq "queued" ? "error" :
                 $TimedOut ? "timeout" : "";

  Debug(Elapsed($Start), " Taking a screenshot\n");
  TakeScreenshot($VM, "$TaskDir/screenshot.png");

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

  if ($Step->Type eq 'suite' and $Status eq 'completed' and !$TimedOut)
  {
    foreach my $Mission (@{$TaskMissions->{Missions}})
    {
      # Keep the old report if the new one is missing
      my $RptFileName = GetMissionBaseName($Mission) .".report";
      if (-f "$TaskDir/$RptFileName" and !-z "$TaskDir/$RptFileName")
      {
        # Update the VM's reference WineTest results for WineSendLog.pl
        my $RefReport = "$DataDir/latest/". $Task->VM->Name ."_$RptFileName";
        unlink($RefReport);
        link("$TaskDir/$RptFileName", $RefReport);

        unlink("$RefReport.err");
        if (-f "$TaskDir/$RptFileName.err" and !-z "$TaskDir/$RptFileName.err")
        {
          link("$TaskDir/$RptFileName.err", "$RefReport.err");
        }
      }
    }
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

  WrapUpAndExit('boterror', undef, $Retry);
}

sub FatalTAError($$;$)
{
  my ($TA, $ErrMessage, $PossibleCrash) = @_;
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
    $ErrMessage = "The test VM is powered off! Did the test shut it down?\n";
  }
  if ($PossibleCrash and !$Task->CanRetry())
  {
    # The test did it!
    LogTaskError($ErrMessage);
    WrapUpAndExit('completed', 1);
  }
  FatalError($ErrMessage, $Retry);
}


#
# Check the VM and Step
#

if ($VM->Type ne "wine")
{
  FatalError("This is not a Wine VM! (" . $VM->Type . ")\n");
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

if ($Step->Type ne "suite" and $Step->Type ne "single")
{
  FatalError("Unexpected step type '". $Step->Type ."' found\n");
}
if (($Step->Type eq "suite" and $Step->FileType ne "none") or
    ($Step->Type ne "suite" and $Step->FileType !~ /^(?:exe32|exe64|patch)$/))
{
  FatalError("Unexpected file type '". $Step->FileType ."' found for ". $Step->Type ." step\n");
}

my ($ErrMessage, $Missions) = ParseMissionStatement($Task->Missions);
FatalError "$ErrMessage\n" if (defined $ErrMessage);
FatalError "Empty mission statement\n" if (!@$Missions);
FatalError "Cannot specify missions for multiple tasks\n" if (@$Missions > 1);
$TaskMissions = $Missions->[0];


#
# Setup the VM
#
my $TA = $VM->GetAgent();
Debug(Elapsed($Start), " Setting the time\n");
if (!$TA->SetTime())
{
  # Not a fatal error. Try the next port in case the VM runs a privileged
  # TestAgentd daemon there.
  my $PrivilegedTA = $VM->GetAgent(1);
  if (!$PrivilegedTA->SetTime())
  {
    LogTaskError("Unable to set the VM system time: ". $PrivilegedTA->GetLastError() .". Maybe the TestAgentd process is missing the required privileges.\n");
    $PrivilegedTA->Disconnect();
  }
}

my $FileName = $Step->FileName;
if (defined $FileName)
{
  Debug(Elapsed($Start), " Sending '$FileName'\n");
  my $Dst = $Step->FileType eq "patch" ? "patch.diff" : $FileName;
  if (!$TA->SendFile($Step->GetFullFileName(), "staging/$Dst", 0))
  {
    FatalTAError($TA, "Could not send '$FileName' to the VM");
  }
}

my $Script = "#!/bin/sh\n".
             "( set -x\n".
             "  export WINETEST_DEBUG=". $Step->DebugLevel ."\n";
if ($Step->ReportSuccessfulTests)
{
  $Script .= "  export WINETEST_REPORT_SUCCESS=1\n";
}
$Script .= "  ../bin/build/WineTest.pl ";
if ($Step->Type eq "suite")
{
  my $BaseTag = BuildTag($VM->Name);
  $Script .= "--winetest ". ShQuote($Task->Missions) ." $BaseTag ";
  if (defined $WebHostName)
  {
    my $URL = GetTaskURL($JobId, $StepNo, $TaskNo, 1);
    $Script .= "-u ". ShQuote(MakeSecureURL($URL)) ." ";
  }
  my $Info = $VM->Description ? $VM->Description : "";
  if ($VM->Details)
  {
      $Info .= ": " if ($Info ne "");
      $Info .=  $VM->Details;
  }
  $Script .= join(" ", "-m", ShQuote($AdminEMail), "-i", ShQuote($Info));
}
elsif ($Step->FileType eq "patch")
{
  $Script .= "--testpatch ". ShQuote($Task->Missions) ." patch.diff";
}
else
{
  $Script .= join(" ", "--testexe", ShQuote($Task->Missions), $FileName, $Task->CmdLineArg);
}
$Script .= "\n) >Task.log 2>&1\n";
Debug(Elapsed($Start), " Sending the script: [$Script]\n");
if (!$TA->SendFileFromString($Script, "task", $TestAgent::SENDFILE_EXE))
{
  FatalTAError($TA, "Could not send the task script to the VM");
}


#
# Run the test
#

Debug(Elapsed($Start), " Starting the script\n");
my $Pid = $TA->Run(["./task"], 0);
if (!$Pid)
{
  FatalTAError($TA, "Failed to start the test");
}


#
# From that point on we want to at least try to grab the task log
# and a screenshot before giving up
#

my $NewStatus = 'completed';
my ($TaskFailures, $TaskTimedOut, $TAError, $PossibleCrash);
Debug(Elapsed($Start), " Waiting for the script (", $Task->Timeout, "s timeout)\n");
if (!defined $TA->Wait($Pid, $Task->Timeout, 60))
{
  $ErrMessage = $TA->GetLastError();
  if ($ErrMessage =~ /timed out waiting for the child process/)
  {
    $ErrMessage = "The task timed out\n";
    # We don't know if the timeout was caused by the build or the tests.
    # Until we get the task log assume it's the tests' fault.
    $TaskFailures = 1;
    $TaskTimedOut = 1;
  }
  else
  {
    $PossibleCrash = 1;
    $TAError = "An error occurred while waiting for the task to complete: $ErrMessage";
    $ErrMessage = undef;
  }
}

Debug(Elapsed($Start), " Retrieving 'Task.log'\n");
if ($TA->GetFile("Task.log", "$TaskDir/log"))
{
  my $Summary = ParseTaskLog("$TaskDir/log");
  if ($Summary->{Task} eq "ok")
  {
    # We must have gotten the full log and the task completed successfully
    # (with or without test failures). So clear any previous errors, including
    # $TaskFailures since there was not really a timeout after all.
    $NewStatus = "completed";
    $TaskFailures = $TAError = $ErrMessage = $PossibleCrash = undef;
  }
  elsif ($Summary->{Task} eq "badpatch")
  {
    # This too is conclusive enough to ignore other errors.
    $NewStatus = "badpatch";
    $TaskFailures = $TAError = $ErrMessage = $PossibleCrash = undef;
  }
  elsif ($Summary->{NoLog})
  {
    FatalError("$Summary->{NoLog}\n", "retry");
  }
  elsif ($Summary->{Type} eq "build")
  {
    # The error happened before the tests started so blame the build.
    $NewStatus = "badbuild";
    $TaskFailures = $PossibleCrash = undef;
  }
  elsif (!$TaskTimedOut and !defined $TAError)
  {
    # Did WineTest.pl crash?
    $NewStatus = "boterror";
    $TaskFailures = undef;
    $PossibleCrash = 1;
  }
}
elsif (!defined $TAError)
{
  $TAError = "An error occurred while retrieving the task log: ". $TA->GetLastError();
}


#
# Grab the test reports if any
#

foreach my $Mission (@{$TaskMissions->{Missions}})
{
  my $RptFileName = GetMissionBaseName($Mission) .".report";
  Debug(Elapsed($Start), " Retrieving '$RptFileName'\n");
  if ($TA->GetFile($RptFileName, "$TaskDir/$RptFileName"))
  {
    chmod 0664, "$TaskDir/$RptFileName";

    my ($TestUnitCount, $TimeoutCount, $LogFailures, $LogErrors) = ParseWineTestReport("$TaskDir/$RptFileName", $Step->FileType eq "patch", $TaskTimedOut);
    $TaskTimedOut = 1 if ($TestUnitCount == $TimeoutCount);
    if (!defined $LogFailures and @$LogErrors == 1)
    {
      # Could not open the file
      $NewStatus = 'boterror';
      Error "Unable to open '$RptFileName' for reading: $!\n";
      LogTaskError("Unable to open '$RptFileName' for reading: $!\n");
    }
    else
    {
      # $LogFailures can legitimately be undefined in case of a timeout
      $TaskFailures += $LogFailures || 0;
      if (@$LogErrors and open(my $Log, ">", "$TaskDir/$RptFileName.err"))
      {
        # Save the extra errors detected by ParseWineTestReport() in
        # $RptFileName.err:
        # - This keep the .report file clean.
        # - Each .err file can be matched to its corresponding .report, even
        #   if there are multiple .report files in the directory.
        # - The .err file can be moved to the latest directory next to the
        #   reference report.
        print $Log "$_\n" for (@$LogErrors);
        close($Log);
      }
    }
  }
  elsif (!defined $TAError and
         $TA->GetLastError() !~ /: No such file or directory/)
  {
    $TAError = "An error occurred while retrieving $RptFileName: ". $TA->GetLastError();
    $NewStatus = 'boterror';
  }
}

Debug(Elapsed($Start), " Disconnecting\n");
$TA->Disconnect();


#
# Grab a copy of the reference logs
#

# Note that this may be a bit inaccurate right after a Wine commit.
# See WineSendLog.pl for more details.
if ($NewStatus eq 'completed')
{
  my $LatestDir = "$DataDir/latest";
  my $StepDir = $Step->GetDir();
  foreach my $Mission (@{$TaskMissions->{Missions}})
  {
    my $RptFileName = GetMissionBaseName($Mission) .".report";
    my $RefReport = $Task->VM->Name ."_$RptFileName";
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


#
# Wrap up
#

# Report the task errors even though they may have been caused by
# TestAgent trouble.
LogTaskError($ErrMessage) if (defined $ErrMessage);
FatalTAError(undef, $TAError, $PossibleCrash) if (defined $TAError);

WrapUpAndExit($NewStatus, $TaskFailures, undef, $TaskTimedOut);
