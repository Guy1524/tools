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

package WineTestBot::LogUtils;

=head1 NAME

WineTestBot::LogUtils - Provides functions to parse task logs

=cut


use Exporter 'import';
our @EXPORT = qw(GetLogFileNames GetLogLabel GetLogErrors GetNewLogErrors
                 GetLogLineCategory GetReportLineCategory
                 RenameReferenceLogs RenameTaskLogs
                 ParseTaskLog ParseWineTestReport);

use Algorithm::Diff;
use File::Basename;

use WineTestBot::Config; # For $MaxUnitSize
use WineTestBot::Utils; # For LocaleName()


#
# Task log parser
#

=pod
=over 12

=item C<_IsPerlError()>

Returns true if the string looks like a Perl error message.

=back
=cut

sub _IsPerlError($)
{
  my ($Str) = @_;

  return $Str =~ /^Use of uninitialized value / ||
         $Str =~ /^Undefined subroutine / ||
         $Str =~ /^Global symbol / ||
         $Str =~ /^Possible precedence issue /;
}


=pod
=over 12

=item C<ParseTaskLog()>

Returns a hashtable containing a summary of the task log:
=over

=item Type
'tests' if the task ran Wine tests and 'build' otherwise.

=item Task
Either 'ok' if the task was successful or a code indicating why it failed.

=item NoLog
Contains an error message if the task log could not be read.

=back
=cut

sub ParseTaskLog($)
{
  my ($FileName) = @_;

  if (open(my $LogFile, "<", $FileName))
  {
    my $Summary = {Type => "build"};
    foreach my $Line (<$LogFile>)
    {
      chomp $Line;
      if ($Line eq "Task: tests")
      {
        $Summary->{Type} = "tests";
      }
      elsif ($Line eq "Task: ok")
      {
        $Summary->{Task} ||= "ok";
      }
      elsif ($Line eq "Task: Patch failed to apply")
      {
        $Summary->{Task} = "badpatch";
        last; # Should be the last and most specific message
      }
      elsif ($Line =~ /^Task: Updated ([a-zA-Z0-9.]+)$/)
      {
        $Summary->{$1} = "updated";
      }
      elsif ($Line =~ /^Task: / or _IsPerlError($Line))
      {
        $Summary->{Task} = "failed";
      }
    }
    close($LogFile);
    $Summary->{Task} ||= "missing";
    return $Summary;
  }
  return {NoLog => "Unable to open the task log for reading: $!"};
}


=pod
=over 12

=item C<GetLogLineCategory()>

Identifies the category of the given log line: an error message, a Wine
diagnostic line, a TestBot error, etc.

The category can then be used to decide whether to hide the line or, on
the contrary, highlight it.

=back
=cut

sub GetLogLineCategory($)
{
  my ($Line) = @_;

  if (# Build messages
      $Line =~ /^\+ \S/ or
      $Line =~ /^LANG=/ or
      $Line =~ /^Running (?:the tests|WineTest) / or
      $Line =~ /^Task: (?:ok|tests|Updated)/)
  {
    return "info";
  }
  if (# Git errors
      $Line =~ /^CONFLICT / or
      $Line =~ /^error: patch failed:/ or
      $Line =~ /^error: corrupt patch / or
      # Build errors
      $Line =~ /: error: / or
      $Line =~ /^make: [*]{3} No rule to make target / or
      $Line =~ /^Makefile:[0-9]+: recipe for target .* failed$/ or
      $Line =~ /^Task: / or
      # Typical perl errors
      _IsPerlError($Line))
  {
    return "error";
  }
  if ($Line =~ /:winediag:/)
  {
    return "diag";
  }
  if (# TestBot script error messages
      $Line =~ /^[a-zA-Z.]+:error: / or
      # TestBot error
      $Line =~ /^BotError:/ or
      # X errors
      $Line =~ /^X Error of failed request: / or
      $Line =~ / opcode of failed request: /)
  {
    return "boterror";
  }

  return "none";
}


#
# WineTest report parser
#

