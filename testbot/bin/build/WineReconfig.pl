#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Updates the Wine source from Git and rebuilds it.
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

use File::Basename;
use File::Path;

use Build::Utils;
use WineTestBot::Config;
use WineTestBot::Missions;


#
# Build helpers
#

sub BuildWine($$$$;$)
{
  my ($TaskMissions, $NoRm, $Build, $Extras, $WithWine) = @_;

  return 1 if (!$TaskMissions->{Builds}->{$Build});
  mkdir "$DataDir/wine-$Build" if (!-d "$DataDir/wine-$Build");

  # If $NoRm is not set, rebuild from scratch to make sure cruft will not
  # accumulate
  InfoMsg "\nRebuilding the $Build Wine\n";
  my $CPUCount = GetCPUCount();
  $Extras .= " --with-wine64='$WithWine'" if (defined $WithWine);
  system("cd '$DataDir/wine-$Build' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure $Extras && ".
         "time make -j$CPUCount");
  if ($? != 0)
  {
    LogMsg "The $Build Wine build failed\n";
    return !1;
  }

  return 1;
}

sub UpdateWineBuilds($$)
{
  my ($TaskMissions, $NoRm) = @_;

  return BuildWine($TaskMissions, $NoRm, "win32", "") &&
         BuildWine($TaskMissions, $NoRm, "wow64", "--enable-win64") &&
         BuildWine($TaskMissions, $NoRm, "wow32", "", "$DataDir/wine-wow64");
}


#
# WinePrefix helpers
#

sub UpdateWinePrefixes($)
{
  my ($TaskMissions) = @_;

  # Make sure no obsolete wineprefix is left behind in case WineReconfig
  # is called with a different set of targets
  foreach my $Dir (glob("'$DataDir/wineprefix-*'"))
  {
    if (basename($Dir) =~ /^(wineprefix-[a-zA-Z0-9\@_.-]+)$/) # untaint
    {
      rmtree("$DataDir/$1");
    }
  }

  # Set up brand new WinePrefixes ready for use for testing.
  # This way we do it once instead of doing it for every test, thus saving
  # time. Note that this requires using a different wineprefix for each
  # mission.
  foreach my $Mission (@{$TaskMissions->{Missions}})
  {
    next if ($Mission->{test} eq "build");

    my $BaseName = SetupWineEnvironment($Mission);
    InfoMsg "\nRecreating the $BaseName wineprefix\n";

    # Wait for the wineprefix creation to complete so it is really done
    # before the snapshot gets updated.
    my $ErrMessage = CreateWinePrefix($Mission, "wait");
    if (defined $ErrMessage)
    {
      LogMsg "$ErrMessage\n";
      return 0;
    }
  }
  return 1;
}


#
# Setup and command line processing
#

my ($Usage, $OptUpdate, $OptBuild, $OptNoRm, $OptAddOns, $OptWinePrefix, $MissionStatement);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg eq "--update")
  {
    $OptUpdate = 1;
  }
  elsif ($Arg eq "--build")
  {
    $OptBuild = 1;
  }
  elsif ($Arg eq "--no-rm")
  {
    $OptNoRm = 1;
  }
  elsif ($Arg eq "--addons")
  {
    $OptAddOns = 1;
  }
  elsif ($Arg eq "--wineprefix")
  {
    $OptWinePrefix = 1;
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
  if (!$OptUpdate and !$OptBuild and !$OptAddOns and !$OptWinePrefix)
  {
    $OptUpdate = $OptBuild = $OptAddOns = $OptWinePrefix = 1;
  }
  $MissionStatement ||= "win32:wow32:wow64";
  my ($ErrMessage, $Missions) = ParseMissionStatement($MissionStatement);
  if (defined $ErrMessage)
  {
    Error "$ErrMessage\n";
    $Usage = 2;
  }
  elsif (!@$Missions)
  {
    Error "Empty mission statement\n";
    $Usage = 2;
  }
  elsif (@$Missions > 1)
  {
    Error "Cannot specify missions for multiple tasks\n";
    $Usage = 2;
  }
  else
  {
    $TaskMissions = $Missions->[0];
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
  print "Usage: $Name0 [--update] [--build [--no-rm]] [--addons] [--wineprefix]\n";
  print "                       [--help] [MISSIONS]\n";
  print "\n";
  print "Performs all the tasks needed for the host to be ready to test new patches: update the Wine source and addons, and rebuild the Wine binaries.\n";
  print "\n";
  print "Where:\n";
  print "  --update     Update Wine's source code.\n";
  print "  --build      Update the Wine builds.\n";
  print "  --addons     Update the Gecko and Mono Wine addons.\n";
  print "  --wineprefix Update the wineprefixes.\n";
  print "If none of the above actions is specified they are all performed.\n";
  print "  MISSIONS     Is a colon-separated list of missions. By default the\n";
  print "               following missions are run.\n";
  print "               - win32: Build the regular 32 bit Wine.\n";
  print "               - wow32: Build the 32 bit WoW Wine.\n";
  print "               - wow64: Build the 64 bit WoW Wine.\n";
  print "  --no-rm      Don't rebuild from scratch.\n";
  print "  --help       Shows this usage message.\n";
  exit 0;
}

if (! -d "$DataDir/staging" and ! mkdir "$DataDir/staging")
{
    LogMsg "Unable to create '$DataDir/staging': $!\n";
    exit(1);
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}


#
# Run the builds and/or tests
#

exit(1) if (!BuildNativeTestAgentd());
exit(1) if (!BuildTestLauncher());
exit(1) if ($OptUpdate and !GitPull("wine"));
exit(1) if ($OptAddOns and !UpdateAddOns());
exit(1) if ($OptBuild and !UpdateWineBuilds($TaskMissions, $OptNoRm));
exit(1) if ($OptWinePrefix and !UpdateWinePrefixes($TaskMissions));

LogMsg "ok\n";
exit;
