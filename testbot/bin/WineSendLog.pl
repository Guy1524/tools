#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Sends the job log to the submitting user and informs the Wine Patches web
# site of the test results.
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


use Algorithm::Diff;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Log;
use WineTestBot::LogUtils;
use WineTestBot::StepsTasks;


my $PART_BOUNDARY = "==13F70BD1-BA1B-449A-9CCB-B6A8E90CED47==";


#
# Logging and error handling helpers
#

my $Debug;
sub Debug(@)
{
  print STDERR @_ if ($Debug);
}

sub DebugTee($@)
{
  my ($File) = shift;
  print $File @_;
  Debug(@_);
}

my $LogOnly;
sub Error(@)
{
  print STDERR "$Name0:error: ", @_ if (!$LogOnly);
  LogMsg @_;
}


#
# Reporting
#

sub GetTitle($$)
{
  my ($StepTask, $LogName) = @_;

  my $Label = GetLogLabel($LogName);
  if ($LogName !~ /\.report$/ and
      ($StepTask->Type eq "build" or $StepTask->VM->Type eq "wine"))
  {
    $Label = "build log";
  }

  return $StepTask->VM->Name . " ($Label)";
}

sub DumpLogAndErr($$)
{
  my ($File, $Path) = @_;

  my $PrintSeparator;
  foreach my $FileName ($Path, "$Path.err")
  {
    if (open(my $LogFile, "<",  $FileName))
    {
      my $First = 1;
      foreach my $Line (<$LogFile>)
      {
        $Line =~ s/\s*$//;
        if ($First and $PrintSeparator)
        {
          print $File "\n";
          $First = 0;
        }
        print $File "$Line\n";
      }
      close($LogFile);
      $PrintSeparator = 1;
    }
  }
}

