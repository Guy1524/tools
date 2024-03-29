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

package WineTestBot::PatchUtils;

=head1 NAME

WineTestBot::PatchUtils - Parse and analyze patches.

=head1 DESCRIPTION

Provides functions to parse patches and figure out which impact they have on
the Wine builds.

=cut

use Exporter 'import';
our @EXPORT = qw(GetPatchImpacts LastPartSeparator UpdateWineData
                 GetBuildTimeout GetTestTimeout);

use List::Util qw(min max);

use WineTestBot::Config;
use WineTestBot::Utils;


#
# Source repository maintenance
#

=pod
=over 12

=item C<UpdateWineData()>

Updates information about the Wine source, such as the list of Wine files,
for use by the TestBot server.

=back
=cut

sub UpdateWineData($)
{
  my ($WineDir) = @_;

  mkdir "$DataDir/latest" if (!-d "$DataDir/latest");

  my $ErrMessage = `cd '$WineDir' && git ls-tree -r --name-only HEAD 2>&1 >'$DataDir/latest/winefiles.txt' && egrep '^PARENTSRC *=' dlls/*/Makefile.in programs/*/Makefile.in >'$DataDir/latest/wine-parentsrc.txt'`;
  return $? != 0 ? $ErrMessage : undef;
}

my $_TimeStamp;
my $_WineFiles;
my $_TestList;
my $_WineParentDirs;

=pod
=over 12

=item C<_LoadWineFiles()>

Reads latest/winefiles.txt to build a per-module hashtable of the test unit
files and a hashtable of all the Wine files.

=back
=cut

sub _LoadWineFiles()
{
  my $FileName = "$DataDir/latest/winefiles.txt";
  my $MTime = GetMTime($FileName);

  if ($_TestList and $_TimeStamp == $MTime)
  {
    # The file has not changed since we loaded it
    return;
  }

  $_TimeStamp = $MTime;
  $_TestList = {};
  $_WineFiles = {};
  if (open(my $fh, "<", $FileName))
  {
    while (my $Line = <$fh>)
    {
      chomp $Line;
      $_WineFiles->{$Line} = 1;

      if ($Line =~ m~^(dlls|programs)/([^/]+)/tests/([^/]+)$~)
      {
        my ($Root, $Module, $File) = ($1, $2, $3);
        next if ($File eq "testlist.c");
        next if ($File !~ /\.(?:c|spec)$/);
        $Module .= ".exe" if ($Root eq "programs");
        $_TestList->{$Module}->{$File} = 1;
      }
    }
    close($fh);
  }

  $_WineParentDirs = {};
  $FileName = "$DataDir/latest/wine-parentsrc.txt";
  if (open(my $fh, "<", $FileName))
  {
    while (my $Line = <$fh>)
    {
      if ($Line =~ m~^\w+/([^/]+)/Makefile\.in:PARENTSRC *= *\.\./([^/\s]+)~)
      {
        my ($Child, $Parent) = ($1, $2);
        $_WineParentDirs->{$Parent}->{$Child} = 1;
      }
    }
    close($fh);
  }
}


#
# Wine patch analysis
#

# These paths are too generic to be proof that this is a Wine patch.
my $AmbiguousPathsRe = join('|',
  'Makefile\.in$',
  # aclocal.m4 gets special treatment
  # configure gets special treatment
  # configure.ac gets special treatment
  'include/Makefile\.in$',
  'include/config\.h\.in$',
  'po/',
  'tools/Makefile.in',
  'tools/config.guess',
  'tools/config.sub',
  'tools/install-sh',
  'tools/makedep.c',
);

# Patches to these paths don't impact the Wine build. So ignore them.
my $IgnoredPathsRe = join('|',
  '\.mailmap$',
  'ANNOUNCE$',
  'AUTHORS$',
  'COPYING\.LIB$',
  'LICENSE\$',
  'LICENSE\.OLD$',
  'MAINTAINERS$',
  'README$',
  'VERSION$',
  'documentation/',
  'tools/c2man\.pl$',
  'tools/winapi/',
  'tools/winemaker/',
);

sub LastPartSeparator()
{
  return "===== TestBot: Last patchset part =====\n";
}

