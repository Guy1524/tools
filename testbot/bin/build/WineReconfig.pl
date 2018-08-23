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

use Build::Utils;
use WineTestBot::Config;


#
# Build helpers
#

sub BuildWine($$$$)
{
  my ($Targets, $NoRm, $Build, $Extras) = @_;

  return 1 if (!$Targets->{$Build});
  # FIXME Temporary code to ensure compatibility during the transition
  my $OldDir = "build-$Build";
  if (-d "$DataDir/$OldDir" and !-d "$DataDir/wine-$Build")
  {
    rename("$DataDir/$OldDir", "$DataDir/wine-$Build");
    # Add a symlink from compatibility with older server-side TestBot scripts
    symlink("wine-$Build", "$DataDir/$OldDir");
  }
  mkdir "$DataDir/wine-$Build" if (!-d "$DataDir/wine-$Build");

  # If $NoRm is not set, rebuild from scratch to make sure cruft will not
  # accumulate
  InfoMsg "\nRebuilding the $Build Wine\n";
  my $CPUCount = GetCPUCount();
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
  my ($Targets, $NoRm) = @_;

  return BuildWine($Targets, $NoRm, "win32", "") &&
         BuildWine($Targets, $NoRm, "wow64", "--enable-win64") &&
         BuildWine($Targets, $NoRm, "wow32", "--with-wine64='$DataDir/wine-wow64'");
}


#
# WinePrefix helpers
#

sub UpdateWinePrefixes($)
{
  my ($Targets) = @_;

  # Set up brand new WinePrefixes ready for use for testing.
  # This way we do it once instead of doing it for every test, thus saving
  # time. Note that this requires using a different wineprefix for each build.
  foreach my $Build ("win32", "wow64", "wow32")
  {
    next if (!$Targets->{$Build});

    # Wait for the wineprefix creation to complete so it is really done
    # before the snapshot gets updated.
    SetupWineEnvironment($Build);
    my $ErrMessage = CreateWinePrefix($Build, "wait");
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

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my %AllTargets;
map { $AllTargets{$_} = 1 } qw(win32 wow32 wow64);

my ($Usage, $OptUpdate, $OptBuild, $OptNoRm, $OptAddOns, $OptWinePrefix, $TargetList);
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
  elsif (!defined $TargetList)
  {
    $TargetList = $Arg;
  }
  else
  {
    Error "unexpected argument '$Arg'\n";
    $Usage = 2;
    last;
  }
}

# Check and untaint parameters
my $Targets;
if (!defined $Usage)
{
  if (!$OptUpdate and !$OptBuild and !$OptAddOns and !$OptWinePrefix)
  {
    $OptUpdate = $OptBuild = $OptAddOns = $OptWinePrefix = 1;
  }
  $TargetList = join(",", keys %AllTargets) if (!defined $TargetList);
  foreach my $Target (split /,/, $TargetList)
  {
    if (!$AllTargets{$Target})
    {
      Error "invalid target name $Target\n";
      $Usage = 2;
      last;
    }
    $Targets->{$Target} = 1;
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
  print "                       [--help] [TARGETS]\n";
  print "\n";
  print "Performs all the tasks needed for the host to be ready to test new patches: update the Wine source and addons, and rebuild the Wine binaries.\n";
  print "\n";
  print "Where:\n";
  print "  --update     Update Wine's source code.\n";
  print "  --build      Update the Wine builds.\n";
  print "  --addons     Update the Gecko and Mono Wine addons.\n";
  print "  --wineprefix Update the wineprefixes.\n";
  print "If none of the above actions is specified they are all performed.\n";
  print "  TARGETS      Is a comma-separated list of targets to process. By default all\n";
  print "               targets are processed.\n";
  print "               - win32: Apply the above to the regular 32 bit Wine.\n";
  print "               - wow32: Apply the above to the 32 bit WoW Wine.\n";
  print "               - wow64: Apply the above to the 64 bit WoW Wine.\n";
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
exit(1) if ($OptUpdate and !GitPull("wine"));
exit(1) if ($OptAddOns and !UpdateAddOns());
exit(1) if ($OptBuild and !UpdateWineBuilds($Targets, $OptNoRm));
exit(1) if ($OptWinePrefix and !UpdateWinePrefixes($Targets));

LogMsg "ok\n";
exit;
