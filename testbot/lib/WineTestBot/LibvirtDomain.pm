# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
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

package LibvirtDomain;

=head1 NAME

WineTestBot::LibvirtDomain - A Libvirt VM instance

=head1 DESCRIPTION

This provides methods for starting, stopping, getting the status of the
Libvirt virtual machine, as well as manipulating its snapshots. These methods
are implemented through Sys::Virt to provide portability across virtualization
technologies.

=cut

use Exporter 'import';
our @EXPORT_OK = qw(new);

use Sys::Virt;
use Image::Magick;


my %_Hypervisors;
my %_Domains;


#
# Domain state description
#

my %_StateNameReasons = (
  Sys::Virt::Domain::STATE_NOSTATE => ["no state",
    {
      Sys::Virt::Domain::STATE_NOSTATE_UNKNOWN => "unknown",
    }],
  Sys::Virt::Domain::STATE_RUNNING => ["running",
    {
      Sys::Virt::Domain::STATE_RUNNING_BOOTED => "booted",
      Sys::Virt::Domain::STATE_RUNNING_FROM_SNAPSHOT => "snapshot",
      Sys::Virt::Domain::STATE_RUNNING_MIGRATED => "migrated",
      Sys::Virt::Domain::STATE_RUNNING_MIGRATION_CANCELED => "migration canceled",
      Sys::Virt::Domain::STATE_RUNNING_RESTORED => "restored",
      Sys::Virt::Domain::STATE_RUNNING_SAVE_CANCELED => "save canceled",
      Sys::Virt::Domain::STATE_RUNNING_UNKNOWN => "unknown",
      Sys::Virt::Domain::STATE_RUNNING_UNPAUSED => "unpaused",
      Sys::Virt::Domain::STATE_RUNNING_WAKEUP => "wakeup",
      Sys::Virt::Domain::STATE_RUNNING_CRASHED => "crashed",
      Sys::Virt::Domain::STATE_RUNNING_POSTCOPY => "postcopy",
    }],
  Sys::Virt::Domain::STATE_BLOCKED => ["blocked",
    {
      Sys::Virt::Domain::STATE_BLOCKED_UNKNOWN => "unknown",
    }],
  Sys::Virt::Domain::STATE_PAUSED => ["paused",
    {
      Sys::Virt::Domain::STATE_PAUSED_DUMP => "dump",
      Sys::Virt::Domain::STATE_PAUSED_FROM_SNAPSHOT => "from snapshot",
      Sys::Virt::Domain::STATE_PAUSED_IOERROR => "ioerror",
      Sys::Virt::Domain::STATE_PAUSED_MIGRATION => "migration",
      Sys::Virt::Domain::STATE_PAUSED_SAVE => "save",
      Sys::Virt::Domain::STATE_PAUSED_UNKNOWN => "unknown",
      Sys::Virt::Domain::STATE_PAUSED_USER => "user",
      Sys::Virt::Domain::STATE_PAUSED_WATCHDOG => "watchdog",
      Sys::Virt::Domain::STATE_PAUSED_SHUTTING_DOWN => "shutting down",
      Sys::Virt::Domain::STATE_PAUSED_SNAPSHOT => "snapshot",
      Sys::Virt::Domain::STATE_PAUSED_CRASHED => "crashed",
      Sys::Virt::Domain::STATE_PAUSED_STARTING_UP => "starting up",
      Sys::Virt::Domain::STATE_PAUSED_POSTCOPY => "postcopy",
      Sys::Virt::Domain::STATE_PAUSED_POSTCOPY_FAILED => "postcopy failed",
    }],
  Sys::Virt::Domain::STATE_SHUTDOWN => ["shutdown",
    {
      Sys::Virt::Domain::STATE_SHUTDOWN_UNKNOWN => "unknown",
    }],
  Sys::Virt::Domain::STATE_SHUTOFF => ["shutoff",
    {
      Sys::Virt::Domain::STATE_SHUTOFF_CRASHED => "crashed",
      Sys::Virt::Domain::STATE_SHUTOFF_DESTROYED => "destroyed",
      Sys::Virt::Domain::STATE_SHUTOFF_FAILED => "failed",
      Sys::Virt::Domain::STATE_SHUTOFF_FROM_SNAPSHOT => "from snapshot",
      Sys::Virt::Domain::STATE_SHUTOFF_MIGRATED => "migrated",
      Sys::Virt::Domain::STATE_SHUTOFF_SAVED => "saved",
      Sys::Virt::Domain::STATE_SHUTOFF_SHUTDOWN => "shutdown",
      Sys::Virt::Domain::STATE_SHUTOFF_UNKNOWN => "unknown",
      Sys::Virt::Domain::STATE_SHUTOFF_DAEMON => "daemon",
    }],
  Sys::Virt::Domain::STATE_CRASHED => ["crashed",
    {
      Sys::Virt::Domain::STATE_CRASHED_UNKNOWN => "unknown",
      Sys::Virt::Domain::STATE_CRASHED_PANICKED => "panicked",
    }],
  Sys::Virt::Domain::STATE_PMSUSPENDED => ["pmsuspended",
    {
      Sys::Virt::Domain::STATE_PMSUSPENDED_UNKNOWN => "unknown",
      Sys::Virt::Domain::STATE_PMSUSPENDED_DISK_UNKNOWN => "disk unknown",
    }],
);

