# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Interface with testagentd to send to and receive files from the VMs and
# to run scripts.
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2019 Francois Gouget
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

package TestAgent;
use strict;

use Exporter 'import';
our @EXPORT_OK = qw(new);

my $BLOCK_SIZE = 65536;

my $RPC_PING = 0;
my $RPC_GETFILE = 1;
my $RPC_SENDFILE = 2;
my $RPC_RUN = 3;
my $RPC_WAIT = 4;
my $RPC_RM = 5;
my $RPC_WAIT2 = 6;
my $RPC_SETTIME = 7;
my $RPC_GETPROPERTIES = 8;
my $RPC_UPGRADE = 9;
my $RPC_RMCHILDPROC = 10;
my $RPC_GETCWD = 11;
my $RPC_SETPROPERTY = 12;
my $RPC_RESTART = 13;

my %RpcNames=(
    $RPC_PING => 'ping',
    $RPC_GETFILE => 'getfile',
    $RPC_SENDFILE => 'sendfile',
    $RPC_RUN => 'run',
    $RPC_WAIT => 'wait',
    $RPC_RM => 'rm',
    $RPC_WAIT2 => 'wait2',
    $RPC_SETTIME => 'settime',
    $RPC_GETPROPERTIES => 'getproperties',
    $RPC_UPGRADE => 'upgrade',
    $RPC_RMCHILDPROC => 'rmchildproc',
    $RPC_GETCWD => 'getcwd',
    $RPC_SETPROPERTY => 'setproperty',
    $RPC_RESTART => 'restart',
);

my $Debug = 0;
sub debug(@)
{
    print STDERR @_ if ($Debug);
}

my $time_hires;
sub now()
{
    local $@;
    $time_hires=eval { require Time::HiRes } if (!defined $time_hires);
    return eval { Time::HiRes::time() } if ($time_hires);
    return time();
}

sub trace_speed($$)
{
    if ($Debug)
    {
        my ($Bytes, $Elapsed) = @_;
        my $Speed = "";
        if ($Elapsed)
        {
            $Speed = $Bytes * 8 / $Elapsed / 1000;
            $Speed = $Speed < 1000 ? sprintf(" (%.1f kb/s)", $Speed) :
                                     sprintf(" (%.1f Mb/s)", $Speed / 1000);
        }
        $Bytes = $Bytes < 8 * 1024 ? "$Bytes bytes" :
                 $Bytes < 8 * 1024 * 1024 ? sprintf("%.1f KiB", $Bytes / 1024) :
                 sprintf("%.1f MiB", $Bytes / 1024 / 1024);
        $Elapsed = $Elapsed < 1 ? sprintf("%.1f ms", $Elapsed * 1000) :
                   sprintf("%.1f s", $Elapsed);
        debug("Transferred $Bytes in $Elapsed$Speed\n");
    }
}

sub new($$$;$)
{
  my ($class, $Hostname, $Port, $Tunnel) = @_;

  my $self = {
    agenthost  => $Hostname,
    agentport  => $Port,
    connection => "$Hostname:$Port",
    conetimeout  => 20,
    cminattempts => 2,
    cmintimeout  => 10,
    timeout    => 0,
    fd         => undef,
    deadline   => undef,
    err        => undef};
  if ($Tunnel)
  {
    $Tunnel->{sshhost} ||= $Hostname;
    $Tunnel->{sshport} ||= 22;
    $self->{connection} = "$Tunnel->{sshhost}:$Tunnel->{sshport}:$self->{connection}";
    $self->{tunnel} = $Tunnel;
  }

  $self = bless $self, $class;
  return $self;
}

sub Disconnect($)
{
  my ($self) = @_;

  if ($self->{ssh})
  {
    # This may close the SSH channel ($self->{fd}) as a side-effect,
    # which will avoid undue delays.
    $self->{ssh} = undef;
    waitpid($self->{sshpid}, 0) if ($self->{sshpid});
    $self->{sshpid} = undef;
  }
  if ($self->{fd})
  {
      close($self->{fd});
      $self->{fd} = undef;
  }
  $self->{agentversion} = undef;
}

=pod
=over 12

=item C<SetConnectTimeout()>

Configures how many times and for how long to attempt to connect to the server.

=item OneTimeout

OneTimeout specifies the timeout for one connection attempt in seconds.
Zero means there will be no timeout. Undef means the value is not changed.

=item MinAttempts

MinAttempts specifies the minimum number of connection attempts. It must be a
non-zero positive integer. Undef means the value is not changed.

=item MinTimeout

MinTimeout specifies the minimum period during which connection attempts should
be made in seconds. Zero means there will be no minimum timeout. Undef means
the value is not changed.

This means connection attempts will be made until either one succeeds or
MinTimeout seconds have elapsed, even if each attempt fails quickly such that
more than $MinAttempts attempts are performed. Conversely, if each attempt
takes a long time such that more MinTimeout is reached before MinAttempt
connection attempts have been made, then attempts will continue until the
minimum number of attempts is reached.

Thus the worst case connection timeout is:

   max($MinAttempts * $OneTimeout, $MinTimeout + $OneTimeout)

=item Return value

For each modified value (i.e. not undef), the old value is returned.

=item Usage

To perform a single connection attempt with a 20 second timeout:

    $TA->SetConnectionTimeout(20, 1, 0);

For a bit more robustness in case one expects short network disruptions:

    $TA->SetConnectionTimeout(20, 2, 10);

