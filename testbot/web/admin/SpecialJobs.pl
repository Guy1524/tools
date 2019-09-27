# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot special jobs creation page
#
# Copyright 2019 Francois Gouget
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

package SpecialJobsPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::SpecialJobs;
use WineTestBot::Utils;
use WineTestBot::Log;


#
# Page state management
#

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->{JobTemplates} = {
    "Build" => {Label   => "Update build VMs",
                Options => ["No", "All Build VMs"],
                VMs     => GetReconfigVMs(undef, "build"),
    },
    "Win32" => {Label   => "Run the 32 bit WineTest suite on Windows VMs",
                Options => ["No", "All Base VMs", "All WineTest VMs",
                            "All Base and WineTest VMs"],
                VMs     => GetWindowsTestVMs(undef, "exe32", undef),
    },
    "Win64" => {Label   => "Run the 64 bit WineTest suite on Windows VMs",
                Options => ["No", "All Base VMs", "All WineTest VMs",
                            "All Base and WineTest VMs"],
                VMs     => GetWindowsTestVMs(undef, "exe64", undef),
    },
    "Wine"  => {Label   => "Update Wine VMs",
                Options => ["No", "All Wine VMs"],
                VMs     => GetReconfigVMs(undef, "wine"),
    },
    "WineTest" => {Label   => "Run the WineTest suite on Wine VMs",
                   Options => ["No", "All Wine VMs"],
                   VMs     => GetWineTestVMs(undef),
    },
  };

  foreach my $JobName (keys %{$self->{JobTemplates}})
  {
    my $JobTemplate = $self->{JobTemplates}->{$JobName};
    my $VMKey = $self->GetParam($JobName);
    foreach my $Option (@{$JobTemplate->{Options}})
    {
      if ($VMKey eq "*$Option")
      {
        $JobTemplate->{VMKey} = $VMKey;
        last;
      }
    }
    if (!exists $JobTemplate->{VMKey})
    {
      foreach my $VM (@{$JobTemplate->{VMs}})
      {
        if ($VMKey eq $VM->Name)
        {
          $JobTemplate->{VMKey} = $VM->Name;
          last;
        }
      }
    }
    $JobTemplate->{VMKey} ||= "*No";
  }

  $self->SUPER::_initialize($Request, $RequiredRole, undef);
}


#
# Page generation
#

sub GetTitle($)
{
  #my ($self) = @_;
  return "Create Special Jobs";
}

sub GenerateJobFields($$$$$)
{
  my ($self, $JobName) = @_;

  my $JobTemplate = $self->{JobTemplates}->{$JobName};
  return if (!@{$JobTemplate->{VMs}});

  print "<div class='ItemProperty'><label>$JobTemplate->{Label}</label>\n",
        "<div class='ItemValue'>\n",
        "<select name='$JobName' size='1'>\n";
  foreach my $Option (@{$JobTemplate->{Options}})
  {
    my $Selected = $JobTemplate->{VMKey} eq "*$Option" ? " selected" : "";
    print "<option value='*", $self->CGI->escapeHTML($Option),
        "'$Selected>$Option</option>\n";
  }
  foreach my $VM (@{$JobTemplate->{VMs}})
  {
    my $Selected = $JobTemplate->{VMKey} eq $VM->Name ? " selected" : "";
    print "<option value='", $self->CGI->escapeHTML($VM->Name),
        "'$Selected>", $self->CGI->escapeHTML($VM->Name), "</option>\n";
  }
  print "</select>&nbsp;</div></div>\n";
}

sub GenerateFields($)
{
  my ($self) = @_;

  $self->GenerateJobFields("Build");
  $self->GenerateJobFields("Win32");
  $self->GenerateJobFields("Win64");

  $self->GenerateJobFields("Wine");
  $self->GenerateJobFields("WineTest");

  $self->SUPER::GenerateFields();
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  push @$Actions, "Submit";
  return $Actions;
}


#
# Page actions
#