=pod
=over 12

=item C<_GetStateDescription()>

Provides a description of the domain state for diagnostics.

=back
=cut

sub _GetStateDescription($$)
{
  my ($State, $Reason) = @_;

  my $StateInfo = $_StateNameReasons{$State};
  my ($StateName, $ReasonName);
  if ($StateInfo)
  {
    $StateName = $StateInfo->[0];
    $ReasonName = $StateInfo->[1]->{$Reason};
  }

  return join(":", $StateName || sprintf("%d", $State),
                   $ReasonName || sprintf("%d", $Reason));
}


#
# LibvirtDomain class
#

sub new($$)
{
  my ($class, $VM) = @_;

  my $self = { VM => $VM };
  $self = bless $self, $class;
  return $self;
}

=pod
=over 12

=item C<_Reset()>

Resets the connection to this domain's hypervisor. This is meant to be invoked
after an error to ensure we will start from a clean connection next time,
rather than keep using a broken or stuck connection.

=back
=cut

sub _Reset($;)
{
  my $self = shift @_;

  my $VirtURI = $self->{VM}->VirtURI;
  delete $_Domains{$VirtURI};
  delete $_Hypervisors{$VirtURI};
  return $_[0] if (!wantarray() and scalar(@_) == 1);
  return @_;
}


=pod
=over 12

=item C<_eval_err()>

Returns the message for whichever error happened inside the eval block,
be it a LibVirt error or a perl one.

=back
=cut

sub _eval_err()
{
  return ref($@) ? $@->message() : $@;
}

=pod
=over 12

=item C<_GetHypervisor()>

Creates, caches and returns the Libvirt connection to the hypervisor.

=back
=cut

sub _GetHypervisor($)
{
  my ($self) = @_;

  my $URI = $self->{VM}->VirtURI;
  my $Hypervisor = $_Hypervisors{$URI};
  if (!$Hypervisor)
  {
    eval { $Hypervisor = Sys::Virt->new(uri => $URI) };
    return (_eval_err(), undef) if ($@);

    $_Hypervisors{$URI} = $Hypervisor;
  }
  return (undef, $Hypervisor);
}

=pod
=over 12

=item C<_GetDomain()>

Creates, caches and returns the Libvirt Domain object.

If an error occurs this resets the hypervisor connection.

=back
=cut

sub _GetDomain($)
{
  my ($self) = @_;

  my $URI = $self->{VM}->VirtURI;
  my $Name = $self->{VM}->VirtDomain;
  my $Domain = $_Domains{$URI}->{$Name};
  if (!$Domain)
  {
    my ($ErrMessage, $Hypervisor) = $self->_GetHypervisor();
    return ($ErrMessage, undef) if (defined $ErrMessage);

    eval { $Domain = $Hypervisor->get_domain_by_name($Name) };
    return $self->_Reset(_eval_err(), undef) if ($@);

    $_Domains{$URI}->{$Name} = $Domain;
  }
  return (undef, $Domain);
}

sub _GetSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  my $Snapshot;
  eval
  {
    # Work around the lack of get_snapshot_by_name() in older libvirt versions.
    foreach my $Snap ($Domain->list_snapshots())
    {
      if ($Snap->get_name() eq $SnapshotName)
      {
        $Snapshot = $Snap;
        last;
      }
    }
  };
  return (undef, $Domain, $Snapshot) if ($Snapshot);

  return (_eval_err() || "Snapshot '$SnapshotName' not found", undef, undef);
}

sub HasSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain, $Snapshot) = $self->_GetSnapshot($SnapshotName);
  return $ErrMessage ? 0 : 1;
}

sub GetSnapshotName($)
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return ($ErrMessage, undef) if (defined $ErrMessage);

  my $SnapshotName;
  eval
  {
    if ($Domain->has_current_snapshot())
    {
      my $Snapshot = $Domain->current_snapshot();
      $SnapshotName = $Snapshot->get_name() if ($Snapshot);
    }
  };
  return $self->_Reset(_eval_err(), undef) if ($@);

  return (undef, $SnapshotName);
}

