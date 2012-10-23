# Copyright 2009 Ge van Geldorp
# Copyright 2012 Francois Gouget
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

package WineTestBot::VM::Hypervisors;

=head1 NAME

WineTestBot::VM::Hypervisors - A cache of hypervisor objects

=head1 DESCRIPTION

A hypervisor is the software running on the host that handles the hardware
virtualisation in support of the VMs. Thus each host has its own hypervisor,
but some may have more than one, typically if more than one virtualisation
software is used such as QEmu and VirtualBox.

WineTestBot typically needs to deal with many VMs spread across a few hosts to
spread the load and thus a few hypervisors. WineTestBot identifies the
hypervisors via their VirtURI from which we get a Sys::Virt hypervisor.
This class caches these  objects so only one is created per URI.

=cut

use WineTestBot::Config;

use vars qw (@ISA @EXPORT_OK);

require Exporter;
@ISA = qw(Exporter);

@EXPORT_OK = qw(new);

sub new($)
{
  my ($class) = @_;

  my $self = {};
  $self = bless $self, $class;
  return $self;
}

=pod
=over 12

=head1 C<GetHypervisor()>

Returns the Sys::Virt hypervisor object corresponding to the specified URI.
This object is cached so only one hypervisor object is created per URI.

=back
=cut

sub GetHypervisor($$)
{
  my ($self, $URI) = @_;

  my $Key = $URI || "";
  if (!defined $self->{$Key})
  {
      eval { $self->{$Key} = Sys::Virt->new(uri => $URI); };
      return ($@->message(), undef) if ($@);
  }

  return (undef, $self->{$Key});
}


package WineTestBot::VM;

=head1 NAME

WineTestBot::VM - A VM instance

=head1 DESCRIPTION

This provides methods for starting, stopping, getting the status of the VM,
as well as manipulating its snapshots. These methods are implemented through
Sys::Virt to provide portability across virtualization technologies.

This class also provides methods to copy files to or from the VM and running
commands in it. This part is used to start the tasks in the VM but is
implemented independently from the VM's hypervisor since most do not provide
this functionality.

The VM type defines what the it can do:

=over 12

=item build

This is a Unix VM that can build the 32-bit and 64-bit Windows test binaries.

=item win32

This is a 32-bit Windows VM that can run the 32-bit tests.

=item win64

This is a 64-bit Windows VM that can run both the 32-bit and 64-bit tests.

=back


The VM role defines what we use it for:

=over 12

=item retired

A retired VM is no longer used at all. No new jobs can be scheduled to run on
them.

=item base

A base VM is used for every suitable task. This is the only role that build VMs
can play besides retired. For Windows VMs, this means that it will run the
WineTest jobs, the wine-patches jobs, and also the manually submitted jobs
unless the submitter decided otherwise.

=item winetest

This is only valid for Windows VMs. By default these VMs only run the WineTest
jobs. They can also be selected for manually submitted jobs.

=item extra

This is only valid for Windows VMs. They are only used if selected for a
manually submitted job.

=back


A VM typically goes through the following states in this order:

=over 12

=item reverting

The VM is currently being reverted to the idle snapshot. Note that the idle
snapshot is supposed to be taken on a powered on VM so this also powers on the
VM.

=item sleeping

The VM has been reverted to the idle snapshot and we are now letting it settle
down for $SleepAfterRevert seconds (for instance so it gets time to renew its
DHCP leases). It is not running a task yet.

=item idle

The VM powered on and is no longer in its sleeping phase. So it is ready to be
given a task.

=item running

The VM is running some task.

=item dirty

The VM has completed the task it was given and thus has been powered off. The
next step will be to revert it to the idle snapshot so it can be used again.

=item offline

This VM should not be used. The WineTestBot automatically puts VMs into this
state if errors happen when manipulating them, such as if they fail to revert,
etc. The main web status page has a warning indicator on when some VMs are
offline.

=back

=cut

use Sys::Virt;
use Image::Magick;

use ObjectModel::BackEnd;
use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::TestAgent;
use WineTestBot::WineTestBotObjects;
use WineTestBot::Log;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub _initialize($$)
{
  my ($self, $VMs) = @_;

  $self->{Hypervisors} = $VMs->{Hypervisors};
  $self->{Hypervisor} = undef;
  $self->{Domain} = undef;
  $self->{OldStatus} = undef;
}

sub InitializeNew
{
  my $self = shift;

  $self->Status("Idle");
  $self->IdleSnapshot("winetest_on");

  $self->SUPER::InitializeNew(@_);
}