sub _NewCurrentUnit($$)
{
  my ($Dll, $Unit) = @_;

  return {
    # There is more than one test unit when running the full test suite so keep
    # track of the current one. Note that for the TestBot we don't count or
    # complain about misplaced skips.
    Dll => $Dll,
    Unit => $Unit,
    Units => {$Unit => 1},
    UnitsRE => $Unit,
    UnitSize => 0,
    LineFailures => 0,
    LineTodos => 0,
    LineSkips => 0,
    SummaryFailures => 0,
    SummaryTodos => 0,
    SummarySkips => 0,
    IsBroken => 0,
    Rc => undef,
    Pids => {},
  };
}

sub _AddError($$;$)
{
  my ($Parser, $Error, $Cur) = @_;

  $Error = "$Cur->{Dll}:$Cur->{Unit} $Error" if (defined $Cur);
  push @{$Parser->{Errors}}, $Error;
  $Parser->{Failures}++;
}

sub _CheckUnit($$$$)
{
  my ($Parser, $Cur, $Unit, $Type) = @_;

  if ($Cur->{Units}->{$Unit} or $Cur->{Unit} eq "")
  {
    $Parser->{IsWineTest} = 1;
  }
  # To avoid issuing many duplicate errors,
  # only report the first misplaced message.
  elsif ($Parser->{IsWineTest} and !$Cur->{IsBroken})
  {
    _AddError($Parser, "contains a misplaced $Type message for $Unit", $Cur);
    $Cur->{IsBroken} = 1;
  }
}

sub _CheckSummaryCounter($$$$)
{
  my ($Parser, $Cur, $Field, $Type) = @_;

  if ($Cur->{"Line$Field"} != 0 and $Cur->{"Summary$Field"} == 0)
  {
    _AddError($Parser, "has unaccounted for $Type messages", $Cur);
  }
  elsif ($Cur->{"Line$Field"} == 0 and $Cur->{"Summary$Field"} != 0)
  {
    _AddError($Parser, "is missing some $Type messages", $Cur);
  }
}

sub _CloseTestUnit($$$)
{
  my ($Parser, $Cur, $Last) = @_;

  # Verify the summary lines
  if (!$Cur->{IsBroken})
  {
    _CheckSummaryCounter($Parser, $Cur, "Failures", "failure");
    _CheckSummaryCounter($Parser, $Cur, "Todos", "todo");
    _CheckSummaryCounter($Parser, $Cur, "Skips", "skip");
  }

  # Note that the summary lines may count some failures twice
  # so only use them as a fallback.
  $Cur->{LineFailures} ||= $Cur->{SummaryFailures};

  if ($Cur->{UnitSize} > $MaxUnitSize)
  {
    _AddError($Parser, "prints too much data ($Cur->{UnitSize} bytes)", $Cur);
  }
  if (!$Cur->{IsBroken} and defined $Cur->{Rc})
  {
    # Check the exit code, particularly against failures reported
    # after the 'done' line (e.g. by subprocesses).
    if ($Cur->{LineFailures} != 0 and $Cur->{Rc} == 0)
    {
      _AddError($Parser, "returned success despite having failures", $Cur);
    }
    elsif (!$Parser->{IsWineTest} and $Cur->{Rc} != 0)
    {
      _AddError($Parser, "The test returned a non-zero exit code");
    }
    elsif ($Parser->{IsWineTest} and $Cur->{LineFailures} == 0 and $Cur->{Rc} != 0)
    {
      _AddError($Parser, "returned a non-zero exit code despite reporting no failures", $Cur);
    }
  }
  # For executables TestLauncher's done line may not be recognizable.
  elsif ($Parser->{IsWineTest} and !defined $Cur->{Rc})
  {
    if (!$Last)
    {
      _AddError($Parser, "has no done line (or it is garbled)", $Cur);
    }
    elsif ($Last and !$Parser->{TaskTimedOut})
    {
      _AddError($Parser, "The report seems to have been truncated");
    }
  }

  $Parser->{Failures} += $Cur->{LineFailures};
}

=pod
=over 12

=item C<ParseWineTestReport()>