But if the server needs time to boot before accepting connections, then
MinTimeout should be set to the amount of time this is expected to take. It
would make sense to reset MinTimeout after the first RPC has completed since
then a reconnection would not have to wait for the server to boot again:

    my $OldMinTimeout = $TA->SetConnectionTimeout(undef, undef, 90);

    ... first RPC ...

    $TA->SetConnectionTimeout(undef, undef, $OldMinTimeout);

=back
=cut

sub SetConnectTimeout($$;$$)
{
  my ($self, $OneTimeout, $MinAttempts, $MinTimeout) = @_;
  my @Ret;
  if (defined $OneTimeout)
  {
    push @Ret, $self->{conetimeout};
    $self->{conetimeout} = $OneTimeout;
  }
  if (defined $MinAttempts)
  {
    push @Ret, $self->{cminattempts};
    $self->{cminattempts} = $MinAttempts;
  }
  if (defined $MinTimeout)
  {
    push @Ret, $self->{cmintimeout};
    $self->{cmintimeout} = $MinTimeout;
  }
  return @Ret;
}

=pod
=over 12

=item C<SetTimeout()>

Configures how long an individual RPC can take to complete (in seconds).

Note that some operations like Wait() and Wait2() involve multiple RPCs. These
have their own timeouts.

=back
=cut

sub SetTimeout($$)
{
  my ($self, $Timeout) = @_;
  my $OldTimeout = $self->{timeout};
  $self->{timeout} = $Timeout;
  return $OldTimeout;
}

sub _SetAlarm($)
{
  my ($self) = @_;
  if ($self->{deadline})
  {
    my $Timeout = $self->{deadline} - time();
    die "timeout" if ($Timeout <= 0);
    # alarm() has a 32-bit limit, even on 64-bit systems
    alarm($Timeout <= 0xffffffff ? $Timeout : 0xffffffff);
  }
}


#
# Error handling
#

my $ERROR = 0;
my $FATAL = 1;

sub _SetError($$$)
{
  my ($self, $Level, $Msg) = @_;

  # Only overwrite non-fatal errors
  if ($self->{fd})
  {
    # Cleanup errors coming from the server
    $self->{err} = $Msg;

    # And disconnect on fatal errors since the connection is unusable anyway
    $self->Disconnect() if ($Level == $FATAL);
  }
  elsif (!$self->{err})
  {
    # We did not even manage to connect but record the error anyway
    $self->{err} = $Msg;
  }
  debug("$self->{err}\n");
}

sub GetLastError($)
{
  my ($self) = @_;
  return $self->{err};
}


#
# Low-level functions to receive raw data
#

sub _RecvRawData($$$)
{
  my ($self, $Name, $Size) = @_;
  return undef if (!defined $self->{fd});

  my $Result;
  my ($Pos, $Remaining) = (0, $Size);
  eval
  {
    local $SIG{ALRM} = sub { die "timeout" };
    $self->_SetAlarm();

    my $Data = "";
    while ($Remaining)
    {
      my $Buffer;
      my $r = $self->{fd}->read($Buffer, $Remaining);
      if (!defined $r)
      {
        alarm(0);
        $self->_SetError($FATAL, "network read error ($self->{rpc}:$Name:$Pos/$Size): $!");
        return; # out of eval
      }
      if ($r == 0)
      {
        alarm(0);
        $self->_SetError($FATAL, "network read got a premature EOF ($self->{rpc}:$Name:$Pos/$Size)");
        return; # out of eval
      }
      $Data .= $Buffer;
      $Pos += $r;
      $Remaining -= $r;
    }
    alarm(0);
    $Result = $Data;
  };
  if ($@)
  {
    if ($@ =~ /^timeout /)
    {
      $@ = "network read timed out ($self->{rpc}:$Name:$Pos/$Size)";
    }
    $self->_SetError($FATAL, $@);
  }
  return $Result;
}

sub _SkipRawData($$)
{
  my ($self, $Name, $Size) = @_;
  return undef if (!defined $self->{fd});

  my $Success;
  my ($Pos, $Remaining) = (0, $Size);
  eval
  {
    local $SIG{ALRM} = sub { die "timeout" };
    $self->_SetAlarm();

    while ($Remaining)
    {
      my $Buffer;
      my $s = $Remaining < $BLOCK_SIZE ? $Remaining : $BLOCK_SIZE;
      my $n = $self->{fd}->read($Buffer, $s);
      if (!defined $n)
      {
        alarm(0);
        $self->_SetError($FATAL, "network skip failed ($self->{rpc}:$Name:$Pos/$Size): $!");
        return; # out of eval
      }
      if ($n == 0)
      {
        alarm(0);
        $self->_SetError($FATAL, "network skip got a premature EOF ($self->{rpc}:$Name:$Pos/$Size)");
        return; # out of eval
      }
      $Pos += $n;
      $Remaining -= $n;
    }
    alarm(0);
    $Success = 1;
  };
  if ($@)
  {
    if ($@ =~ /^timeout /)
    {
      $@ = "network skip timed out ($self->{rpc}:$Name:$Pos/$Size)";
    }
    $self->_SetError($FATAL, $@);
  }
  return $Success;
}

sub _RecvRawString($$$)
{
  my ($self, $Name, $Size) = @_;

  my $Str = $self->_RecvRawData($Name, $Size);
  if (defined $Str)
  {
    # Remove the trailing '\0'
    chop $Str;
    debug("  RecvRawString('$Name') -> '$Str'\n");
  }
  return $Str;
}

sub _RecvRawUInt32($$)
{
  my ($self, $Name) = @_;

  my $Data = $self->_RecvRawData($Name, 4);
  return undef if (!defined $Data);
  return unpack('N', $Data);
}