sub GetHost($)
{
  my ($self) = @_;

  # The URI is of the form protocol://user@hostname/hypervisor-specific-data
  return $1 if ($self->VirtURI =~ m%^[^:]+://(?:[^/@]*@)?([^/]+)/%);
  return "localhost";
}

sub _GetDomain($)
{
  my ($self) = @_;

  if (!defined $self->{Domain})
  {
    my ($ErrMessage, $Hypervisor) = $self->{Hypervisors}->GetHypervisor($self->VirtURI);
    return ($ErrMessage,  undef) if (defined $ErrMessage);

    $self->{Hypervisor} = $Hypervisor;
    eval { $self->{Domain} = $self->{Hypervisor}->get_domain_by_name($self->VirtDomain) };
    return ($@->message(), undef) if ($@);
  }
  return (undef, $self->{Domain});
}

sub UpdateStatus($$)
{
  my ($self, $Domain) = @_;

  if ($self->Status eq "offline")
  {
    return undef;
  }

  my ($State, $Reason) = $Domain->get_state();
  return $@->message() if ($@);
  if ($State == Sys::Virt::Domain::STATE_SHUTDOWN or
      $State == Sys::Virt::Domain::STATE_SHUTOFF)
  {
    $self->Status("dirty");
    $self->Save();
  }

  return undef;
}

sub _GetSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  my $Snapshot;
  eval { $Snapshot = $Domain->get_snapshot_by_name($SnapshotName) };
  return ($@->message(), undef, undef) if ($@);
  return (undef, $Domain, $Snapshot);
}

sub RevertToSnapshot($$)
{
  my ($self, $SnapshotName) = @_;
  LogMsg("Reverting ", $self->VirtDomain, " to $SnapshotName\n");

  my ($ErrMessage, $Domain, $Snapshot) = $self->_GetSnapshot($SnapshotName);
  return $ErrMessage if (defined $ErrMessage);
  eval { $Snapshot->revert_to(Sys::Virt::DomainSnapshot::REVERT_RUNNING) };
  return $@->message() if ($@);

  return $self->UpdateStatus($Domain);
}

sub CreateSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  # FIXME: XML escaping
  my $Xml = "<domainsnapshot><name>$SnapshotName</name></domainsnapshot>";
  eval { $Domain->create_snapshot($Xml, 0) };
  return $@->message() if ($@);
  return undef;
}

sub RemoveSnapshot($$)
{
  my ($self, $SnapshotName) = @_;

  my ($ErrMessage, $Domain, $Snapshot) = $self->_GetSnapshot($SnapshotName);
  return $ErrMessage if (defined $ErrMessage);

  eval { $Snapshot->delete(0) };
  return $@->message() if ($@);
  return undef;
}

sub PowerOn
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  eval { $Domain->create(0) };
  return $@->message() if ($@);

  return $self->UpdateStatus($Domain);
}

sub PowerOff
{
  my ($self) = @_;

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return $ErrMessage if (defined $ErrMessage);

  eval { $Domain->destroy() };
  return $@->message() if ($@);

  return $self->UpdateStatus($Domain);
}

sub WaitForToolsInGuest($;$)
{
  my ($self, $Timeout) = @_;

  $Timeout ||= $WaitForToolsInVM;
  LogMsg("Waiting for ", $self->Name, " (up to ${Timeout}s)\n");
  my ($Status, $Err) = TestAgent::GetStatus($self->Hostname, $Timeout);
  # In fact we don't care about the status
  return $Err;
}

sub CopyFileFromHostToGuest($$$)
{
  my ($self, $HostPathName, $GuestPathName) = @_;
  return TestAgent::SendFile($self->Hostname,  $HostPathName, $GuestPathName);
}

sub CopyFileFromGuestToHost($$$)
{
  my ($self, $GuestPathName, $HostPathName) = @_;
  return TestAgent::GetFile($self->Hostname,  $GuestPathName, $HostPathName);
}

sub RunScriptInGuestTimeout($$$)
{
  my ($self, $ScriptText, $Timeout) = @_;
  return TestAgent::RunScript($self->Hostname, $ScriptText, $Timeout);
}

my %StreamData;

sub _Stream2Image($$$)
{
    my ($Stream, $Data, $Size) = @_;
    my $Image=$StreamData{$Stream};
    $Image->{Size} += $Size;
    $Image->{Bytes} .= $Data;
    return $Size;
}

sub CaptureScreenImage($)
{
  my ($self) = @_;
  LogMsg("CaptureScreenImage ", $self->Name, "\n");

  my ($ErrMessage, $Domain) = $self->_GetDomain();
  return ($ErrMessage, undef, undef) if (defined $ErrMessage);

  my $Stream;
  eval { $Stream = $self->{Hypervisor}->new_stream(0) };
  return ($@->message(), undef, undef) if ($@);

  my $Image={Size => 0, Bytes => ""};
  $StreamData{$Stream}=$Image;
  eval {
    $Domain->screenshot($Stream, 0, 0);
    $Stream->recv_all(\&WineTestBot::VM::_Stream2Image);
    $Stream->finish();
  };
  delete $StreamData{$Stream};
  return ($@->message(), undef, undef) if ($@);

  # The screenshot format depends on the hypervisor (e.g. PPM for QEmu)
  # but callers expect PNG images.
  my $image=Image::Magick->new();
  my ($width, $height, $size, $format) = $image->Ping(blob => $Image->{Bytes});
  if ($format ne "PNG")
  {
    my @blobs=($Image->{Bytes});
    $image->BlobToImage(@blobs);
    $Image->{Bytes}=($image->ImageToBlob(magick => 'png'))[0];
    $Image->{Size}=length($Image->{Bytes});
  }
  return (undef, $Image->{Size}, $Image->{Bytes});
}

