# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Job details page
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014,2017-2018 Francois Gouget
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

use File::Basename;
use URI::Escape;

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::LogUtils;
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

sub InitMoreInfo($)
{
  my ($self) = @_;

  my $More = $self->{More} = {};
  my $Keys = $self->SortKeys(undef, $self->{Collection}->GetKeys());
  foreach my $Key (@$Keys)
  {
    my $StepTask = $self->{Collection}->GetItem($Key);
    $More->{$Key}->{Screenshot} = $self->GetParam("s$Key");

    my $Value = $self->GetParam("f$Key");
    my $TaskDir = $StepTask->GetTaskDir();
    foreach my $Log (@{GetLogFileNames($TaskDir, 1)})
    {
      push @{$More->{$Key}->{Logs}}, $Log;
      $More->{$Key}->{Full} = $Log if ($Log eq $Value);
    }
    $More->{$Key}->{Full} ||= "";
  }
}

sub GetMoreInfoLink($$$$;$)
{
  my ($self, $LinkKey, $Label, $Set, $Value) = @_;

  my $Url = $ENV{"SCRIPT_NAME"} ."?Key=". uri_escape($self->{JobId});

  my $Action = "Show". ($Set eq "Full" and $Label !~ /old/ ? " full" : "");
  foreach my $Key (sort keys %{$self->{More}})
  {
    my $MoreInfo = $self->{More}->{$Key};
    if ($Key eq $LinkKey and $Set eq "Screenshot")
    {
      if (!$MoreInfo->{Screenshot})
      {
        $Url .= "&s$Key=1";
      }
      else
      {
        $Action = "Hide";
      }
    }
    else
    {
      $Url .= "&s$Key=1" if ($MoreInfo->{Screenshot});
    }

    if ($Key eq $LinkKey and $Set eq "Full")
    {
      if ($MoreInfo->{Full} ne $Value)
      {
        $Url .= "&f$Key=". uri_escape($Value);
      }
      else
      {
        $Action = "Hide";
      }
    }
    else
    {
      $Url .= "&f$Key=". uri_escape($MoreInfo->{Full}) if ($MoreInfo->{Full});
    }
  }
  $Url .= "#k" . uri_escape($LinkKey);
  return ($Action, $Url);
}

sub GenerateMoreInfoLink($$$$;$)
{
  my ($self, $LinkKey, $Label, $Set, $Value) = @_;

  my ($Action, $Url) = $self->GetMoreInfoLink($LinkKey, $Label, $Set, $Value);
  my $Title = ($Value =~ /^(.*)\.report$/) ? " title='$1'" : "";

  my $Html = "<a href='". $self->CGI->escapeHTML($Url) ."'$Title>$Action $Label</a>";
  if ($Action eq "Hide")
  {
    $Html = "<span class='TaskMoreInfoSelected'>$Html</span>";
  }
  print "<div class='TaskMoreInfoLink'>$Html</div>\n";
}

sub GetErrorCategory($)
{
  return "error";
}

sub GenerateFullLog($$$;$)
{
  my ($self, $FileName, $HideLog, $Header) = @_;

  my $GetCategory = $FileName =~ /\.err$/ ? \&GetErrorCategory :
                    $FileName =~ /\.report$/ ? \&GetReportLineCategory :
                    \&GetLogLineCategory;

  my $IsEmpty = 1;
  if (open(my $LogFile, "<", $FileName))
  {
    foreach my $Line (<$LogFile>)
    {
      $Line =~ s/\s*$//;
      if ($IsEmpty)
      {
        print $Header if (defined $Header);
        print "<pre$HideLog><code>";
        $IsEmpty = 0;
      }

      my $Category = $GetCategory->($Line);
      my $Html = $self->escapeHTML($Line);
      if ($Category ne "none")
      {
        $Html =~ s~^(.*\S)\s*\r?$~<span class='log-$Category'>$1</span>~;
      }
      print "$Html\n";
    }
    close($LogFile);
  }
  print "</code></pre>\n" if (!$IsEmpty);

  return $IsEmpty;
}