sub _CreateTestInfo($$$)
{
  my ($Impacts, $Root, $Dir) = @_;

  my $Module = ($Root eq "programs") ? "$Dir.exe" : $Dir;
  $Impacts->{BuildModules}->{$Module} = 1;
  $Impacts->{IsWinePatch} = 1;

  my $Tests = $Impacts->{Tests};
  if (!$Tests->{$Module})
  {
    $Tests->{$Module} = {
      "Module"  => $Module,
      "Path"    => "$Root/$Dir/tests",
      "ExeBase" => "${Module}_test",
    };
    foreach my $File (keys %{$_TestList->{$Module}})
    {
      $Tests->{$Module}->{Files}->{$File} = 0; # not modified
    }
  }

  return $Module;
}

sub _HandleFile($$$)
{
  my ($Impacts, $FilePath, $Change) = @_;

  if ($Change eq "new")
  {
    delete $Impacts->{DeletedFiles}->{$FilePath};
    $Impacts->{NewFiles}->{$FilePath} = 1;
  }
  elsif ($Change eq "rm")
  {
    delete $Impacts->{NewFiles}->{$FilePath};
    $Impacts->{DeletedFiles}->{$FilePath} = 1;
  }

  if ($FilePath =~ m~^(dlls|programs)/([^/]+)/tests/([^/\s]+)$~)
  {
    my ($Root, $Dir, $File) = ($1, $2, $3);

    my $Module = _CreateTestInfo($Impacts, $Root, $Dir);
    $Impacts->{PatchedTests} = 1;
    $Impacts->{Tests}->{$Module}->{Files}->{$File} = $Change;

    if ($File eq "Makefile.in" and $Change ne "modify")
    {
      # This adds / removes a directory
      $Impacts->{MakeMakefiles} = 1;
    }
  }
  elsif ($FilePath =~ m~^(dlls|programs)/([^/]+)/([^/\s]+)$~)
  {
    my ($Root, $PatchedDir, $File) = ($1, $2, $3);

    foreach my $Dir ($PatchedDir, keys %{$_WineParentDirs->{$PatchedDir} || {}})
    {
      my $Module = _CreateTestInfo($Impacts, $Root, $Dir);
      $Impacts->{Tests}->{$Module}->{PatchedModule} = 1;
    }
    $Impacts->{PatchedModules} = 1;

    if ($File eq "Makefile.in" and $Change ne "modify")
    {
      # This adds / removes a directory
      $Impacts->{MakeMakefiles} = 1;
    }
  }
  else
  {
    my $WineFiles = $Impacts->{WineFiles} || $_WineFiles;
    if ($WineFiles->{$FilePath})
    {
      if ($FilePath !~ /^(?:$AmbiguousPathsRe)/)
      {
        $Impacts->{IsWinePatch} = 1;
      }
      # Else this file exists in Wine but has a very common name so it may just
      # as well belong to another repository.

      if ($FilePath !~ /^(?:$IgnoredPathsRe)/)
      {
        $Impacts->{PatchedRoot} = 1;
        if ($FilePath =~ m~/Makefile.in$~ and $Change ne "modify")
        {
          # This adds / removes a directory
          $Impacts->{MakeMakefiles} = 1;
        }
      }
      # Else patches to this file don't impact the Wine build.
    }
    elsif ($FilePath =~ m~/Makefile.in$~ and $Change eq "new")
    {
      # This may or may not be a Wine patch but the new Makefile.in will be
      # added to the build by make_makefiles.
      $Impacts->{PatchedRoot} = $Impacts->{MakeMakefiles} = 1;
    }
  }
}

=pod
=over 12

=item C<GetPatchImpacts()>

Analyzes a patch and returns a hashtable describing the impact it has on the
Wine build: whether it requires updating the makefiles, re-running autoconf or
configure, whether it impacts the tests, etc.

=back
=cut