sub Status
{
  my $self = shift;

  my $CurrentStatus = $self->SUPER::Status;
  if (! @_)
  {
    return $CurrentStatus;
  }

  my $NewStatus = $_[0];
  if ($NewStatus ne $CurrentStatus)
  {
    $self->SUPER::Status($NewStatus);
    $self->{OldStatus} = $CurrentStatus;
  }

  return $NewStatus;
}

sub Validate
{
  my $self = shift;

  if ($self->Type ne "win32" && $self->Type ne "win64" &&
      ($self->Role eq "winetest" || $self->Role eq "extra"))
  {
      return ("Role", "Only win32 and win64 VMs can have a role of '" . $self->Role . "'");
  }
  return $self->SUPER::Validate(@_);
}

sub OnSaved
{
  my $self = shift;

  $self->SUPER::OnSaved(@_);

  if (defined($self->{OldStatus}))
  {
    my $NewStatus = $self->Status;
    if ($NewStatus ne $self->{OldStatus})
    {
      VMStatusChange($self->GetKey(), $self->{OldStatus}, $NewStatus);
    }
  }
}

sub RunRevert
{
  my $self = shift;

  $self->Status("reverting");
  $self->Save();

  $self->GetBackEnd()->PrepareForFork();
  my $Pid = fork;
  if (defined($Pid) && ! $Pid)
  {
    $ENV{PATH} = "/usr/bin:/bin";
    delete $ENV{ENV};
    exec("$BinDir/RevertVM.pl", $self->GetKey());
    exit;
  }
  if (! defined($Pid))
  {
    return "Unable to start child process: $!";
  }

  return undef;
}


package WineTestBot::VMs;

=head1 NAME

WineTestBot::VMs - A VM collection

=head1 DESCRIPTION

This is the collection of VMs the testbot knows about, no matter their type,
role or status.

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::EnumPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateVMs);

sub _initialize
{
  my $self = shift;
  $self->{Hypervisors} = WineTestBot::VM::Hypervisors->new();
  $self->SUPER::_initialize(@_);
}

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Name", "VM name", 1, 1, "A", 20),
    CreateBasicPropertyDescriptor("SortOrder", "Display order", !1, 1, "N", 3),
    CreateEnumPropertyDescriptor("Type", "Type of VM", !1, 1, ['win32', 'win64', 'build']),
    CreateEnumPropertyDescriptor("Role", "VM Role", !1, 1, ['extra', 'base', 'winetest', 'retired']),
    CreateEnumPropertyDescriptor("Status", "Current status", !1, 1, ['dirty', 'reverting', 'sleeping', 'idle', 'running', 'offline']),
    CreateBasicPropertyDescriptor("VirtURI", "LibVirt URI of the VM", !1, 1, "A", 64),
    CreateBasicPropertyDescriptor("VirtDomain", "LibVirt Domain for the VM", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("IdleSnapshot", "Name of idle snapshot", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("Hostname", "The VM hostname", !1, 1, "A", 64),
    CreateBasicPropertyDescriptor("Description", "Description", !1, !1, "A", 40),
  );
}

sub CreateItem
{
  my $self = shift;

  return WineTestBot::VM->new($self);
}

sub CreateVMs
{
  return WineTestBot::VMs::->new("VMs", "VMs", "VM", \@PropertyDescriptors);
}

sub CountRevertingRunningVMs
{
  my $self = shift;

  my $RevertingVMs = 0;
  my $RunningVMs = 0;

  foreach my $VMKey (@{$self->GetKeys()})
  {
    my $VMStatus = $self->GetItem($VMKey)->Status;

    if ($VMStatus eq "reverting")
    {
      $RevertingVMs++;
    }
    if ($VMStatus eq "running")
    {
      $RunningVMs++;
    }
  }

  return ($RevertingVMs, $RunningVMs);
}

sub CountPoweredOnNonBaseVMs
{
  my $self = shift;

  my $PowerdOnVMs = 0;
  foreach my $VMKey (@{$self->GetKeys()})
  {
    my $VM = $self->GetItem($VMKey);
    my $VMStatus = $VM->Status;

    if ($VM->Role ne "base" &&
        ($VMStatus eq "reverting" ||
         $VMStatus eq "sleeping" ||
         $VMStatus eq "idle" ||
         $VMStatus eq "running"))
    {
      $PowerdOnVMs++;
    }
  }

  return $PowerdOnVMs;
}

sub SortKeysBySortOrder
{
  my $self = shift;
  my $Keys = $_[0];

  my %SortOrder;
  foreach my $Key (@$Keys)
  {
    $SortOrder{$Key} = $self->GetItem($Key)->SortOrder;
  }

  my @SortedKeys = sort { $SortOrder{$a} <=> $SortOrder{$b} } @$Keys;
  return \@SortedKeys;
}

sub FilterHypervisor
{
  my $self = shift;
  my $Hypervisor = $_[0];

  $self->AddFilter("VirtURI", $Hypervisor);
}

1;
