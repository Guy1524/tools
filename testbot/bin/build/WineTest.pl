#!/usr/bin/perl
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Applies the patch and rebuilds Wine.
#
# This script does not use tainting (-T) because its whole purpose is to run
# arbitrary user-provided code anyway.
#
# Copyright 2018 Francois Gouget
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

use warnings;
use strict;

sub BEGIN
{
  if ($0 !~ m=^/=)
  {
    # Turn $0 into an absolute path so it can safely be used in @INC
    require Cwd;
    $0 = Cwd::cwd() . "/$0";
  }
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
  $::BuildEnv = 1;
}

use Build::Utils;
use WineTestBot::Config;
use WineTestBot::Missions;
use WineTestBot::Utils;


#
# Build helpers
#

sub BuildWine($$)
{
  my ($TaskMissions, $Build) = @_;

  return 1 if (!$TaskMissions->{Builds}->{$Build});

  InfoMsg "\nRebuilding the $Build Wine\n";
  my $CPUCount = GetCPUCount();
  system("cd '$DataDir/wine-$Build' && set -x && ".
         "time make -j$CPUCount");
  if ($? != 0)
  {
    LogMsg "The $Build build failed\n";
    return !1;
  }

  return 1;
}


#
# Test helpers
#

my $InTests;

sub SetupTest($$)
{
  my ($Test, $Mission) = @_;

  LogMsg "tests\n" if (!$InTests);
  $InTests = 1;

  my $BaseName = SetupWineEnvironment($Mission);
  InfoMsg "\nRunning $Test in the $BaseName Wine\n";
  InfoMsg "LANG=$ENV{LANG}\n";
  return $BaseName;
}

sub DailyWineTest($$$$)
{
  my ($Mission, $NoSubmit, $BaseTag, $Args) = @_;

  my $BaseName = SetupTest("WineTest", $Mission);

  # Run WineTest. Ignore the exit code since it returns non-zero whenever
  # there are test failures.
  my $Tag = SanitizeTag("$BaseTag-$BaseName");
  RunWine($Mission, "./programs/winetest/winetest.exe.so",
          "-c -o '../$BaseName.report' -t $Tag ". ShArgv2Cmd(@$Args));
  if (!-f "$BaseName.report")
  {
    LogMsg "WineTest did not produce the $BaseName report\n";
    return 0;
  }

  # Send the report to the website
  if ((!$NoSubmit and !$Mission->{nosubmit}) and
      RunWine($Mission, "./programs/winetest/winetest.exe.so",
              "-c -s '../$BaseName.report'"))
  {
    LogMsg "WineTest failed to send the $BaseName report\n";
    # Soldier on in case it's just a network issue
  }

  return 1;
}

