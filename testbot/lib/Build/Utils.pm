# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
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

package Build::Utils;

=head1 NAME

Build::Utils - Utility functions for the build scripts

=cut

use Exporter 'import';
our @EXPORT = qw(GetToolName InfoMsg LogMsg Error
                 GitPull ApplyPatch
                 GetCPUCount BuildNativeTestAgentd BuildWindowsTestAgentd
                 GetTestLauncher BuildTestLauncher UpdateAddOns
                 SetupWineEnvironment RunWine CreateWinePrefix);

use Digest::SHA;
use File::Path;

use WineTestBot::Config;
use WineTestBot::Missions;
use WineTestBot::PatchUtils;
use WineTestBot::Utils;

WineTestBot::Config::PrependPaths("/usr/lib/ccache");


#
# Logging and error handling
#

my $Name0 = $0;
$Name0 =~ s+^.*/++;

sub GetToolName()
{
  return $Name0;
}

sub InfoMsg(@)
{
  print @_;
}

sub LogMsg(@)
{
  print "Task: ", @_;
}

sub Error(@)
{
  print STDERR "$Name0:error: ", @_;
}


#
# Repository updates
#

sub GitPull($)
{
  my ($Dir) = @_;

  InfoMsg "\nUpdating the $Dir source\n";
  system("cd '$DataDir/$Dir' && git pull");
  if ($? != 0)
  {
    LogMsg "Git pull failed\n";
    return !1;
  }

  if ($Dir eq "wine")
  {
    my $ErrMessage = UpdateWineData("$DataDir/$Dir");
    if ($ErrMessage)
    {
      LogMsg "$ErrMessage\n";
      return !1;
    }
  }

  return 1;
}

sub ApplyPatch($$)
{
  my ($Dir, $PatchFile) = @_;

  InfoMsg "Applying patch\n";
  system("cd '$DataDir/$Dir' && ".
         "echo $Dir:HEAD=`git rev-parse HEAD` && ".
         "set -x && ".
         "git apply --verbose ". ShQuote($PatchFile) ." && ".
         "git add -A");
  if ($? != 0)
  {
    LogMsg "Patch failed to apply\n";
    return undef;
  }

  my $Impacts = GetPatchImpacts($PatchFile);
  if ($Impacts->{MakeRequests})
  {
    InfoMsg "\nRunning make_requests\n";
    system("cd '$DataDir/$Dir' && set -x && ./tools/make_requests");
    if ($? != 0)
    {
      LogMsg "make_requests failed\n";
      return undef;
    }
  }
  if ($Impacts->{MakeVulkan})
  {
    InfoMsg "\nRunning make_vulkan\n";
    system("cd '$DataDir/$Dir' && set -x && ./dlls/winevulkan/make_vulkan");
    if ($? != 0)
    {
      LogMsg "make_vulkan failed\n";
      return undef;
    }
  }

  if ($Impacts->{MakeMakefiles})
  {
    InfoMsg "\nRunning make_makefiles\n";
    system("cd '$DataDir/$Dir' && set -x && ./tools/make_makefiles");
    if ($? != 0)
    {
      LogMsg "make_makefiles failed\n";
      return undef;
    }
  }

  if ($Impacts->{Autoconf})
  {
    InfoMsg "\nRunning autoreconf\n";
    system("cd '$DataDir/$Dir' && set -x && autoreconf");
    if ($? != 0)
    {
      LogMsg "autoreconf failed\n";
      return undef;
    }
  }

  return $Impacts;
}


#
# Build helpers
#

my $_CPUCount;

sub GetCPUCount()
{
  if (!defined $_CPUCount)
  {
    if (open(my $Fh, "<", "/proc/cpuinfo"))
    {
      # Linux
      map { $_CPUCount++ if (/^processor/); } <$Fh>;
      close($Fh);
    }
    $_CPUCount ||= 1;
  }
  return $_CPUCount;
}

sub BuildNativeTestAgentd()
{
  # If testagentd already exists it's likely already running
  # so don't rebuild it.
  return 1 if (-x "$BinDir/build/testagentd");

  InfoMsg "\nBuilding the native testagentd\n";
  my $CPUCount = GetCPUCount();
  system("cd '$::RootDir/src/testagentd' && set -x && ".
         "time make -j$CPUCount build");
  if ($? != 0)
  {
    LogMsg "Build testagentd failed\n";
    return !1;
  }

  return 1;
}

sub BuildWindowsTestAgentd()
{
  InfoMsg "\nRebuilding the Windows TestAgentd\n";
  my $CPUCount = GetCPUCount();
  system("cd '$::RootDir/src/testagentd' && set -x && ".
         "time make -j$CPUCount iso");
  if ($? != 0)
  {
    LogMsg "Build winetestbot.iso failed\n";
    return !1;
  }

  return 1;
}

sub GetTestLauncher($)
{
  my ($Mission) = @_;

  my $Bits = ($Mission->{Build} =~ /64/) ? "64" : "32";
  return "$::RootDir/src/TestLauncher/TestLauncher$Bits.exe";
}

sub BuildTestLauncher()
{
  InfoMsg "\nRebuilding TestLauncher\n";
  my $CPUCount = GetCPUCount();
  system("cd '$::RootDir/src/TestLauncher' && set -x && ".
         "time make -j$CPUCount");
  if ($? != 0)
  {
    LogMsg "Build TestLauncher failed\n";
    return !1;
  }

  return 1;
}


#
# Wine addons updates
#

sub _VerifyAddOn($$)
{
  my ($AddOn, $Arch) = @_;

  my $Sha256 = Digest::SHA->new(256);
  eval { $Sha256->addfile("$DataDir/$AddOn->{name}/$AddOn->{filename}") };
  return "$@" if ($@);

  my $Checksum = $Sha256->hexdigest();
  return undef if ($Checksum eq $AddOn->{$Arch});
  return "Bad checksum for '$AddOn->{filename}'";
}

