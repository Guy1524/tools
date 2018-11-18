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

package WineTestBot::Missions;

=head1 NAME

WineTestBot::Missions - Missions parser and helper functions

=cut

use Exporter 'import';
our @EXPORT = qw(DumpMissions GetMissionBaseName GetTaskMissionDescription
                 ParseMissionStatement
                 MergeMissionStatementTasks SplitMissionStatementTasks);

use WineTestBot::Utils;


sub DumpMissions($$)
{
  my ($Label, $Missions) = @_;

  print STDERR "$Label:\n";
  foreach my $TaskMissions (@$Missions)
  {
    print STDERR "Builds=", join(",", sort keys %{$TaskMissions->{Builds}}), "\n";
    foreach my $Mission (@{$TaskMissions->{Missions}})
    {
      print STDERR "  [$Mission->{Build}]\n";
      print STDERR "    \"$_\"=\"$Mission->{$_}\"\n" for (sort grep(!/^Build$/,keys %$Mission));
    }
  }
}

sub ParseMissionStatement($)
{
  my ($MissionStatement) = @_;

  my @Missions;
  foreach my $TaskStatement (split /[|]/, $MissionStatement)
  {
    my $TaskMissions = { Statement => $TaskStatement };
    push @Missions, $TaskMissions;
    foreach my $Statement (split /:/, $TaskStatement)
    {
      my ($Build, @Options) = split /,/, $Statement;
      if ($Build !~ /^([a-z0-9]+)$/)
      {
        return ("Invalid mission name '$Build'", undef);
      }
      $Build = $1; # untaint
      $TaskMissions->{Builds}->{$Build} = 1;
      my $Mission = {
        Build => $Build,
        Statement => $Statement,
        test => "test", # Set the default value
      };
      push @{$TaskMissions->{Missions}}, $Mission;

      foreach my $Option (@Options)
      {
        if ($Option !~ s/^([a-z0-9_]+)//)
        {
          return ("Invalid option name '$Option'", undef);
        }
        my $Name = $1; # untaint
        # do not untaint the value
        $Mission->{$Name} = ($Option =~ s/^=//) ? $Option : 1;
      }
    }
  }
  return (undef, \@Missions);
}

sub GetMissionBaseName($)
{
  my ($Mission) = @_;

  my $BaseName = $Mission->{Build};

  # Option values may be tainted if they come from the command line
  my $Lang = $Mission->{lang} || "";
  $BaseName .= "_$1" if ($Lang =~ /^([a-zA-Z0-9\@_.-]+)$/); # untaint

  return $BaseName;
}

sub GetTaskMissionDescription($)
{
  my ($TaskMission) = @_;

  my $Builds = $TaskMission->{Builds};
  my $Description =
      $Builds->{build} ? "build" :
      ($Builds->{exe64} and ($Builds->{exe32} or $Builds->{exe32})) ? "32 & 64 bit executable" :
      $Builds->{exe32} ? "32 bit executable" :
      $Builds->{exe64} ? "64 bit executable" :
      ($Builds->{wow64} and ($Builds->{win32} or $Builds->{wow32})) ? "32 & 64 bit" :
      $Builds->{win32} ? "32 bit" :
      $Builds->{wow32} ? "32 bit WoW" :
      "64 bit WoW";

  my $Lang;
  foreach my $Mission (@{$TaskMission->{Missions}})
  {
    next if (!$Mission->{lang});
    if (defined $Lang)
    {
      $Description .= " + Locales";
      $Lang = undef;
      last;
    }
    $Lang = $Mission->{lang};
  }
  $Description .= " ". LocaleName($Lang) if ($Lang);
  return $Description;
}

sub MergeMissionStatementTasks($)
{
  my ($MissionStatement) = @_;
  $MissionStatement =~ s/\|/:/g;
  return $MissionStatement;
}

sub SplitMissionStatementTasks($)
{
  my ($MissionStatement) = @_;
  $MissionStatement =~ s/:/|/g;
  return $MissionStatement;
}

1;