sub OnSubmit($)
{
  my ($self) = @_;
  my $VMKey;
  my @Errors = ();

  # Update Build VMs
  $VMKey = $self->{JobTemplates}->{Build}->{VMKey};
  if ($VMKey ne "*No")
  {
    $VMKey = undef if ($VMKey eq "*All Wine VMs");
    my $VMs = GetReconfigVMs($VMKey, "build");
    push @Errors, "Found no build VM to update" if (!@$VMs);
    my $ErrMessage = AddReconfigJob($VMs, $VMKey, "build");
  }

  # Run 32 bit WineTest
  $VMKey = $self->{JobTemplates}->{Win32}->{VMKey};
  if ($VMKey ne "*No")
  {
    my @BaseJobs = $VMKey eq "*All Base VMs" ? ("base") :
                   $VMKey eq "*All WineTest VMs" ? ("other") :
                   $VMKey eq "*All Base and WineTest VMs" ? ("base", "other") :
                   (undef);
    $VMKey = undef if ($VMKey =~ /^\*/);
    foreach my $BaseJob (@BaseJobs)
    {
      my $VMs = GetWindowsTestVMs($VMKey, "exe32", $BaseJob);
      push @Errors, "Found no $BaseJob VM to run WineTest on" if (!@$VMs);
      my $ErrMessage = AddWindowsTestJob($VMs, $VMKey, "exe32", $BaseJob, "winetest-latest.exe");
      push @Errors, $ErrMessage if (defined $ErrMessage);
    }
  }

  # Run 64 bit WineTest
  $VMKey = $self->{JobTemplates}->{Win64}->{VMKey};
  if ($VMKey ne "*No")
  {
    # Traditionally we don't create separate 'base' and 'other' jobs for
    # 64 bit VMs.
    my $BaseJob = $VMKey eq "*All Base VMs" ? "base" :
                  $VMKey eq "*All WineTest VMs" ? "other" :
                  $VMKey eq "*All Base and WineTest VMs" ? "all" :
                  undef;
    $VMKey = undef if ($VMKey eq "*All Base and WineTest VMs");
    my $VMs = GetWindowsTestVMs($VMKey, "exe64", $BaseJob);
    push @Errors, "Found no 64 bit VM to run WineTest on" if (!@$VMs);
    my $ErrMessage = AddWindowsTestJob($VMs, $VMKey, "exe64", $BaseJob, "winetest64-latest.exe");
    push @Errors, $ErrMessage if (defined $ErrMessage);
  }

  # Update Wine VMs
  $VMKey = $self->{JobTemplates}->{Wine}->{VMKey};
  if ($VMKey ne "*No")
  {
    $VMKey = undef if ($VMKey eq "*All Wine VMs");
    my $VMs = GetReconfigVMs($VMKey, "wine");
    push @Errors, "Found no Wine VM to update" if (!@$VMs);
    my $ErrMessage = AddReconfigJob($VMs, $VMKey, "wine");
    push @Errors, $ErrMessage if (defined $ErrMessage);
  }

  # Run WineTest on Wine
  $VMKey = $self->{JobTemplates}->{WineTest}->{VMKey};
  if ($VMKey ne "*No")
  {
    $VMKey = undef if ($VMKey eq "*All Wine VMs");
    my $VMs = GetWineTestVMs($VMKey);
    push @Errors, "Found no Wine VM to run WineTest on" if (!@$VMs);
    my $ErrMessage = AddWineTestJob($VMs, $VMKey);
    push @Errors, $ErrMessage if (defined $ErrMessage);
  }

  # Notify engine
  my $ErrMessage = RescheduleJobs();
  push @Errors, $ErrMessage if (defined $ErrMessage);

  if (@Errors)
  {
    $self->{ErrMessage} = join("\n", @Errors);
    return undef;
  }

  $self->Redirect("/"); # does not return
  exit;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Submit")
  {
    return $self->OnSubmit();
  }

  return $self->SUPER::OnAction($Action);
}


package main;

my $Request = shift;

my $SubmitPage = SpecialJobsPage->new($Request, "admin");
$SubmitPage->GeneratePage();