sub _UpdateAddOn($$$)
{
  my ($AddOn, $Name, $Arch) = @_;

  if (!defined $AddOn)
  {
    LogMsg "Could not get information on the $Name addon\n";
    return 0;
  }
  if (!$AddOn->{version})
  {
    LogMsg "Could not get the $Name version\n";
    return 0;
  }
  if (!$AddOn->{$Arch})
  {
    LogMsg "Could not get the $Name $Arch checksum\n";
    return 0;
  }

  $AddOn->{filename} = "wine". ($Name eq "gecko" ? "_" : "-") .
                       "$Name-$AddOn->{version}".
                       ($Arch eq "" ? "" : "-$Arch") .".msi";
  return 1 if (!_VerifyAddOn($AddOn, $Arch));

  InfoMsg "Downloading $AddOn->{filename}\n";
  mkdir "$DataDir/$Name";

  my $Url="http://dl.winehq.org/wine/wine-$Name/$AddOn->{version}/$AddOn->{filename}";
  for (1..3)
  {
    system("cd '$DataDir/$Name' && set -x && ".
           "wget --no-verbose -O- '$Url' >'$AddOn->{filename}'");
    last if ($? == 0);
  }
  my $ErrMessage = _VerifyAddOn($AddOn, $Arch);
  return 1 if (!defined $ErrMessage);
  LogMsg "$ErrMessage\n";
  return 0;
}

sub UpdateAddOns()
{
  my %AddOns;
  if (open(my $fh, "<", "$DataDir/wine/dlls/appwiz.cpl/addons.c"))
  {
    my $Arch = "";
    while (my $Line= <$fh>)
    {
      if ($Line =~ /^\s*#\s*define\s+ARCH_STRING\s+"([^"]+)"/)
      {
        $Arch = $1;
      }
      elsif ($Line =~ /^\s*#\s*define\s*(GECKO|MONO)_VERSION\s*"([^"]+)"/)
      {
        my ($AddOn, $Version) = ($1, $2);
        $AddOn =~ tr/A-Z/a-z/;
        $AddOns{$AddOn}->{name} = $AddOn;
        $AddOns{$AddOn}->{version} = $Version;
      }
      elsif ($Line =~ /^\s*#\s*define\s*(GECKO|MONO)_SHA\s*"([^"]+)"/)
      {
        my ($AddOn, $Checksum) = ($1, $2);
        $AddOn =~ tr/A-Z/a-z/;
        $AddOns{$AddOn}->{$Arch} = $Checksum;
        $Arch = "";
      }
    }
    close($fh);
  }
  else
  {
    LogMsg "Could not open 'wine/dlls/appwiz.cpl/addons.c': $!\n";
    return 0;
  }

  return _UpdateAddOn($AddOns{gecko}, "gecko", "x86") &&
         _UpdateAddOn($AddOns{gecko}, "gecko", "x86_64") &&
         _UpdateAddOn($AddOns{mono},  "mono",  "");
}


#
# Wine helpers
#

sub SetupWineEnvironment($)
{
  my ($Mission) = @_;

  my $BaseName = GetMissionBaseName($Mission);
  $ENV{WINEPREFIX} = "$DataDir/wineprefix-$BaseName";
  $ENV{DISPLAY} ||= ":0.0";

  my $Lang = $Mission->{lang} || "en_US";
  if ($Lang =~ /^[a-zA-Z0-9\@_.-]+$/)
  {
    $Lang =~ s/(@[a-z]*$|$)/.UTF-8$1/ if ($Lang !~ /\./);
    $ENV{LANG} = $Lang;
  }

  return $BaseName;
}

sub RunWine($$$)
{
  my ($Mission, $Cmd, $CmdArgs) = @_;

  my $WineDir = "$DataDir/wine-$Mission->{Build}";
  $Cmd = "$WineDir/$Cmd" if ($Cmd =~ /\.exe\.so$/);

  my $CurDir = "$ENV{WINEPREFIX}/dosdevices";
  if (!-d $CurDir)
  {
    $CurDir = ".";
  }
  else
  {
    my $Dir = $Mission->{dir} || "";
    # We cannot put colons in missions so restore the drive letter
    $Dir = "$CurDir/c:/$Dir" if ($Dir !~ s~^([a-z])/~$CurDir/$1:/~);
    $CurDir = -d $Dir ? $Dir : "$ENV{WINEPREFIX}/dosdevices/c:";
  }

  my $Magic = `file '$Cmd'`;
  my $Wine = ($Magic =~ /ELF 64/ ? "$WineDir/wine64" : "$WineDir/wine");
  return system("set -x && cd '$CurDir' && ".
                "time '$Wine' '$Cmd' $CmdArgs");
}


#
# WinePrefix helpers
#

sub CreateWinePrefix($;$)
{
  my ($Mission, $Wait) = @_;

  return "\$WINEPREFIX is not set!" if (!$ENV{WINEPREFIX});
  rmtree($ENV{WINEPREFIX});

  # Crash dialogs cause delays so disable them
  if (RunWine($Mission, "reg.exe", "ADD HKCU\\\\Software\\\\Wine\\\\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0"))
  {
    return "Failed to disable the crash dialogs: $!";
  }

  if ($Wait)
  {
    # Ensure the WinePrefix has been fully created and the registry files
    # saved before returning.
    my $WineDir = "$DataDir/wine-$Mission->{Build}";
    system("'$WineDir/server/wineserver' -w");
  }

  return undef;
}

1;