sub _RecvRawUInt64($$)
{
  my ($self, $Name) = @_;

  my $Data = $self->_RecvRawData($Name, 8);
  return undef if (!defined $Data);
  my ($High, $Low) = unpack('NN', $Data);
  return $High << 32 | $Low;
}


#
# Low-level functions to result lists
#

sub _RecvEntryHeader($)
{
  my ($self, $Name) = @_;

  my $Data = $self->_RecvRawData("$Name.h", 9);
  return (undef, undef) if (!defined $Data);
  my ($Type, $High, $Low) = unpack('cNN', $Data);
  $Type = chr($Type);
  return ($Type, $High << 32 | $Low);
}

sub _ExpectEntryHeader($$$;$)
{
  my ($self, $Name, $Type, $Size) = @_;

  my ($HType, $HSize) = $self->_RecvEntryHeader($Name);
  return undef if (!defined $HType);
  if ($HType ne $Type)
  {
    $self->_SetError($ERROR, "Expected $Name to be a $Type entry but got $HType instead");
  }
  elsif (defined $Size and $HSize != $Size)
  {
    $self->_SetError($ERROR, "Expected $Name to be of size $Size but got $HSize instead");
  }
  else
  {
    return $HSize;
  }
  if ($HType eq 'e')
  {
    # The expected data was replaced with an error message
    my $Message = $self->_RecvRawString("$Name.e", $HSize);
    return undef if (!defined $Message);
    $self->_SetError($ERROR, $Message);
  }
  else
  {
    $self->_SkipRawData($Name, $HSize);
  }
  return undef;
}

sub _ExpectEntry($$$$)
{
  my ($self, $Name, $Type, $Size) = @_;

  $Size = $self->_ExpectEntryHeader($Name, $Type, $Size);
  return undef if (!defined $Size);
  return $self->_RecvRawData($Name, $Size);
}

sub _RecvUInt32($$)
{
  my ($self, $Name) = @_;

  return undef if (!defined $self->_ExpectEntryHeader($Name, 'I', 4));
  my $Value = $self->_RecvRawUInt32($Name);
  debug("  RecvUInt32('$Name') -> $Value\n") if (defined $Value);
  return $Value;
}

sub _RecvUInt64($$)
{
  my ($self, $Name) = @_;

  return undef if (!defined $self->_ExpectEntryHeader($Name, 'Q', 8));
  my $Value = $self->_RecvRawUInt64($Name);
  debug("  RecvUInt64('$Name') -> $Value\n") if (defined $Value);
  return $Value;
}

sub _RecvString($$;$)
{
  my ($self, $Name, $EType) = @_;

  my $Str = $self->_ExpectEntry($Name, $EType || 's');
  if (defined $Str)
  {
    # Remove the trailing '\0'
    chop $Str;
    debug("  RecvString('$Name') -> '$Str'\n");
  }
  return $Str;
}

sub _RecvFile($$$$)
{
  my ($self, $Name, $Dst, $Filename) = @_;
  return undef if (!defined $self->{fd});
  debug("  RecvFile('$Name', '$Filename')\n");

  my $Size = $self->_ExpectEntryHeader("$Name/Size", 'd');
  return undef if (!defined $Size);

  my $Success;
  my ($Start, $Pos, $Remaining) = (now(), 0, $Size);
  eval
  {
    local $SIG{ALRM} = sub { die "timeout" };
    $self->_SetAlarm();

    while ($Remaining)
    {
      my $Buffer;
      my $s = $Remaining < $BLOCK_SIZE ? $Remaining : $BLOCK_SIZE;
      my $r = $self->{fd}->read($Buffer, $s);
      if (!defined $r)
      {
        alarm(0);
        $self->_SetError($FATAL, "got a network error while receiving '$Filename' ($self->{rpc}:$Name:$Pos+$s/$Size): $!");
        return; # out of eval
      }
      if ($r == 0)
      {
        alarm(0);
        $self->_SetError($FATAL, "got a premature EOF while receiving '$Filename' ($self->{rpc}:$Name:$Pos/$Size)");
        return; # out of eval
      }
      $Remaining -= $r;
      my $w = syswrite($Dst, $Buffer, $r, 0);
      $Pos += $w if (defined $w);
      if (!defined $w or $w != $r)
      {
        alarm(0);
        $self->_SetError($ERROR, "an error occurred while writing to '$Filename' ($self->{rpc}:$Name:$Pos+$r/$Size): $!");
        $self->_SkipRawData($Name, $Remaining);
        return; # out of eval
      }
    }
    alarm(0);
    $Success = 1;
  };
  if ($@)
  {
    if ($@ =~ /^timeout /)
    {
      $@ = "timed out while receiving '$Filename' ($self->{rpc}:$Name:$Pos/$Size)";
    }
    $self->_SetError($FATAL, $@);
  }

  trace_speed($Pos, now() - $Start);
  return $Success;
}

sub _SkipEntries($$)
{
  my ($self, $Count) = @_;
  debug("  SkipEntries($Count)\n");

  for (my $i = 0; $i < $Count; $i++)
  {
    my ($Type, $Size) = $self->_RecvEntryHeader("Skip$i");
    return undef if (!defined $Type);
    if ($Type eq 'e')
    {
      # The expected data was replaced with an error message
      my $Message = $self->_RecvRawString("Skip$i.e", $Size);
      return undef if (!defined $Message);
      $self->_SetError($ERROR, $Message);
    }
    elsif (!$self->_SkipRawData("Skip$i", $Size))
    {
      return undef;
    }
  }
  return 1;
}