sub RevertToSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain, $Snapshot) = $self->_GetSnapshot($SnapshotName);
  return ($ErrMessage, undef) if (defined $ErrMessage);

  # Note that if the snapshot was of a powered off domain, this boots it up
  eval { $Snapshot->revert_to(Sys::Virt::DomainSnapshot::REVERT_RUNNING) };
  return $self->_Reset(_eval_err(), undef) if ($@);

  my ($State, $Reason) = $Domain->get_state();
  if ($State != Sys::Virt::Domain::STATE_RUNNING)
  {
    return ($self->{VM}->Name ." is not running (".
            _GetStateDescription($State, $Reason)
            .") after revert to $SnapshotName", undef);
  }
  return (undef, $Reason != Sys::Virt::Domain::STATE_RUNNING_FROM_SNAPSHOT);
}

sub CreateSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  # FIXME: XML escaping
  my $Xml = "<domainsnapshot><name>$SnapshotName</name></domainsnapshot>";
  eval { $Domain->create_snapshot($Xml, 0) };
  return $@ ? $self->_Reset(_eval_err()) : undef;
}

sub RemoveSnapshot($)
{
  my ($self) = @_;

  my $SnapshotName = $self->{VM}->IdleSnapshot;
  my ($ErrMessage, $_Domain, $Snapshot) = $self->_GetSnapshot($SnapshotName);
  return $ErrMessage if (defined $ErrMessage);

  eval { $Snapshot->delete(0) };
  return $@ ? $self->_Reset(_eval_err()) : undef;
}

sub IsPoweredOn($)
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  if (defined $ErrMessage)
  {
    $@ = $ErrMessage;
    return undef;
  }

  my ($State, $_Reason);
  eval { ($State, $_Reason) = $Domain->get_state() };
  return $self->_Reset(undef) if ($@);
  return ($State == Sys::Virt::Domain::STATE_RUNNING);
}

sub IsReady($)
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  if (defined $ErrMessage)
  {
    $@ = $ErrMessage;
    return undef;
  }

  my ($State, $_Reason);
  eval { ($State, $_Reason) = $Domain->get_state() };
  return $self->_Reset(undef) if ($@);
  return ($State == Sys::Virt::Domain::STATE_RUNNING or
          $State == Sys::Virt::Domain::STATE_SHUTOFF or
          $State == Sys::Virt::Domain::STATE_CRASHED or
          $State == Sys::Virt::Domain::STATE_PMSUSPENDED
      );
}

sub GetStateDescription($)
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  my ($State, $Reason);
  eval { ($State, $Reason) = $Domain->get_state() };
  return $self->_Reset($@) if ($@);
  return _GetStateDescription($State, $Reason)
}

sub PowerOff($)
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  eval { $Domain->destroy() };
  return undef if (!$@); # Success
  $ErrMessage = _eval_err();

  # destroy() sets $@->code to Sys::Virt::Error::ERR_OPERATION_INVALID (55)
  # if the domain was already off. But this could happen for other reasons so
  # just check the domain state.
  my ($State, $Reason);
  eval { ($State, $Reason) = $Domain->get_state() };
  if ($@)
  {
    # Only return the initial error
    return $self->_Reset("Could not power off ". $self->{VM}->Name .": $ErrMessage");
  }
  if ($State == Sys::Virt::Domain::STATE_SHUTOFF)
  {
    # This is what we wanted so ignore past errors
    return undef;
  }
  return $self->_Reset($self->{VM}->Name ." is not off (". _GetStateDescription($State, $Reason)  ."): $ErrMessage");
}

my %_StreamData;

sub _Stream2Image($$$)
{
  my ($Stream, $Data, $Size) = @_;
  my $Image = $_StreamData{$Stream};
  $Image->{Size} += $Size;
  $Image->{Bytes} .= $Data;
  return $Size;
}

sub CaptureScreenImage($)
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return ($ErrMessage, undef, undef) if (defined $ErrMessage);

  my $Hypervisor;
  ($ErrMessage, $Hypervisor) = $self->_GetHypervisor();
  return ($ErrMessage, undef, undef) if (defined $ErrMessage);

  my $Stream;
  my $Image = {Size => 0, Bytes => ""};
  eval
  {
    $Stream = $Hypervisor->new_stream(0);
    if ($Stream)
    {
      $_StreamData{$Stream} = $Image;
      $Domain->screenshot($Stream, 0, 0);
      $Stream->recv_all(\&LibvirtDomain::_Stream2Image);
      $Stream->finish();
    }
  };
  delete $_StreamData{$Stream} if ($Stream);
  return $self->_Reset(_eval_err(), undef, undef) if ($@);

  # The screenshot format depends on the hypervisor (e.g. PPM for QEmu)
  # but callers expect PNG images.
  my $image=Image::Magick->new();
  my ($width, $height, $size, $format) = $image->Ping(blob => $Image->{Bytes});
  if ($format ne "PNG")
  {
    my @blobs = ($Image->{Bytes});
    $image->BlobToImage(@blobs);
    $Image->{Bytes} = ($image->ImageToBlob(magick => 'png'))[0];
    $Image->{Size} = length($Image->{Bytes});
  }
  return (undef, $Image->{Size}, $Image->{Bytes});
}

1;