Parses a Wine test report and returns the number of failures and extra errors,
a list of extra errors, and whether the test timed out.

=back
=cut

sub ParseWineTestReport($$$)
{
  my ($FileName, $IsWineTest, $TaskTimedOut) = @_;

  my $LogFile;
  if (!open($LogFile, "<", $FileName))
  {
    my $BaseName = basename($FileName);
    return (undef, undef, undef, ["Unable to open '$BaseName' for reading: $!"]);
  }

  my $Parser = {
    IsWineTest => $IsWineTest,
    TaskTimedOut => $TaskTimedOut,

    TestUnitCount => 0,
    TimeoutCount => 0,
    Failures => undef,
    Errors => [],
  };

  my $Cur = _NewCurrentUnit("", "");
  foreach my $Line (<$LogFile>)
  {
    $Cur->{UnitSize} += length($Line);
    if ($Line =~ m%^([_.a-z0-9-]+):([_a-z0-9]*) (start|skipped) (?:-|[/_.a-z0-9]+) (?:-|[.0-9a-f]+)\r?$%)
    {
      my ($Dll, $Unit, $Type) = ($1, $2, $3);

      # Close the previous test unit
      _CloseTestUnit($Parser, $Cur, 0) if ($Cur->{Dll} ne "");
      $Cur = _NewCurrentUnit($Dll, $Unit);
      $Parser->{TestUnitCount}++;

      # Recognize skipped messages in case we need to skip tests in the VMs
      $Cur->{Rc} = 0 if ($Type eq "skipped");
    }
    elsif ($Line =~ /^([_.a-z0-9-]+)\.c:\d+: Subtest ([_.a-z0-9-]+)\r?$/)
    {
      my ($Unit, $SubUnit) = ($1, $2);
      if ($Cur->{Units}->{$Unit})
      {
        $Cur->{Units}->{$SubUnit} = 1;
        $Cur->{UnitsRE} = join("|", keys %{$Cur->{Units}});
      }
      else
      {
        _AddError($Parser, "Misplaced $SubUnit subtest\n");
      }
    }
    elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Test (?:failed|succeeded inside todo block): / or
           ($Cur->{Unit} ne "" and
            $Line =~ /($Cur->{UnitsRE})\.c:\d+: Test (?:failed|succeeded inside todo block): /))
    {
      _CheckUnit($Parser, $Cur, $1, "failure");
      $Cur->{LineFailures}++;
    }
    elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Test marked todo: / or
           ($Cur->{Unit} ne "" and
            $Line =~ /($Cur->{UnitsRE})\.c:\d+: Test marked todo: /))
    {
      _CheckUnit($Parser, $Cur, $1, "todo");
      $Cur->{LineTodos}++;
    }
    elsif ($Line =~ /^([_a-z0-9]+)\.c:\d+: Tests skipped: / or
           ($Cur->{Unit} ne "" and
            $Line =~ /($Cur->{UnitsRE})\.c:\d+: Tests skipped: /))
    {
      my $Unit = $1;
      # Don't complain and don't count misplaced skips. Only complain if they
      # are misreported (see _CloseTestUnit).
      if ($Cur->{Units}->{$Unit} or $Cur->{Unit} eq "")
      {
        $Cur->{LineSkips}++;
      }
    }
    elsif ($Line =~ /^Fatal: test '([_a-z0-9]+)' does not exist/)
    {
      # This also replaces a test summary line.
      $Cur->{Pids}->{0} = 1;
      $Cur->{SummaryFailures}++;
      $Parser->{IsWineTest} = 1;

      $Cur->{LineFailures}++;
    }
    elsif ($Line =~ /^(?:([0-9a-f]+):)?([_.a-z0-9]+): unhandled exception [0-9a-fA-F]{8} at / or
           ($Cur->{Unit} ne "" and
            $Line =~ /(?:([0-9a-f]+):)?($Cur->{UnitsRE}): unhandled exception [0-9a-fA-F]{8} at /))
    {
      my ($Pid, $Unit) = ($1, $2);

      if ($Cur->{Units}->{$Unit})
      {
        # This also replaces a test summary line.
        $Cur->{Pids}->{$Pid || 0} = 1;
        $Cur->{SummaryFailures}++;
      }
      _CheckUnit($Parser, $Cur, $Unit, "unhandled exception");
      $Cur->{LineFailures}++;
    }
    elsif ($Line =~ /^(?:([0-9a-f]+):)?([_a-z0-9]+): \d+ tests? executed \((\d+) marked as todo, (\d+) failures?\), (\d+) skipped\./ or
           ($Cur->{Unit} ne "" and
            $Line =~ /(?:([0-9a-f]+):)?($Cur->{Unit}): \d+ tests? executed \((\d+) marked as todo, (\d+) failures?\), (\d+) skipped\./))
    {
      my ($Pid, $Unit, $Todos, $Failures, $Skips) = ($1, $2, $3, $4, $5);

      # Dlls that have only one test unit will run it even if there is
      # no argument.
      if ($Unit eq $Cur->{Unit} or $Cur->{Unit} eq "")
      {
        # There may be more than one summary line due to child processes
        $Cur->{Pids}->{$Pid || 0} = 1;
        $Cur->{SummaryFailures} += $Failures;
        $Cur->{SummaryTodos} += $Todos;
        $Cur->{SummarySkips} += $Skips;
        $Parser->{IsWineTest} = 1;
      }
      else
      {
        _CheckUnit($Parser, $Cur, $Unit, "test summary") if ($Todos or $Failures);
      }
    }
    elsif ($Line =~ /^([_.a-z0-9-]+):([_a-z0-9]*)(?::([0-9a-f]+))? done \((-?\d+)\)(?:\r?$| in)/ or
           ($Cur->{Dll} ne "" and
            $Line =~ /(\Q$Cur->{Dll}\E):([_a-z0-9]*)(?::([0-9a-f]+))? done \((-?\d+)\)(?:\r?$| in)/))
    {
      my ($Dll, $Unit, $Pid, $Rc) = ($1, $2, $3, $4);

      if ($Parser->{IsWineTest} and ($Dll ne $Cur->{Dll} or $Unit ne $Cur->{Unit}))
      {
        # First close the current test unit taking into account
        # it may have been polluted by the new one.
        $Cur->{IsBroken} = 1;
        _CloseTestUnit($Parser, $Cur, 0);

        # Then switch to the new one, warning it's missing a start line,
        # and that its results may be inconsistent.
        ($Cur->{Dll}, $Cur->{Unit}) = ($Dll, $Unit);
        _AddError($Parser, "had no start line (or it is garbled)", $Cur);
        $Cur->{IsBroken} = 1;
      }

      if ($Rc == 258)
      {
        # The done line will already be shown as a timeout (see JobDetails)
        # so record the failure but don't add an error message.
        $Parser->{Failures}++;
        $Cur->{IsBroken} = 1;
        $Parser->{TimeoutCount}++;
      }
      elsif ((!$Pid and !%{$Cur->{Pids}}) or
             ($Pid and !$Cur->{Pids}->{$Pid} and !$Cur->{Pids}->{0}))
      {
        # The main summary line is missing
        if ($Rc & 0xc0000000)
        {
          _AddError($Parser, sprintf("%s:%s crashed (%08x)", $Dll, $Unit, $Rc & 0xffffffff));
          $Cur->{IsBroken} = 1;
        }
        elsif ($Parser->{IsWineTest} and !$Cur->{IsBroken})
        {
          _AddError($Parser, "$Dll:$Unit has no test summary line (early exit of the main process?)");
        }
      }
      elsif ($Rc & 0xc0000000)
      {
        # We know the crash happened in the main process which means we got
        # an "unhandled exception" message. So there is no need to add an
        # extra message or to increment the failure count. Still note that
        # there may be inconsistencies (e.g. unreported todos or skips).
        $Cur->{IsBroken} = 1;
      }
      $Cur->{Rc} = $Rc;
    }
  }
  $Cur->{IsBroken} = 1 if ($Parser->{TaskTimedOut});
  _CloseTestUnit($Parser, $Cur, 1);
  close($LogFile);

  return ($Parser->{TestUnitCount}, $Parser->{TimeoutCount},
          $Parser->{Failures}, $Parser->{Errors});
}


