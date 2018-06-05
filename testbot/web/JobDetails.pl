# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Job details page
#
# Copyright 2009 Ge van Geldorp
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

package JobDetailsPage;

use ObjectModel::CGI::CollectionPage;
our @ISA = qw(ObjectModel::CGI::CollectionPage);

use URI::Escape;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::StepsTasks;
use WineTestBot::Engine::Notify;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  my $JobId = $self->GetParam("Key");
  if (! defined($JobId))
  {
    $JobId = $self->GetParam("JobId");
  }
  $self->{Job} = CreateJobs()->GetItem($JobId);
  if (!defined $self->{Job})
  {
    $self->Redirect("/index.pl"); # does not return
  }
  $self->{JobId} = $JobId;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateStepsTasks(undef, $self->{Job}));
}

sub GetPageTitle($)
{
  my ($self) = @_;

  my $PageTitle = $self->{Job}->Remarks;
  $PageTitle =~ s/^[[]wine-patches[]] //;
  $PageTitle = "Job " . $self->{JobId} if ($PageTitle eq "");
  $PageTitle .= " - ${ProjectName} Test Bot";
  return $PageTitle;
}

sub GetTitle($)
{
  my ($self) = @_;

  return "Job " . $self->{JobId} . " - " . $self->{Job}->Remarks;
}