sub GenerateBody($)
{
  my ($self) = @_;

  $self->SUPER::GenerateBody();

  $self->InitMoreInfo();

  print <<EOF;
<script type='text/javascript'>
<!--
function HideLog(event, url)
{
  // Ignore double-clicks on the log text (i.e. on the <code> element) to
  // allow word-selection
  if (event.target.nodeName == 'PRE' && !event.altKey && !event.ctrlKey &&
      !event.metaKey && !event.shiftKey)
  {
    window.open(url, "_self", "", true);
  }
}
//-->
</script>
EOF

  print "<div class='Content'>\n";
  my $Keys = $self->SortKeys(undef, $self->{Collection}->GetKeys());
  my $KeyIndex = 0;
  foreach my $Key (@$Keys)
  {
    my $StepTask = $self->{Collection}->GetItem($Key);
    my $TaskDir = $StepTask->GetTaskDir();
    my $VM = $StepTask->VM;

    my $Prev = $KeyIndex > 0 ? "k". $Keys->[$KeyIndex-1] : "PageTitle";
    my $Next = $KeyIndex + 1 < @$Keys ? "k". $Keys->[$KeyIndex+1] : "PageEnd";
    $KeyIndex++;
    print "<h2><a name='k", $self->escapeHTML($Key), "'></a>",
          $self->escapeHTML($StepTask->GetTitle()),
          " <span class='right'><a class='title' href='#$Prev'>&uarr;</a><a class='title' href='#$Next'>&darr;</a></span></h2>\n";

    print "<details><summary>",
          $self->CGI->escapeHTML($VM->Description || $VM->Name), "</summary>",
          $self->CGI->escapeHTML($VM->Details || "No details!"),
          ($StepTask->Missions ? "<br>Missions: ". $StepTask->Missions : ""),
          "</details>\n";

    my $MoreInfo = $self->{More}->{$Key};
    print "<div class='TaskMoreInfoLinks'>\n";
    if (-r "$TaskDir/screenshot.png")
    {
      if ($MoreInfo->{Screenshot})
      {
        my $URI = "/Screenshot.pl?JobKey=" . uri_escape($self->{JobId}) .
                  "&StepKey=" . uri_escape($StepTask->StepNo) .
                  "&TaskKey=" . uri_escape($StepTask->TaskNo);
        print "<div class='Screenshot'><img src='" .
              $self->CGI->escapeHTML($URI) . "' alt='Screenshot' /></div>\n";
      }
      $self->GenerateMoreInfoLink($Key, "final screenshot", "Screenshot");
    }

    my $ReportCount;
    foreach my $LogName (@{$MoreInfo->{Logs}})
    {
      $self->GenerateMoreInfoLink($Key, GetLogLabel($LogName), "Full", $LogName);
      $ReportCount++ if ($LogName !~ /^old_/ and $LogName =~ /\.report$/);
    }
    print "</div>\n";

    if ($MoreInfo->{Full})
    {
      #
      # Show this log in full, highlighting the important lines
      #

      my ($Action, $Url) = $self->GetMoreInfoLink($Key, GetLogLabel($MoreInfo->{Full}), "Full", $MoreInfo->{Full});
      $Url = $self->CGI->escapeHTML($Url);
      my $HideLog = $Action eq "Hide" ? " ondblclick='HideLog(event, \"$Url\")'" : "";

      my $LogIsEmpty = $self->GenerateFullLog("$TaskDir/$MoreInfo->{Full}", $HideLog);
      my $EmptyDiag;
      if ($LogIsEmpty)
      {
        if ($StepTask->Status eq "canceled")
        {
          $EmptyDiag = "No log, task was canceled\n";
        }
        elsif ($StepTask->Status eq "skipped")
        {
          $EmptyDiag = "No log, task skipped\n";
        }
        else
        {
          print "Empty log\n";
          $LogIsEmpty = 0;
        }
      }

      # And append the associated extra errors
      my $ErrHeader = $MoreInfo->{Full} =~ /\.report/ ? "report" : "task";
      $ErrHeader = "old $ErrHeader" if ($MoreInfo->{Full} =~ /^old_/);
      $ErrHeader = "<div class='HrTitle'>". ucfirst($ErrHeader) ." errors<div class='HrLine'></div></div>";
      my $ErrIsEmpty = $self->GenerateFullLog("$TaskDir/$MoreInfo->{Full}.err", $HideLog, $ErrHeader);
      print $EmptyDiag if ($ErrIsEmpty and defined $EmptyDiag);
    }
    else
    {
      #
      # Show a summary of the errors from all the reports and logs
      #

      # Figure out which logs / reports actually have errors
      my $LogSummaries;
      foreach my $LogName (@{$MoreInfo->{Logs}})
      {
        next if ($LogName =~ /^old_/);
        my ($Groups, $Errors) = GetLogErrors("$TaskDir/$LogName");
        next if (!$Groups or !@$Groups);
        $LogSummaries->{$LogName}->{Groups} = $Groups;
        $LogSummaries->{$LogName}->{Errors} = $Errors;
      }
      my $ShowLogName = ($ReportCount > 1 or scalar(keys %$LogSummaries) > 1);

      my $LogIsEmpty = 1;
      foreach my $LogName (@{$MoreInfo->{Logs}})
      {
        next if (!$LogSummaries->{$LogName});
        $LogIsEmpty = 0;

        if ($ShowLogName)
        {
          # Show the log / report name to avoid ambiguity
          my $Label = ucfirst(GetLogLabel($LogName));
          print "<div class='HrTitle'>$Label<div class='HrLine'></div></div>\n";
        }

        my $Summary = $LogSummaries->{$LogName};
        my $New;
        if ($LogName =~ /\.report$/)
        {
          # Identify new errors in test reports
          my $RefFileName = $StepTask->GetFullFileName($VM->Name ."_$LogName");
          (my $_NewGroups, my $_NewErrors, $New) = GetNewLogErrors($RefFileName, $Summary->{Groups}, $Summary->{Errors});
        }

        foreach my $GroupName (@{$Summary->{Groups}})
        {
          print "<div class='LogDllName'>$GroupName</div>\n" if ($GroupName);

          print "<pre><code>";
          my $ErrIndex = 0;
          foreach my $Line (@{$Summary->{Errors}->{$GroupName}})
          {
            if ($New and $New->{$GroupName}->{$ErrIndex})
            {
              print "<span class='log-new'>", $self->escapeHTML($Line), "</span>\n";
            }
            else
            {
              print $self->escapeHTML($Line), "\n";
            }
            $ErrIndex++;
          }
          print "</code></pre>\n";
        }
      }

      if ($LogIsEmpty)
      {
        if ($StepTask->Status eq "canceled")
        {
          print "No log, task was canceled\n";
        }
        elsif ($StepTask->Status eq "skipped")
        {
          print "No log, task skipped\n";
        }
        else
        {
          print "No errors\n";
        }
      }
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