sub _RecvListSize($$)
{
  my ($self, $Name) = @_;

  my $Value = $self->_RecvRawUInt32($Name);
  debug("  RecvListSize('$Name') -> $Value\n") if (defined $Value);
  return $Value;
}

sub _RecvList($$)
{
  my ($self, $ETypes) = @_;

  debug("  RecvList($ETypes)\n");
  my $HCount = $self->_RecvListSize('ListSize');
  return undef if (!defined $HCount);

  my $Count = length($ETypes);
  if ($HCount != $Count)
  {
    $self->_SetError($ERROR, "Expected $Count results but got $HCount instead");
    $self->_SkipEntries($HCount);
    return undef;
  }

  my @List;
  my $i = 0;
  foreach my $EType (split //, $ETypes)
  {
    # '.' is a placeholder for data handled by the caller so let it handle
    # the rest
    last if ($EType eq '.');

    my $Data;
    if ($EType eq 'I')
    {
      $Data = $self->_RecvUInt32("List$i.I");
      $Count--;
    }
    elsif ($EType eq 'Q')
    {
      $Data = $self->_RecvUInt64("List$i.Q");
      $Count--;
    }
    elsif ($EType eq 's')
    {
      $Data = $self->_RecvString("List$i.s");
      $Count--;
    }
    else
    {
      $self->_SetError($ERROR, "_RecvList() cannot receive a result of type $EType");
    }
    if (!defined $Data)
    {
      $self->_SkipEntries($Count);
      return undef;
    }
    push @List, $Data;
    $i++;
  }
  return 1 if (!@List);
  return $List[0] if (@List == 1);
  return @List;
}

sub _RecvErrorList($)
{
  my ($self) = @_;

  my $Count = $self->_RecvListSize('ErrCount');
  return $self->GetLastError() if (!defined $Count);
  return undef if (!$Count);

  my ($Errors, $i) = ([], 0);
  while ($Count--)
  {
    my ($Type, $Size) = $self->_RecvEntryHeader("Err$i");
    if ($Type eq 'u')
    {
      debug("  RecvUndef()\n");
      push @$Errors, undef;
    }
    elsif ($Type eq 's')
    {
      my $Status = $self->_RecvRawString("Err$i.s", $Size);
      return $self->GetLastError() if (!defined $Status);
      debug("  RecvStatus() -> '$Status'\n");
      push @$Errors, $Status;
    }
    elsif ($Type eq 'e')
    {
      # The expected data was replaced with an error message
      my $Message = $self->_RecvRawString("Err$i.e", $Size);
      if (defined $Message)
      {
        debug("  RecvError() -> '$Message'\n");
        $self->_SetError($ERROR, $Message);
      }
      $self->_SkipEntries($Count);
      return $self->GetLastError();
    }
    else
    {
      $self->_SetError($ERROR, "Expected an s, u or e entry but got $Type instead");
      $self->_SkipRawData("Err$i.$Type", $Size);
      $self->_SkipEntries($Count);
      return $self->GetLastError();
    }
    $i++;
  }
  return $Errors;
}


#
# Low-level functions to send raw data
#

sub _Write($$$)
{
  my ($self, $Name, $Data) = @_;
  return undef if (!defined $self->{fd});

  my $Size = length($Data);
  my ($Pos, $Remaining) = (0, $Size);
  while ($Remaining)
  {
    my $w = syswrite($self->{fd}, $Data, $Remaining, $Pos);
    if (!defined $w)
    {
      $self->_SetError($FATAL, "network write error ($self->{rpc}:$Name:$Pos/$Size): $!");
      return undef;
    }
    if ($w == 0)
    {
      $self->_SetError($FATAL, "unable to send more data ($self->{rpc}:$Name:$Pos/$Size)");
      return $Pos;
    }
    $Pos += $w;
    $Remaining -= $w;
  }
  return $Pos;
}

sub _SendRawData($$$)
{
  my ($self, $Name, $Data) = @_;
  return undef if (!defined $self->{fd});

  my $Success;
  eval
  {
    local $SIG{ALRM} = sub { die "timeout" };
    $self->_SetAlarm();
    $self->_Write($Name, $Data);
    alarm(0);

    # _Write() errors are fatal and break the connection
    $Success = 1 if (defined $self->{fd});
  };
  if ($@)
  {
    if ($@ =~ /^timeout /)
    {
      $@ = "network write timed out ($self->{rpc}:$Name)";
    }
    $self->_SetError($FATAL, $@);
  }
  return $Success;
}

sub _SendRawUInt32($$$)
{
  my ($self, $Name, $Value) = @_;

  return $self->_SendRawData($Name, pack('N', $Value));
}

sub _SendRawUInt64($$$)
{
  my ($self, $Name, $Value) = @_;

  my ($High, $Low) = ($Value >> 32, $Value & 0xffffffff);
  return $self->_SendRawData($Name, pack('NN', $High, $Low));
}


#
# Functions to send parameter lists
#

sub _SendListSize($$$)
{
  my ($self, $Name, $Size) = @_;

  debug("  SendListSize('$Name', $Size)\n");
  return $self->_SendRawUInt32($Name, $Size);
}

sub _SendEntryHeader($$$$)
{
  my ($self, $Name, $Type, $Size) = @_;

  my ($High, $Low) = ($Size >> 32, $Size & 0xffffffff);
  return $self->_SendRawData("$Name.h", pack('cNN', ord($Type), $High, $Low));
}

sub _SendUInt32($$$)
{
  my ($self, $Name, $Value) = @_;

  debug("  SendUInt32('$Name', $Value)\n");
  return $self->_SendEntryHeader($Name, 'I', 4) &&
         $self->_SendRawUInt32($Name, $Value);
}

sub _SendUInt64($$$)
{
  my ($self, $Name, $Value) = @_;

  debug("  SendUInt64('$Name', $Value)\n");
  return $self->_SendEntryHeader($Name, 'Q', 8) &&
         $self->_SendRawUInt64($Name, $Value);
}

sub _SendString($$$;$)
{
  my ($self, $Name, $Str, $Type) = @_;
  $Type ||= 's';
  debug("  SendString('$Name', '$Str', '$Type')\n");

  # Add a trailing '\0' to strings to match the C convention.
  $Str .= "\0" if ($Type eq 's');
  return $self->_SendEntryHeader($Name, $Type, length($Str)) &&
         $self->_SendRawData($Name, $Str);
}

sub _SendFile($$$$)
{
  my ($self, $Name, $Src, $Filename) = @_;
  return undef if (!defined $self->{fd});
  debug("  SendFile('$Name', '$Filename')\n");

  my $Size = -s $Filename;
  return undef if (!$self->_SendEntryHeader("$Name/Size", 'd', $Size));

  my $Success;
  my ($Start, $Pos, $Remaining) = (now(), 0, $Size);
  eval
  {
    local $SIG{ALRM} = sub { die "timeout" };
    $self->_SetAlarm();

    while ($Remaining)
    {
      my $Buffer;
      my $s = $Remaining < $BLOCK_SIZE ? $Remaining : $BLOCK_SIZE;
      my $r = sysread($Src, $Buffer, $s);
      if (!defined $r)
      {
        alarm(0);
        $self->_SetError($FATAL, "an error occurred while reading from '$Filename' ($self->{rpc}:$Name:$Pos+$s/$Size): $!");
        return; # out of eval
      }
      if ($r == 0)
      {
        alarm(0);
        $self->_SetError($FATAL, "got a premature EOF while reading from '$Filename' ($self->{rpc}:$Name:$Pos/$Size)");
        return; # out of eval
      }
      $Remaining -= $r;
      my $w = $self->_Write($Name, $Buffer);
      $Pos += $w if (defined $w);
      if (!defined $w or $w != $r)
      {
        alarm(0);
        # Overwrite _Write()'s error message with a more appropriate one
        $self->_SetError($FATAL, "got a network error while sending '$Filename' ($self->{rpc}:$Name:$Pos+$r/$Size): $!");
        return; # out of eval
      }
    }
    alarm(0);
    $Success = 1;
  };
  if ($@)
  {
    if ($@ =~ /^timeout /)
    {
      $@ = "timed out while sending '$Filename' ($self->{rpc}:$Name:$Pos/$Size)";
    }
    $self->_SetError($FATAL, $@);
  }

  trace_speed($Pos, now() - $Start);
  return $Success;
}


#
# Connection management functions
#

sub create_ip_socket(@)
{
  return IO::Socket::IP->new(@_);
}

sub create_inet_socket(@)
{
  return IO::Socket::INET->new(@_);
}

my $create_socket = \&create_ip_socket;
eval "use IO::Socket::IP";
if ($@)
{
  use IO::Socket::INET;
  $create_socket = \&create_inet_socket;
}

sub _ssherror($)
{
  my ($self) = @_;
  return $self->{ssh}->error();
}

sub _Connect($)
{
  my ($self) = @_;

  my $OldRPC = $self->{rpc};
  $self->{rpc} = ($self->{rpc} ? "$self->{rpc}/" : "") ."connect";

  my $Attempt = 1;
  my $MinDeadline = $self->{cmintimeout} ? time() + $self->{cmintimeout} : 0;
  while (1)
  {
    my $Step = "initializing";
    eval
    {
      local $SIG{ALRM} = sub { die "timeout" };
      my $OneDeadline = $self->{conetimeout} ? time() + $self->{conetimeout} : 0;
      $self->{deadline} = ($OneDeadline < $MinDeadline) ? $MinDeadline : $OneDeadline;
      $self->_SetAlarm();

      if ($self->{tunnel})
      {
        # We are in fact connected to the SSH server.
        # Now forward that connection to the TestAgent server.
        $Step = "tunnel_connect";

        require Net::OpenSSH;
        $Net::OpenSSH::debug = ~0 if ($Debug > 1);
        $self->{ssh} = Net::OpenSSH->new($self->{tunnel}->{sshhost},
                                         port => $self->{tunnel}->{sshport},
                                         user => $self->{tunnel}->{username},
                                         key_path => $self->{tunnel}->{privatekey},
                                         batch_mode => 1);
        if ($self->_ssherror())
        {
          alarm(0);
          $self->_SetError($FATAL, "Unable to connect to the SSH server: " . $self->_ssherror());
          return; # out of eval
        }

        $Step = "tunnel_channel";
        ($self->{fd}, $self->{sshpid}) = $self->{ssh}->open_tunnel($self->{agenthost}, $self->{agentport});
        if (!$self->{fd})
        {
          alarm(0);
          $self->_SetError($FATAL, "Unable to create the SSH channel: " . $self->_ssherror());
          return; # out of eval
        }
      }
      else
      {
        $Step = "create_socket";
        $self->{fd} = &$create_socket(PeerHost => $self->{agenthost},
                                      PeerPort => $self->{agentport},
                                      Type => SOCK_STREAM);
        if (!$self->{fd})
        {
          alarm(0);
          if ($!{EINVAL})
          {
            $self->_SetError($FATAL, "The '$self->{agenthost}' hostname or the '$self->{agentport}' port is invalid.");
            die "socket";
          }
          $self->_SetError($FATAL, $!);
          return; # out of eval
        }
      }

      # Get the protocol version supported by the server.
      # This also lets us verify that the connection really works.
      $Step = "agent_version";
      $self->{agentversion} = $self->_RecvString('AgentVersion');
      if (!defined $self->{agentversion})
      {
        alarm(0);
        # We have already been disconnected at this point
        debug("could not get the protocol version spoken by the server\n");
        return; # out of eval
      }

      alarm(0);
      $Step = "done";
    };
    if ($Step eq "done")
    {
      $self->{rpc} = $OldRPC;
      return 1;
    }

    if ($@)
    {
      if ($@ =~ /^timeout /)
      {
        $self->_SetError($FATAL, "Timed out in $Step while connecting to $self->{connection}");
      }
      last;
    }

    $Attempt++;
    last if ($Attempt > $self->{cminattempts} and $MinDeadline <= time() + 1);

    # Wait at least 1 second between attempts so that if the error happens on
    #the client-side (e.g. in case of an invalid ssh argument) we don't busy
    # loop for $MinTimeout seconds.
    sleep(1);
  }
  $self->{rpc} = $OldRPC;
  return undef;
}

sub _StartRPC($$)
{
  my ($self, $RpcId) = @_;

  # Set up the new RPC
  $self->{rpc} = $RpcNames{$RpcId} || $RpcId;
  $self->{err} = undef;

  # First assume all is well and that we already have a working connection
  $self->{deadline} = $self->{timeout} ? time() + $self->{timeout} : undef;
  if (!$self->_SendRawUInt32('RpcId.1', $RpcId))
  {
    # No dice, clean up whatever was left of the old connection
    $self->Disconnect();

    # And reconnect
    return undef if (!$self->_Connect());
    debug("Using protocol '$self->{agentversion}'\n");

    # Reconnecting resets the operation deadline
    $self->{deadline} = $self->{timeout} ? time() + $self->{timeout} : undef;
    return $self->_SendRawUInt32('RpcId.2', $RpcId);
  }
  return 1;
}


#
# Implement the high-level RPCs
#

sub Ping($)
{
  my ($self) = @_;

  # Send the RPC and get the reply
  return $self->_StartRPC($RPC_PING) &&
         $self->_SendListSize('ArgC', 0) &&
         $self->_RecvList('');
}

sub GetVersion($)
{
  my ($self) = @_;

  if (!$self->{agentversion})
  {
    # Retrieve the server version
    $self->_Connect();
  }
  # And return the version we got.
  # If the connection failed it will be undef as expected.
  return $self->{agentversion};
}

our $SENDFILE_EXE = 1;

sub _SendStringOrFile($$$$$$)
{
  my ($self, $Data, $fh, $LocalPathName, $ServerPathName, $Flags) = @_;

  # Send the RPC and get the reply
  return $self->_StartRPC($RPC_SENDFILE) &&
         $self->_SendListSize('ArgC', 3) &&
         $self->_SendString('ServerPathName', $ServerPathName) &&
         $self->_SendUInt32('Flags', $Flags || 0) &&
         ($fh ? $self->_SendFile('File', $fh, $LocalPathName) :
                $self->_SendString('String', $Data, 'd')) &&
         $self->_RecvList('');
}

=pod
=over 12

=item C<SendFile()>

Sends the $LocalPathName file and saves it as the $ServerPathName file on the
server. If $Flags is set to $SENDFILE_EXE the file will be made executable.

Note that the transfer must complete within the SetTimeout() limit.

=back
=cut

sub SendFile($$$;$)
{
  my ($self, $LocalPathName, $ServerPathName, $Flags) = @_;
  debug("SendFile '$LocalPathName' -> $self->{agenthost} '$ServerPathName' Flags=", $Flags || 0, "\n");

  if (open(my $fh, "<", $LocalPathName))
  {
    my $Success = $self->_SendStringOrFile(undef, $fh, $LocalPathName,
                                           $ServerPathName, $Flags);
    close($fh);
    return $Success;
  }
  $self->_SetError($ERROR, "Unable to open '$LocalPathName' for reading: $!");
  return undef;
}

=pod
=over 12

=item C<SendFileFromString()>

Sends the $Data string and saves it as the $ServerPathName file on the
server. If $Flags is set to $SENDFILE_EXE the file will be made executable.

Note that the transfer must complete within the SetTimeout() limit.

=back
=cut

sub SendFileFromString($$$;$)
{
  my ($self, $Data, $ServerPathName, $Flags) = @_;
  debug("SendFile String -> $self->{agenthost} '$ServerPathName' Flags=", $Flags || 0, "\n");
  return $self->_SendStringOrFile($Data, undef, undef, $ServerPathName, $Flags);
}

sub _GetStringOrFile($$$)
{
  my ($self, $ServerPathName, $LocalPathName, $fh) = @_;

  # Send the RPC and get the reply
  return $self->_StartRPC($RPC_GETFILE) &&
         $self->_SendListSize('ArgC', 1) &&
         $self->_SendString('ServerPathName', $ServerPathName) &&
         $self->_RecvList('.') &&
         ($fh ? $self->_RecvFile('File', $fh, $LocalPathName) :
                $self->_RecvString('String', 'd'));
}

=pod
=over 12

=item C<GetFile()>

Retrieves the $ServerPathName file from the server and saves it as
$LocalPathName.

Note that the transfer must complete within the SetTimeout() limit.

=back
=cut

sub GetFile($$$)
{
  my ($self, $ServerPathName, $LocalPathName) = @_;
  debug("GetFile $self->{agenthost} '$ServerPathName' -> '$LocalPathName'\n");

  if (open(my $fh, ">", $LocalPathName))
  {
    my $Success = $self->_GetStringOrFile($ServerPathName, $LocalPathName, $fh);
    close($fh);
    unlink $LocalPathName if (!$Success);
    return $Success;
  }
  $self->_SetError($ERROR, "Unable to open '$LocalPathName' for writing: $!");
  return undef;
}

=pod
=over 12

=item C<GetFileToString()>

Retrieves the $ServerPathName file from the server returns it as a string.

Note that the transfer must complete within the SetTimeout() limit.

=back
=cut

sub GetFileToString($$)
{
  my ($self, $ServerPathName) = @_;
  debug("GetFile $self->{agenthost} '$ServerPathName' -> String\n");

  return $self->_GetStringOrFile($ServerPathName, undef, undef);
}

our $RUN_DNT = 1;
our $RUN_DNTRUNC_OUT = 2;
our $RUN_DNTRUNC_ERR = 4;
our $RUN_DNTRUNC = $RUN_DNTRUNC_OUT | $RUN_DNTRUNC_ERR;

sub Run($$$;$$$)
{
  my ($self, $Argv, $Flags, $ServerInPath, $ServerOutPath, $ServerErrPath) = @_;
  debug("Run $self->{agenthost} '", join("' '", @$Argv), "'\n");
  if ($Flags or $ServerInPath or $ServerOutPath or $ServerErrPath)
  {
    debug("  Flags=", $Flags || 0, " In='", $ServerInPath || "",
          "' Out='", $ServerOutPath || "", "' Err='", $ServerErrPath || "",
          "'\n");
  }

  if (!$self->_StartRPC($RPC_RUN) or
      !$self->_SendListSize('ArgC', 4 + @$Argv) or
      !$self->_SendUInt32('Flags', $Flags) or
      !$self->_SendString('ServerInPath', $ServerInPath || "") or
      !$self->_SendString('ServerOutPath', $ServerOutPath || "") or
      !$self->_SendString('ServerErrPath', $ServerErrPath || ""))
  {
    return undef;
  }
  my $i = 0;
  foreach my $Arg (@$Argv)
  {
      return undef if (!$self->_SendString("Cmd$i", $Arg));
      $i++;
  }

  # Get the reply
  return $self->_RecvList('Q');
}

=pod
=over 12

=item C<Wait()>

Waits at most WaitTimeout seconds for the specified remote process to terminate.
The Keepalive specifies how often, in seconds, to check that the remote end
is still alive and reachable.

=back
=cut

sub Wait($$$;$)
{
  my ($self, $Pid, $WaitTimeout, $Keepalive) = @_;
  debug("Wait $Pid, ", defined $WaitTimeout ? $WaitTimeout : "<undef>", ", ",
        defined $Keepalive ? $Keepalive : "<undef>", "\n");

  my $Result;
  $Keepalive ||= 0xffffffff;
  my $OldTimeout = $self->{timeout};

  my $WaitDeadline = $WaitTimeout ? time() + $WaitTimeout : undef;
  while (1)
  {
    my $Remaining = $Keepalive;
    if ($WaitDeadline)
    {
      $Remaining = $WaitDeadline - time();
      last if ($Remaining < 0);
      $Remaining = $Keepalive if ($Keepalive < $Remaining);
    }
    # Add a 5 second leeway to take into account network transmission delays
    $self->SetTimeout($Remaining + 5);

    # Make sure we have the server version
    last if (!$self->{agentversion} and !$self->_Connect());

    # Send the command
    if ($self->{agentversion} =~ / 1\.0$/)
    {
      if (!$self->_StartRPC($RPC_WAIT) or
          !$self->_SendListSize('ArgC', 1) or
          !$self->_SendUInt64('Pid', $Pid))
      {
        last;
      }
    }
    else
    {
      if (!$self->_StartRPC($RPC_WAIT2) or
          !$self->_SendListSize('ArgC', 2) or
          !$self->_SendUInt64('Pid', $Pid) or
          !$self->_SendUInt32('Timeout', $Remaining))
      {
        last;
      }
    }

    # Get the reply
    $Result = $self->_RecvList('I');

    # The process has quit
    last if (defined $Result);

    # The only 'error' we should be getting here is the TestAgent server
    # telling us it timed out waiting for the process. However flaky network
    # connections like to break while we're waiting for the reply. So retry
    # if that happens and let the automatic reconnection detect real network
    # issues.
    last if ($self->{err} !~ /(?:timed out waiting|network read timed out)/);
  }
  $self->SetTimeout($OldTimeout);
  return $Result;
}

sub Rm($@)
{
  my $self = shift @_;
  debug("Rm\n");

  # Send the command
  if (!$self->_StartRPC($RPC_RM) or
      !$self->_SendListSize('Count', scalar(@_)))
  {
    return $self->GetLastError();
  }
  my $i = 0;
  foreach my $Filename (@_)
  {
    return $self->GetLastError() if (!$self->_SendString("File$i", $Filename));
    $i++;
  }

  # Get the reply
  return $self->_RecvErrorList();
}

sub SetTime($)
{
  my ($self) = @_;
  debug("SetTime\n");

  # Send the command
  if (!$self->_StartRPC($RPC_SETTIME) or
      !$self->_SendListSize('ArgC', 2) or
      !$self->_SendUInt64('Time', time()) or
      !$self->_SendUInt32('Leeway', 30))
  {
      return undef;
  }

  # Get the reply
  return $self->_RecvList('');
}

sub GetProperties($;$)
{
  my ($self, $PropName) = @_;
  debug("GetProperties ", $PropName || "", "\n");

  # Send the command
  if (!$self->_StartRPC($RPC_GETPROPERTIES) or
      !$self->_SendListSize('ArgC', 0))
  {
    return undef;
  }

  # Get the reply
  my $Count = $self->_RecvListSize('PropertyCount');
  return undef if (!$Count);

  my $i = 0;
  my $Properties;
  while ($Count--)
  {
    my ($Type, $Size) = $self->_RecvEntryHeader("Prop$i");
    if ($Type eq 's')
    {
      my $Property = $self->_RecvRawString("Prop$i.s", $Size);
      return undef if (!defined $Property);
      debug("  RecvProperty() -> '$Property'\n");
      if ($Property =~ s/^([a-zA-Z0-9.]+(?:\[[0-9]+\])?)=//)
      {
        $Properties->{$1} = $Property;
      }
      else
      {
        $self->_SetError($ERROR, "Invalid property string '$Property'");
        $self->_SkipEntries($Count);
        return undef;
      }
    }
    elsif ($Type eq 'e')
    {
      # The expected property was replaced with an error message
      my $Message = $self->_RecvRawString("Str$i.e", $Size);
      if (defined $Message)
      {
        debug("  RecvError() -> '$Message'\n");
        $self->_SetError($ERROR, $Message);
      }
      $self->_SkipEntries($Count);
      return undef;
    }
    else
    {
      $self->_SetError($ERROR, "Expected an s entry but got $Type instead");
      $self->_SkipRawData("Prop$i.$Type", $Size);
      $self->_SkipEntries($Count);
      return undef;
    }
    $i++;
  }

  return $Properties->{$PropName} if (defined $PropName);
  return $Properties;
}

sub SetProperty($$$)
{
  my ($self, $PropName, $PropValue) = @_;
  debug("SetProperty\n");

  # Send the command
  if (!$self->_StartRPC($RPC_SETPROPERTY) or
      !$self->_SendListSize('ArgC', 2) or
      !$self->_SendString('PropName', $PropName) or
      !$self->_SendString('PropValue', $PropValue))
  {
    return undef;
  }

  # Get the reply
  return $self->_RecvList('');
}

sub Upgrade($$)
{
  my ($self, $Filename) = @_;
  debug("Upgrade $Filename\n");

  my $fh;
  if (!open($fh, "<", $Filename))
  {
      $self->_SetError($ERROR, "Unable to open '$Filename' for reading: $!");
      return undef;
  }

  # Send the command
  if (!$self->_StartRPC($RPC_UPGRADE) or
      !$self->_SendListSize('ArgC', 1) or
      !$self->_SendFile('File', $fh, $Filename))
  {
      close($fh);
      return undef;
  }
  close($fh);

  # Get the reply
  my $rc = $self->_RecvList('');

  # The server has quit and thus the connection is no longer usable.
  # So disconnect now to force the next RPC to reconnect, instead or letting it
  # try to reuse the broken connection and fail.
  $self->Disconnect();

  return $rc;
}

sub Restart($$)
{
  my ($self, $Argv) = @_;

  if (!$Argv || !@$Argv)
  {
    # Restart the server with the same parameters
    my $Properties = $self->GetProperties();
    my $Argc = $Properties->{"server.argc"};
    if (!$Argc)
    {
      $self->_SetError($ERROR, "Could not get the server command line argument count");
      return undef;
    }
    for (my $i = 0; $i < $Argc; $i++)
    {
      my $Arg = $Properties->{sprintf("server.argv[%d]", $i)};
      if (!defined $Arg)
      {
        $self->_SetError($ERROR, "Server argument $i is undefined!");
        return undef;
      }
      push @$Argv, $Arg;
    }
  }
  debug("Restart TestAgentd: '", join("' '", @$Argv), "'\n");

  if (!$self->_StartRPC($RPC_RESTART) or
      !$self->_SendListSize('ArgC', scalar(@$Argv)))
  {
    return undef;
  }
  my $i = 0;
  foreach my $Arg (@$Argv)
  {
    return undef if (!$self->_SendString("Cmd$i", $Arg));
    $i++;
  }

  # Get the reply
  my $rc = $self->_RecvList('');

  # The server has quit and thus the connection is no longer usable.
  # So disconnect now to force the next RPC to reconnect, instead or letting it
  # try to reuse the broken connection and fail.
  $self->Disconnect();

  return $rc;
}

sub RemoveChildProcess($$)
{
  my ($self, $Pid) = @_;
  debug("RmChildProcess $Pid\n");

  # Make sure we have the server version
  return undef if (!$self->{agentversion} and !$self->_Connect());

  # Up to 1.5 a seemingly successful Wait RPC automatically removes child
  # processes.
  return 1 if ($self->{agentversion} =~ / 1\.[0-5]$/);

  # Send the command
  if (!$self->_StartRPC($RPC_RMCHILDPROC) or
      !$self->_SendListSize('ArgC', 1) or
      !$self->_SendUInt64('Pid', $Pid))
  {
      return undef;
  }

  # Get the reply
  return $self->_RecvList('');
}

sub GetCwd($)
{
  my ($self) = @_;
  debug("GetCwd\n");

  # Send the command
  if (!$self->_StartRPC($RPC_GETCWD) or
      !$self->_SendListSize('ArgC', 0))
  {
    return undef;
  }

  # Get the reply
  return $self->_RecvList('s');
}

1;