sub SendLog($)
{
  my ($Job) = @_;

  my $To = $WinePatchToOverride || $Job->GetEMailRecipient();
  if (! defined($To))
  {
    return;
  }

  my $StepsTasks = CreateStepsTasks(undef, $Job);
  my @SortedKeys = sort { $a <=> $b } @{$StepsTasks->GetKeys()};

  my $JobURL = ($UseSSL ? "https://" : "http://") .
               "$WebHostName/JobDetails.pl?Key=". $Job->GetKey();


  #
  # Send a job summary and all the logs as attachments to the developer
  #

  Debug("-------------------- Developer email --------------------\n");
  my $Sendmail;
  if ($Debug)
  {
    open($Sendmail, ">>&=", 1);
  }
  else
  {
    open($Sendmail, "|-", "/usr/sbin/sendmail -oi -t -odq");
  }
  print $Sendmail "From: $RobotEMail\n";
  print $Sendmail "To: $To\n";
  my $Subject = "TestBot job " . $Job->Id . " results";
  my $Description = $Job->GetDescription();
  if ($Description)
  {
    $Subject .= ": " . $Description;
  }
  print $Sendmail "Subject: $Subject\n";
  if ($Job->Patch and $Job->Patch->MessageId)
  {
    print $Sendmail "In-Reply-To: ", $Job->Patch->MessageId, "\n";
    print $Sendmail "References: ", $Job->Patch->MessageId, "\n";
  }
  print $Sendmail <<"EOF";
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="$PART_BOUNDARY"

--$PART_BOUNDARY
Content-Type: text/plain; charset="UTF-8"
MIME-Version: 1.0
Content-Transfer-Encoding: 8bit
Content-Disposition: inline

VM                   Status   Failures Command
EOF
  foreach my $Key (@SortedKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);

    my $TestFailures = $StepTask->TestFailures;
    $TestFailures = "" if (!defined $TestFailures);
    my $Status = $StepTask->Status;
    $Status = $TestFailures ? "failed" : "success" if ($Status eq "completed");
    my $Cmd = "";
    $Cmd = $StepTask->FileName ." " if ($StepTask->FileType =~ /^exe/);
    $Cmd .= $StepTask->CmdLineArg if (defined $StepTask->CmdLineArg);

    printf $Sendmail "%-20s %-8s %-8s %s\n", $StepTask->VM->Name, $Status,
                     $TestFailures, $Cmd;
  }

  print $Sendmail "\nYou can also see the results at:\n$JobURL\n\n";

  # Print the job summary
  my ($JobErrors, $ReportCounts);
  foreach my $Key (@SortedKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();

    my $LogNames = GetLogFileNames($TaskDir);
    $JobErrors->{$Key}->{LogNames} = $LogNames;
    foreach my $LogName (@$LogNames)
    {
      my ($Groups, $Errors) = GetLogErrors("$TaskDir/$LogName");
      next if (!$Groups or !@$Groups);
      $JobErrors->{$Key}->{HasErrors} = 1;
      $JobErrors->{$Key}->{$LogName}->{Groups} = $Groups;
      $JobErrors->{$Key}->{$LogName}->{Errors} = $Errors;

      print $Sendmail "\n=== ", GetTitle($StepTask, $LogName), " ===\n";

      foreach my $GroupName (@$Groups)
      {
        print $Sendmail ($GroupName ? "\n$GroupName:\n" : "\n");
        print $Sendmail "$_\n" for (@{$Errors->{$GroupName}});
      }
    }
  }

  # Print the log attachments
  foreach my $Key (@SortedKeys)
  {
    my $StepTask = $StepsTasks->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();

    foreach my $LogName (@{$JobErrors->{$Key}->{LogNames}})
    {
      print $Sendmail <<"EOF";

--$PART_BOUNDARY
Content-Type: text/plain; charset="UTF-8"
MIME-Version: 1.0
Content-Transfer-Encoding: 8bit
EOF
      print $Sendmail "Content-Disposition: attachment; filename=",
                     $StepTask->VM->Name, "_$LogName\n\n";
      if ($Debug)
      {
        print $Sendmail "Not dumping logs in debug mode\n";
      }
      else
      {
        DumpLogAndErr($Sendmail, "$TaskDir/$LogName");
      }
    }
  }
  
  print $Sendmail "\n--$PART_BOUNDARY--\n";
  close($Sendmail);

  # This is all for jobs submitted from the website
  if (!defined $Job->Patch)
  {
    Debug("Not a mailing list patch -> all done.\n");
    return;
  }


  #
  # Build a job summary with only the new errors
  #

  # Note that this may be a bit inaccurate right after a Wine commit if this
  # job's patch got compiled on top of the new Wine before all the reference
  # WineTest results were updated. This is made more likely by the job
  # priorities: high for Wine updates, and low for WineTest runs.
  # However in practice this would only be an issue if the patch reintroduced
  # an error that just disappeared in the latest Wine which is highly unlikely.
  my @Messages;
  foreach my $Key (@SortedKeys)
  {
    next if (!$JobErrors->{$Key}->{HasErrors});
    my $StepTask = $StepsTasks->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();

    # Note: We could check $StepTask->Status for TestBot errors. However,
    # whether they are caused by the patch or not, they prevent the TestBot
    # from checking for new errors which justifies sending an email to the
    # mailing list so that the patch receives greater scrutiny.

    foreach my $LogName (@{$JobErrors->{$Key}->{LogNames}})
    {
      my $LogErrors = $JobErrors->{$Key}->{$LogName};
      my $RefFileName = "$DataDir/latest". $StepTask->VM->Name ."_$LogName";
      my ($NewGroups, $NewErrors) = GetNewLogErrors($RefFileName, $LogErrors->{Groups}, $LogErrors->{Errors});
      if (!$NewGroups)
      {
        # There was no reference log (typical of build logs)
        # so every error is new
        $NewGroups = $LogErrors->{Groups};
        $NewErrors = $LogErrors->{Errors};
      }
      elsif (!@$NewGroups)
      {
        # There is no new error
        next;
      }

      push @Messages, "\n=== ". GetTitle($StepTask, $LogName) ." ===\n";

      foreach my $GroupName (@$NewGroups)
      {
        push @Messages, ($GroupName ? "\n$GroupName:\n" : "\n");
        push @Messages, "$_\n" for (@{$NewErrors->{$GroupName}});
      }
    }
  }


  #
  # Send a summary of the new errors to the mailing list
  #

  Debug("\n-------------------- Mailing list email --------------------\n");

  if (@Messages)
  {
    if ($Debug)
    {
      open($Sendmail, ">>&=", 1);
    }
    else
    {
      open($Sendmail, "|-", "/usr/sbin/sendmail -oi -t -odq");
    }
    print $Sendmail "From: $RobotEMail\n";
    print $Sendmail "To: $To\n";
    print $Sendmail "Cc: $WinePatchCc\n";
    print $Sendmail "Subject: Re: ", $Job->Patch->Subject, "\n";
    if ($Job->Patch->MessageId)
    {
      print $Sendmail "In-Reply-To: ", $Job->Patch->MessageId, "\n";
      print $Sendmail "References: ", $Job->Patch->MessageId, "\n";
    }
    print $Sendmail <<"EOF";

Hi,

While running your changed tests on Windows, I think I found new failures.
Being a bot and all I'm not very good at pattern recognition, so I might be
wrong, but could you please double-check?

Full results can be found at:
$JobURL

Your paranoid android.

EOF

    print $Sendmail $_ for (@Messages);
    close($Sendmail);
  }
  else
  {
    Debug("Found no error to report to the mailing list\n");
  }


  #
  # Create a .testbot file for the patches website
  #

  my $Patch = $Job->Patch;
  if (defined $Patch->WebPatchId and -d "$DataDir/webpatches")
  {
    my $BaseName = "$DataDir/webpatches/" . $Patch->WebPatchId;
    Debug("\n-------------------- WebPatches report --------------------\n");
    Debug("-- $BaseName.testbot --\n");
    if (open(my $Result, ">", "$BaseName.testbot"))
    {
      # Only take into account new errors to decide whether the job was
      # successful or not.
      DebugTee($Result, "Status: ". (@Messages ? "Failed" : "OK") ."\n");
      DebugTee($Result, "Job-ID: ". $Job->Id ."\n");
      DebugTee($Result, "URL: $JobURL\n");

      foreach my $Key (@SortedKeys)
      {
        my $StepTask = $StepsTasks->GetItem($Key);
        my $TaskDir = $StepTask->GetTaskDir();

        foreach my $LogName (@{$JobErrors->{$Key}->{LogNames}})
        {
          print $Result "=== ", GetTitle($StepTask, $LogName), " ===\n";
          DumpLogAndErr($Result, "$TaskDir/$LogName");
        }
      }
      print $Result "--- END FULL_LOGS ---\n";
      close($Result);
    }
    else
    {
      Error "Job ". $Job->Id .": Unable to open '$BaseName.testbot' for writing: $!";
    }
  }
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/bin:/bin";
delete $ENV{ENV};

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

my ($JobId);
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
  if (!defined $JobId)
  {
    Error "you must specify the job id\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  if ($Usage)
  {
    Error "try '$Name0 --help' for more information\n";
    exit $Usage;
  }
  print "Usage: $Name0 [--debug] [--help] JOBID\n";
  print "\n";
  print "Analyze the job's logs and notifies the developer and the patches website.\n";
  print "\n";
  print "Where:\n";
  print "  JOBID      Id of the job to report on.\n";
  print "  --debug    More verbose messages for debugging.\n";
  print "  --log-only Only send error messages to the log instead of also printing them\n";
  print "             on stderr.\n";
  print "  --help     Shows this usage message.\n";
  exit 0;
}

my $Job = CreateJobs()->GetItem($JobId);
if (!defined $Job)
{
  Error "Job $JobId doesn't exist\n";
  exit 1;
}


#
# Analyze the log, notify the developer and the Patches website
#

SendLog($Job);

LogMsg "Log for job $JobId sent\n";

exit 0;
