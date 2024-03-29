#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs poweroff, revert and other operations on the specified VM.
# These operations can take quite a bit of time, particularly in case of
# network trouble, and thus are best performed in a separate process.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2019 Francois Gouget
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
use WineTestBot::Log;
use WineTestBot::Utils;
use WineTestBot::VMs;

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

# Grab the command line options
my ($Usage, $Action, $VMKey);
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
  elsif ($Arg =~ /^(?:checkidle|checkoff|monitor|poweroff|revert)$/)
  {
    $Action = $Arg;
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
  elsif (!defined $VMKey)
  {
    $VMKey = $Arg;
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check and untaint parameters
my $VM;
if (!defined $Usage)
{
  if (!defined $Action)
  {
    Error "you must specify the action to perform\n";
    $Usage = 2;
  }
  if (!defined $VMKey)
  {
    Error "you must specify the VM name\n";
    $Usage = 2;
  }
  elsif ($VMKey =~ /^([a-zA-Z0-9_]+)$/)
  {
    $VMKey = $1; # untaint
    $VM = CreateVMs()->GetItem($VMKey);
    if (!defined $VM)
    {
      Error "VM $VMKey does not exist\n";
      $Usage = 2;
    }
  }
  else
  {
    Error "'$VMKey' is not a valid VM name\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  print "Usage: $Name0 [--debug] [--log-only] [--help] (checkidle|checkoff|monitor|poweroff|revert) VMName\n";
  exit $Usage;
}


#
# Main
#

my $Start = Time();

my $CurrentStatus;

=pod
=over 12

=item C<FatalError()>

Logs the fatal error, notifies the administrator and exits the process.

This function never returns!

=back
=cut

sub FatalError($)
{
  my ($ErrMessage) = @_;
  Error $ErrMessage;

  # Get the up-to-date VM status
  $VM = CreateVMs()->GetItem($VMKey);

  if ($VM->Status eq "maintenance")
  {
    # Still proceed with changing the non-Status fields and notifying the
    # administrator to allow for error handling debugging.
  }
  elsif ($VM->Status ne $CurrentStatus)
  {
    LogMsg "Not updating the VM because its status changed: ". $VM->Status ." != $CurrentStatus\n";
    exit 1;
  }
  else
  {
    $VM->Status("offline");
  }
  $VM->ChildDeadline(undef);
  $VM->ChildPid(undef);
  my $Errors = ($VM->Errors || 0) + 1;
  $VM->Errors($Errors);

  my ($ErrProperty, $SaveErrMessage) = $VM->Save();
  if (defined $SaveErrMessage)
  {
    LogMsg "Could not put the $VMKey VM offline: $SaveErrMessage ($ErrProperty)\n";
  }
  elsif ($Errors >= $MaxVMErrors)
  {
    NotifyAdministrator("The $VMKey VM needs maintenance",
                        "Got $Errors consecutive errors working on the $VMKey VM:\n".
                        "\n$ErrMessage\n".
                        "It probably needs fixing to get back online.");
  }
  else
  {
    NotifyAdministrator("Putting the $VMKey VM offline",
                        "Could not perform the $Action operation on the $VMKey VM:\n".
                        "\n$ErrMessage\n".
                        "The VM has been put offline and the TestBot will try to regain access to it.");
  }
  exit 1;
}

=pod
=over 12

=item C<ChangeStatus()>

Checks that the VM status has not been tampered with and sets it to the new
value.

Returns a value suitable for the process exit code: 0 in case of success,
1 otherwise.

=back
=cut

sub ChangeStatus($$;$)
{
  my ($From, $To, $Done) = @_;

  # Get the up-to-date VM status
  $VM = CreateVMs()->GetItem($VMKey);
  if (!$VM or (defined $From and $VM->Status ne $From))
  {
    LogMsg "Not changing status\n";
    # Not changing the status is allowed in debug mode so the VM can be
    # put in 'maintenance' mode to avoid interference from the TestBot.
    return $Debug ? 0 : 1;
  }

  $VM->Status($To);
  if ($Done)
  {
    $VM->ChildDeadline(undef);
    $VM->ChildPid(undef);
  }
  my ($ErrProperty, $ErrMessage) = $VM->Save();
  if (defined $ErrMessage)
  {
    FatalError("Could not change the $VMKey VM status: $ErrMessage\n");
  }
  $CurrentStatus = $To;
  return 0;
}

sub Monitor()
{
  # Still try recovering the VM in case of repeated errors, but space out
  # attempts to not keep the host busy with a broken VM. Note that after
  # 1 hour the monitor process gets killed and replaced (to deal with stuck
  # monitor processes) but even so the VM will be checked once per hour.
  my $Interval = ($VM->Errors || 0) >= $MaxVMErrors ? 1860 : 60;
  my $NextTry = time() + $Interval;
  Debug(Elapsed($Start), " Checking $VMKey in ${Interval}s\n");

  $CurrentStatus = "offline";
  while (1)
  {
    # Get a fresh status
    $VM = CreateVMs()->GetItem($VMKey);
    if (!defined $VM or $VM->Role eq "retired" or $VM->Role eq "deleted" or
        $VM->Status eq "maintenance")
    {
      my $Reason = $VM ? "Role=". $VM->Role ."\nStatus=". $VM->Status :
                         "$VMKey does not exist anymore";
      NotifyAdministrator("The $VMKey VM is not relevant anymore",
                          "The $VMKey VM was offline but ceased to be relevant after ".
                          PrettyElapsed($Start). ":\n\n$Reason\n");
      return 1;
    }
    if ($VM->Status ne "offline")
    {
      NotifyAdministrator("The $VMKey VM is working again (". $VM->Status .")",
                          "The status of the $VMKey VM unexpectedly switched from offline\n".
                          "to ". $VM->Status ." after ". PrettyElapsed($Start) .".");
      return 0;
    }
    my $Sleep = $NextTry - time();
    if ($Sleep > 0)
    {
      # Check that the VM still needs monitoring at least once per minute.
      $Sleep = 60 if ($Sleep > 60);
      sleep($Sleep);
      next;
    }

    my $IsReady = $VM->GetDomain()->IsReady();
    if ($IsReady and $VM->GetDomain()->IsPoweredOn())
    {
      my $ErrMessage = $VM->GetDomain()->PowerOff();
      if (defined $ErrMessage)
      {
        Error "$ErrMessage\n";
        $IsReady = undef;
      }
    }
    if ($IsReady)
    {
      return 1 if (ChangeStatus("offline", "off", "done"));
      NotifyAdministrator("The $VMKey VM is working again",
                          "The $VMKey VM started working again after ".
                          PrettyElapsed($Start) .".");
      return 0;
    }

    Debug(Elapsed($Start), " $VMKey is still busy / unreachable, trying again in ${Interval}s\n");
    $NextTry = time() + $Interval;
  }
}

sub PowerOff()
{
  # Power off VMs no matter what their initial status is
  $CurrentStatus = $VM->Status;
  my $ErrMessage = $VM->GetDomain()->PowerOff();
  FatalError("$ErrMessage\n") if (defined $ErrMessage);

  return ChangeStatus(undef, "off", "done");
}

sub CheckIdle()
{
  $CurrentStatus = "dirty";
  my $IsPoweredOn = $VM->GetDomain()->IsPoweredOn();
  return ChangeStatus("dirty", "offline", "done") if (!defined $IsPoweredOn);
  return ChangeStatus("dirty", "off", "done") if (!$IsPoweredOn);

  my ($ErrMessage, $SnapshotName) = $VM->GetDomain()->GetSnapshotName();
  FatalError("$ErrMessage\n") if (defined $ErrMessage);

  # If the snapshot does not match then the virtual machine may be used by
  # another VM instance. So don't touch it. All that counts is that this
  # VM instance is not running.
  my $NewStatus = ($SnapshotName eq $VM->IdleSnapshot) ? "idle" : "off";
  return ChangeStatus("dirty", $NewStatus, "done");
}

sub CheckOff()
{
  $CurrentStatus = "dirty";
  my $IsPoweredOn = $VM->GetDomain()->IsPoweredOn();
  return ChangeStatus("dirty", "offline", "done") if (!defined $IsPoweredOn);

  if ($IsPoweredOn)
  {
    my ($ErrMessage, $SnapshotName) = $VM->GetDomain()->GetSnapshotName();
    FatalError("$ErrMessage\n") if (defined $ErrMessage);
    if ($SnapshotName eq $VM->IdleSnapshot)
    {
      my $ErrMessage = $VM->GetDomain()->PowerOff();
      FatalError("$ErrMessage\n") if (defined $ErrMessage);
    }
  }

  return ChangeStatus("dirty", "off", "done");
}

sub SetupTestAgentd($$$$)
{
  my ($VM, $Booting, $UpgradeTestAgentd, $ResetStartCount) = @_;

  Debug(Elapsed($Start), " Setting up the $VMKey TestAgent server\n");
  LogMsg "Setting up the $VMKey TestAgent server\n";
  my $TA = $VM->GetAgent();
  $TA->SetConnectTimeout(undef, undef, $WaitForBoot) if ($Booting);
  my $Version = $TA->GetVersion();
  if (!$Version)
  {
    my $ErrMessage = $TA->GetLastError();
    FatalError("Could not connect to the $VMKey TestAgent: $ErrMessage\n");
  }

  # Upgrade TestAgentd
  if ($UpgradeTestAgentd and ($VM->Type eq "win32" or $VM->Type eq "win64"))
  {
    Debug(Elapsed($Start), " Upgrading the $VMKey TestAgent server from $Version\n");
    LogMsg "Upgrading the $VMKey TestAgent server from $Version\n";
    if ($Version !~ / ([0-9]+)\.([0-9]+)$/)
    {
      FatalError("Unsupported TestAgent server version: $Version\n");
    }
    # We want 'TestAgentd --detach --show-restarts' on Windows but this was
    # not supported before this version and changing how the server is started
    # is too complex.
    $Version = sprintf("%02d.%02d", $1, $2);
    if ($Version lt "01.07")
    {
      FatalError("The TestAgent server is too old to be upgraded: $Version\n");
    }

    if (!$TA->Upgrade("$DataDir/latest/TestAgentd.exe"))
    {
      my $ErrMessage = $TA->GetLastError();
      FatalError("Could not upgrade the $VMKey TestAgent: $ErrMessage\n");
    }
    # Give the server enough time to restart, thus (maybe) avoiding a timeout
    # on the first (re)connection attempt.
    sleep(1);
    $Version = $TA->GetVersion();
    if (!$Version)
    {
      my $ErrMessage = $TA->GetLastError();
      FatalError("Could not connect to the new $VMKey TestAgent: $ErrMessage\n");
    }
    LogMsg "Upgraded the $VMKey TestAgent server to $Version\n";

    # Note that the privileged TestAgent server (if any) is usually run with
    # --set-time-only which means it cannot be upgraded since the restart RPC
    # is blacklisted. But that also means it's unlikely to need upgrading.
    # A side effect is that it will force TestAgentd.exe.old to stay around.
  }

  if ($Booting and $VM->Type eq "wine")
  {
    # Make sure the X session has had time to start
    Debug(Elapsed($Start), " Waiting for the X session\n");
    LogMsg "Waiting for the $VMKey X session\n";
    my $Pid = $TA->Run(["sh", "-c", "while ! xset -display :0.0 q >/dev/null; do sleep 1; done"], 0);
    FatalError("Could not check for the X session on $VMKey\n") if (!$Pid);

    if (!defined $TA->Wait($Pid, $SleepAfterBoot))
    {
      my $ErrMessage = $TA->GetLastError();
      if ($ErrMessage =~ /timed out waiting for the child process/)
      {
        FatalError("Timed out waiting for the X session\n");
      }
      FatalError("An error occurred while waiting for the X session: $ErrMessage\n");
    }
  }

  if ($ResetStartCount)
  {
    # If SetProperty() is not supported neither is --show-restarts.
    # So it all works out.
    $TA->SetProperty("start.count", 0);
  }
  else
  {
    # Check that TestAgentd is not displaying the "Has Windows rebooted?"
    # warning.
    my $Count = $TA->GetProperties("start.count");
    if (defined $Count and $Count > 1)
    {
      FatalError("Cannot take a live snapshot because start.count=$Count > 1");
    }
  }
  $TA->Disconnect();
}

sub CreateSnapshot($$)
{
  my ($Domain, $SnapshotName) = @_;

  if ($SleepAfterBoot != 0)
  {
    Debug(Elapsed($Start), " Sleeping for the $SnapshotName snapshot\n");
    LogMsg "Letting $VMKey settle down for the $SnapshotName snapshot\n";
    sleep($SleepAfterBoot);
  }

  Debug(Elapsed($Start), " Creating the $SnapshotName snapshot\n");
  my $ErrMessage = $Domain->CreateSnapshot($SnapshotName);
  if (defined $ErrMessage)
  {
    FatalError("Could not recreate the $SnapshotName snapshot on $VMKey: $ErrMessage\n");
  }
}

sub Revert()
{
  my $VM = CreateVMs()->GetItem($VMKey);
  if (!$Debug and $VM->Status ne "reverting")
  {
    Error("The VM is not ready to be reverted (". $VM->Status .")\n");
    return 1;
  }
  $CurrentStatus = "reverting";
  my $DomainSnapshot = $VM->IdleSnapshot;
  my $ExtraTimeout = 0;
  my ($SetLocale, $CreateSnapshot);

  my $Domain = $VM->GetDomain();
  if (($VM->Type eq "win32" or $VM->Type eq "win64") and
      !$Domain->HasSnapshot($DomainSnapshot) and
      $DomainSnapshot =~ s/-([a-z]{2})-([A-Z]{2})$//)
  {
    # Add some extra time to set up the VM locale and reboot it
    $ExtraTimeout += $VMToolTimeout;
    $SetLocale = "$1-$2";
    Debug(Elapsed($Start), " $VMKey does not yet have a $DomainSnapshot-$SetLocale snapshot\n");
  }
  if (!$Domain->HasSnapshot($DomainSnapshot) and $DomainSnapshot =~ s/-live$//)
  {
    # Add some extra time to boot the VM and create the live snapshot
    $ExtraTimeout += $WaitForBoot + $VMToolTimeout / 2;
    $CreateSnapshot = 1;
    Debug(Elapsed($Start), " $VMKey does not yet have a $DomainSnapshot-live snapshot\n");
  }
  if (!$Domain->HasSnapshot($DomainSnapshot))
  {
    FatalError("Could not find $VMKey\'s $DomainSnapshot snapshot\n");
  }
  if ($ExtraTimeout)
  {
    Debug(Elapsed($Start), " Extend the $VMKey revert deadline by $ExtraTimeout\n");
    my $Deadline = $VM->Status eq "maintenance" ? (time() + $VMToolTimeout) :
                                                  $VM->ChildDeadline;
    $VM->ChildDeadline($Deadline + $ExtraTimeout);
    $VM->Save();
  }

  # Revert the VM (and power it on if necessary)
  Debug(Elapsed($Start), " Reverting $VMKey to $DomainSnapshot\n");
  my ($ErrMessage, $Booting) = $Domain->RevertToSnapshot($DomainSnapshot);
  if (defined $ErrMessage)
  {
    # Libvirt/QEmu is buggy and cannot revert a running VM from one hardware
    # configuration to another. So try again after powering off the VM, though
    # this can be much slower.
    Debug(Elapsed($Start), " Powering off the VM\n");
    $ErrMessage = $Domain->PowerOff();
    if (defined $ErrMessage)
    {
      FatalError("Could not power off $VMKey: $ErrMessage\n");
    }

    Debug(Elapsed($Start), " Reverting $VMKey to $DomainSnapshot... again\n");
    ($ErrMessage, $Booting) = $Domain->RevertToSnapshot($DomainSnapshot);
  }
  if (defined $ErrMessage)
  {
    FatalError("Could not revert $VMKey to $DomainSnapshot: $ErrMessage\n");
  }

  # Mark the VM as sleeping which allows the scheduler to abort the revert in
  # favor of higher priority tasks. But don't allow interruptions in the
  # middle of snapshot creation!
  if (!$CreateSnapshot and !$SetLocale)
  {
    return 1 if (ChangeStatus("reverting", "sleeping"));
  }

  # Set up the TestAgent server. Note that setting the locale will require a
  # reboot so reset start.count in that case.
  SetupTestAgentd($VM, $Booting, ($CreateSnapshot or $SetLocale), $SetLocale);

  if ($CreateSnapshot)
  {
    $DomainSnapshot .= "-live";
    CreateSnapshot($Domain, $DomainSnapshot);

    if ($VM->Type eq "build" or $VM->Type eq "wine")
    {
      require WineTestBot::SpecialJobs;
      $ErrMessage = WineTestBot::SpecialJobs::AddReconfigJob([$VM], $VM->Name, $VM->Type);
      if (defined $ErrMessage)
      {
        Error("Could not create a job to update and rebuild Wine on the $VMKey VM: $ErrMessage\n");
        NotifyAdministrator("Could not create a job to update $VMKey",
          "A live snapshot was created for $VMKey but no job could be\n".
          "created to update and rebuild Wine on it:\n\n".
          "$ErrMessage\n");
      }
      else
      {
        Debug(Elapsed($Start), " Added a job to update and rebuild Wine on $VMKey\n");
      }
    }
  }

  # Set up the VM locale
  if ($SetLocale)
  {
    Debug(Elapsed($Start), " Setting up the $SetLocale locale on $VMKey\n");
    if (system("$BinDir/SetWinLocale", "--vm", $VMKey, "--default", $SetLocale))
    {
      FatalError("Could not set the $VMKey locale to $SetLocale\n");
    }

    Debug(Elapsed($Start), " Wait for the $VMKey locale-setting reboot to complete\n");
    LogMsg "Wait for the $VMKey locale-setting reboot to complete\n";
    while (1)
    {
      my $TA = $VM->GetAgent();
      my $Count = $TA->GetProperties("start.count");
      $TA->Disconnect();

      # SetupTestAgentd() has reset start.count to zero.
      # It will only change after the reboot.
      last if (defined $Count and $Count != 0);

      sleep(1);
    }

    $DomainSnapshot .= "-$SetLocale";
    CreateSnapshot($Domain, $DomainSnapshot);
  }
  elsif (!$CreateSnapshot)
  {
    my $Sleep = ($Booting and $SleepAfterBoot > $SleepAfterRevert) ?
                $SleepAfterBoot : $SleepAfterRevert;
    Debug(Elapsed($Start), " Sleeping\n");
    LogMsg "Letting $VMKey settle down for ${Sleep}s\n";
    sleep($Sleep);
  }

  if ($CreateSnapshot or $SetLocale)
  {
    # The activity monitor does not like it when VMs skip the sleeping step
    return 1 if (ChangeStatus("reverting", "sleeping"));
  }

  return ChangeStatus($CurrentStatus, "idle", "done");
}


my $Rc;
if ($Action eq "checkidle")
{
  $Rc = CheckIdle();
}
elsif ($Action eq "checkoff")
{
  $Rc = CheckOff();
}
elsif ($Action eq "monitor")
{
  $Rc = Monitor();
}
elsif ($Action eq "poweroff")
{
  $Rc = PowerOff();
}
elsif ($Action eq "revert")
{
  $Rc = Revert();
}
else
{
  Error("Unsupported action $Action!\n");
  $Rc = 1;
}
LogMsg "$Action on $VMKey completed in ", PrettyElapsed($Start), "\n";

exit $Rc;