sub DisplayProperty($$$)
{
  my ($self, $CollectionBlock, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();

  return $PropertyName eq "StepNo" || $PropertyName eq "TaskNo" ||
         $PropertyName eq "Status" || $PropertyName eq "VM" ||
         $PropertyName eq "Timeout" || $PropertyName eq "FileName" ||
         $PropertyName eq "CmdLineArg" || $PropertyName eq "Started" ||
         $PropertyName eq "Ended" || $PropertyName eq "TestFailures";
}

sub GetItemActions($$)
{
  #my ($self, $CollectionBlock) = @_;
  return [];
}

sub CanCancel($)
{
  my ($self) = @_;

  my $Status = $self->{Job}->Status;
  if ($Status ne "queued" && $Status ne "running")
  {
    return "Job already $Status"; 
  }

  my $Session = $self->GetCurrentSession();
  if (! defined($Session))
  {
    return "You are not authorized to cancel this job";
  }
  my $CurrentUser = $Session->User;
  if (! $CurrentUser->HasRole("admin") &&
      $self->{Job}->User->GetKey() ne $CurrentUser->GetKey())
  {
    return "You are not authorized to cancel this job";
  }

  return undef;
}

sub CanRestart($)
{
  my ($self) = @_;

  my $Status = $self->{Job}->Status;
  if ($Status ne "boterror" && $Status ne "canceled")
  {
    return "Not a failed / canceled Job";
  }

  my $Session = $self->GetCurrentSession();
  if (! defined($Session))
  {
    return "You are not authorized to restart this job";
  }
  my $CurrentUser = $Session->User;
  if (! $CurrentUser->HasRole("admin") &&
      $self->{Job}->User->GetKey() ne $CurrentUser->GetKey()) # FIXME: Admin only?
  {
    return "You are not authorized to restart this job";
  }

  return undef;
}

sub GetActions($$)
{
  my ($self, $CollectionBlock) = @_;

  # These are mutually exclusive
  return ["Cancel job"] if (!defined $self->CanCancel());
  return ["Restart job"] if (!defined $self->CanRestart());
  return [];
}

sub OnCancel($)
{
  my ($self) = @_;

  my $ErrMessage = $self->CanCancel();
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $ErrMessage = JobCancel($self->{JobId});
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $self->Redirect("/JobDetails.pl?Key=" . $self->{JobId}); # does not return
  exit;
}

sub OnRestart($)
{
  my ($self) = @_;

  my $ErrMessage = $self->CanRestart();
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $ErrMessage = JobRestart($self->{JobId});
  if (defined($ErrMessage))
  {
    $self->{ErrMessage} = $ErrMessage;
    return !1;
  }

  $self->Redirect("/JobDetails.pl?Key=" . $self->{JobId}); # does not return
  exit;
}

sub OnAction($$$)
{
  my ($self, $CollectionBlock, $Action) = @_;

  if ($Action eq "Cancel job")
  {
    return $self->OnCancel();
  }
  elsif ($Action eq "Restart job")
  {
    return $self->OnRestart();
  }

  return $self->SUPER::OnAction($CollectionBlock, $Action);
}

sub SortKeys($$$)
{
  my ($self, $CollectionBlock, $Keys) = @_;

  my @SortedKeys = sort { $a <=> $b } @$Keys;
  return \@SortedKeys;
}

sub GeneratePage($)
{
  my ($self) = @_;

  if ($self->{Job}->Status =~ /^(queued|running)$/)
  {
    $self->{Request}->headers_out->add("Refresh", "30");
  }

  $self->SUPER::GeneratePage();
}

sub GenerateBody($)
{
  my ($self) = @_;

  $self->SUPER::GenerateBody();

  print "<div class='Content'>\n";
  my $Keys = $self->SortKeys(undef, $self->{Collection}->GetKeys());
  foreach my $Key (@$Keys)
  {
    my $StepTask = $self->{Collection}->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();
    my $VM = $StepTask->VM;
    print "<h2><a name='k", $self->escapeHTML($Key), "'></a>" ,
          $self->escapeHTML($StepTask->GetTitle()), "</h2>\n";

    print "<details><summary>",
          $self->CGI->escapeHTML($VM->Description || $VM->Name), "</summary>",
          $self->CGI->escapeHTML($VM->Details || "No details!"),
          "</details>\n";

    my $FullLogParamName = "log_$Key";
    my $FullLog = $self->GetParam($FullLogParamName);
    $FullLog = "" if ($FullLog !~ /^[12]$/);

    my $ScreenshotParamName = "scrshot_$Key";
    my $Screenshot = $self->GetParam($ScreenshotParamName);
    $Screenshot = "" if ($Screenshot ne "1");


    print "<div class='TaskMoreInfoLinks'>\n";
    # FIXME: Disable live screenshots for now
    if (0 && $StepTask->Status eq "running" &&
        ($StepTask->Type eq "single" || $StepTask->Type eq "suite"))
    {
      if ($Screenshot)
      {
        my $URI = "/Screenshot.pl?VMName=" . uri_escape($VM->Name);
        print "<div class='Screenshot'><img src='" .
              $self->CGI->escapeHTML($URI) . "' alt='Screenshot' /></div>\n";
      }
      else
      {
        my $URI = $ENV{"SCRIPT_NAME"} . "?Key=" . uri_escape($self->{JobId}) .
                  "&$ScreenshotParamName=1";
        $URI .= "#k" . uri_escape($Key);
        print "<div class='TaskMoreInfoLink'><a href='" .
              $self->CGI->escapeHTML($URI) .
              "'>Show live screenshot</a></div>";
        print "\n";
      }
    }
    elsif (-r "$TaskDir/screenshot.png")
    {
      if ($Screenshot)
      {
        my $URI = "/Screenshot.pl?JobKey=" . uri_escape($self->{JobId}) .
                  "&StepKey=" . uri_escape($StepTask->StepNo) .
                  "&TaskKey=" . uri_escape($StepTask->TaskNo);
        print "<div class='Screenshot'><img src='" .
              $self->CGI->escapeHTML($URI) . "' alt='Screenshot' /></div>\n";
      }
      else
      {
        my $URI = $ENV{"SCRIPT_NAME"} . "?Key=" . uri_escape($self->{JobId}) .
                  "&$ScreenshotParamName=1";
        $URI .= "&$FullLogParamName=$FullLog";
        $URI .= "#k" . uri_escape($Key);
        print "<div class='TaskMoreInfoLink'><a href='" .
              $self->CGI->escapeHTML($URI) .
              "'>Show final screenshot</a></div>";
        print "\n";
      }
    }

    my $LogName = "$TaskDir/log";
    my $ErrName = "$TaskDir/err";
    if (-r $LogName and $FullLog != "1")
    {
      my $URI = $ENV{"SCRIPT_NAME"} . "?Key=" . uri_escape($self->{JobId}) .
                "&$FullLogParamName=1";
      $URI .= "&$ScreenshotParamName=$Screenshot";
      $URI .= "#k" . uri_escape($Key);
      print "<div class='TaskMoreInfoLink'><a href='" .
            $self->CGI->escapeHTML($URI) .
            "'>Show full log</a></div>\n";
    }
    if ((-r $LogName or -r $ErrName) and $FullLog == "2")
    {
      my $URI = $ENV{"SCRIPT_NAME"} . "?Key=" . uri_escape($self->{JobId});
      $URI .= "&$ScreenshotParamName=$Screenshot";
      $URI .= "#k" . uri_escape($Key);
      print "<div class='TaskMoreInfoLink'><a href='" .
            $self->CGI->escapeHTML($URI) .
            "'>Show latest log</a></div>\n";
    }
    if ((-r "$LogName.old" or -r "$ErrName.old") and $FullLog != "2")
    {
      my $URI = $ENV{"SCRIPT_NAME"} . "?Key=" . uri_escape($self->{JobId}) .
                "&$FullLogParamName=2";
      $URI .= "&$ScreenshotParamName=$Screenshot";
      $URI .= "#k" . uri_escape($Key);
      print "<div class='TaskMoreInfoLink'><a href='" .
            $self->CGI->escapeHTML($URI) .
            "'>Show old logs</a></div>\n";
    }
    print "</div>\n";

    if ($FullLog eq "2")
    {
      $LogName .= ".old";
      $ErrName .= ".old";
    }

    if (open LOGFILE, "<$LogName")
    {
      my $HasLogEntries = !1;
      my $First = 1;
      my $CurrentDll = "";
      my $PrintedDll = "";
      my $Line;
      while (defined($Line = <LOGFILE>))
      {
        $HasLogEntries = 1;
        chomp($Line);
        if ($Line =~ m/^([^:]+):[^ ]+ start [^ ]+ -\s*$/)
        {
          $CurrentDll = $1;
        }
        if ($FullLog ||
            $Line =~ m/: Test (?:failed|succeeded inside todo block): / ||
            $Line =~ m/Fatal: test '[^']+' does not exist/ ||
            $Line =~ m/ done \(258\)/ ||
            $Line =~ m/: unhandled exception [0-9a-fA-F]{8} at /)
        {
          if ($PrintedDll ne $CurrentDll && ! $FullLog)
          {
            if ($First)
            {
              $First = !1;
            }
            else
            {
              print "</code></pre>";
            }
            print "<div class='LogDllName'>$CurrentDll:</div><pre><code>";
            $PrintedDll = $CurrentDll;
          }
          elsif ($First)
          {
            print "<pre><code>";
            $First = !1;
          }
          if (! $FullLog && $Line =~ m/^[^:]+:([^:]*)(?::[0-9a-f]+)? done \(258\)/)
          {
            my $Unit = $1 ne "" ? "$1: " : "";
            print "${Unit}Timeout\n";
          }
          else
          {
            print $self->escapeHTML($Line), "\n";
          }
        }
      }
      close LOGFILE;

      if (open ERRFILE, "<$ErrName")
      {
        $CurrentDll = "*err*";
        while (defined($Line = <ERRFILE>))
        {
          $HasLogEntries = 1;
          chomp($Line);
          if ($PrintedDll ne $CurrentDll)
          {
            if ($First)
            {
              $First = !1;
            }
            else
            {
              print "</code></pre>\n";
            }
            print "<br><pre><code>";
            $PrintedDll = $CurrentDll;
          }
          print $self->escapeHTML($Line), "\n";
        }
        close ERRFILE;
      }

      if (! $First)
      {
        print "</code></pre>\n";
      }
      else
      {
        print $HasLogEntries ? "No " .
                               ($StepTask->Type eq "single" ||
                                $StepTask->Type eq "suite" ? "test" : "build") .
                               " failures found" : "Empty log";
      }
    }
    elsif (open ERRFILE, "<$ErrName")
    {
      my $HasErrEntries = !1;
      my $Line;
      while (defined($Line = <ERRFILE>))
      {
        chomp($Line);
        if (! $HasErrEntries)
        {
          print "<pre><code>";
          $HasErrEntries = 1;
        }
        print $self->escapeHTML($Line), "\n";
      }
      if ($HasErrEntries)
      {
        print "</code></pre>\n";
      }
      else
      {
        print "Empty log";
      }
      close ERRFILE;
    }
    elsif ($StepTask->Status eq "canceled")
    {
      print "<p>No log, task was canceled</p>\n";
    }
    elsif ($StepTask->Status eq "skipped")
    {
      print "<p>No log, task skipped</p>\n";
    }
    else
    {
      print "<p>No log available yet</p>\n";
    }
  }
  print "</div>\n";
}