=pod
=over 12

=item C<GetReportLineCategory()>

Identifies the category of the given test report line: an error message,
a todo, just an informational message or none of these.

The category can then be used to decide whether to hide the line or, on
the contrary, highlight it.

=back
=cut

sub GetReportLineCategory($)
{
  my ($Line) = @_;

  if ($Line =~ /: Test marked todo: /)
  {
    return "todo";
  }
  if ($Line =~ /: Tests skipped: / or
      $Line =~ /^[_.a-z0-9-]+:[_a-z0-9]* skipped /)
  {
    return "skip";
  }
  if ($Line =~ /: Test (?:failed|succeeded inside todo block): / or
      $Line =~ /Fatal: test .* does not exist/ or
      $Line =~ / done \(258\)/ or
      $Line =~ /: unhandled exception [0-9a-fA-F]{8} at / or
      $Line =~ /^Unhandled exception: /)
  {
    return "error";
  }
  if ($Line =~ /^[_.a-z0-9-]+:[_a-z0-9]* start /)
  {
    return "info";
  }

  return "none";
}


#
# Log querying and formatting
#

sub RenameReferenceLogs()
{
  if (opendir(my $dh, "$DataDir/latest"))
  {
    # We will be renaming files so read the directory in one go
    my @Entries = readdir($dh);
    close($dh);
    foreach my $Entry (@Entries)
    {
      if ($Entry =~ /^([a-z0-9._]+)$/)
      {
        my $NewName = $Entry = $1;
        $NewName =~ s/\.log$/.report/;
        $NewName =~ s/(_[a-z0-9]+)\.err$/$1.report.err/;
        $NewName =~ s/_(32|64)\.report/_exe$1.report/;
        if ($Entry ne $NewName and !-f "$DataDir/latest/$NewName")
        {
          rename "$DataDir/latest/$Entry", "$DataDir/latest/$NewName";
        }
      }
    }
  }
}

