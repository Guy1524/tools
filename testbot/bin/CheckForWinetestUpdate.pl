#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Checks if a new winetest binary is available on http://test.winehq.org/data/.
# If so, triggers an update of the build VM to the latest Wine source and
# runs the full test suite on the standard Windows test VMs.
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

use File::Basename;
use File::Compare;
use File::Copy;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Response;
use HTTP::Status;

use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::Log;
use WineTestBot::SpecialJobs;
use WineTestBot::VMs;


my %WineTestUrls = (
    "exe32" => "http://test.winehq.org/builds/winetest-latest.exe",
    "exe64" => "http://test.winehq.org/builds/winetest64-latest.exe"
);

my %TaskTypes = (build => "Update and rebuild Wine on the build VMs.",
                 base32 => "Run WineTest on the 32 bit Windows VMs with the 'base' role.",
                 other32 => "Run WineTest on the 32 bit Windows VMs with the 'winetest' role.",
                 all64 => "Run WineTest on the all the 64 bit Windows VMs.",
                 winebuild => "Update and rebuild Wine on the Wine VMs.",
                 winetest => "Run WineTest on the Wine VMs.");


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


=pod
=over 12

=item C<UpdateWineTest()>

Downloads the latest WineTest executable.

Returns 1 if the executable was updated, 0 if it was not, and -1 if an
error occurred.

=back
=cut

sub UpdateWineTest($$)
{
  my ($OptCreate, $Build) = @_;

  my $BitsSuffix = ($Build eq "exe64" ? "64" : "");
  my $LatestBaseName = "winetest${BitsSuffix}-latest.exe";
  my $LatestFileName = "$DataDir/latest/$LatestBaseName";
  if ($OptCreate)
  {
    return (1, $LatestBaseName) if (-r $LatestFileName);
    Debug("$LatestBaseName is missing\n");
  }

  # See if the online WineTest executable is newer
  my $UA = LWP::UserAgent->new();
  $UA->agent("WineTestBot");
  my $Request = HTTP::Request->new(GET => $WineTestUrls{$Build});
  if (-r $LatestFileName)
  {
    my $Since = gmtime(GetMTime($LatestFileName));
    $Request->header("If-Modified-Since" => "$Since GMT");
  }
  Debug("Checking $WineTestUrls{$Build}\n");
  my $Response = $UA->request($Request);
  if ($Response->code == RC_NOT_MODIFIED)
  {
    Debug("$LatestBaseName is already up to date\n");
    return (0, $LatestBaseName); # Already up to date
  }
  if ($Response->code != RC_OK)
  {
    Error "Unexpected HTTP response code ", $Response->code, "\n";
    return (-1, undef);
  }

  # Download the WineTest executable
  Debug("Downloading $LatestBaseName\n");
  umask 002;
  mkdir "$DataDir/staging";
  my ($fh, $StagingFileName) = OpenNewFile("$DataDir/staging", "_$LatestBaseName");
  if (!$fh)
  {
    Error "Could not create staging file: $!\n";
    return (-1, undef);
  }
  print $fh $Response->decoded_content();
  close($fh);

  if (-r $LatestFileName and compare($StagingFileName, $LatestFileName) == 0)
  {
    Debug("$LatestBaseName did not change\n");
    unlink($StagingFileName);
    return (0, $LatestBaseName); # No change after all
  }

  # Save the WineTest executable to the latest directory for the next round
  mkdir "$DataDir/latest";
  if (!move($StagingFileName, $LatestFileName))
  {
    Error "Could not move '$StagingFileName' to '$LatestFileName': $!\n";
    unlink($StagingFileName);
    return (-1, undef);
  }
  utime time, $Response->last_modified, $LatestFileName;

  return (1, $LatestBaseName);
}

sub DoReconfig($$)
{
  my ($VMKey, $VMType) = @_;
  Debug("Creating the $VMType reconfig job\n");
  my $VMs = GetReconfigVMs($VMKey, $VMType);
  if (@$VMs)
  {
    my $ErrMessage = AddReconfigJob($VMs, $VMKey, $VMType);
    if (defined $ErrMessage)
    {
      ErrorMessage("$ErrMessage\n");
      return 0;
    }
  }
  elsif (defined $VMKey)
  {
    Error("The $VMKey VM is not a $VMType VM\n");
    return 0;
  }
  else
  {
    Debug("Found no VM for the $VMType reconfig job\n");
  }
  return 1;
}

sub DoWindowsTest($$$$)
{
  my ($VMKey, $Build, $BaseJob, $LatestBaseName) = @_;
  Debug("Creating the $BaseJob $Build Windows tests job\n");
  my $VMs = GetWindowsTestVMs($VMKey, $Build, $BaseJob);
  if (@$VMs)
  {
    my $ErrMessage = AddWindowsTestJob($VMs, $VMKey, $Build, $BaseJob, $LatestBaseName);
    if (defined $ErrMessage)
    {
      ErrorMessage("$ErrMessage\n");
      return 0;
    }
  }
  elsif (defined $VMKey)
  {
    Error("The $VMKey VM is not suitable for $BaseJob $Build Windows tests jobs\n");
    return 0;
  }
  else
  {
    Debug("Found no VM for the $BaseJob $Build Windows tests job\n");
  }
  return 1;
}