sub GetPatchImpacts($)
{
  my ($PatchFileName) = @_;

  my $fh;
  return undef if (!open($fh, "<", $PatchFileName));

  my $Impacts = {
    # Number of test units impacted either directly, or indirectly by a module
    # patch.
    ModuleUnitCount => 0,
    # Number of patched test units.
    TestUnitCount => 0,
    # The modules that need a rebuild, even if only for the tests.
    BuildModules => {},
    # Information about 'tests' directories.
    Tests => {},
  };
  _LoadWineFiles();

  my $PastImpacts;
  my ($Path, $Change);
  while (my $Line = <$fh>)
  {
    if ($Line =~ m=^--- \w+/(?:aclocal\.m4|configure\.ac)$=)
    {
      $Impacts->{PatchedRoot} = $Impacts->{Autoconf} = 1;
    }
    elsif ($Line =~ m=^--- \w+/tools/make_makefiles$=)
    {
      $Impacts->{PatchedRoot} = $Impacts->{MakeMakefiles} = 1;
      $Impacts->{IsWinePatch} = 1;
    }
    elsif ($Line =~ m=^--- \w+/server/protocol\.def$=)
    {
      $Impacts->{PatchedRoot} = $Impacts->{MakeRequests} = 1;
      $Impacts->{IsWinePatch} = 1;
    }
    elsif ($Line =~ m=^--- \w+/dlls/winevulkan/make_vulkan$=)
    {
      $Impacts->{PatchedRoot} = $Impacts->{MakeVulkan} = 1;
      $Impacts->{IsWinePatch} = 1;
    }
    elsif ($Line =~ m=^--- /dev/null$=)
    {
      $Change = "new";
    }
    elsif ($Line =~ m~^--- \w+/([^\s]+)$~)
    {
      $Path = $1;
    }
    elsif ($Line =~ m~^\+\+\+ /dev/null$~)
    {
      _HandleFile($Impacts, $Path, "rm") if (defined $Path);
      $Path = undef;
      $Change = "";
    }
    elsif ($Line =~ m~^\+\+\+ \w+/([^\s]+)$~)
    {
      _HandleFile($Impacts, $1, $Change || "modify");
      $Path = undef;
      $Change = "";
    }
    elsif ($Line eq LastPartSeparator())
    {
      # All the diffs so far belongs to previous parts of this patchset.
      # But:
      # - Only the last part must be taken into account to determine if a
      #   rebuild and testing is needed.
      # - Yet if a rebuild is needed the previous parts' patches will impact
      #   the scope of the rebuild so that information must be preserved.
      # So save current impacts in $PastImpacts and reset the current state.
      $PastImpacts = {};

      # Build a copy of the Wine files list reflecting the current situation.
      $Impacts->{WineFiles} = { %$_WineFiles } if (!$Impacts->{WineFiles});
      map { $Impacts->{WineFiles}->{$_} = 1 } keys %{$Impacts->{NewFiles}};
      map { delete $Impacts->{WineFiles}->{$_} } keys %{$Impacts->{DeletedFiles}};
      $Impacts->{NewFiles} = {};
      $Impacts->{DeletedFiles} = {};

      # The modules impacted by previous parts will still need to be built,
      # but only if the last part justifies a build. So make a backup.
      $PastImpacts->{BuildModules} = $Impacts->{BuildModules};
      $Impacts->{BuildModules} = {};

      # Also backup the build-related fields.
      foreach my $Field ("Autoconf", "MakeMakefiles", "MakeRequests",
                         "MakeVulkan", "PatchedRoot", "PatchedModules",
                         "PatchedTests")
      {
        $PastImpacts->{$Field} = $Impacts->{$Field};
        $Impacts->{$Field} = undef;
      }

      # Reset the status of all test unit files to not modified.
      foreach my $TestInfo (values %{$Impacts->{Tests}})
      {
        foreach my $File (keys %{$TestInfo->{Files}})
        {
          if ($TestInfo->{Files}->{$File} ne "rm")
          {
            $TestInfo->{Files}->{$File} = 0;
          }
        }
      }
      $Impacts->{ModuleUnitCount} = $Impacts->{TestUnitCount} = 0;
    }
    else
    {
      $Path = undef;
      $Change = "";
    }
  }
  close($fh);

  foreach my $TestInfo (values %{$Impacts->{Tests}})
  {
    # For each module, identify modifications to non-C files and helper dlls
    foreach my $File (keys %{$TestInfo->{Files}})
    {
      # Skip unmodified files
      next if (!$TestInfo->{Files}->{$File});
      # Assume makefile modifications may break the build but not the tests
      next if ($File eq "Makefile.in");

      my $Base = $File;
      if ($Base !~ s/(?:\.c|\.spec)$//)
      {
        # Any change to a non-C non-Spec file can potentially impact all tests
        $TestInfo->{All} = 1;
        last;
      }
      if (exists $TestInfo->{Files}->{"$Base.spec"} and
          ($TestInfo->{Files}->{"$Base.c"} or
           $TestInfo->{Files}->{"$Base.spec"}))
      {
        # Any change to a helper dll can potentially impact all tests
        $TestInfo->{All} = 1;
        last;
      }
    }

    $TestInfo->{PatchedUnits} = {};
    foreach my $File (keys %{$TestInfo->{Files}})
    {
      my $Base = $File;
      # Non-C files are not test units
      next if ($Base !~ s/(?:\.c|\.spec)$//);
      # Helper dlls are not test units
      next if (exists $TestInfo->{Files}->{"$Base.spec"});
      # Don't try running a deleted test unit obviously
      next if ($TestInfo->{Files}->{$File} eq "rm");
      $TestInfo->{AllUnits}->{$Base} = 1;

      if ($TestInfo->{All} or $TestInfo->{Files}->{$File})
      {
        $TestInfo->{PatchedUnits}->{$Base} = 1;
        $Impacts->{ModuleUnitCount}++;
      }
      elsif ($TestInfo->{PatchedModule})
      {
        # The module has been patched so this test unit is impacted indirectly.
        $Impacts->{ModuleUnitCount}++;
      }
    }

    $TestInfo->{UnitCount} = scalar(keys %{$TestInfo->{PatchedUnits}});
    $Impacts->{TestUnitCount} += $TestInfo->{UnitCount};
  }

  if ($Impacts->{PatchedRoot} or $Impacts->{PatchedModules} or
      $Impacts->{PatchedTests})
  {
    # Any patched area will need to be rebuilt...
    $Impacts->{RebuildRoot} = $Impacts->{PatchedRoot};
    $Impacts->{RebuildModules} = $Impacts->{PatchedModules};

    # ... even if the patch was in previous parts
    if ($PastImpacts)
    {
      $Impacts->{Autoconf} ||= $PastImpacts->{Autoconf};
      $Impacts->{MakeMakefiles} ||= $PastImpacts->{MakeMakefiles};
      $Impacts->{MakeRequests} ||= $PastImpacts->{MakeRequests};
      $Impacts->{MakeVulkan} ||= $PastImpacts->{MakeVulkan};
      $Impacts->{RebuildRoot} ||= $PastImpacts->{PatchedRoot};
      $Impacts->{RebuildModules} ||= $PastImpacts->{PatchedModules};
      map { $Impacts->{BuildModules}->{$_} = 1 } keys %{$PastImpacts->{BuildModules}};
    }
  }

  return $Impacts;
}


#
# Compute task timeouts based on the patch data
#

sub GetBuildTimeout($$)
{
  my ($Impacts, $TaskMissions) = @_;

  my ($ExeCount, $WineCount);
  map {$_ =~ /^exe/ ? $ExeCount++ : $WineCount++ } keys %{$TaskMissions->{Builds}};

  # Set $ModuleCount to 0 if a full rebuild is needed
  my $ModuleCount = (!$Impacts or $Impacts->{RebuildRoot}) ? 0 :
                    scalar(keys %{$Impacts->{BuildModules}});

  my ($ExeTimeout, $WineTimeout) = (0, 0);
  if ($ExeCount)
  {
    my $OneBuild = $ModuleCount ? $ModuleCount * $ExeModuleTimeout :
                                  $ExeBuildTestTimeout;
    $ExeTimeout = ($ModuleCount ? 0 : $ExeBuildNativeTimeout) +
                  $ExeCount * min($ExeBuildTestTimeout, $OneBuild);
  }
  if ($WineCount)
  {
    my $OneBuild = $ModuleCount ? $ModuleCount * $WineModuleTimeout :
                                  $WineBuildTimeout;
    $WineTimeout = $WineCount * min($WineBuildTimeout, $OneBuild);
  }

  return $ExeTimeout + $WineTimeout;
}

sub GetTestTimeout($$)
{
  my ($Impacts, $TaskMissions) = @_;

  my $Timeout = 0;
  foreach my $Mission (@{$TaskMissions->{Missions}})
  {
    if (!$Impacts or ($Mission->{test} eq "all" and
                      ($Impacts->{PatchedRoot} or $Impacts->{PatchedModules})))
    {
      $Timeout += $SuiteTimeout;
    }
    elsif ($Mission->{test} ne "build")
    {
      # Note: If only test units have been patched then
      #       ModuleUnitCount == TestUnitCount.
      my $UnitCount = $Mission->{test} eq "test" ? $Impacts->{TestUnitCount} :
                                                   $Impacts->{ModuleUnitCount};
      my $TestsTimeout = min(2, $UnitCount) * $SingleTimeout +
                         max(0, $UnitCount - 2) * $SingleAvgTime;
      $Timeout += min($SuiteTimeout, $TestsTimeout);
    }
  }
  return $Timeout;
}

1;
