# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Shows the VM activity
#
# Copyright 2017 Francois Gouget
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

package ActivityPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use POSIX qw(strftime);
use URI::Escape;

use WineTestBot::Config;
use WineTestBot::Activity;
use WineTestBot::Log;
use WineTestBot::Utils;
use WineTestBot::VMs;


my $HOURS_DEFAULT = 12;

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->{start} = Time();
  $self->{hours} = $self->GetParam("Hours");
  if (!defined $self->{hours} or $self->{hours} !~ /^\d{1,3}$/)
  {
    $self->{hours} = $HOURS_DEFAULT;
  }

  $self->SUPER::_initialize($Request, $RequiredRole);
  $self->{Method} = "get";
}

sub GetPageTitle($$)
{
  my ($self, $Page) = @_;

  return "Activity - ${ProjectName} Test Bot";
}

sub GeneratePage($)
{
  my ($self) = @_;
  if ($self->{hours} and $self->{hours} <= $HOURS_DEFAULT)
  {
    $self->{Request}->headers_out->add("Refresh", "60");
  }
  $self->SUPER::GeneratePage();
}

sub _GetHtmlTime($)
{
  my ($Timestamp) = @_;
  return "<noscript><div>",
      strftime("<a class='title' title='%d'>%H:%M:%S</a>", localtime($Timestamp)), "</div></noscript>\n" .
      "<script type='text/javascript'><!--\n" .
      "ShowDateTime($Timestamp);\n" .
      "//--></script>";
}

sub _GetHtmlDuration($)
{
  my ($Secs) = @_;
  return ($Secs < 2) ? "" : "<span class='RecordDuration'>". DurationToString($Secs) ."</span>";
}

sub _CompareVMs()
{
    my ($aHost, $bHost) = ($a->GetHost(), $b->GetHost());
    if ($PrettyHostNames)
    {
      $aHost = $PrettyHostNames->{$aHost} || $aHost;
      $bHost = $PrettyHostNames->{$bHost} || $bHost;
    }
    return $aHost cmp $bHost || $a->Name cmp $b->Name;
}

