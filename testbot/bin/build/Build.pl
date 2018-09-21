#!/usr/bin/perl
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# Performs the 'build' task in the build machine. Specifically this applies a
# conformance test patch, rebuilds the impacted test and retrieves the
# resulting 32 and 64 bit binaries.
#
# This script does not use tainting (-T) because its whole purpose is to run
# arbitrary user-provided code anyway (in patch form).
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
use WineTestBot::Utils;


#
# Build helpers
#


sub BuildNative()
{
  InfoMsg "\nRebuilding native tools\n";
  my $CPUCount = GetCPUCount();
  system("cd '$DataDir/wine-native' && set -x && ".
         "time make -j$CPUCount __tooldeps__");
  if ($? != 0)
  {
    LogMsg "The Wine native tools build failed\n";
    return !1;
  }

  return 1;
}

sub BuildTestExecutables($$$)
{
  my ($Targets, $Impacts, $Build) = @_;

  return 1 if (!$Targets->{$Build});

  my (@BuildDirs, @TestExes);
  foreach my $TestInfo (values %{$Impacts->{Tests}})
  {
    push @BuildDirs, $TestInfo->{Path};
    my $TestExe = "$TestInfo->{Path}/$TestInfo->{ExeBase}.exe";
    push @TestExes, $TestExe;
    unlink("$DataDir/wine-$Build/$TestExe"); # Ignore errors
  }

  InfoMsg "\nBuilding the $Build Wine test executable(s)\n";
  my $CPUCount = GetCPUCount();
  system("cd '$DataDir/wine-$Build' && set -x && ".
         "time make -j$CPUCount ". join(" ", sort @BuildDirs));
  if ($? != 0)
  {
    LogMsg "The $Build Wine crossbuild failed\n";
    return !1;
  }

  my $Success = 1;
  foreach my $TestExe (@TestExes)
  {
    if (!-f "$DataDir/wine-$Build/$TestExe")
    {
      LogMsg "Make didn't produce the $Build $TestExe file\n";
      $Success = !1;
    }
  }

  return $Success;
}


#
# Setup and command line processing
#

$ENV{PATH} = "/usr/lib/ccache:/usr/bin:/bin";
delete $ENV{ENV};

my %AllTargets;
map { $AllTargets{$_} = 1 } qw(exe32 exe64);

my ($Usage, $PatchFile, $TargetList);
while (@ARGV)
{
  my $Arg = shift @ARGV;
  if ($Arg =~ /^(?:-\?|-h|--help)$/)
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
  elsif (!defined $PatchFile)
  {
    if (IsValidFileName($Arg))
    {
      $PatchFile = "$DataDir/staging/$Arg";
      if (!-r $PatchFile)
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
  if (!defined $PatchFile)
  {
    Error "you must specify a patch to apply\n";
    $Usage = 2;
  }

  $TargetList = join(",", keys %AllTargets) if (!defined $TargetList);
  foreach my $Target (split /[,:]/, $TargetList)
  {
    $Target = "exe$1" if ($Target =~ /^(32|64)$/);
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
  print "Usage: $Name0 [--help] PATCHFILE TARGETS\n";
  print "\n";
  print "Applies the specified patch and rebuilds the Wine test executables.\n";
  print "\n";
  print "Where:\n";
  print "  PATCHFILE Is the staging file containing the patch to build.\n";
  print "  TARGETS   Is a comma-separated list of build targets. By default every\n";
  print "            target is run.\n";
  print "            - exe32: Rebuild the 32 bit Windows test executables.\n";
  print "            - exe64: Rebuild the 64 bit Windows test executables.\n";
  print "  --help    Shows this usage message.\n";
  exit 0;
}

if ($DataDir =~ /'/)
{
    LogMsg "The install path contains invalid characters\n";
    exit(1);
}


#
# Run the builds
#

my $Impacts = ApplyPatch("wine", $PatchFile);

if (!$Impacts or
    ($Impacts->{PatchedRoot} and !BuildNative()) or
    !BuildTestExecutables($Targets, $Impacts, "exe32") or
    !BuildTestExecutables($Targets, $Impacts, "exe64"))
{
  exit(1);
}

LogMsg "ok\n";
exit;