sub RenameTaskLogs($)
{
  my ($Dir) = @_;

  if (-f "$Dir/err" and !-f "$Dir/log.err")
  {
    rename "$Dir/err", "$Dir/log.err";
  }

  if (-f "$Dir/log.old" and !-f "$Dir/old_log")
  {
    rename "$Dir/log.old", "$Dir/old_log";
  }
  if (-f "$Dir/err.old" and !-f "$Dir/old_log.err")
  {
    rename "$Dir/err.old", "$Dir/old_log.err";
  }
}

=pod
=over 12

=item C<GetLogFileNames()>

Scans the directory for test reports and task logs and returns their filenames.
The filenames are returned in the order in which the logs are meant to be
presented.

=back
=cut

sub GetLogFileNames($;$)
{
  my ($Dir, $IncludeOld) = @_;

  my @Globs = qw(exe32.report exe32_*.report
                 exe64.report exe64_*.report
                 win32.report win32_*.report
                 wow32.report wow32_*.report
                 wow64.report wow64_*.report
                 log);
  push @Globs, "old_log" if ($IncludeOld);

  my (@Logs, %Seen);
  foreach my $Glob (@Globs)
  {
    foreach my $FileName (glob("'$Dir/$Glob*'"))
    {
      my $LogName = basename($FileName);
      if ($LogName !~ s/\.err$// and $LogName !~ /\.report$/ and
          $LogName ne $Glob) # 'log' case
      {
        # Not a valid log filename (where does this file come from?)
        next;
      }
      next if ($Seen{$LogName});
      $Seen{$LogName} = 1;

      if ((-f "$Dir/$LogName" and !-z "$Dir/$LogName") or
          (-f "$Dir/$LogName.err" and !-z "$Dir/$LogName.err"))
      {
        push @Logs, $LogName;
      }
    }
  }
  return \@Logs;
}

