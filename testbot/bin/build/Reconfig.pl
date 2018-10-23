#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'reconfig' task in the build machine. Specifically this updates
# the build machine's Wine repository, re-runs configure, and rebuilds the
# 32 and 64 bit winetest binaries.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014, 2017-2018 Francois Gouget
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

use Build::Utils;
use WineTestBot::Config;
use WineTestBot::Missions;


#
# Build helpers
#

sub BuildNative($)
{
  my ($NoRm) = @_;

  mkdir "$DataDir/wine-native" if (!-d "$DataDir/wine-native");

  # Rebuild from scratch to make sure cruft will not accumulate
  InfoMsg "\nRebuilding native tools\n";
  my $CPUCount = GetCPUCount();
  system("cd '$DataDir/wine-native' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure --enable-win64 --without-x --without-freetype --disable-winetest && ".
         "time make -j$CPUCount __tooldeps__");

  if ($? != 0)
  {
    LogMsg "The Wine native tools build failed\n";
    return !1;
  }

  return 1;
}

sub BuildCross($$$)
{
  my ($TaskMissions, $NoRm, $Build) = @_;

  return 1 if (!$TaskMissions->{Builds}->{$Build});
  mkdir "$DataDir/wine-$Build" if (!-d "$DataDir/wine-$Build");

  # Rebuild from scratch to make sure cruft will not accumulate
  InfoMsg "\nRebuilding the $Build Wine test executables\n";
  my $CPUCount = GetCPUCount();
  my $Host = ($Build eq "exe64" ? "x86_64-w64-mingw32" : "i686-w64-mingw32");
  system("cd '$DataDir/wine-$Build' && set -x && ".
         ($NoRm ? "" : "rm -rf * && ") .
         "time ../wine/configure --host=$Host --with-wine-tools=../wine-native --without-x --without-freetype --disable-winetest && ".
         "time make -j$CPUCount buildtests");
  if ($? != 0)
  {
    LogMsg "The $Build Wine crossbuild failed\n";
    return !1;
  }

  return 1;
}

sub UpdateWineBuilds($$)
{
  my ($TaskMissions, $NoRm) = @_;

  return BuildNative($NoRm) &&
         BuildCross($TaskMissions, $NoRm, "exe32") &&
         BuildCross($TaskMissions, $NoRm, "exe64");
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my ($Usage, $OptUpdate, $OptBuild, $OptNoRm, $MissionStatement);
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
  if (!$OptUpdate and !$OptBuild)
  {
    $OptUpdate = $OptBuild = 1;
  }
  $MissionStatement ||= "exe32:exe64";
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
  print "Usage: $Name0 [--update] [--build [--no-rm]] [--help] [MISSIONS]\n";
  print "\n";
  print "Updates Wine to the latest version and recompiles it so the host is ready to build executables for the Windows tests.\n";
  print "\n";
  print "Where:\n";
  print "  --update     Update Wine's source code.\n";
  print "  --build      Update the Wine builds.\n";
  print "  MISSIONS     Is a colon-separated list of missions. By default the following\n";
  print "               missions are run.\n";
  print "               - exe32: Build the 32 bit Windows test executables.\n";
  print "               - exe64: Build the 64 bit Windows test executables.\n";
  print "  --no-rm      Don't rebuild from scratch.\n";
  print "  --help       Shows this usage message.\n";
  exit 0;
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}
if (! -d "$DataDir/staging" and ! mkdir "$DataDir/staging")
{
    LogMsg "Unable to create '$DataDir/staging': $!\n";
    exit(1);
}


#
# Run the builds
#

exit(1) if (!BuildNativeTestAgentd() or !BuildWindowsTestAgentd());
exit(1) if (!BuildTestLauncher());
exit(1) if ($OptUpdate and !GitPull("wine"));
exit(1) if ($OptBuild and !UpdateWineBuilds($TaskMissions, $OptNoRm));

LogMsg "ok\n";
exit;