sub GenerateBody($)
{
  my ($self) = @_;

  # Generate a custom form to let the user specify the Hours field.
  $self->GenerateFormStart();
  print "<div class='ItemProperty'><label>Analyze the activity of the past <div class='ItemValue'><input type='text' name='Hours' maxlength='3' size='3' value='$self->{hours}'/></div> hours.</label></div>\n";
  $self->GenerateFormEnd();

  print "<h1>${ProjectName} Test Bot activity</h1>\n";
  print "<div class='Content'>\n";

  print <<"EOF";
<script type='text/javascript'><!--\
function Pad2(n)
{
    return n < 10 ? '0' + n : n;
}
function ShowDateTime(Sec1970)
{
  var Dt = new Date(Sec1970 * 1000);
  document.write('<a class="title" title="' + Pad2(Dt.getDate()) + '">' + Pad2(Dt.getHours()) + ':' +
                 Pad2(Dt.getMinutes()) + ':' + Pad2(Dt.getSeconds()) + "</a>");
}
//--></script>
EOF

  ### Get the sorted VMs list

  my $VMs = CreateVMs();
  $VMs->FilterEnabledRole();
  my @SortedVMs = sort _CompareVMs @{$VMs->GetItems()};

  ### Generate the table header : one column per VM

  print "<div class='CollectionBlock'><table>\n";
  print "<thead><tr><th class='Record'>Time</th>\n";
  print "<th class='Record'><a class='title' title='Runnable / queued task count before scheduling'>Tasks</a></th>\n";
  foreach my $VM (@SortedVMs)
  {
    my $Host = $VM->GetHost();
    if ($PrettyHostNames and defined $PrettyHostNames->{$Host})
    {
      $Host = $PrettyHostNames->{$Host};
    }
    $Host = " on $Host" if ($Host ne "");
    print "<th class='Record'>", $VM->Name, "$Host</th>\n";
  }
  print "</tr></thead>\n";

  ### Generate the HTML table with the newest record first

  print "<tbody>\n";
  my ($Activity, $_Counters) = GetActivity($VMs, $self->{hours} * 3600);
  for (my $Index = @$Activity; $Index--; )
  {
    my $Group = $Activity->[$Index];
    next if (!$Group->{statusvms});

    my $GroupId = $Group->{id};
    print "<tr><td id='g$GroupId'>", _GetHtmlTime($Group->{start}), "</td>";
    if ($Group->{engine})
    {
      print "<td class='Record RecordEngine'>$Group->{engine}</td>\n";
      print "<td colspan='", scalar(@SortedVMs), "'><hr></td>\n";
      next;
    }
    if ($Group->{runnable} or $Group->{queued} or $Group->{blocked})
    {
      print "<td class='Record'>", ($Group->{runnable} || 0), " / ",
            ($Group->{queued} || 0),
            ($Group->{blocked} ? "+$Group->{blocked}" : ""), "</td>";
    }
    else
    {
      print "<td class='Record'>&nbsp;</td>";
    }

    foreach my $Col (0..@SortedVMs-1)
    {
      my $VM = $SortedVMs[$Col];
      my $VMStatus = $Group->{statusvms}->{$VM->Name};
      next if ($VMStatus->{merged});

      # Add borders to separate VM hosts and indicate various anomalies.
      print "<td class='Record Record-$VMStatus->{status}";
      if ($VMStatus->{result} eq "timeout")
      {
        print " Record-timeout";
      }
      elsif ($VMStatus->{result} eq "boterror")
      {
        print " Record-boterror";
      }
      elsif ($VMStatus->{result} eq "error")
      {
        print " Record-error";
      }
      else
      {
        my $Host = $VM->GetHost();
        print " Record-left" if ($Col > 0 and $SortedVMs[$Col-1]->GetHost() ne $Host);
        print " Record-right" if ($Col+1 < @SortedVMs and $SortedVMs[$Col+1]->GetHost() ne $Host);
      }
      print " Record-miss" if ($VMStatus->{mispredict});
      print "'";
      print " rowspan='$VMStatus->{rows}'" if ($VMStatus->{rows} > 1);
      print ">";

      my $Label;
      if ($VMStatus->{task})
      {
        $Label = "<span class='RecordJob'>". $VMStatus->{job}->Id .":</span>";
        if ($VMStatus->{step}->Type eq "build")
        {
          $Label .= " Build";
        }
        elsif ($VMStatus->{step}->Type eq "reconfig")
        {
          $Label .= " Reconfig";
        }
        elsif ($VMStatus->{step}->Type eq "suite")
        {
          $Label .= " WineTest";
        }
        else
        {
          $Label .= " ". $self->escapeHTML($VMStatus->{step}->FileName);
          if ($VMStatus->{task}->CmdLineArg =~ /^\w+$/ and
              $Label =~ s/_(?:cross)?test(64)?\.exe$//)
          {
            my $Bitness = $1;
            $Label .= ":". $VMStatus->{task}->CmdLineArg;
            $Label .= "/64" if ($Bitness);
          }
        }
        my $URL = GetTaskURL($VMStatus->{job}->Id, $VMStatus->{step}->No, $VMStatus->{task}->No);
        my $Title = $self->escapeHTML($VMStatus->{job}->Remarks);
        $Label = "<a href='$URL' title='$Title'>$Label</a>";
      }
      elsif ($VMStatus->{status} eq "dirty")
      {
        $Label = $VMStatus->{details} || $VMStatus->{status};
      }
      elsif ($VMStatus->{status} eq "reverting")
      {
        $Label = "<a class='title' title='". $VM->Name ."'>reverting</a>";
      }
      else
      {
        $Label = $VMStatus->{status};
      }
      if ($VMStatus->{host} and $VMStatus->{host} ne $VM->GetHost())
      {
        my $Host = $VMStatus->{host};
        # Here we keep the original hostname if the pretty one is empty
        $Host = $PrettyHostNames->{$Host} || $Host if ($PrettyHostNames);
        $Label = "<span class='RecordHost'>(on $Host)</span><br>$Label";
      }
      print "$Label ", _GetHtmlDuration($VMStatus->{end} - $VMStatus->{start});

      my $Result = "";
      if ($VMStatus->{status} ne "dirty")
      {
        $Result = $VMStatus->{result} if ($VMStatus->{result});
        $Result .= " $VMStatus->{tries}/$VMStatus->{maxtries}" if ($VMStatus->{tries});
        $Result .= ": $VMStatus->{details}" if ($VMStatus->{details});
        $Result =~ s/^: //;
      }
      print "<br><span class='RecordResult'>$Result</span>" if ($Result);

      print "</td>\n";
    }
    print "</tr>\n";
  }

  ### Generate the table footer

  print "</tbody></table></div>\n";
  print "</div>\n";
}

sub GenerateFooter($)
{
  my ($self) = @_;
  print "<p></p><div class='CollectionBlock'><table>\n";
  print "<thead><tr><th class='Record'>Legend</th></tr></thead>\n";
  print "<tbody><tr><td class='Record'>\n";

  print "<p>The VM typically goes through these states: <span class='Record-off'>off</span>,<br>\n";
  print "<span class='Record-reverting'>reverting</span> to the proper test configuration,<br>\n";
  print "<span class='Record-sleeping'>sleeping</span> until the server can connect to it,<br>\n";
  print "<span class='Record-running'>running</span> a task (in which case it links to it),<br>\n";
  print "<span class='Record-dirty'>dirty</span> while the server is powering off the VM after a task or while it assesses its state on startup.</p>\n";

  print "<p>If no time is indicated then the VM remained in that state for less than 2 seconds. The tasks column indicates the number of runnable / queued tasks before that scheduling round. If any task needs to run on a maintenance, retired or deleted VM is is shown as +N. A long horizontal bar indicates the TestBot server was restarted. </p>\n";
  print "<p>This <span class='Record Record-running Record-timeout'>border</span> indicates that the task timed out,<br>\n";
  print "this <span class='Record Record-running Record-error'>border</span> denotes a transient (network?) error so the task will be re-run,<br>\n";
  print "and this <span class='Record Record-running Record-boterror'>border</span> indicates a TestBot error.<br>\n";
  print "Finally this <span class='Record Record-idle Record-miss'>border</span> indicates that the server threw away the VM's current state without using it.</p>\n";

  print "<p>The VM could also be <span class='Record-offline'>offline</span> due to a temporary issue,<br>\n";
  print "or until the administrator can look at it for <span class='Record-maintenance'>maintenance</span>,<br>\n";
  print "or <span class='Record-retired'>retired</span> prior to a possible<br>\n";
  print "<span class='Record-deleted'>deletion</span>.</p>\n";

  print "</td></tr></tbody>\n";
  print "</table></div>\n";
  print "<p class='GeneralFooterText'>Generated in ", Elapsed($self->{start}), " s</p>\n";
  $self->SUPER::GenerateFooter();
}


package main;

my $Request = shift;

my $ActivityPage = ActivityPage->new($Request, "wine-devel");
$ActivityPage->GeneratePage();