sub TestPatch($$)
{
  my ($Mission, $Impacts) = @_;

  return 1 if ($Mission->{test} eq "build");

  my @TestList;
  if ($Mission->{test} eq "all" and
      ($Impacts->{PatchedRoot} or $Impacts->{PatchedModules}))
  {
    push @TestList, "-m", "do.not.submit";
  }
  else
  {
    foreach my $Module (sort keys %{$Impacts->{Tests}})
    {
      my $TestInfo = $Impacts->{Tests}->{$Module};
      if ($TestInfo->{All} or
          ($Mission->{test} eq "module" and $TestInfo->{PatchedModule}))
      {
        # When given a module name WineTest runs all its tests.
        # But make sure the module actually has tests first!
        push @TestList, $Module if (%{$TestInfo->{Files}});
      }
      else
      {
        foreach my $PatchedUnit (sort keys %{$TestInfo->{PatchedUnits}})
        {
          push @TestList, "$Module:$PatchedUnit";
        }
      }
    }
    return 1 if (!@TestList);
  }

  my $BaseName = SetupTest("the tests", $Mission);
  if (!-d $ENV{WINEPREFIX})
  {
    # FIXME Wait for the wineserver as a workaround for bug 41713.
    my $ErrMessage = CreateWinePrefix($Mission, "wait");
    if (defined $ErrMessage)
    {
      LogMsg "Could not create the $BaseName wineprefix: $ErrMessage\n";
      return 0;
    }
  }

  # Run WineTest. Ignore the exit code since it returns non-zero whenever
  # there are test failures.
  RunWine($Mission, "./programs/winetest/winetest.exe.so",
          "-c -o '../$BaseName.report' -t do.not.submit ".
          join(" ", @TestList));
  if (!-f "$BaseName.report")
  {
    LogMsg "WineTest did not produce the $BaseName report\n";
    return 0;
  }

  return 1;
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my $Action = "";
my ($Usage, $OptNoSubmit, $MissionStatement, $FileName, $BaseTag);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--testpatch")
  {
    $Action = "testpatch";
  }
  elsif ($Arg eq "--winetest" or $Arg eq "winetest")
  {
    $Action = "winetest";
  }
  elsif ($Arg eq "--no-submit")
  {
    $OptNoSubmit = 1;
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
  elsif (!defined $MissionStatement)
  {
    $MissionStatement = $Arg;
  }
  elsif ($Action eq "winetest")
  {
    $BaseTag = $Arg;
    # The remaining arguments are meant for WineTest
    last;
  }
  elsif (!defined $FileName)
  {
    if (IsValidFileName($Arg))
    {
      $FileName = "$DataDir/staging/$Arg";
      if (!-r $FileName)
      {
        Error "'$Arg' is not readable\n";
        $Usage = 2;
      }
    }
    else
    {
      Error "the '$Arg' filename contains invalid characters\n";
      $Usage = 2;
      last;
    }
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check and untaint parameters
my $TaskMissions;
if (!defined $Usage)
{
  if (defined $MissionStatement)
  {
    my ($ErrMessage, $Missions) = ParseMissionStatement($MissionStatement);
    if (defined $ErrMessage)
    {
      Error "$ErrMessage\n";
      $Usage = 2;
    }
    elsif (!@$Missions)
    {
      Error "empty mission statement\n";
      $Usage = 2;
    }
    elsif (@$Missions > 1)
    {
      Error "cannot specify missions for multiple tasks\n";
      $Usage = 2;
    }
    else
    {
      $TaskMissions = $Missions->[0];
    }
  }
  else
  {
    Error "you must specify the mission statement\n";
    $Usage = 2;
  }

  if (!$Action)
  {
    Error "you must specify the action to perform\n";
    $Usage = 2;
  }
  elsif ($Action eq "winetest")
  {
    if (!defined $BaseTag)
    {
      Error "you must specify a base tag for WineTest\n";
      $Usage = 2;
    }
    elsif ($BaseTag =~ m/^([\w_.\-]+)$/)
    {
      $BaseTag = $1;
    }
    else
    {
      Error "invalid WineTest base tag '$BaseTag'\n";
      $Usage = 2;
    }
  }
  else
  {
    my $Builds = $TaskMissions->{Builds};
    if ($Builds->{"wow32"} or $Builds->{"wow64"})
    {
      # Always rebuild both WoW targets before running the tests to make sure
      # we don't run into issues caused by the two Wine builds being out of
      # sync.
      $Builds->{"wow32"} = $Builds->{"wow64"} = 1;
    }
  }

  if (!defined $FileName and $Action eq "testpatch")
  {
    Error "you must provide a patch to test\n";
    $Usage = 2;
  }
}
if (defined $Usage)
{
  my $Name0 = GetToolName();
  if ($Usage)
  {
    Error "try '$Name0 --help' for more information\n";
    exit $Usage;
  }
  print "Usage: $Name0 [--help] --testpatch MISSIONS PATCH\n";
  print "or     $Name0 [--help] --winetest [--no-submit] MISSIONS BASETAG ARGS\n";
  print "\n";
  print "Tests the specified patch or runs WineTest in Wine.\n";
  print "\n";
  print "Where:\n";
  print "  --testpatch  Verify that the patch compiles and run the impacted tests.\n";
  print "  --winetest   Run WineTest and submit the result to the website.\n";
  print "  --no-submit  Do not submit the WineTest results to the website.\n";
  print "  MISSIONS     Is a colon-separated list of missions for the specified action.\n";
  print "               - win32: The regular 32 bit Wine build.\n";
  print "               - wow32: The 32 bit WoW Wine build.\n";
  print "               - wow64: The 64 bit WoW Wine build.\n";
  print "  PATCH        Is the staging file containing the patch to test.\n";
  print "  BASETAG      Is the tag for this WineTest run. Note that the build type is\n";
  print "               automatically added to this tag.\n";
  print "  ARGS         The WineTest arguments.\n";
  print "  --help       Shows this usage message.\n";
  exit $Usage;
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}


#
# Run the builds and tests
#

# Clean up old reports
unlink map { GetMissionBaseName($_) .".report" } @{$TaskMissions->{Missions}};

my $Impacts;
if ($Action eq "testpatch")
{
  $Impacts = ApplyPatch("wine", $FileName);
  exit(1) if (!$Impacts or
              !BuildWine($TaskMissions, "win32") or
              !BuildWine($TaskMissions, "wow64") or
              !BuildWine($TaskMissions, "wow32"));
}
foreach my $Mission (@{$TaskMissions->{Missions}})
{
  if ($Action eq "testpatch")
  {
    exit(1) if (!TestPatch($Mission, $Impacts));
  }
  elsif ($Action eq "winetest")
  {
    exit(1) if (!DailyWineTest($Mission,  $OptNoSubmit, $BaseTag, \@ARGV));
  }
}

LogMsg "ok\n";
exit;
