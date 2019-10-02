# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Sends a Task's report or log file
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

use warnings;
use strict;

use Apache2::Const -compile => qw(REDIRECT);
use CGI;
use Fcntl; # for O_READONLY
use WineTestBot::Config;


sub SendTaskFile($$$$$)
{
  my ($Request, $JobId, $StepNo, $TaskNo, $File) = @_;

  # Validate and untaint
  return undef if ($JobId !~ m/^(\d+)$/);
  $JobId = $1;
  return undef if ($StepNo !~ m/^(\d+)$/);
  $StepNo = $1;
  return undef if ($TaskNo !~ m/^(\d+)$/);
  $TaskNo = $1;
  return undef if ($File !~ m/^(log|[a-zA-Z0-9_-]+\.report)$/);
  $File = $1;

  my $FileName = "$DataDir/jobs/$JobId/$StepNo/$TaskNo/$File";
  if (sysopen(my $fh, $FileName, O_RDONLY))
  {
    my ($FileSize, $MTime, $BlkSize) = (stat($fh))[7, 9, 11];

    $Request->headers_out->add("Last-Modified", scalar(gmtime($MTime)) ." GMT");
    $Request->content_type("text/plain");
    $Request->headers_out->add("Content-length", $FileSize);
    $Request->headers_out->add("Content-Disposition",
                               "attachment; filename='$File'");

    $BlkSize ||= 16384;
    print $_ while (sysread($fh, $_, $BlkSize));
    close($fh);

    return 1;
  }

  return undef;
}


my $Request = shift;

my $CGIObj = CGI->new($Request);
my $JobId = $CGIObj->param("Job") || "";
my $StepNo = $CGIObj->param("Step") || "";
my $TaskNo = $CGIObj->param("Task") || "";
my $File = $CGIObj->param("File") || "";

if (!SendTaskFile($Request, $JobId, $StepNo, $TaskNo, $File))
{
  $Request->headers_out->set("Location", "/");
  $Request->status(Apache2::Const::REDIRECT);
}

exit;