sub GenerateDataCell($$$$$)
{
  my ($self, $CollectionBlock, $StepTask, $PropertyDescriptor, $DetailsPage) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  if ($PropertyName eq "VM")
  {
    print "<td><a href='#k", $self->escapeHTML($StepTask->GetKey()), "'>";
    print $self->escapeHTML($self->GetDisplayValue($CollectionBlock, $StepTask,
                                                   $PropertyDescriptor));
    print "</a></td>\n";
  }
  elsif ($PropertyName eq "FileName")
  {
    my $FileName = $StepTask->GetFullFileName();
    if ($FileName and -r $FileName)
    {
      my $URI = "/GetFile.pl?JobKey=" . uri_escape($self->{JobId}) .
                  "&StepKey=" . uri_escape($StepTask->StepNo);
      print "<td><a href='" . $self->escapeHTML($URI) . "'>";
      print $self->escapeHTML($self->GetDisplayValue($CollectionBlock, $StepTask,
                                                     $PropertyDescriptor));
      print "</a></td>\n";
    }
    else
    {
      $self->SUPER::GenerateDataCell($CollectionBlock, $StepTask, $PropertyDescriptor, $DetailsPage);
    }
  }
  else
  {
    $self->SUPER::GenerateDataCell($CollectionBlock, $StepTask, $PropertyDescriptor, $DetailsPage);
  }
}


package main;

my $Request = shift;

my $JobDetailsPage = JobDetailsPage->new($Request, "");
$JobDetailsPage->GeneratePage();
