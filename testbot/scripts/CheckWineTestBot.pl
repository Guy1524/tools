#!/usr/bin/perl -Tw
#
# Ping WineTestBot engine to see if it is alive
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

sub BEGIN
{
  if ($0 !~ m=^/=)
  {
    # Turn $0 into an absolute path so it can safely be used in @INC
    require Cwd;
    $0 = Cwd::cwd() . "/$0";
  }
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
}

use WineTestBot::Config;
use WineTestBot::Utils;
use WineTestBot::Engine::Notify;

my $rc = 0;
if (! PingEngine())
{
  if ($> == 0)
  {
    system "/usr/sbin/service winetestbot restart > /dev/null";
    sleep 5;
  }

  my $Body;
  if ($> != 0)
  {
    $Body = "Insufficient permissions to restart the engine\n";
    $rc = 1;
  }
  elsif (PingEngine())
  {
    $Body = "The engine was restarted successfully\n";
  }
  else
  {
    $Body = "Unable to restart the engine\n";
    $rc = 1;
  }
  NotifyAdministrator("WineTestBot engine died", $Body);
}
exit($rc);