sub DoWineTest($)
{
  my ($VMKey) = @_;
  Debug("Creating the Wine tests job\n");
  my $VMs = GetWineTestVMs($VMKey);
  if (@$VMs)
  {
    my $ErrMessage = AddWineTestJob($VMs, $VMKey);
    if (defined $ErrMessage)
    {
      ErrorMessage("$ErrMessage\n");
      return 0;
    }
  }
  elsif (defined $VMKey)
  {
    Error("The $VMKey VM is not suitable for Wine tests jobs\n");
    return 0;
  }
  else
  {
    Debug("Found no VM for the Wine tests job\n");
  }
  return 1;
}


#
# Command line processing
#

my $Usage;
sub CheckValue($$)
{
    my ($Option, $Value)=@_;

    if (defined $Value)
    {
        Error "$Option can only be specified once\n";
        $Usage = 2; # but continue processing this option
    }
    if (!@ARGV)
    {
        Error "missing value for $Option\n";
        $Usage = 2;
        return undef;
    }
    return shift @ARGV;
}

my ($OptCreate, %OptTypes, $OptVMKey);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--create")
  {
    $OptCreate = 1;
  }
  elsif ($Arg eq "--vm")
  {
    $OptVMKey = CheckValue($Arg, $OptVMKey);
  }
  elsif ($TaskTypes{$Arg})
  {
    $OptTypes{$Arg} = 1;
  }
  elsif ($Arg eq "--debug")
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
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check and untaint parameters
if (!defined $Usage)
{
  if (!defined $OptVMKey)
  {
    # By default create all types of jobs except the winetest ones which will
    # be created for each Wine VM by the corresponding winebuild task.
    if (!%OptTypes)
    {
      %OptTypes = %TaskTypes;
      delete $OptTypes{winetest};
    }
  }
  elsif ($OptVMKey =~ /^([a-zA-Z0-9_]+)$/)
  {
    $OptVMKey = $1; # untaint
    my $VM = CreateVMs()->GetItem($OptVMKey);
    if (!defined $VM)
    {
      Error "The $OptVMKey VM does not exist\n";
      $Usage = 2;
    }
    elsif (!%OptTypes)
    {
      %OptTypes = $VM->Type eq "build" ? ("build" => 1) :
                  $VM->Type eq "wine" ?  ("winebuild" => 1) :
                  $VM->Type eq "win32" ? ("base32" => 1) :
                  ("base32" => 1, "all64" => 1);
    }
  }
  else
  {
    Error "'$OptVMKey' is not a valid VM name\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  print "Usage: $Name0 [--debug] [--log-only] [--help] [--create] [--vm VM] [TASKTYPE] ...\n";
  print "\n";
  print "Where TASKTYPE is one of:\n";
  foreach my $TaskType (sort keys %TaskTypes)
  {
    printf(" %-15s %s\n", $TaskType, $TaskTypes{$TaskType});
  }
  exit $Usage;
}


#
# Create the 32 bit tasks
#

my $Rc = 0;
if ($OptTypes{build} or $OptTypes{base32} or $OptTypes{other32} or
    $OptTypes{winebuild} or $OptTypes{winetest})
{
  my ($Create, $LatestBaseName) = UpdateWineTest($OptCreate, "exe32");
  if ($Create < 0)
  {
    $Rc = 1;
  }
  elsif ($Create == 1)
  {
    # A new executable means there have been commits so update Wine. Create
    # this job first purely to make the WineTestBot job queue look nice, and
    # arbitrarily do it only for 32-bit executables to avoid redundant updates.
    $Rc = 1 if ($OptTypes{build} and !DoReconfig($OptVMKey, "build"));
    $Rc = 1 if ($OptTypes{base32} and !DoWindowsTest($OptVMKey, "exe32", "base", $LatestBaseName));
    $Rc = 1 if ($OptTypes{other32} and !DoWindowsTest($OptVMKey, "exe32", "other", $LatestBaseName));

    $Rc = 1 if ($OptTypes{winebuild} and !DoReconfig($OptVMKey, "wine"));
    $Rc = 1 if ($OptTypes{winetest} and !DoWineTest($OptVMKey));
  }
}


#
# Create the 64 bit tasks
#

if ($OptTypes{all64})
{
  my ($Create, $LatestBaseName) = UpdateWineTest($OptCreate, "exe64");
  if ($Create < 0)
  {
    $Rc = 1;
  }
  elsif ($Create == 1)
  {
    $Rc = 1 if ($OptTypes{all64} and !DoWindowsTest($OptVMKey, "exe64", "", $LatestBaseName));
  }
}

RescheduleJobs();

LogMsg "Submitted jobs\n";

exit $Rc;