my %_LogFileLabels = (
  "exe32.report" => '32 bit%s report',
  "exe64.report" => '64 bit%s report',
  "win32.report" => '32 bit%s report',
  "wow32.report" => '32 bit%s WoW report',
  "wow64.report" => '64 bit%s WoW report',
  "log"          => 'task%s log',
  "old_log"      => 'old%s logs',
);

=pod
=over 12

=item C<GetLogLabel()>

Returns a user-friendly description of the content of the specified log file.

=back
=cut

sub GetLogLabel($)
{
  my ($LogFileName) = @_;

  my $Extra = "";
  if ($LogFileName =~ /^([^_]+)_(.*)\.report$/)
  {
    $LogFileName = "$1.report";
    $Extra = " ". LocaleName($2);
  }
  my $Label = $_LogFileLabels{$LogFileName};
  return defined $Label ? sprintf($Label, $Extra) : $LogFileName;
}


sub _DumpErrors($$$)
{
  my ($Label, $Groups, $Errors) = @_;

  print STDERR "$Label:\n";
  print STDERR "  Groups=", scalar(@$Groups), " [", join(",", @$Groups), "]\n";
  my @ErrorKeys = sort keys %$Errors;
  print STDERR "  Errors=", scalar(@ErrorKeys), " [", join(",", @ErrorKeys), "]\n";
  foreach my $GroupName (@$Groups)
  {
    print STDERR "  [$GroupName]\n";
    print STDERR "    [$_]\n" for (@{$Errors->{$GroupName}});
  }
}

sub _AddErrorGroup($$$)
{
  my ($Groups, $Errors, $GroupName) = @_;

  # In theory the error group names are all unique. But, just in case, make
  # sure we don't overwrite $Errors->{$GroupName}.
  if (!$Errors->{$GroupName})
  {
    push @$Groups, $GroupName;
    $Errors->{$GroupName} = [];
  }
  return $Errors->{$GroupName};
}

=pod
=over 12

=item C<GetLogErrors()>

Analyzes the specified log and associated error file to filter out unimportant
messages and only return the errors, split by module (for Wine reports that's
per dll / program being tested).

Returns a list of modules containing errors, and a hashtable containing the list of errors for each module.

=back
=cut

sub GetLogErrors($)
{
  my ($LogFileName) = @_;

  my ($IsReport, $GetCategory);
  if ($LogFileName =~ /\.report$/)
  {
    $IsReport = 1;
    $GetCategory = \&GetReportLineCategory;
  }
  else
  {
    $GetCategory = \&GetLogLineCategory;
  }

  my $NoLog = 1;
  my $Groups = [];
  my $Errors = {};
  if (open(my $LogFile, "<", $LogFileName))
  {
    $NoLog = 0;
    my $CurrentModule = "";
    my $CurrentGroup;
    foreach my $Line (<$LogFile>)
    {
      $Line =~ s/\s*$//;
      if ($IsReport and $Line =~ /^([_.a-z0-9-]+):[_a-z0-9]* start /)
      {
        $CurrentModule = $1;
        $CurrentGroup = undef;
        next;
      }

      next if ($GetCategory->($Line) !~ /error/);

      if ($Line =~ m/^[^:]+:([^:]*)(?::[0-9a-f]+)? done \(258\)/)
      {
        my $Unit = $1;
        $Line = $Unit ne "" ? "$Unit: Timeout" : "Timeout";
      }
      if (!$CurrentGroup)
      {
        $CurrentGroup = _AddErrorGroup($Groups, $Errors, $CurrentModule);
      }
      push @$CurrentGroup, $Line;
    }
    close($LogFile);
  }
  elsif (-f $LogFileName)
  {
    $NoLog = 0;
    my $Group = _AddErrorGroup($Groups, $Errors, "TestBot errors");
    push @$Group, "Could not open '". basename($LogFileName) ."' for reading: $!";
  }

  if (open(my $LogFile, "<", "$LogFileName.err"))
  {
    $NoLog = 0;
    # Add the related extra errors
    my $CurrentGroup;
    foreach my $Line (<$LogFile>)
    {
      $Line =~ s/\s*$//;
      if (!$CurrentGroup)
      {
        # Note: $GroupName must not depend on the previous content as this
        #       would break diffs.
        my $GroupName = $IsReport ? "Report errors" : "Task errors";
        $CurrentGroup = _AddErrorGroup($Groups, $Errors, $GroupName);
      }
      push @$CurrentGroup, $Line;
    }
    close($LogFile);
  }
  elsif (-f "$LogFileName.err")
  {
    $NoLog = 0;
    my $Group = _AddErrorGroup($Groups, $Errors, "TestBot errors");
    push @$Group, "Could not open '". basename($LogFileName) .".err' for reading: $!";
  }

  return $NoLog ? (undef, undef) : ($Groups, $Errors);
}

sub _DumpDiff($$)
{
  my ($Label, $Diff) = @_;

  print STDERR "$Label:\n";
  $Diff = $Diff->Copy();
  while ($Diff->Next())
  {
    if ($Diff->Same())
    {
      print STDERR " $_\n" for ($Diff->Same());
    }
    else
    {
      print STDERR "-$_\n" for ($Diff->Items(1));
      print STDERR "+$_\n" for ($Diff->Items(2));
    }
  }
}

=pod
=over 12

=item C<_GetLineKey()>

This is a helper for GetNewLogErrors(). It reformats the log lines so they can
meaningfully be compared to the reference log even if line numbers change, etc.

=back
=cut

sub _GetLineKey($)
{
  my ($Line) = @_;
  return undef if (!defined $Line);

  # Remove the line number
  $Line =~ s/^([_a-z0-9]+\.c:)\d+:( Test (?:failed|succeeded inside todo block): )/$1$2/;

  # Remove the crash code address: it changes whenever the test is recompiled
  $Line =~ s/^(Unhandled exception: .* code) \(0x[0-9a-fA-F]{8,16}\)\.$/$1/;

  # The exact amount of data printed does not change the error
  $Line =~ s/^([_.a-z0-9-]+:[_a-z0-9]* prints too much data )\([0-9]+ bytes\)$/$1/;

  # Note: Only the 'done (258)' lines are reported as errors and they are
  #       modified by GetLogErrors() so that they no longer contain the pid.
  #       So there is no need to remove the pid from the done lines.

  return $Line;
}

=pod
=over 12

=item C<GetNewLogErrors()>

Compares the specified errors to the reference log and returns only the ones
that are new.

Returns a list of error groups containing new errors, a hashtable containing
the list of new errors for each group, and a hashtable containing the indices
of the new errors in the input errors list for each group.

=back
=cut

sub GetNewLogErrors($$$)
{
  my ($RefFileName, $Groups, $Errors) = @_;

  my ($RefGroups, $RefErrors) = GetLogErrors($RefFileName);
  return (undef, undef) if (!$RefGroups);

  my (@NewGroups, %NewErrors, %NewIndices);
  foreach my $GroupName (@$Groups)
  {
    if ($RefErrors->{$GroupName})
    {
      my $Diff = Algorithm::Diff->new($RefErrors->{$GroupName},
                                      $Errors->{$GroupName},
                                      { keyGen => \&_GetLineKey });
      my ($CurrentGroup, $CurrentIndices);
      while ($Diff->Next())
      {
        # Skip if there are no new lines
        next if ($Diff->Same() or !$Diff->Items(2));

        if (!$CurrentGroup)
        {
          push @NewGroups, $GroupName;
          $CurrentGroup = $NewErrors{$GroupName} = [];
          $CurrentIndices = $NewIndices{$GroupName} = {};
        }
        push @$CurrentGroup, $Diff->Items(2);
        $CurrentIndices->{$_} = 1 for ($Diff->Range(2));
      }
    }
    else
    {
      # This group did not have errors before, so every error is new
      push @NewGroups, $GroupName;
      $NewErrors{$GroupName} = $Errors->{$GroupName};
      $NewIndices{$GroupName} = {};
      my $Last = @{$Errors->{$GroupName}} - 1;
      $NewIndices{$GroupName}->{$_} = 1 for (0..$Last);
    }
  }

  return (\@NewGroups, \%NewErrors, \%NewIndices);
}

1;
